#!/usr/bin/env python3
"""Run `make check`, or another target, on the shared CI Mac instead of this one.

    python3 Scripts/remote.py check [target]      # on the other Mac, waiting for it politely
    python3 Scripts/remote.py anywhere [target]   # here or there, whichever is quieter
    python3 Scripts/remote.py status              # both Macs' load, GPU and the lock
    python3 Scripts/remote.py free                # exit 0 if the other Mac would take work now

The other Mac is named in ~/.config/bombcad/remote.json (see docs/continuous-integration.md).
A check there copies this worktree, takes a lock so that only one BombCAD job runs there at a
time, waits while its CI runners are busy or in the quiet window, runs `make <target>` in one
shared folder whose build cache is kept between runs (capped in size), streams its output here
and returns its exit status. The same file runs on the other Mac, sent over SSH, so the policy
and the lock are the same at both ends; `BombCAD worker` keeps the same lock (see RemoteGate).
"""
import datetime
import hashlib
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import time

CONFIG = os.environ.get("BOMBCAD_REMOTE_CONFIG", os.path.expanduser("~/.config/bombcad/remote.json"))
DEFAULTS = {
    # The Mac checks and workers go to, an SSH host; none until configured.
    "host": None,
    # Hosts `BombCAD sweep` and `BombCAD ensemble` include when free, without --worker.
    "workers": [],
    # Runners (folders under the other Mac's home) whose jobs it waits for.
    "runners": ["Developer/bombcad-runner", "Developer/actions-runner", "Developer/actions-runner-2"],
    # Times, in UTC, it keeps clear of: Scrimply's nightly.
    "quietUTC": ["01:30-04:30"],
    # Above this load average a core, the other Mac is busy.
    "maxLoadPerCore": 1.0,
    # The shared build cache there is cleared when it grows past this.
    "cacheGB": 20,
    # How many times longer a check takes there than here, both quiet.
    "remoteRatio": 3.0,
}
ROOT = "bombcad-remote"  # under the other Mac's home
SSH = ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "-o", "ServerAliveInterval=15",
       "-o", "ServerAliveCountMax=4"]
STALE_SECONDS = 6 * 3600


def config():
    settings = dict(DEFAULTS)
    try:
        with open(CONFIG) as handle:
            settings.update(json.load(handle))
    except FileNotFoundError:
        pass
    return settings


# MARK: - What a machine is doing (runs on either Mac)

def gpu_times():
    """Each process's accumulated GPU time in ns, from ioreg: the AppUsage line comes before the
    line naming the client's creator, so it is kept until that line arrives."""
    try:
        text = subprocess.run(["ioreg", "-r", "-c", "AGXDeviceUserClient", "-l", "-w0"],
                              capture_output=True, text=True, timeout=20).stdout
    except (OSError, subprocess.SubprocessError):
        return {}
    times = {}
    usage = None
    for line in text.splitlines():
        if '"AppUsage"' in line:
            usage = line
        match = re.search(r'"IOUserClientCreator" = "pid (\d+), ([^"]*)"', line)
        if match:
            total = sum(int(v) for v in re.findall(r'"accumulatedGPUTime"=(\d+)', usage or ""))
            key = (int(match.group(1)), match.group(2))
            times[key] = times.get(key, 0) + total
            usage = None
    return times


def busy_runners(runners):
    """The runners in `runners` running a job now: a Runner.Worker process under their folder."""
    try:
        text = subprocess.run(["ps", "-Ao", "command"], capture_output=True, text=True).stdout
    except OSError:
        return []
    home = os.path.expanduser("~")
    busy = []
    for runner in runners:
        folder = os.path.join(home, runner)
        if any(line.startswith(folder + "/bin/Runner.Worker") for line in text.splitlines()):
            busy.append(runner)
    return busy


def in_quiet_window(windows, now=None):
    """Whether UTC time `now` (default the present) falls in one of `windows`, "HH:MM-HH:MM"."""
    now = now or datetime.datetime.now(datetime.timezone.utc)
    minute = now.hour * 60 + now.minute
    for window in windows:
        start, end = window.split("-")
        a = int(start[:2]) * 60 + int(start[3:])
        b = int(end[:2]) * 60 + int(end[3:])
        if (a <= minute < b) if a <= b else (minute >= a or minute < b):
            return True
    return False


