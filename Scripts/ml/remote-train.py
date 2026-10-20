#!/usr/bin/env python3
"""Train on another machine's GPU: send a dataset and a script, run it there, bring the results back.

    python3 -I Scripts/ml/remote-train.py <host> <dataset-dir> <train-script> [options] [--args ...]

    --job NAME        the job's name (default: <script>-<UTC time>-<host>)
    --venv PATH       the Python environment there (default the host's, ~/bombcad-ml/venv);
                      "none" for the host's own python3
    --timeout T       stop the script after T (seconds, or 90m, 1.5h; default the host's limit)
    --wait T          wait up to T for the host's lock (default 0: give up at once if it is held)
    --results DIR     where results come back to (default /Volumes/StudioData/bombcad/ml)
    --dry-run         say what would be sent and run, and where, without sending or running
    --args ...        everything after it goes to the training script

The dataset goes to ~/bombcad-ml/datasets/<name>-<hash>/ on the host, named by a hash of its
files' contents, so a dataset already there is not sent again. The script and this file go to
~/bombcad-ml/jobs/<job>/. There, under a lock (one job per GPU, the lock's owner a live process
on that boot), the script runs in the host's Python environment as

    python -u <script> --data <dataset> --out out [args...]

with its output streamed here. Then the job's folder (out/, log.txt, status.json) comes back to
<results>/<job>/, with job.json: the host, its GPU (from nvidia-smi, if it has one), the times,
the exit status and what was sent. Exit status: the script's; 124 if it was stopped at the
timeout; 69 if the host could not be reached; 75 if its lock stayed taken.

Hosts are SSH names (with a Host entry in ~/.ssh/config); see docs/learned-models.md for setting
up a PC. The same file runs on the host, sent there with the job, so both ends agree.
"""
import datetime
import hashlib
import json
import os
import re
import shlex
import signal
import subprocess
import sys
import threading
import time

# The machines, by their SSH names. `venv` is the Python environment under the host's home (None:
# its own python3); `lock`, the lock folder under its home (the mini's is the one BombCAD's checks
# and workers take, so that a test job never runs beside them); `maxHours`, the default timeout.
HOSTS = {
    "bombcad-pc": {
        "about": "the desktop PC: RTX 3080 Ti, 12 GB, WSL2 Ubuntu",
        "venv": "bombcad-ml/venv", "lock": "bombcad-ml/lock", "maxHours": 24,
    },
    "bombcad-laptop": {
        "about": "the laptop: mobile RTX 4080, 12 GB, WSL2 Ubuntu (it throttles on long jobs: keep them short)",
        "venv": "bombcad-ml/venv", "lock": "bombcad-ml/lock", "maxHours": 2,
    },
    "scrimply-ci-tb": {
        "about": "the CI Mac mini, for testing the runner: its own python3, nothing installed",
        "venv": None, "lock": "bombcad-remote/lock", "maxHours": 1.5,
    },
}
DEFAULT_HOST = {"about": "a host not in HOSTS", "venv": "bombcad-ml/venv", "lock": "bombcad-ml/lock", "maxHours": 12}
ROOT = "bombcad-ml"  # under the host's home
RESULTS = "/Volumes/StudioData/bombcad/ml"
SSH = ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "-o", "ServerAliveInterval=15",
       "-o", "ServerAliveCountMax=4"]
HASH_CACHE = os.path.expanduser("~/.cache/bombcad-ml/hashes.json")
NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,99}$")
UNREACHABLE, TAKEN, TIMED_OUT = 69, 75, 124


# MARK: - Arguments

def duration(text):
    """Seconds from "3600", "90m", "1.5h" or "30s"."""
    match = re.fullmatch(r"\s*([0-9]*\.?[0-9]+)\s*([smh]?)\s*", str(text))
    if not match:
        raise ValueError("a duration such as 3600, 90m or 1.5h, not %r" % text)
    return float(match.group(1)) * {"": 1, "s": 1, "m": 60, "h": 3600}[match.group(2)]


