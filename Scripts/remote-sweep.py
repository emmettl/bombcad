#!/usr/bin/env python3
"""Run a sweep of `blastmodel` studies on a Linux host (or here), and compare two sweeps' results.

    python3 -I Scripts/remote-sweep.py run <host|--here> <sweep.json> [--cores 16] [--wait 30m] [--results DIR]
    python3 -I Scripts/remote-sweep.py compare <results-A> <results-B> [--tolerance 1e-9]

A sweep (JSON) names its cases, each the arguments of one `blastmodel` command, and the files they
read:

    {"name": "protect-masses",
     "inputs": ["/Volumes/StudioData/bombcad/glass-strength/protect.json", ...],
     "cases": [{"name": "2t", "args": ["protect", "--osm", "{repo}/Fixtures/SyntheticDistrict/district.osm",
                                       "--inputs", "/Volumes/StudioData/bombcad/glass-strength/protect.json",
                                       "--out", "{out}/plans.json"]}]}

In the arguments, `{repo}` is the repository's copy, `{out}` the case's output folder, and any
argument naming one of the inputs (or a file under an input folder) is taken to the host's copy.

`run` on a host: this worktree goes to ~/bombcad-sweeps/src there (rsync, its build kept between
sweeps), the inputs to ~/bombcad-sweeps/inputs/<sweep>/; then, under the host's sweep lock (one
sweep at a time, the lock's owner a live process of that boot: `--wait` waits for it), `blastmodel`
is built in release and each case run in turn, held to `--cores` of the host's cores (16 of the
PC's 24 by default, so that it may share the box with a training job on the GPU), each case's
output and log in its folder. The results come back to <results>/<sweep>-<host>/ (default
/Volumes/StudioData/bombcad/sweeps), with sweep.json: the host, the cores, each case's time and
exit status. With `--here`, the same on this Mac, with this worktree's release build.

`compare` sets two sweeps' results side by side, file by file in each case's folder: the same
bytes, or for JSON the same structure with numbers within `--tolerance` (relative), or for text
the same lines once times ("in 12.3 s") are left out. Exit 0 if every file agrees.

Exit status of `run`: the first failing case's, 69 if the host could not be reached, 75 if its lock
stayed taken. Nothing on the host but ~/bombcad-sweeps is touched: not the training runner's
~/bombcad-ml or its lock.
"""
import importlib.util
import json
import os
import re
import shlex
import shutil
import signal
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
ROOT = "bombcad-sweeps"  # under the host's home
RESULTS = "/Volumes/StudioData/bombcad/sweeps"
SWIFT_PATHS = "$HOME/.local/share/swiftly/bin"
UNREACHABLE, TAKEN = 69, 75


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
    lock = os.path.join(home, ROOT, "lock")
    boot = runner.boot_id()
    what = "sweep %s" % options["sweep"]["name"]
    deadline = time.time() + options["wait"]
    said = None
    while not runner.acquire(lock, what, boot):
        owner = runner.lock_owner(lock, boot) or {}
        if time.time() >= deadline:
            print("remote-sweep: the lock ~/%s/lock is held (%s); gave up" % (ROOT, owner.get("what", "unknown")),
                  flush=True)
            return TAKEN
        if owner.get("what") != said:
            said = owner.get("what")
            print("remote-sweep: waiting for the lock (%s)" % said, flush=True)
        time.sleep(10)

    def hung_up(signum, frame):
        runner.release(lock)
        os._exit(128 + signum)

    signal.signal(signal.SIGHUP, hung_up)
    signal.signal(signal.SIGTERM, hung_up)
    try:
        def log(line):
            print("remote-sweep: " + line, flush=True)
        repo = os.path.join(home, ROOT, "src")
        out_root = os.path.join(home, ROOT, "runs", options["sweep"]["name"])
        shutil.rmtree(out_root, ignore_errors=True)
        os.makedirs(out_root)
        binary = build(repo, options["cores"], log)
        if binary is None:
            return 1
        started = time.time()
        records, failed = run_cases(options["sweep"], repo, binary, out_root,
                                    os.path.join(home, ROOT, "inputs", options["sweep"]["name"]), options["cores"], log)
        with open(os.path.join(out_root, "sweep.json"), "w") as handle:
            json.dump({"sweep": options["sweep"]["name"], "host": options["host"], "machine": machine(),
                       "coresUsed": options["cores"], "seconds": round(time.time() - started, 1), "cases": records},
                      handle, indent=1)
        return failed
    finally:
        runner.release(lock)


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
    why = runner.reachable(host)
    if why:
        print("remote-sweep: %s is unreachable: %s" % (host, why), file=sys.stderr)
        return UNREACHABLE
    rsync = ["rsync", "-a", "-e", " ".join(SSH)]
    made = runner.ssh(host, "mkdir -p %s/src %s/inputs/%s %s/tools" % (ROOT, ROOT, sweep["name"], ROOT))
    if made.returncode != 0:
        print("remote-sweep: could not make ~/%s on %s" % (ROOT, host), file=sys.stderr)
        return UNREACHABLE
    log("sending this worktree to %s:~/%s/src" % (host, ROOT))
    steps = [
        rsync + ["--delete", "--exclude", "/.build", "--exclude", "/.git", "--exclude", "/.claude", "--exclude", "/dist",
                 REPO + "/", "%s:%s/src/" % (host, ROOT)],
        rsync + [os.path.abspath(__file__), os.path.join(HERE, "ml", "remote-train.py"), "%s:%s/tools/" % (host, ROOT)],
    ]
    if sweep.get("inputs"):
        log("sending %d inputs" % len(sweep["inputs"]))
        steps.append(rsync + [s.rstrip("/") for s in sweep["inputs"]] + ["%s:%s/inputs/%s/" % (host, ROOT, sweep["name"])])
    for step in steps:
        if subprocess.run(step, stdin=subprocess.DEVNULL).returncode != 0:
            print("remote-sweep: sending failed: %s" % " ".join(step[:3]), file=sys.stderr)
            return 1
    options = {"sweep": sweep, "host": host, "cores": cores, "wait": wait}
    command = SSH + ["-tt", "-q", host, "python3 %s/tools/remote-sweep.py serve-run %s" % (
        ROOT, shlex.quote(json.dumps(options)))]
    process = subprocess.Popen(command, stdin=subprocess.DEVNULL)
    code = process.wait()
    os.makedirs(results)
    back = subprocess.run(rsync + ["%s:%s/runs/%s/" % (host, ROOT, sweep["name"]), results + "/"], stdin=subprocess.DEVNULL)
    log("exit %d; results in %s%s" % (code, results, "" if back.returncode == 0 else " (copying them back failed)"))
    return code


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


def main(arguments):
    if arguments and arguments[0] == "serve-run":
        return serve_run(json.loads(arguments[1]))
    if len(arguments) >= 3 and arguments[0] == "run":
        return run(arguments[1:])
    if len(arguments) >= 3 and arguments[0] == "compare":
        return compare(arguments[1:])
    print(__doc__)
    return 0 if arguments[:1] in (["-h"], ["--help"]) else 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
