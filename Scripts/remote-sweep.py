#!/usr/bin/env python3
"""Run a sweep of `blastmodel` studies on a Linux host (or here), and compare two sweeps' results.

    python3 -I Scripts/remote-sweep.py run <host|--here> <sweep.json> [--cores 16] [--wait 30m] [--results DIR]
    python3 -I Scripts/remote-sweep.py compare <results-A> <results-B> [--tolerance 1e-9]
    python3 -I Scripts/remote-sweep.py test <host> <Suite>[,<Suite>…] [--cores 16] [--wait 0]

A sweep (JSON) names its cases, each the arguments of one `blastmodel` command, and the files they
read:

    {"name": "protect-masses",
     "inputs": ["/Volumes/StudioData/bombcad/glass-strength/protect.json", ...],
     "cases": [{"name": "2t", "args": ["protect", "--osm", "{repo}/Fixtures/SyntheticDistrict/district.osm",
                                       "--inputs", "/Volumes/StudioData/bombcad/glass-strength/protect.json",
                                       "--out", "{out}/plans.json"]}]}

In the arguments, `{repo}` is the repository's copy, `{out}` the case's output folder, and any
argument naming one of the inputs (or a file under an input folder) is taken to the host's copy.

`run` and `test` first send a verified source/input/tool snapshot to a fresh
~/bombcad-sweeps/staging/<invocation>/ directory. Only after taking the host lock may a worker
activate that source in the reusable ~/bombcad-sweeps/src build checkout. Inputs and results
remain invocation-private. Source, input, tool and request changes are refused; generated
build/Git/bytecode metadata is excluded only from source/tools, never declared payloads.
A live worker or its non-zombie orphaned process group
retains ownership. TERM/HUP/INT drains owned children before unlocking.

Each case runs on --cores of the host's CPUs (16 by default). Results return to
<results>/<sweep>-<host>/, with invocation and retrieval receipts; an existing destination is
never merged or overwritten, and failed retrieval is failure.

Stages are pruned by the worker as it finishes, under the lock (or by `prune` by hand): the newest
4 are kept, with the source basis, a run's results until they are retrieved (14 days at most),
and anything staged or interrupted in the last 2 days; the rest go. The build checkout is one
folder, reused. Nothing is sent to a host that would be left under 50 GB free, or 15% of a
smaller disk, on its home's disk or (inside WSL) the Windows drive holding WSL's disk image.

    python3 -I Scripts/remote-sweep.py prune <host> [--dry-run]

    python3 -I Scripts/remote-sweep.py resume HOST INVOCATION [--wait 30m] [--results NEW-BASE]

Resume sends no current sources or inputs. It can start a staged-but-not-started invocation or
reuse a verified completion without rebuilding/rerunning. Interrupted partial work is retained
and refused for automatic replay; use a fresh invocation for an explicit retry. A pending/live
worker still owns its lock: observe its existing handle, do not restart on an observation timeout.
With --here, the ordinary local worktree/build is used as before.

`compare` sets two sweeps' results side by side, file by file in each case's folder: the same
bytes, or for JSON the same structure with numbers within `--tolerance` (relative), or for text
the same lines once times ("in 12.3 s") are left out. Exit 0 if every file agrees.

`test` is the Linux lane of `check-affected`: BlastModel's test suites named, built and run on the
host under the same lock and cores, from this worktree's copy there, their output streamed back.
Its exit status is the tests'; 69 (the host unreachable), 75 (its lock taken), 73 (too short of
space) or 255 (the connection lost) say the lane was not there, and the suites should run here.

Exit status of `run`: the first failing case's, 69 if the host could not be reached, 75 if its lock
stayed taken. Nothing on the host but ~/bombcad-sweeps is touched: not the training runner's
~/bombcad-ml or its lock.
"""
import importlib.util
import hashlib
import contextlib
import fcntl
import json
import os
import re
import shlex
import shutil
import signal
import subprocess
import sys
import time
import uuid
from pathlib import Path

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
ROOT = "bombcad-sweeps"  # under the host's home
RESULTS = "/Volumes/StudioData/bombcad/sweeps"
SWIFT_PATHS = "$HOME/.local/share/swiftly/bin"
UNREACHABLE, TAKEN, NOSPACE = 69, 75, 73
# What says the lane was not there (the host, its lock, its space, the connection), rather than a
# test failing.
LANE_DOWN = {UNREACHABLE, TAKEN, NOSPACE, 255}
# Staging's retention: the newest stages kept whatever they are; how long a stage staged or
# interrupted is kept (resumable), and a run's results not yet retrieved.
KEEP_STAGES = 4
PENDING_SECONDS = 2 * 86400
UNRETRIEVED_SECONDS = 14 * 86400
EXCLUDED = {".build", ".git", ".claude", "dist", "__pycache__", ".DS_Store", ".pytest_cache"}


def invocation_path(invocation):
    if not re.fullmatch(r"[0-9a-f]{32}", invocation):
        raise ValueError("invalid invocation identity")
    return ROOT + "/staging/" + invocation


def tree_manifest(folder, excluded=()):
    """All payload entries by default; source/tool callers explicitly exclude generated products."""
    base = Path(folder).resolve()
    result = {}
    for directory, dirs, files in os.walk(base):
        dirs[:] = sorted(d for d in dirs if d not in excluded)
        for name in sorted(dirs + [f for f in files if f not in excluded]):
            path = Path(directory) / name
            relative = str(path.relative_to(base))
            if path.is_symlink():
                target = os.readlink(path)
                if os.path.isabs(target) or base not in path.resolve(strict=True).parents:
                    raise ValueError("snapshot link must remain inside its tree: " + str(path))
                result[relative] = {"link": target}
            elif path.is_file():
                digest = hashlib.sha256()
                with path.open("rb") as handle:
                    for block in iter(lambda: handle.read(1024 * 1024), b""):
                        digest.update(block)
                result[relative] = {"sha256": digest.hexdigest(), "mode": path.stat().st_mode & 0o777}
            elif path.is_dir():
                result[relative] = {"directory": True}
            else:
                raise ValueError("unsupported snapshot entry: " + str(path))
    return result