def parse(arguments, now=None):
    """The options from `arguments`, with the host's settings filled in. Everything after `--args`
    goes to the script untouched."""
    if "--args" in arguments:
        at = arguments.index("--args")
        arguments, script_args = arguments[:at], arguments[at + 1:]
    else:
        script_args = []
    options = {"job": None, "venv": None, "timeout": None, "wait": "0", "results": RESULTS, "dry_run": False}
    positional = []
    i = 0
    while i < len(arguments):
        argument = arguments[i]
        if argument == "--dry-run":
            options["dry_run"] = True
        elif argument in ("--job", "--venv", "--timeout", "--wait", "--results"):
            if i + 1 >= len(arguments):
                raise ValueError("%s needs a value" % argument)
            options[argument[2:]] = arguments[i + 1]
            i += 1
        elif argument.startswith("--"):
            raise ValueError("unknown option %s (the script's own options go after --args)" % argument)
        else:
            positional.append(argument)
        i += 1
    if len(positional) != 3:
        raise ValueError("usage: remote-train.py <host> <dataset-dir> <train-script> [options] [--args ...]")
    host, dataset, script = positional
    settings = dict(HOSTS.get(host, DEFAULT_HOST))
    if options["venv"] is not None:
        settings["venv"] = None if options["venv"] == "none" else options["venv"]
    now = now or datetime.datetime.now(datetime.timezone.utc)
    job = options["job"] or "%s-%s-%s" % (
        re.sub(r"[^A-Za-z0-9_-]", "-", os.path.splitext(os.path.basename(script))[0]),
        now.strftime("%Y%m%d-%H%M%S"), host.split(".")[0])
    if not NAME.match(job):
        raise ValueError("a job name of letters, digits, dots, dashes and underscores, not %r" % job)
    return {
        "host": host, "known": host in HOSTS, "dataset": os.path.abspath(dataset), "script": os.path.abspath(script),
        "args": script_args, "job": job, "settings": settings, "dryRun": options["dry_run"],
        "timeout": duration(options["timeout"]) if options["timeout"] else settings["maxHours"] * 3600,
        "wait": duration(options["wait"]), "results": options["results"],
    }


# MARK: - The dataset's content address

def manifest(folder, cache=None):
    """[(relative path, size, sha256)] of the files under `folder`, sorted, leaving out hidden ones
    (.DS_Store and the like). `cache` ({path: [size, mtime_ns, sha256]}) saves hashing files that
    have not changed; it is updated in place."""
    entries = []
    for directory, folders, files in os.walk(folder):
        folders[:] = sorted(f for f in folders if not f.startswith("."))
        for name in sorted(files):
            if name.startswith("."):
                continue
            path = os.path.join(directory, name)
            stat = os.stat(path)
            known = (cache or {}).get(path)
            if known and known[0] == stat.st_size and known[1] == stat.st_mtime_ns:
                digest = known[2]
            else:
                hasher = hashlib.sha256()
                with open(path, "rb") as handle:
                    for chunk in iter(lambda: handle.read(1 << 20), b""):
                        hasher.update(chunk)
                digest = hasher.hexdigest()
                if cache is not None:
                    cache[path] = [stat.st_size, stat.st_mtime_ns, digest]
            entries.append((os.path.relpath(path, folder).replace(os.sep, "/"), stat.st_size, digest))
    return sorted(entries)


def content_hash(entries):
    """One hash for a manifest: of each file's path, size and hash, a line each."""
    hasher = hashlib.sha256()
    for path, size, digest in entries:
        hasher.update(("%s\t%d\t%s\n" % (path, size, digest)).encode())
    return hasher.hexdigest()


def dataset_name(folder, digest):
    """The dataset's folder on the host: its own name and the first 16 of its hash."""
    base = re.sub(r"[^A-Za-z0-9._-]", "-", os.path.basename(os.path.normpath(folder))) or "dataset"
    return "%s-%s" % (base, digest[:16])