def lock_owner(path):
    """The lock's owner, if it is held by a process still alive and not stale; else None."""
    try:
        with open(os.path.join(path, "owner")) as handle:
            owner = json.load(handle)
    except (OSError, ValueError):
        # Being written: a moment old, it is held.
        return {"pid": None, "what": "starting"} if os.path.isdir(path) else None
    try:
        os.kill(int(owner["pid"]), 0)
    except (OSError, KeyError, ValueError, TypeError):
        return None
    if time.time() - float(owner.get("since", 0)) > STALE_SECONDS:
        return None
    return owner


def acquire(path, what):
    """Takes the lock if it is free or its owner gone; False if another holds it."""
    if lock_owner(path) is None and os.path.isdir(path):
        shutil.rmtree(path, ignore_errors=True)
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        os.mkdir(path)
    except FileExistsError:
        return False
    with open(os.path.join(path, "owner"), "w") as handle:
        json.dump({"pid": os.getpid(), "since": time.time(), "what": what}, handle)
    return True


def release(path):
    owner = lock_owner(path)
    if owner is not None and owner.get("pid") == os.getpid():
        shutil.rmtree(path, ignore_errors=True)


def status(settings, seconds=2.0):
    """This Mac's load, GPU use and, on the other Mac, the lock, runners and quiet window."""
    first = gpu_times()
    time.sleep(seconds)
    second = gpu_times()
    deltas = {key: second[key] - first[key] for key in second if key in first and second[key] > first[key]}
    top = sorted(deltas.items(), key=lambda item: -item[1])[:3]
    lock = os.path.join(os.path.expanduser("~"), ROOT, "lock")
    return {
        "load": os.getloadavg()[0],
        "cores": os.cpu_count() or 1,
        "gpu": sum(deltas.values()) / (seconds * 1e9),
        "gpuTop": ["%s %.0f%%" % (key[1], 100 * value / (seconds * 1e9)) for key, value in top],
        "lock": lock_owner(lock),
        "runners": busy_runners(settings["runners"]),
        "quiet": in_quiet_window(settings["quietUTC"]),
    }


# MARK: - Deciding

def unavailable(remote, settings):
    """Why the other Mac should not take a job now, or None."""
    if remote.get("lock"):
        return "another BombCAD job holds it (%s)" % remote["lock"].get("what", "unknown")
    if remote.get("runners"):
        return "its CI runners are busy (%s)" % ", ".join(remote["runners"])
    if remote.get("quiet"):
        return "it is Scrimply's nightly window (%s UTC)" % ", ".join(settings["quietUTC"])
    return None


def busyness(machine):
    """How much a job would be slowed: load beyond half a core each, plus the GPU's use."""
    return max(0.0, machine["load"] / machine["cores"] - 0.5) + min(machine["gpu"], 2.0)


def choose(local, remote, settings):
    """Where to run: ("here" or "there", the reason). There if it is free and its estimated time,
    `remoteRatio` times this Mac's when both are quiet, is shorter with each one's busyness."""
    if remote is None:
        return "here", "the other Mac did not answer"
    reason = unavailable(remote, settings)
    if reason:
        return "here", "the other Mac is not free: " + reason
    here = 1 + busyness(local)
    there = settings["remoteRatio"] * (1 + busyness(remote))
    detail = "here %.1f (load %.0f on %d cores, GPU %.0f%%) against there %.1f (load %.0f on %d, GPU %.0f%%)" % (
        here, local["load"], local["cores"], 100 * local["gpu"], there, remote["load"], remote["cores"],
        100 * remote["gpu"])
    return ("there", detail) if there < here else ("here", detail)


# MARK: - On the other Mac

def serve_status(settings):
    print(json.dumps(status(settings)))