def atomic_json(path, value):
    temporary = str(path) + "." + uuid.uuid4().hex
    with open(temporary, "w") as handle:
        json.dump(value, handle, sort_keys=True)
    os.replace(temporary, path)


def snapshot_root(options):
    return os.path.join(os.path.expanduser("~"), invocation_path(options["invocation"]))


def completed_code(options, stage):
    with open(os.path.join(stage, "completion.json")) as handle:
        receipt = json.load(handle)
    if receipt.get("invocation") != options["invocation"] or type(receipt.get("exitCode")) is not int:
        raise ValueError("invalid completion identity/status")
    if options.get("kind") == "run" and tree_manifest(os.path.join(stage, "results")) != receipt.get("results"):
        raise ValueError("completed results changed")
    print("remote-sweep: cached completion %s exit %d" % (options["invocation"], receipt["exitCode"]), flush=True)
    return receipt["exitCode"]


def verify_snapshot(options):
    stage = snapshot_root(options)
    with open(os.path.join(stage, "manifest.json")) as handle:
        expected = json.load(handle)
    for tree in ("src", "inputs", "tools"):
        if tree_manifest(os.path.join(stage, tree), EXCLUDED if tree in ("src", "tools") else ()) != expected[tree]:
            raise ValueError("staged snapshot changed: " + tree)
    with open(os.path.join(stage, "request.json")) as handle:
        request = json.load(handle)
        if request != expected["request"]:
            raise ValueError("staged request changed")
        if {k: v for k, v in request.items() if k != "wait"} != {k: v for k, v in options.items() if k != "wait"}:
            raise ValueError("request differs from staged invocation")
    return stage, expected


def activate_snapshot(options):
    """Called only after host ownership: verify staging, update the reusable build checkout."""
    stage, expected = verify_snapshot(options)
    repo = os.path.join(os.path.expanduser("~"), ROOT, "src")
    os.makedirs(repo, exist_ok=True)
    copied = subprocess.run(["rsync", "-a", "--checksum", "--delete", *sum((["--exclude", x] for x in sorted(EXCLUDED)), []),
                             os.path.join(stage, "src") + "/", repo + "/"], stdin=subprocess.DEVNULL)
    if copied.returncode or tree_manifest(repo, EXCLUDED) != expected["src"]:
        raise ValueError("build checkout differs from staged source")
    return repo, stage


def group_members(pgid):
    """Non-zombie members; orphan children retain sweep ownership after their parent dies."""
    if os.path.isdir("/proc"):
        members = []
        for name in os.listdir("/proc"):
            if not name.isdigit():
                continue
            try:
                fields = Path("/proc", name, "stat").read_text().rsplit(")", 1)[1].split()
                if int(fields[2]) == pgid and fields[0] != "Z":
                    members.append(int(name))
            except (OSError, ValueError, IndexError):
                continue
        return members
    probe = subprocess.Popen(["ps", "-axo", "pid=,pgid=,stat="], stdout=subprocess.PIPE, text=True)
    output, _ = probe.communicate()
    if probe.returncode:
        raise RuntimeError("cannot verify sweep process group")
    return [int(p) for p, group, state in (line.split() for line in output.splitlines())
            if int(p) != probe.pid and int(group) == pgid and not state.startswith("Z")]


def sweep_owner(lock, boot):
    try:
        with open(os.path.join(lock, "owner")) as handle:
            owner = json.load(handle)
    except (OSError, ValueError):
        return runner.lock_owner(lock, boot)
    if owner.get("boot") == boot and owner.get("pgid"):
        if group_members(owner["pgid"]):
            return owner
        runner.release(lock, pid=owner["pid"])
        return None
    return runner.lock_owner(lock, boot)


@contextlib.contextmanager
def ownership_guard(lock, blocking=True):
    """Serialize directory-lease reclamation/acquisition/release, including stale-owner races."""
    os.makedirs(os.path.dirname(lock), exist_ok=True)
    with open(lock + ".guard", "a") as handle:
        fcntl.flock(handle, fcntl.LOCK_EX | (0 if blocking else fcntl.LOCK_NB))
        try:
            yield
        finally:
            fcntl.flock(handle, fcntl.LOCK_UN)


def release_sweep(lock):
    if os.getpgrp() == os.getpid():
        deadline = time.monotonic() + 5
        while [p for p in group_members(os.getpgrp()) if p != os.getpid()]:
            if time.monotonic() >= deadline:
                # Kill our whole group, including this worker. Keep the lock for stale-group
                # recovery; never unlock while an owned child can still mutate the cache.
                os.killpg(os.getpgrp(), signal.SIGKILL)
            time.sleep(0.05)
    with ownership_guard(lock):
        runner.release(lock)


def prepare_worker():
    try:
        os.setpgid(0, 0)
    except PermissionError:
        if os.getpgrp() != os.getpid():
            raise

    def interrupted(signum, frame):
        for name in (signal.SIGHUP, signal.SIGTERM, signal.SIGINT):
            signal.signal(name, signal.SIG_IGN)
        os.killpg(os.getpgrp(), signal.SIGTERM)
        raise SystemExit(128 + signum)

    for name in (signal.SIGHUP, signal.SIGTERM, signal.SIGINT):
        signal.signal(name, interrupted)