def hashed(folder):
    """The manifest of `folder`, through the cache in ~/.cache/bombcad-ml."""
    try:
        with open(HASH_CACHE) as handle:
            cache = json.load(handle)
    except (OSError, ValueError):
        cache = {}
    entries = manifest(folder, cache)
    try:
        os.makedirs(os.path.dirname(HASH_CACHE), exist_ok=True)
        temporary = HASH_CACHE + ".%d" % os.getpid()
        with open(temporary, "w") as handle:
            json.dump(cache, handle)
        os.replace(temporary, HASH_CACHE)
    except OSError:
        pass
    return entries


# MARK: - The lock (runs on the host)

def boot_id():
    """This boot of this machine: a lock left by a process of an earlier boot is stale, whatever
    process has its pid now."""
    try:
        with open("/proc/sys/kernel/random/boot_id") as handle:
            return handle.read().strip()
    except OSError:
        pass
    try:
        return subprocess.run(["sysctl", "-n", "kern.boottime"], capture_output=True, text=True,
                              timeout=10).stdout.strip() or None
    except (OSError, subprocess.SubprocessError):
        return None


def alive(pid):
    try:
        os.kill(int(pid), 0)
    except PermissionError:
        return True
    except (OSError, ValueError, TypeError):
        return False
    return True


def lock_owner(path, boot=None, stale_seconds=None):
    """The lock's owner if a live process of this boot holds it (and, with `stale_seconds`, took it
    no longer ago than that); else None. A lock folder without an owner file is being taken."""
    try:
        with open(os.path.join(path, "owner")) as handle:
            owner = json.load(handle)
    except (OSError, ValueError):
        return {"pid": None, "what": "starting"} if os.path.isdir(path) else None
    if owner.get("boot") and boot and owner["boot"] != boot:
        return None
    if not alive(owner.get("pid")):
        return None
    if stale_seconds is not None and time.time() - float(owner.get("since", 0)) > stale_seconds:
        return None
    return owner


def acquire(path, what, boot=None, stale_seconds=None, pid=None):
    """Takes the lock for `pid` (this process) if it is free or its owner gone: True, or False if
    another holds it. The owner file is written whole, so a reader never finds half of it; its
    pid, since and what are the fields Scripts/remote.py reads."""
    if lock_owner(path, boot, stale_seconds) is None and os.path.isdir(path):
        for name in os.listdir(path):
            try:
                os.remove(os.path.join(path, name))
            except OSError:
                pass
        try:
            os.rmdir(path)
        except OSError:
            pass
    try:
        os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
        os.mkdir(path)
    except FileExistsError:
        return False
    owner = {"pid": pid or os.getpid(), "since": time.time(), "what": what, "boot": boot}
    temporary = os.path.join(path, "owner.%d" % os.getpid())
    with open(temporary, "w") as handle:
        json.dump(owner, handle)
    os.replace(temporary, os.path.join(path, "owner"))
    return True


def release(path, pid=None):
    """Lets the lock go if this process (`pid`) holds it."""
    try:
        with open(os.path.join(path, "owner")) as handle:
            owner = json.load(handle)
    except (OSError, ValueError):
        return False
    if owner.get("pid") != (pid or os.getpid()):
        return False
    for name in os.listdir(path):
        try:
            os.remove(os.path.join(path, name))
        except OSError:
            pass
    try:
        os.rmdir(path)
    except OSError:
        pass
    return True


# MARK: - On the host

def gpu_name():
    """The GPUs nvidia-smi names, with their memory, or None without nvidia-smi."""
    try:
        result = subprocess.run(["nvidia-smi", "--query-gpu=name,memory.total", "--format=csv,noheader"],
                                capture_output=True, text=True, timeout=30)
    except (OSError, subprocess.SubprocessError):
        return None
    lines = [line.strip() for line in result.stdout.splitlines() if line.strip()]
    return "; ".join(lines) if result.returncode == 0 and lines else None