def serve_check(settings, worktree, target, wait):
    """On the other Mac: wait for the lock and for the runners, then run `make target` in the
    shared folder, from the worktree copied to worktrees/<worktree>, and clean up."""
    home = os.path.expanduser("~")
    root = os.path.join(home, ROOT)
    lock = os.path.join(root, "lock")
    source = os.path.join(root, "worktrees", worktree)
    shared = os.path.join(root, "check")
    deadline = time.time() + wait
    said = None
    process = None

    def stop(signum, frame):
        if process is not None and process.poll() is None:
            os.killpg(process.pid, signal.SIGTERM)
        release(lock)
        shutil.rmtree(source, ignore_errors=True)
        sys.exit(128 + signum)

    for signum in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM):
        signal.signal(signum, stop)
    while True:
        remote = {"lock": None, "runners": busy_runners(settings["runners"]),
                  "quiet": in_quiet_window(settings["quietUTC"])}
        reason = unavailable(remote, settings)
        if reason is None:
            if acquire(lock, "make %s from %s" % (target, worktree)):
                break
            reason = "another BombCAD job holds it (%s)" % (lock_owner(lock) or {}).get("what", "unknown")
        if time.time() > deadline:
            print("remote: gave up waiting: %s" % reason, flush=True)
            shutil.rmtree(source, ignore_errors=True)
            return 75
        if reason != said:
            print("remote: waiting, since %s" % reason, flush=True)
            said = reason
        time.sleep(30)
    try:
        os.makedirs(shared, exist_ok=True)
        cache = os.path.join(shared, ".build")
        size = int(subprocess.run(["du", "-sk", cache], capture_output=True, text=True).stdout.split()[0] or 0) \
            if os.path.isdir(cache) else 0
        if size > settings["cacheGB"] * 1024 * 1024:
            print("remote: the build cache is %.1f GB, over %d GB: cleared" % (size / 1048576, settings["cacheGB"]),
                  flush=True)
            shutil.rmtree(cache, ignore_errors=True)
        # Into the one shared folder, so that its paths, and the build cache, are the same each time.
        subprocess.run(["rsync", "-a", "--delete", "--exclude", "/.build", source + "/", shared + "/"], check=True)
        print("remote: make %s on %s, in ~/%s/check" % (target, os.uname()[1], ROOT), flush=True)
        started = time.time()
        process = subprocess.Popen(["make", target], cwd=shared, start_new_session=True)
        code = process.wait()
        print("remote: make %s exited %d after %.0f s" % (target, code, time.time() - started), flush=True)
        return code
    finally:
        # Keep only the build cache.
        shutil.rmtree(source, ignore_errors=True)
        if os.path.isdir(shared):
            for name in os.listdir(shared):
                if name != ".build":
                    path = os.path.join(shared, name)
                    if os.path.isdir(path) and not os.path.islink(path):
                        shutil.rmtree(path, ignore_errors=True)
                    else:
                        os.remove(path)
        release(lock)


# MARK: - Here

def repository():
    return os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def remote_python(host, arguments):
    """Runs this file on `host` with `arguments`, sent over SSH, and returns what it printed."""
    with open(os.path.abspath(__file__), "rb") as handle:
        script = handle.read()
    command = SSH + [host, "python3 - " + " ".join(arguments)]
    result = subprocess.run(command, input=script, capture_output=True, timeout=120)
    if result.returncode != 0:
        raise RuntimeError(result.stderr.decode(errors="replace").strip() or "no answer from %s" % host)
    return result.stdout.decode()


def remote_status(host, settings):
    try:
        return json.loads(remote_python(host, ["serve-status", "--config", quote(json.dumps(settings))]))
    except (RuntimeError, ValueError, subprocess.SubprocessError) as error:
        print("remote: %s did not answer: %s" % (host, error), file=sys.stderr)
        return None


def quote(text):
    return "'" + text.replace("'", "'\\''") + "'"