def _runner():
    """Scripts/ml/remote-train.py, whose lock (live owner, this boot) and SSH settings these share."""
    path = os.path.join(HERE, "ml", "remote-train.py")
    if not os.path.exists(path):  # on the host, sent beside this file
        path = os.path.join(HERE, "remote-train.py")
    spec = importlib.util.spec_from_file_location("remote_train", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


runner = _runner()
SSH = runner.SSH


def duration(text):
    return runner.duration(text)


# MARK: - Cases

def localize(args, inputs, repo, out, inputs_dir):
    """`args` for a machine whose repository copy is `repo`, the case's output folder `out` and the
    inputs under `inputs_dir`, each input `inputs[k]` there by its base name."""
    mapped = []
    for arg in args:
        arg = arg.replace("{repo}", repo).replace("{out}", out)
        for source in inputs:
            source = source.rstrip("/")
            if inputs_dir is not None and (arg == source or arg.startswith(source + "/")):
                arg = os.path.join(inputs_dir, os.path.basename(source)) + arg[len(source):]
                break
        mapped.append(arg)
    return mapped


def run_cases(sweep, repo, binary, out_root, inputs_dir, cores, log):
    """Runs each case with `binary`, its output in out_root/<case>/: (record, first failing exit)."""
    records, failed = [], 0
    for case in sweep["cases"]:
        out = os.path.join(out_root, case["name"])
        os.makedirs(out, exist_ok=True)
        args = localize(case["args"], sweep.get("inputs", []), repo, out, inputs_dir)
        command = [binary] + args
        if cores and shutil.which("taskset"):
            command = ["taskset", "-c", "0-%d" % (cores - 1)] + command
        log("case %s: %s" % (case["name"], " ".join(shlex.quote(a) for a in args)))
        started = time.time()
        with open(os.path.join(out, "log.txt"), "wb") as handle:
            code = subprocess.run(command, stdin=subprocess.DEVNULL, stdout=handle, stderr=subprocess.STDOUT).returncode
        seconds = round(time.time() - started, 1)
        log("case %s: exit %d in %.1f s" % (case["name"], code, seconds))
        records.append({"case": case["name"], "args": args, "exitCode": code, "seconds": seconds})
        if code != 0 and not failed:
            failed = code
    return records, failed


def build(repo, cores, log):
    """`blastmodel` in release in `repo`, at most `cores` jobs: its path, or None."""
    jobs = ["-j", str(cores)] if cores else []
    log("building blastmodel in %s" % repo)
    started = time.time()
    result = subprocess.run(["swift", "build", "-c", "release", "--product", "blastmodel"] + jobs, cwd=repo,
                            stdin=subprocess.DEVNULL, capture_output=True, text=True)
    if result.returncode != 0:
        log(result.stdout[-4000:] + result.stderr[-4000:])
        return None
    log("built in %.0f s" % (time.time() - started))
    return os.path.join(repo, ".build", "release", "blastmodel")


def machine():
    """What the cases ran on: the system and the cores."""
    uname = os.uname()
    return {"system": "%s %s %s" % (uname.sysname, uname.release, uname.machine), "cores": os.cpu_count()}


# MARK: - On the host

def serve_run(options):
    """Under the host's sweep lock: build, run the cases, write sweep.json beside them."""
    home = os.path.expanduser("~")
    os.environ["PATH"] = os.path.expandvars(SWIFT_PATHS) + ":" + os.environ.get("PATH", "")
    lock = take_lock(options, "sweep %s" % options["sweep"]["name"])
    if lock is None:
        return TAKEN

    try:
        def log(line):
            print("remote-sweep: " + line, flush=True)
        stage, _ = verify_snapshot(options)
        completion = os.path.join(stage, "completion.json")
        if os.path.exists(completion):
            return completed_code(options, stage)
        if os.path.exists(os.path.join(stage, "started.json")):
            log("interrupted invocation retained; use a fresh invocation to retry partial work")
            return 1
        repo, stage = activate_snapshot(options)
        atomic_json(os.path.join(stage, "started.json"), {"pid": os.getpid(), "boot": runner.boot_id()})
        out_root = os.path.join(stage, "results")
        os.makedirs(out_root)
        binary = build(repo, options["cores"], log)
        if binary is None:
            atomic_json(completion, {"invocation": options["invocation"], "exitCode": 1, "phase": "build",
                                     "results": tree_manifest(out_root)})
            return 1
        started = time.time()
        records, failed = run_cases(options["sweep"], repo, binary, out_root,
                                    os.path.join(stage, "inputs"), options["cores"], log)
        with open(os.path.join(out_root, "sweep.json"), "w") as handle:
            json.dump({"sweep": options["sweep"]["name"], "host": options["host"], "machine": machine(),
                       "coresUsed": options["cores"], "seconds": round(time.time() - started, 1), "cases": records,
                       "invocation": options["invocation"], "space": runner.space_here()},
                      handle, indent=1)
        atomic_json(completion, {"invocation": options["invocation"], "exitCode": failed, "phase": "cases",
                                 "results": tree_manifest(out_root)})
        return failed
    finally:
        prune_after(lock, options.get("invocation"))
        release_sweep(lock)


def take_lock(options, what):
    """The host's sweep lock, waiting up to options["wait"] seconds: (lock path or None)."""
    lock = os.path.join(os.path.expanduser("~"), ROOT, "lock")
    boot = runner.boot_id()
    deadline = time.monotonic() + options["wait"]
    said = None
    while True:
        try:
            with ownership_guard(lock, blocking=False):
                owner = sweep_owner(lock, boot)
                if owner is None and runner.acquire(lock, what, boot):
                    with open(os.path.join(lock, "owner")) as handle:
                        owned = json.load(handle)
                    owned.update(invocation=options["invocation"], pgid=os.getpgrp() if os.getpgrp() == os.getpid() else None)
                    atomic_json(os.path.join(lock, "owner"), owned)
                    return lock
        except BlockingIOError:
            owner = {"what": "lease transition"}
        owner = owner or {}
        if time.monotonic() >= deadline:
            print("remote-sweep: the lock ~/%s/lock is held (%s)" % (ROOT, owner.get("what", "unknown")), flush=True)
            return None
        if owner.get("what") != said:
            said = owner.get("what")
            print("remote-sweep: waiting for the lock (%s)" % said, flush=True)
        time.sleep(min(5, max(0, deadline - time.monotonic())))


def serve_test(options):
    """Under the host's sweep lock: BlastModel's tests built, and the suites named run."""
    os.environ["PATH"] = os.path.expandvars(SWIFT_PATHS) + ":" + os.environ.get("PATH", "")
    lock = take_lock(options, "tests %s" % ",".join(options["suites"])[:80])
    if lock is None:
        return TAKEN

    try:
        stage, _ = verify_snapshot(options)
        completion = os.path.join(stage, "completion.json")
        if os.path.exists(completion):
            return completed_code(options, stage)
        if os.path.exists(os.path.join(stage, "started.json")):
            print("remote-sweep: interrupted tests retained; use a fresh invocation to retry", flush=True)
            return 1
        repo, stage = activate_snapshot(options)
        atomic_json(os.path.join(stage, "started.json"), {"pid": os.getpid(), "boot": runner.boot_id()})
        cores = options["cores"]
        pinned = ["taskset", "-c", "0-%d" % (cores - 1)] if cores and shutil.which("taskset") else []
        started = time.time()
        built = subprocess.run(["swift", "build", "--build-tests", "-j", str(cores)], cwd=repo,
                               stdin=subprocess.DEVNULL)
        print("remote-sweep: tests built in %.0f s" % (time.time() - started), flush=True)
        if built.returncode:
            atomic_json(completion, {"invocation": options["invocation"], "exitCode": built.returncode, "phase": "build-tests"})
            return built.returncode
        pattern = r"\.(" + "|".join(options["suites"]) + r")(/|$)"
        code = subprocess.run(pinned + ["swift", "test", "--skip-build", "--filter", pattern], cwd=repo,
                              stdin=subprocess.DEVNULL).returncode
        atomic_json(completion, {"invocation": options["invocation"], "exitCode": code, "phase": "tests"})
        return code
    finally:
        prune_after(lock, options.get("invocation"))
        release_sweep(lock)


def file_record(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return {"sha256": digest.hexdigest(), "mode": os.stat(path).st_mode & 0o777}


def input_manifest(inputs):
    result = {}
    for source in inputs:
        source = Path(source.rstrip("/"))
        name = source.name
        if not name or name in (".", "..") or name in result or source.is_symlink():
            raise ValueError("input basenames must be distinct, transferable, non-symlink entries")
        if source.is_dir():
            result[name] = {"directory": True}
            result.update({name + "/" + k: v for k, v in tree_manifest(source).items()})
        else:
            result[name] = file_record(source)
    return result


def source_basis(root=ROOT):
    """Newest verified completed source stage; never the mutable build checkout.

    No lease is needed to read immutable stages. Removal during selection/transfer can
    fall back or fail verification; no worker may start with an incomplete destination.
    """
    staging = Path(root) / "staging"
    if not staging.is_dir():
        return None
    candidates = []
    try:
        entries = list(staging.iterdir())
    except FileNotFoundError:
        return None
    for path in entries:
        if re.fullmatch(r"[0-9a-f]{32}", path.name) and not path.is_symlink():
            try:
                candidates.append((path.stat().st_mtime_ns, path))
            except FileNotFoundError:
                continue
    for _, path in sorted(candidates, reverse=True):
        try:
            receipt = json.loads((path / "completion.json").read_text())
            expected = json.loads((path / "manifest.json").read_text())
            if not isinstance(receipt, dict) or not isinstance(expected, dict) or not isinstance(expected.get("src"), dict):
                continue
            if receipt.get("invocation") != path.name or type(receipt.get("exitCode")) is not int or receipt["exitCode"] != 0:
                continue
            if (path / "src").is_symlink():
                continue
            if tree_manifest(path / "src", EXCLUDED) == expected["src"]:
                return path.name
        except (OSError, ValueError, KeyError):
            continue
    return None


def prepare_source_basis(invocation, root=ROOT):
    """Private link view of identical file records only (including permissions).

    Some openrsync receivers link a mode-changed file without applying its new mode.
    Filtering before rsync avoids that case and prevents attribute writes to a basis
    inode. Directories and symlinks are always created fresh by the transfer.
    """
    stage = Path(root) / "staging" / Path(invocation_path(invocation)).name
    desired = json.loads((stage / "manifest.json").read_text())["src"]
    identity = source_basis(root)
    if identity is None:
        return None
    source = Path(root) / "staging" / identity / "src"
    view = stage / "basis"
    view.mkdir()  # Never reuse or mutate an older invocation's view.
    for name, record in desired.items():
        path = Path(name)
        if path.is_absolute() or ".." in path.parts:
            raise ValueError("invalid source manifest path")
        if "sha256" not in record:
            continue
        candidate = source / path
        try:
            if candidate.is_symlink() or file_record(candidate) != record:
                continue
            target = view / path
            target.parent.mkdir(parents=True, exist_ok=True)
            os.link(candidate, target)
        except FileNotFoundError:
            continue  # Concurrent removal: transfer this file normally instead.
    return identity


RECEIPTS = ("manifest.json", "request.json", "started.json", "completion.json", "retrieved.json")


def stage_changed(path):
    """When a stage last moved on: its newest receipt, else the folder itself. (Removing files from
    a stage by hand changes the folder's time but no receipt's, so it doesn't make a stage new.)"""
    times = []
    for name in RECEIPTS:
        try:
            times.append((path / name).stat().st_mtime)
        except OSError:
            pass
    return max(times) if times else path.stat().st_mtime


def stage_plan(root=ROOT, current=None, keep=KEEP_STAGES, now=None):
    """Which stages under root/staging may go: ([(name, why)] to remove, [(name, why)] kept).

    Called under the host's sweep lock, so no other worker is using a stage. Kept: the newest
    `keep` (by last change), the `current` invocation, the source basis (emmettl/bombcad-work#70's
    newest verified, completed source), whatever is staged-not-started or interrupted within
    PENDING_SECONDS (a resume can still start or inspect it; a send may be under way), and a run's
    results not yet retrieved, for UNRETRIEVED_SECONDS. Completed tests, retrieved runs and
    anything older go whole."""
    now = time.time() if now is None else now
    staging = Path(root) / "staging"
    stages = []
    for path in staging.iterdir() if staging.is_dir() else []:
        if re.fullmatch(r"[0-9a-f]{32}", path.name) and path.is_dir() and not path.is_symlink():
            try:
                stages.append((stage_changed(path), path))
            except FileNotFoundError:
                continue
    stages.sort(reverse=True)
    basis = source_basis(root) if stages else None
    remove, kept = [], []
    for rank, (changed, path) in enumerate(stages):
        age = now - changed
        if rank < keep:
            kept.append((path.name, "one of the newest %d" % keep))
            continue
        if path.name == current:
            kept.append((path.name, "this invocation"))
            continue
        if path.name == basis:
            kept.append((path.name, "the source basis"))
            continue
        completed = (path / "completion.json").exists()
        if not completed:
            state = "interrupted" if (path / "started.json").exists() else "staged, never started"
            if age < PENDING_SECONDS:
                kept.append((path.name, state + ", recent"))
            else:
                remove.append((path.name, state + ", over %d days old" % (PENDING_SECONDS // 86400)))
            continue
        try:
            kind = json.loads((path / "request.json").read_text()).get("kind")
        except (OSError, ValueError, AttributeError):
            kind = None
        if kind == "run" and not (path / "retrieved.json").exists() and age < UNRETRIEVED_SECONDS:
            kept.append((path.name, "run results not yet retrieved"))
        elif kind == "run":
            remove.append((path.name, "run retrieved" if (path / "retrieved.json").exists()
                           else "run unretrieved for over %d days" % (UNRETRIEVED_SECONDS // 86400)))
        else:
            remove.append((path.name, "%s completed" % (kind or "stage")))
    return remove, kept


def prune_staging(root=ROOT, current=None, keep=KEEP_STAGES, dry_run=False, now=None):
    """Removes what stage_plan says may go: a report of what went, what stayed and the bytes freed
    (by the file system, so files hard-linked into a kept stage count nothing)."""
    remove, kept = stage_plan(root, current, keep, now)
    staging = Path(root) / "staging"

    def free():
        try:
            stat = os.statvfs(staging)
            return stat.f_bavail * stat.f_frsize
        except OSError:
            return 0
    before = free()
    removed = []
    for name, why in remove:
        if not dry_run:
            shutil.rmtree(staging / name, ignore_errors=True)
            if (staging / name).exists():
                why += " (could not remove)"
        removed.append({"stage": name, "why": why})
    return {"removed": removed, "kept": [{"stage": n, "why": w} for n, w in kept],
            "freedBytes": max(0, free() - before), "dryRun": dry_run}


def prune_after(lock, invocation):
    """The worker's prune as it finishes, still holding `lock` (~/bombcad-sweeps/lock). A failure
    here never fails the work."""
    if not isinstance(lock, str) or not os.path.isabs(lock):
        return
    try:
        report = prune_staging(os.path.dirname(lock), current=invocation)
        if report["removed"]:
            print("remote-sweep: staging pruned: %d stage(s) removed, %s freed, %d kept" % (
                len(report["removed"]), runner.human(report["freedBytes"]), len(report["kept"])), flush=True)
    except Exception as error:  # noqa: BLE001 - retention must not turn a pass into a failure
        print("remote-sweep: staging not pruned: %s" % error, flush=True)


def serve_prune(options):
    """`prune` on the host: under the sweep lock (given up at once if held), staging pruned."""
    root = os.path.join(os.path.expanduser("~"), ROOT)
    if options.get("dryRun"):
        report = prune_staging(root, dry_run=True)
    else:
        lock = take_lock(dict(invocation="prune", wait=0), "staging prune")
        if lock is None:
            print(json.dumps({"held": True}))
            return TAKEN
        try:
            report = prune_staging(root)
        finally:
            with ownership_guard(lock):
                runner.release(lock)
    report["space"] = runner.space_here()
    print(json.dumps(report))
    return 0


def sending_bytes(inputs):
    """At most what a send carries: the source (as staged) and the inputs, before any file is
    found already on the host."""
    total = 0
    for top, excluded in [(REPO, EXCLUDED)] + [(p.rstrip("/"), ()) for p in inputs]:
        if os.path.isfile(top):
            total += os.path.getsize(top)
            continue
        for directory, dirs, files in os.walk(top):
            dirs[:] = [d for d in dirs if d not in excluded]
            for name in files:
                if name not in excluded:
                    try:
                        total += os.lstat(os.path.join(directory, name)).st_size
                    except OSError:
                        pass
    return total


def room_for(host, inputs, log):
    """None if `host` has room for a send of the source and `inputs`, else why not (said)."""
    space = runner.host_space(host)
    refusal = runner.space_refusal(space, sending_bytes(inputs))
    if refusal:
        log("refused: %s: %s" % (host, refusal))
    return refusal


def send_worktree(host, log, options):
    """Transfer only to a fresh invocation directory; no active checkout/input/tool mutation."""
    stage = invocation_path(options["invocation"])
    inputs = options.get("sweep", {}).get("inputs", [])
    expected = {"src": tree_manifest(REPO, EXCLUDED), "inputs": input_manifest(inputs), "request": json.loads(json.dumps(options)),
                "tools": {"remote-sweep.py": file_record(__file__),
                          "remote-train.py": file_record(os.path.join(HERE, "ml", "remote-train.py"))}}
    made = runner.ssh(host, "mkdir -p %s/staging && mkdir %s && mkdir %s/src %s/inputs %s/tools" %
                       (ROOT, stage, stage, stage, stage))
    if made.returncode:
        return UNREACHABLE
    log("staging invocation %s at %s:~/%s" % (options["invocation"], host, stage))
    rsync = ["rsync", "-a", "-e", " ".join(SSH)]
    # Bootstrap the invocation-private helper before asking it for a verified source basis.
    tools = subprocess.run(rsync + [os.path.abspath(__file__), os.path.join(HERE, "ml", "remote-train.py"),
                                   "%s:%s/tools/" % (host, stage)], stdin=subprocess.DEVNULL)
    if tools.returncode:
        return tools.returncode
    sent_manifest = subprocess.run(SSH + [host, "cat > " + stage + "/manifest.json"],
                                   input=json.dumps(expected).encode())
    if sent_manifest.returncode:
        return sent_manifest.returncode
    probe = runner.ssh(host, "python3 %s/tools/remote-sweep.py source-basis %s" %
                       (stage, options["invocation"]), timeout=300)
    if probe.returncode:
        return probe.returncode
    basis = probe.stdout.decode().strip()
    if basis and not re.fullmatch(r"[0-9a-f]{32}", basis):
        raise ValueError("invalid source basis identity")
    log("source basis " + (basis or "none (full transfer)"))
    # rsync's default temp-file/rename updates keep basis inodes unchanged. Never use
    # --inplace or --ignore-times: same-size/mtime edits must be checksummed, and mode
    # differences must create a separate file instead of chmod-ing a shared inode.
    steps = [rsync + ["--checksum", "--stats"] + (["--link-dest=../basis"] if basis else []) +
             sum((["--exclude", x] for x in sorted(EXCLUDED)), []) +
             [REPO + "/", "%s:%s/src/" % (host, stage)]]
    if inputs:
        steps.append(rsync + [os.path.abspath(p.rstrip("/")) for p in inputs] + ["%s:%s/inputs/" % (host, stage)])
    transfer_started = time.monotonic()
    for step in steps:
        code = subprocess.run(step, stdin=subprocess.DEVNULL).returncode
        if code:
            return code
    log("source/input transfer finished in %.3f s (basis %s)" %
        (time.monotonic() - transfer_started, basis or "none"))
    # Detect changes during transfer. The host independently verifies every received byte/link.
    if expected != {"src": tree_manifest(REPO, EXCLUDED), "inputs": input_manifest(inputs), "request": options,
                    "tools": {"remote-sweep.py": file_record(__file__),
                              "remote-train.py": file_record(os.path.join(HERE, "ml", "remote-train.py"))}}:
        log("local snapshot changed during transfer; retained staging, no worker launched")
        return 1
    for name, value in [("manifest.json", expected), ("request.json", options)]:
        sent = subprocess.run(SSH + [host, "cat > " + stage + "/" + name],
                              input=json.dumps(value).encode())
        if sent.returncode:
            return sent.returncode
    return 0


def remote_worker(host, options, stream=None):
    if options["kind"] not in ("run", "test"):
        raise ValueError("unknown staged worker kind")
    stage = invocation_path(options["invocation"])
    command = SSH + ["-tt", "-q", host, "python3 %s/tools/remote-sweep.py serve-%s %s" %
                     (stage, options["kind"], shlex.quote(json.dumps(options)))]
    return subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=stream,
                            stderr=subprocess.STDOUT if stream else None).wait()


def retrieve(host, options, results, code, log):
    stage = invocation_path(options["invocation"])
    read = runner.ssh(host, "cat " + stage + "/completion.json", timeout=30)
    try:
        receipt = json.loads(read.stdout)
    except ValueError:
        log("no completion receipt; invocation %s retained for observation/resume" % options["invocation"])
        return code or 1
    if receipt.get("invocation") != options["invocation"]:
        raise ValueError("completion belongs to another invocation")
    if type(receipt.get("exitCode")) is not int or not isinstance(receipt.get("results"), dict):
        raise ValueError("completion has no valid result manifest")
    if "retrieval.json" in receipt["results"]:
        raise ValueError("result uses the reserved retrieval receipt name")
    if code not in (receipt["exitCode"], receipt["exitCode"] & 255, 255):
        log("worker refused completion; not overriding exit %d with an older receipt" % code)
        return code or 1
    os.makedirs(results)  # Reserve fresh local output; never merge into a previous retrieval.
    copied = subprocess.run(["rsync", "-a", "-e", " ".join(SSH),
                             "%s:%s/results/" % (host, stage), results + "/"], stdin=subprocess.DEVNULL)
    verified = copied.returncode == 0 and tree_manifest(results) == receipt["results"]
    atomic_json(os.path.join(results, "retrieval.json"),
                {"invocation": options["invocation"], "completion": receipt, "copyExitCode": copied.returncode,
                 "workerExitCode": code, "filesVerified": verified})
    if verified:
        # The host's copy is no longer needed for recovery: its next prune may remove the stage.
        runner.ssh(host, "cat > %s/retrieved.json" % stage, timeout=30,
                   stdin=json.dumps({"invocation": options["invocation"], "retrieved": time.time()}).encode())
    log("invocation %s exit %d; results in %s" % (options["invocation"], receipt["exitCode"], results))
    return receipt["exitCode"] or copied.returncode or (0 if verified else 1)


def lane_ready(host):
    """None if `host` answers and its sweep lock is free, else why not: asked before a check splits
    its suites, so that a lane that is not there costs nothing."""
    why = runner.reachable(host)
    if why:
        return why
    # A host that answers but cannot write (a WSL disk gone read-only, I/O errors) is not a lane.
    write = runner.ssh(host, "mkdir -p %s/staging && f=%s/staging/.lane-probe-$$ && : > $f && rm -f $f && echo ok"
                       % (ROOT, ROOT), timeout=30)
    if b"ok" not in write.stdout:
        return "it cannot write its staging folder"
    refusal = runner.space_refusal(runner.host_space(host), sending_bytes([]))
    if refusal:
        return "it is short of space: " + refusal
    probe = runner.ssh(host, "cat %s/lock/owner 2>/dev/null; echo; cat /proc/sys/kernel/random/boot_id" % ROOT,
                       timeout=30)
    lines = probe.stdout.decode(errors="replace").strip().splitlines()
    try:
        owner = json.loads(lines[0]) if lines and lines[0].startswith("{") else None
    except ValueError:
        owner = None
    if owner and owner.get("boot") == (lines[-1] if lines else None):
        identity = -int(owner["pgid"]) if owner.get("pgid") else int(owner.get("pid") or 0)
        alive = runner.ssh(host, "kill -0 -- %d 2>/dev/null && echo alive" % identity, timeout=30)
        if b"alive" in alive.stdout:
            return "its lock is held (%s)" % owner.get("what", "unknown")
    return None


def test(host, suites, cores=16, wait=0, stream=None):
    """BlastModel's `suites` run on `host`, their output to `stream` (a file; default this one's):
    the tests' exit status, or one of LANE_DOWN."""
    def log(line):
        print("remote-sweep: " + line, file=stream or sys.stdout, flush=True)
    if cores <= 0 or wait < 0 or not suites or any(not re.fullmatch(r"[A-Za-z_][A-Za-z_0-9]*", s) for s in suites):
        raise ValueError("positive cores, nonnegative wait and test-suite names required")
    options = {"kind": "test", "invocation": uuid.uuid4().hex, "host": host,
               "suites": suites, "cores": cores, "wait": wait}
    if room_for(host, [], log):
        return NOSPACE
    sent = send_worktree(host, log, options)
    if sent:
        return sent
    return remote_worker(host, options, stream)


# MARK: - Here

def run(arguments):
    def option(name, default):
        return arguments[arguments.index(name) + 1] if name in arguments else default
    target, path = arguments[0], arguments[1]
    with open(path) as handle:
        sweep = json.load(handle)
    if not re.match(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,99}$", sweep.get("name", "")):
        print("remote-sweep: the sweep needs a name of letters, digits, '.', '_' and '-'", file=sys.stderr)
        return 2
    cores = int(option("--cores", "16"))
    wait = duration(option("--wait", "0"))
    results = os.path.join(option("--results", RESULTS), "%s-%s" % (sweep["name"], "here" if target == "--here" else target))
    if os.path.exists(results):
        print("remote-sweep: %s already exists" % results, file=sys.stderr)
        return 2
    for source in sweep.get("inputs", []):
        if not os.path.exists(source):
            print("remote-sweep: no input %s" % source, file=sys.stderr)
            return 2
    if cores <= 0 or wait < 0 or not sweep.get("cases"):
        raise ValueError("positive cores, nonnegative wait and nonempty cases required")
    names = [case["name"] for case in sweep["cases"]]
    if len(set(names)) != len(names) or any(not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,99}", n)
                                        or n in ("sweep.json", "retrieval.json") for n in names):
        raise ValueError("case names must be distinct simple path components")

    def log(line):
        print("remote-sweep: " + line, flush=True)

    if target == "--here":
        binary = build(REPO, None, log)
        if binary is None:
            return 1
        os.makedirs(results)
        started = time.time()
        records, failed = run_cases(sweep, REPO, binary, results, None, None, log)
        with open(os.path.join(results, "sweep.json"), "w") as handle:
            json.dump({"sweep": sweep["name"], "host": "here", "machine": machine(), "coresUsed": None,
                       "seconds": round(time.time() - started, 1), "cases": records}, handle, indent=1)
        return failed
    host = target
    input_manifest(sweep.get("inputs", []))
    why = runner.reachable(host)
    if why:
        print("remote-sweep: %s is unreachable: %s" % (host, why), file=sys.stderr)
        return UNREACHABLE
    options = {"kind": "run", "invocation": uuid.uuid4().hex, "sweep": sweep,
               "host": host, "cores": cores, "wait": wait}
    if room_for(host, sweep.get("inputs", []), log):
        return NOSPACE
    sent = send_worktree(host, log, options)
    if sent:
        return sent
    code = remote_worker(host, options)
    return retrieve(host, options, results, code, log)


def resume(arguments):
    """Recover a retained invocation. Never resend current sources or rerun partial work."""
    host, invocation = arguments[:2]
    stage = invocation_path(invocation)
    read = runner.ssh(host, "cat " + stage + "/request.json", timeout=30)
    if read.returncode:
        return UNREACHABLE
    options = json.loads(read.stdout)
    if options["invocation"] != invocation or options["host"] != host:
        raise ValueError("resume request belongs to another invocation/host")
    if options["kind"] == "run" and not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,99}", options["sweep"]["name"]):
        raise ValueError("invalid retained sweep name")
    if "--wait" in arguments:
        options["wait"] = duration(arguments[arguments.index("--wait") + 1])
    if options["kind"] == "test":
        return remote_worker(host, options)
    base = arguments[arguments.index("--results") + 1] if "--results" in arguments else RESULTS
    results = os.path.join(base, "%s-%s" % (options["sweep"]["name"], host))
    if os.path.exists(results):
        print("remote-sweep: %s already exists" % results, file=sys.stderr)
        return 2
    code = remote_worker(host, options)
    return retrieve(host, options, results, code, lambda line: print("remote-sweep: " + line, flush=True))


# MARK: - Comparing

TIMES = re.compile(r"\d+(\.\d+)?\s*(s|ms|ns)\b|\(\d+(\.\d+)? s\)|in \d+(\.\d+)? s")


def same_json(a, b, tolerance, path=""):
    """Where `a` and `b` differ, beyond `tolerance` (relative) for numbers: a list of paths."""
    if isinstance(a, (int, float)) and isinstance(b, (int, float)) and not isinstance(a, bool):
        scale = max(abs(a), abs(b), 1e-300)
        return [] if a == b or abs(a - b) / scale <= tolerance else ["%s: %r against %r" % (path, a, b)]
    if type(a) is not type(b):
        return ["%s: %r against %r" % (path, a, b)]
    if isinstance(a, dict):
        if set(a) != set(b):
            return ["%s: keys %s against %s" % (path, sorted(set(a) - set(b)), sorted(set(b) - set(a)))]
        return [d for k in a for d in same_json(a[k], b[k], tolerance, "%s.%s" % (path, k))]
    if isinstance(a, list):
        if len(a) != len(b):
            return ["%s: %d items against %d" % (path, len(a), len(b))]
        return [d for k, (x, y) in enumerate(zip(a, b)) for d in same_json(x, y, tolerance, "%s[%d]" % (path, k))]
    return [] if a == b else ["%s: %r against %r" % (path, a, b)]


def compare(arguments):
    left, right = arguments[0], arguments[1]
    tolerance = float(arguments[arguments.index("--tolerance") + 1]) if "--tolerance" in arguments else 1e-9
    with open(os.path.join(left, "sweep.json")) as handle:
        cases = [c["case"] for c in json.load(handle)["cases"]]
    disagreements = 0
    for case in cases:
        a_dir, b_dir = os.path.join(left, case), os.path.join(right, case)
        names = sorted(set(os.listdir(a_dir)) | set(os.listdir(b_dir) if os.path.isdir(b_dir) else []))
        for name in names:
            a, b = os.path.join(a_dir, name), os.path.join(b_dir, name)
            if not (os.path.exists(a) and os.path.exists(b)):
                print("%s/%s: only in %s" % (case, name, left if os.path.exists(a) else right))
                disagreements += 1
                continue
            with open(a, "rb") as x, open(b, "rb") as y:
                da, db = x.read(), y.read()
            if da == db:
                print("%s/%s: the same bytes" % (case, name))
                continue
            if name.endswith(".json"):
                differences = same_json(json.loads(da), json.loads(db), tolerance)
                verdict = "agrees within %g" % tolerance if not differences else "differs at %d places, first %s" % (
                    len(differences), differences[0])
            else:
                la = [TIMES.sub("", line) for line in da.decode(errors="replace").splitlines()]
                lb = [TIMES.sub("", line) for line in db.decode(errors="replace").splitlines()]
                differences = [k for k, (p, q) in enumerate(zip(la, lb)) if p != q] + (
                    [min(len(la), len(lb))] if len(la) != len(lb) else [])
                verdict = "the same lines but for times" if not differences else (
                    "differs at %d lines, first line %d: %r against %r" % (
                        len(differences), differences[0] + 1, la[differences[0]] if differences[0] < len(la) else None,
                        lb[differences[0]] if differences[0] < len(lb) else None))
            print("%s/%s: %s" % (case, name, verdict))
            disagreements += 1 if differences else 0
    print("%d file(s) disagree" % disagreements)
    return 1 if disagreements else 0


def prune(host, dry_run=False):
    """`prune <host>`: the host's staging pruned now, by the rule the workers follow, with these
    tools sent to a private folder there for the purpose and removed after."""
    why = runner.reachable(host)
    if why:
        print("remote-sweep: %s is unreachable: %s" % (host, why), file=sys.stderr)
        return UNREACHABLE
    made = runner.ssh(host, "mkdir -p %s && mktemp -d %s/.prune-XXXXXXXX" % (ROOT, ROOT), timeout=30)
    folder = made.stdout.decode().strip()
    if made.returncode or not re.fullmatch(re.escape(ROOT) + r"/\.prune-[A-Za-z0-9]+", folder):
        print("remote-sweep: could not make a folder for the prune on %s" % host, file=sys.stderr)
        return 1
    try:
        sent = subprocess.run(["rsync", "-a", "-e", " ".join(SSH), os.path.abspath(__file__),
                               os.path.join(HERE, "ml", "remote-train.py"), "%s:%s/" % (host, folder)],
                              stdin=subprocess.DEVNULL)
        if sent.returncode:
            return sent.returncode
        result = runner.ssh(host, "python3 %s/remote-sweep.py serve-prune %s" % (
            folder, shlex.quote(json.dumps({"dryRun": dry_run}))), timeout=900)
    finally:
        runner.ssh(host, "rm -rf -- %s" % folder, timeout=60)
    try:
        report = json.loads(result.stdout.decode().strip().splitlines()[-1])
    except (ValueError, IndexError):
        print("remote-sweep: the prune on %s said nothing readable: %s" % (
            host, result.stderr.decode(errors="replace").strip()), file=sys.stderr)
        return 1
    if report.get("held"):
        print("remote-sweep: not pruned: the sweep lock on %s is held" % host)
        return TAKEN
    verb = "would remove" if dry_run else "removed"
    for entry in report["removed"]:
        print("  %s: staging/%s (%s)" % (verb, entry["stage"], entry["why"]))
    for entry in report["kept"]:
        print("  kept: staging/%s (%s)" % (entry["stage"], entry["why"]))
    print("remote-sweep: %s %d stage(s), %s freed; kept %d. %s: %s" % (
        verb, len(report["removed"]), runner.human(report["freedBytes"]), len(report["kept"]), host,
        runner.describe_space(report.get("space"))))
    return 0


def main(arguments):
    if len(arguments) == 2 and arguments[0] == "source-basis":
        print(prepare_source_basis(arguments[1]) or "")
        return 0
    if len(arguments) == 2 and arguments[0] == "serve-prune":
        return serve_prune(json.loads(arguments[1]))
    if len(arguments) >= 2 and arguments[0] == "prune":
        return prune(arguments[1], "--dry-run" in arguments[2:])
    if arguments and arguments[0] == "serve-run":
        prepare_worker()
        return serve_run(json.loads(arguments[1]))
    if arguments and arguments[0] == "serve-test":
        prepare_worker()
        return serve_test(json.loads(arguments[1]))
    if len(arguments) >= 3 and arguments[0] == "resume":
        return resume(arguments[1:])
    if len(arguments) >= 3 and arguments[0] == "test":
        def option(name, default):
            return arguments[arguments.index(name) + 1] if name in arguments else default
        return test(arguments[1], [s for s in arguments[2].split(",") if s], int(option("--cores", "16")),
                    duration(option("--wait", "0")))
    if len(arguments) >= 3 and arguments[0] == "run":
        return run(arguments[1:])
    if len(arguments) >= 3 and arguments[0] == "compare":
        return compare(arguments[1:])
    print(__doc__)
    return 0 if arguments[:1] in (["-h"], ["--help"]) else 2


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except (ValueError, OSError) as error:
        print("remote-sweep: " + str(error), file=sys.stderr)
        sys.exit(1)