def python_for(venv):
    home = os.path.expanduser("~")
    return os.path.join(home, venv, "bin", "python") if venv else "python3"


def serve_probe(options):
    home = os.path.expanduser("~")
    root = os.path.join(home, ROOT)
    dataset = os.path.join(root, "datasets", options["dataset"])
    lock = os.path.join(home, options["lock"])
    python = python_for(options.get("venv"))
    venv_ok = os.path.exists(python) if options.get("venv") else True
    try:
        stat = os.statvfs(home)
        free = stat.f_bavail * stat.f_frsize
    except OSError:
        free = None
    print(json.dumps({
        "machine": os.uname()[1], "system": "%s %s" % (os.uname()[0], os.uname()[2]),
        "python": sys.version.split()[0], "datasetPresent": os.path.exists(os.path.join(dataset, ".complete")),
        "lock": lock_owner(lock, boot_id(), options.get("stale")), "venv": options.get("venv"),
        "venvPython": python, "venvPresent": venv_ok, "gpu": gpu_name(), "freeBytes": free,
    }))
    return 0


def serve_finish_dataset(options):
    """Puts a dataset sent to its .partial folder in its place and marks it complete."""
    datasets = os.path.join(os.path.expanduser("~"), ROOT, "datasets")
    final = os.path.join(datasets, options["dataset"])
    partial = final + ".partial"
    if os.path.exists(os.path.join(final, ".complete")):
        subprocess.run(["rm", "-rf", partial])
        return 0
    if os.path.isdir(final):
        subprocess.run(["rm", "-rf", final])
    os.rename(partial, final)
    open(os.path.join(final, ".complete"), "w").close()
    return 0


def serve_run(options):
    """Under the lock, runs the job's script with its output streamed and kept in log.txt; writes
    status.json. Hung up on (the Studio's end stopped), it stops the script and lets the lock go."""
    home = os.path.expanduser("~")
    job = os.path.join(home, ROOT, "jobs", options["job"])
    dataset = os.path.join(home, ROOT, "datasets", options["dataset"])
    lock = os.path.join(home, options["lock"])
    boot = boot_id()
    python = python_for(options.get("venv"))
    if options.get("venv") and not os.path.exists(python):
        print("remote-train: no Python environment at ~/%s on %s (see docs/learned-models.md)" % (
            options["venv"], os.uname()[1]), flush=True)
        return 78
    what = "remote-train %s" % options["job"]
    deadline = time.time() + float(options.get("wait", 0))
    said = None
    while not acquire(lock, what, boot, options.get("stale")):
        owner = lock_owner(lock, boot, options.get("stale")) or {}
        if time.time() >= deadline:
            print("remote-train: the lock ~/%s is held (%s); gave up" % (options["lock"], owner.get("what", "unknown")),
                  flush=True)
            return TAKEN
        if owner.get("what") != said:
            said = owner.get("what")
            print("remote-train: waiting for the lock ~/%s (%s)" % (options["lock"], said), flush=True)
        time.sleep(15)
    process = None
    state = {"timedOut": False}

    def stop_group(signum=signal.SIGTERM):
        if process is not None and process.poll() is None:
            try:
                os.killpg(process.pid, signum)
            except OSError:
                pass

    def hung_up(signum, frame):
        stop_group()
        release(lock)
        sys.exit(128 + signum)

    for signum in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM):
        signal.signal(signum, hung_up)
    started = time.time()
    code = None
    try:
        os.makedirs(os.path.join(job, "out"), exist_ok=True)
        command = [python, "-u", options["script"], "--data", dataset, "--out", os.path.join(job, "out")] + \
            list(options.get("args") or [])
        print("remote-train: on %s (%s), GPU %s: %s" % (
            os.uname()[1], sys.platform, gpu_name() or "none named", " ".join(shlex.quote(c) for c in command)),
            flush=True)
        environment = dict(os.environ, BOMBCAD_ML_DATA=dataset, BOMBCAD_ML_OUT=os.path.join(job, "out"),
                           PYTHONUNBUFFERED="1")
        with open(os.path.join(job, "log.txt"), "ab") as log:
            process = subprocess.Popen(command, cwd=job, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                       env=environment, start_new_session=True)

            def timeout():
                state["timedOut"] = True
                print("remote-train: stopped at the timeout, %.0f s" % float(options["timeout"]), flush=True)
                stop_group(signal.SIGTERM)
                time.sleep(30)
                stop_group(signal.SIGKILL)

            timer = threading.Timer(float(options["timeout"]), timeout)
            timer.daemon = True
            timer.start()
            for line in iter(process.stdout.readline, b""):
                log.write(line)
                log.flush()
                sys.stdout.buffer.write(line)
                sys.stdout.buffer.flush()
            code = process.wait()
            timer.cancel()
        if state["timedOut"]:
            code = TIMED_OUT
    finally:
        ended = time.time()
        status = {"exitCode": code, "timedOut": state["timedOut"], "started": started, "ended": ended,
                  "seconds": ended - started, "machine": os.uname()[1], "gpu": gpu_name(),
                  "python": sys.version.split()[0], "venv": options.get("venv")}
        try:
            with open(os.path.join(job, "status.json"), "w") as handle:
                json.dump(status, handle, indent=1)
        except OSError:
            pass
        release(lock)
    print("remote-train: exit %s after %.0f s" % (code, time.time() - started), flush=True)
    return code if code is not None else 1