def check_remote(host, settings, target, wait):
    """Copies this worktree to the other Mac and runs `make target` there; its exit status."""
    root = repository()
    # A folder of its own for each request, so that two from one worktree, one waiting for the
    # other, do not share it.
    worktree = "%s-%s-%s" % (os.path.basename(root), hashlib.sha256(
        (os.uname()[1] + root).encode()).hexdigest()[:8], os.urandom(3).hex())
    destination = "%s:%s/worktrees/%s/" % (host, ROOT, worktree)
    print("remote: copying %s to %s" % (root, destination), flush=True)
    subprocess.run(SSH + [host, "mkdir -p %s/worktrees/%s" % (ROOT, worktree)], check=True)
    copy = subprocess.run(
        ["rsync", "-a", "--delete", "--exclude", "/.build", "--exclude", "/.git", "--exclude", "/.claude",
         "--exclude", "/dist", "--exclude", "/out", "-e", " ".join(SSH), root + "/", destination])
    if copy.returncode != 0:
        return copy.returncode
    # Under a terminal, so that the other Mac's end is hung up on if this one stops, rather than
    # waiting on and running for nobody; the copy's own script runs there. The terminal's line
    # endings are put back as they were.
    command = SSH + ["-tt", host, "python3 %s/worktrees/%s/Scripts/remote.py serve-check --config %s --worktree %s "
                     "--target %s --wait %d" % (ROOT, worktree, quote(json.dumps(settings)), worktree, target,
                                                int(wait))]
    process = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE)
    pending = b""
    while True:
        chunk = process.stdout.read1(65536) if hasattr(process.stdout, "read1") else process.stdout.read(1)
        if not chunk:
            break
        text = (pending + chunk).replace(b"\r\n", b"\n")
        pending = b"\r" if text.endswith(b"\r") else b""
        sys.stdout.buffer.write(text[:-1] if pending else text)
        sys.stdout.buffer.flush()
    return process.wait()


def main(arguments):
    command = arguments[0] if arguments else "status"
    settings = config()
    if "--config" in arguments:
        settings.update(json.loads(arguments[arguments.index("--config") + 1]))

    def option(name, default):
        return arguments[arguments.index(name) + 1] if name in arguments else default

    if command == "serve-status":
        serve_status(settings)
        return 0
    if command == "serve-check":
        return serve_check(settings, option("--worktree", "worktree"), option("--target", "check"),
                           float(option("--wait", "7200")))
    host = os.environ.get("BOMBCAD_REMOTE_HOST") or settings["host"]
    if not host:
        print("No other Mac set: add \"host\" to %s." % CONFIG, file=sys.stderr)
        return 2
    target = next((a for a in arguments[1:] if not a.startswith("-") and arguments[arguments.index(a) - 1]
                   not in ("--wait",)), "check")
    wait = float(option("--wait", "7200"))
    if command == "check":
        return check_remote(host, settings, target, wait)
    if command == "status":
        local = status(settings)
        remote = remote_status(host, settings)
        print("here: load %.1f on %d cores, GPU %.0f%% (%s)" % (
            local["load"], local["cores"], 100 * local["gpu"], ", ".join(local["gpuTop"]) or "idle"))
        if remote:
            print("%s: load %.1f on %d cores, GPU %.0f%% (%s); %s" % (
                host, remote["load"], remote["cores"], 100 * remote["gpu"], ", ".join(remote["gpuTop"]) or "idle",
                unavailable(remote, settings) or "free"))
        print("would run %s: %s" % choose(local, remote, settings))
        return 0
    if command == "free":
        remote = remote_status(host, settings)
        reason = "it did not answer" if remote is None else unavailable(remote, settings) or (
            "its load is %.1f on %d cores" % (remote["load"], remote["cores"])
            if remote["load"] / remote["cores"] > settings["maxLoadPerCore"] else None)
        print("%s is %s" % (host, "free" if reason is None else "not free: " + reason))
        return 0 if reason is None else 1
    if command == "anywhere":
        forced = os.environ.get("BOMBCAD_CHECK_WHERE")
        if forced in ("here", "there"):
            where, why = forced, "BOMBCAD_CHECK_WHERE=%s" % forced
        else:
            where, why = choose(status(settings), remote_status(host, settings), settings)
        print("check-anywhere: running %s on %s, since %s" % (
            target, "this Mac" if where == "here" else host, why), flush=True)
        if where == "there":
            code = check_remote(host, settings, target, wait=0)
            # Taken by another job between the look and the run: here instead.
            if code != 75:
                return code
            print("check-anywhere: %s was taken meanwhile; running here" % host, flush=True)
        return subprocess.run(["make", target], cwd=repository()).returncode
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