# MARK: - Here

def ssh(host, command, timeout=60, stdin=None):
    return subprocess.run(SSH + [host, command], capture_output=True, input=stdin, timeout=timeout)


def reachable(host):
    """None if `host` answers over SSH, else why not."""
    try:
        result = ssh(host, "echo ok", timeout=40)
    except subprocess.TimeoutExpired:
        return "no answer within 40 s"
    if result.returncode != 0 or b"ok" not in result.stdout:
        return (result.stderr.decode(errors="replace").strip() or "ssh exited %d" % result.returncode)
    return None


def remote_options(plan, dataset_dir):
    settings = plan["settings"]
    return {"job": plan["job"], "dataset": dataset_dir, "lock": settings["lock"], "venv": settings["venv"],
            "script": os.path.basename(plan["script"]), "args": plan["args"], "timeout": plan["timeout"],
            "wait": plan["wait"], "stale": settings.get("staleSeconds")}


def probe(host, options):
    """What the host says of the dataset, the lock, its Python and its GPU (this file run there)."""
    with open(os.path.abspath(__file__), "rb") as handle:
        source = handle.read()
    result = ssh(host, "python3 - serve-probe %s" % shlex.quote(json.dumps(options)), timeout=90, stdin=source)
    if result.returncode != 0:
        raise RuntimeError(result.stderr.decode(errors="replace").strip() or "probe exited %d" % result.returncode)
    return json.loads(result.stdout.decode().strip().splitlines()[-1])


def human(count):
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if count < 1000 or unit == "TB":
            return ("%d %s" % (count, unit)) if unit == "B" else ("%.1f %s" % (count, unit))
        count /= 1000.0


def job_record(plan, facts, entries, digest, dataset_dir, sent, started, ended, code, status):
    """job.json: what ran where, from what, when, and how it ended."""
    with open(plan["script"], "rb") as handle:
        script_hash = hashlib.sha256(handle.read()).hexdigest()
    status = status or {}
    return {
        "job": plan["job"], "host": plan["host"], "about": plan["settings"]["about"],
        "machine": (facts or {}).get("machine"), "system": (facts or {}).get("system"),
        "gpu": status.get("gpu") or (facts or {}).get("gpu"), "python": status.get("python") or (facts or {}).get("python"),
        "venv": plan["settings"]["venv"],
        "dataset": {"path": plan["dataset"], "hash": digest, "remote": "~/%s/datasets/%s" % (ROOT, dataset_dir),
                    "files": len(entries), "bytes": sum(size for _, size, _ in entries), "sent": sent},
        "script": {"path": plan["script"], "sha256": script_hash}, "args": plan["args"],
        "timeoutS": plan["timeout"], "started": started, "ended": ended,
        "seconds": None if started is None or ended is None else round(ended - started, 1),
        "remoteSeconds": status.get("seconds"), "exitCode": code, "timedOut": bool(status.get("timedOut")),
    }


def iso(t):
    return None if t is None else datetime.datetime.fromtimestamp(t, datetime.timezone.utc).isoformat()


def main(arguments):
    if arguments and arguments[0].startswith("serve-"):
        options = json.loads(arguments[1])
        return {"serve-probe": serve_probe, "serve-finish-dataset": serve_finish_dataset,
                "serve-run": serve_run}[arguments[0]](options)
    if not arguments or arguments[0] in ("-h", "--help"):
        print(__doc__)
        return 0 if arguments else 2
    try:
        plan = parse(arguments)
    except ValueError as error:
        print("remote-train: %s" % error, file=sys.stderr)
        return 2
    host, settings = plan["host"], plan["settings"]
    if not os.path.isdir(plan["dataset"]):
        print("remote-train: no dataset folder %s" % plan["dataset"], file=sys.stderr)
        return 2
    if not os.path.isfile(plan["script"]):
        print("remote-train: no script %s" % plan["script"], file=sys.stderr)
        return 2
    results = os.path.join(plan["results"], plan["job"])
    if os.path.exists(results) and not plan["dryRun"]:
        print("remote-train: %s already exists; name the job afresh (--job)" % results, file=sys.stderr)
        return 2
    if not plan["known"]:
        print("remote-train: %s is not in HOSTS; using %s" % (host, json.dumps(DEFAULT_HOST)), file=sys.stderr)
    entries = hashed(plan["dataset"])
    digest = content_hash(entries)
    dataset_dir = dataset_name(plan["dataset"], digest)
    size = sum(s for _, s, _ in entries)
    why = reachable(host)
    if why:
        print("remote-train: %s is unreachable: %s" % (host, why), file=sys.stderr)
        return UNREACHABLE
    options = remote_options(plan, dataset_dir)
    try:
        facts = probe(host, options)
    except (RuntimeError, ValueError, subprocess.SubprocessError) as error:
        print("remote-train: %s answered SSH but not the probe (is python3 there?): %s" % (host, error),
              file=sys.stderr)
        return UNREACHABLE
    print("remote-train: %s, %s: %s, Python %s, GPU %s" % (
        host, settings["about"], facts["system"], facts["python"], facts["gpu"] or "none named"), flush=True)
    print("remote-train: dataset %s, %d files, %s, as ~/%s/datasets/%s: %s" % (
        plan["dataset"], len(entries), human(size), ROOT, dataset_dir,
        "already there, not sent" if facts["datasetPresent"] else "to send, %s" % human(size)), flush=True)
    print("remote-train: environment %s (%s); lock ~/%s %s; timeout %.0f s" % (
        "~/" + settings["venv"] if settings["venv"] else "the host's python3",
        "present" if facts["venvPresent"] else "MISSING", settings["lock"],
        "held by %s" % facts["lock"].get("what", "unknown") if facts["lock"] else "free", plan["timeout"]), flush=True)
    print("remote-train: job %s: %s --data <dataset> --out out %s; results to %s" % (
        plan["job"], os.path.basename(plan["script"]), " ".join(shlex.quote(a) for a in plan["args"]), results),
        flush=True)
    if plan["dryRun"]:
        print("remote-train: dry run; nothing sent or run", flush=True)
        return 0 if facts["venvPresent"] else 78
    if not facts["venvPresent"]:
        print("remote-train: no Python environment at ~/%s on %s (see docs/learned-models.md)" % (
            settings["venv"], host), file=sys.stderr)
        return 78
    started = time.time()
    rsync_ssh = ["-e", " ".join(SSH)]
    jobdir = "%s/jobs/%s" % (ROOT, plan["job"])
    made = ssh(host, "mkdir -p %s/datasets %s/out" % (ROOT, jobdir))
    if made.returncode != 0:
        print("remote-train: could not make ~/%s on %s: %s" % (jobdir, host, made.stderr.decode(errors="replace")),
              file=sys.stderr)
        return UNREACHABLE
    sent = False
    if not facts["datasetPresent"]:
        print("remote-train: sending the dataset, %s" % human(size), flush=True)
        copy = subprocess.run(["rsync", "-a", "--partial", "--exclude", ".*"] + rsync_ssh +
                              [plan["dataset"] + "/", "%s:%s/datasets/%s.partial/" % (host, ROOT, dataset_dir)])
        if copy.returncode != 0:
            print("remote-train: sending the dataset failed (rsync %d)" % copy.returncode, file=sys.stderr)
            return copy.returncode
        with open(os.path.abspath(__file__), "rb") as handle:
            finished = ssh(host, "python3 - serve-finish-dataset %s" % shlex.quote(json.dumps(options)),
                           stdin=handle.read())
        if finished.returncode != 0:
            print("remote-train: %s" % finished.stderr.decode(errors="replace"), file=sys.stderr)
            return 1
        sent = True
    copy = subprocess.run(["rsync", "-a"] + rsync_ssh + [plan["script"], os.path.abspath(__file__),
                                                         "%s:%s/" % (host, jobdir)])
    if copy.returncode != 0:
        return copy.returncode
    os.makedirs(results, exist_ok=True)
    command = SSH + ["-tt", "-q", host, "python3 %s/%s serve-run %s" % (
        jobdir, os.path.basename(__file__), shlex.quote(json.dumps(options)))]
    process = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE)

    # Stopped here, the connection goes too, which hangs up the host's end, which stops the script.
    def stop(signum, frame):
        process.terminate()
        sys.exit(128 + signum)

    previous = {signum: signal.signal(signum, stop) for signum in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM)}
    # The host enforces the timeout; this end gives up a quarter of an hour after it and the wait.
    limit = threading.Timer(plan["timeout"] + plan["wait"] + 900, process.terminate)
    limit.daemon = True
    limit.start()
    code = None
    try:
        with open(os.path.join(results, "stream.txt"), "wb") as stream:
            pending = b""
            while True:
                chunk = process.stdout.read1(65536) if hasattr(process.stdout, "read1") else process.stdout.read(1)
                if not chunk:
                    break
                text = (pending + chunk).replace(b"\r\n", b"\n")
                pending = b"\r" if text.endswith(b"\r") else b""
                text = text[:-1] if pending else text
                stream.write(text)
                sys.stdout.buffer.write(text)
                sys.stdout.buffer.flush()
        code = process.wait()
    finally:
        limit.cancel()
        if process.poll() is None:
            process.terminate()
        for signum, handler in previous.items():
            signal.signal(signum, handler)
    # The job's folder back: its output, log and status (the dataset stays there).
    back = subprocess.run(["rsync", "-a"] + rsync_ssh + ["%s:%s/" % (host, jobdir), results + "/"])
    status = None
    try:
        with open(os.path.join(results, "status.json")) as handle:
            status = json.load(handle)
    except (OSError, ValueError):
        pass
    if status and status.get("exitCode") is not None:
        code = status["exitCode"]
    ended = time.time()
    record = job_record(plan, facts, entries, digest, dataset_dir, sent, started, ended, code, status)
    record["started"], record["ended"] = iso(started), iso(ended)
    record["resultsCopied"] = back.returncode == 0
    with open(os.path.join(results, "job.json"), "w") as handle:
        json.dump(record, handle, indent=1)
    print("remote-train: exit %s; results in %s" % (code, results), flush=True)
    return code if isinstance(code, int) else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
