#!/usr/bin/env python3
"""Run `make check`, or another target, on the shared CI Mac instead of this one.

    python3 Scripts/remote.py check [target]      # on the other Mac, waiting for it politely
    python3 Scripts/remote.py anywhere [target]   # here or there, whichever is quieter
    python3 Scripts/remote.py status              # both Macs' load, GPU and the lock
    python3 Scripts/remote.py free [--mem GB]     # exit 0 if the other Mac would take work now

The other Mac is named in ~/.config/bombcad/remote.json (see docs/continuous-integration.md).
A check there copies this worktree, takes a lock so that only one BombCAD job runs there at a
time, waits while its CI runners are busy or in the quiet window, runs `make <target>` in one
shared folder whose build cache is kept between runs (capped in size), streams its output here
and returns its exit status. The same file runs on the other Mac, sent over SSH, so the policy
and the lock are the same at both ends; `BombCAD worker` keeps the same lock (see RemoteGate).

A job that declares its memory (`check-affected`'s build and tests, `laneGB` or less) may run in a
second lane beside another such job, in a folder and build cache of its own, while the two
together stay under `lanesGB`, no CI runner of any project there has a job and the other Mac's
memory is plentiful. `~/bombcad-remote/lock` stays held while any lane runs, so a worker, a full
check or an older copy of this file sees the Mac taken, as before.
"""
import contextlib
import datetime
import fcntl
import glob
import hashlib
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import threading
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
    # BombCAD jobs it runs at once. A second lane takes only a job declaring at most laneGB, beside
    # jobs that all declared theirs, the lanes' sum at most lanesGB; and only while no runner under
    # ~/Developer/*runner* has a job, memory pressure is normal with laneFreePercent of memory
    # free, and the load is under laneLoadPerCore a core (the first lane's build is most of it).
    "lanes": 2,
    "laneGB": 7,
    "lanesGB": 14,
    "laneFreePercent": 50,
    "laneLoadPerCore": 2.0,
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


def all_runners():
    """Every runner on this Mac, of any project: the folders ~/Developer/*runner* with a bin/."""
    home = os.path.expanduser("~")
    return sorted(os.path.relpath(folder, home) for folder in glob.glob(os.path.join(home, "Developer", "*runner*"))
                  if os.path.isdir(os.path.join(folder, "bin")))


def memory_facts():
    """This Mac's memory pressure level (1 is normal) and its free percentage."""
    facts = {"pressure": None, "freePercent": None}
    try:
        facts["pressure"] = int(subprocess.run(["sysctl", "-n", "kern.memorystatus_vm_pressure_level"],
                                               capture_output=True, text=True, timeout=10).stdout.strip())
        text = subprocess.run(["memory_pressure", "-Q"], capture_output=True, text=True, timeout=20).stdout
        match = re.search(r"free percentage: (\d+)%", text)
        facts["freePercent"] = int(match.group(1)) if match else None
    except (OSError, ValueError, subprocess.SubprocessError):
        pass
    return facts


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


# MARK: - Lanes (run on the other Mac)

def lane_owners(root, count):
    """{lane: owner} of the lanes held now, by live processes."""
    owners = {}
    for lane in range(1, count + 1):
        owner = lock_owner(os.path.join(root, "lanes", str(lane)))
        if owner is not None:
            owners[lane] = dict(owner, lane=lane)
    return owners


def lane_folder(root, lane):
    """The lane's folder: `check` for the first, which every check used before lanes."""
    return os.path.join(root, "check" if lane == 1 else "check-%d" % lane)


def second_lane_refusal(owners, facts, settings, mem):
    """Why a job declaring `mem` GB may not run beside the lanes `owners` ({lane: owner}) now, or
    None. `facts`: "allRunners" (any project's runners with a job), "pressure", "freePercent",
    "load" and "cores"."""
    if mem is None:
        return "this job declares no memory"
    if mem > settings["laneGB"]:
        return "this job declares %s GB, more than a lane's %s" % (mem, settings["laneGB"])
    if len(owners) >= settings["lanes"]:
        return "all %d lanes are taken" % settings["lanes"]
    undeclared = [owner.get("what", "unknown") for owner in owners.values() if owner.get("mem") is None]
    if undeclared:
        return "the job there declares no memory"
    total = sum(owner["mem"] for owner in owners.values()) + mem
    if total > settings["lanesGB"]:
        return "the lanes would declare %s GB, more than %s" % (total, settings["lanesGB"])
    if facts.get("allRunners"):
        return "a CI runner there has a job (%s)" % ", ".join(facts["allRunners"])
    if facts.get("pressure") != 1:
        return "its memory pressure is not normal (level %s)" % facts.get("pressure")
    if (facts.get("freePercent") or 0) < settings["laneFreePercent"]:
        return "%s%% of its memory is free, under the %d%% a second lane wants" % (
            facts.get("freePercent"), settings["laneFreePercent"])
    cores = facts.get("cores") or 1
    if facts.get("load", 0) / cores > settings["laneLoadPerCore"]:
        return "its load is %.1f on %d cores" % (facts["load"], cores)
    return None


def local_facts():
    """What second_lane_refusal asks of this Mac."""
    return dict(memory_facts(), allRunners=busy_runners(all_runners()), load=os.getloadavg()[0],
                cores=os.cpu_count() or 1)


@contextlib.contextmanager
def lanes_mutex(root):
    """Lanes are taken and let go by one process at a time; signals wait until it is done, so that
    a handler letting a lane go never waits on its own process."""
    os.makedirs(root, exist_ok=True)
    signals = {signal.SIGHUP, signal.SIGINT, signal.SIGTERM}
    previous = signal.pthread_sigmask(signal.SIG_BLOCK, signals)
    try:
        with open(os.path.join(root, "lanes.mutex"), "a") as handle:
            fcntl.flock(handle, fcntl.LOCK_EX)
            try:
                yield
            finally:
                fcntl.flock(handle, fcntl.LOCK_UN)
    finally:
        signal.pthread_sigmask(signal.SIG_SETMASK, previous)


def write_owner(path, owner):
    """The owner file, replaced whole: a reader never finds it half written."""
    temporary = os.path.join(path, "owner.%d" % os.getpid())
    with open(temporary, "w") as handle:
        json.dump(owner, handle)
    os.replace(temporary, os.path.join(path, "owner"))


def take_lane(root, settings, what, mem, facts=local_facts):
    """Takes a lane for this process: (lane, None), or (None, why not). The first lane also takes
    the Mac's lock; a later one runs only beside jobs that declared their memory (see
    second_lane_refusal), while the lock stays held."""
    lock = os.path.join(root, "lock")
    with lanes_mutex(root):
        owners = lane_owners(root, settings["lanes"])
        holder = lock_owner(lock)
        if holder is not None and holder.get("pid") not in {owner.get("pid") for owner in owners.values()}:
            # A worker, a full check or an older copy of this file: not a lane, and not to be joined.
            return None, "another BombCAD job holds it (%s)" % holder.get("what", "unknown")
        if not owners:
            for lane in range(1, settings["lanes"] + 1):
                shutil.rmtree(os.path.join(root, "lanes", str(lane)), ignore_errors=True)
            if not acquire(lock, what):
                return None, "another BombCAD job holds it (%s)" % (lock_owner(lock) or {}).get("what", "unknown")
            write_owner(lock, {"pid": os.getpid(), "since": time.time(), "what": what, "mem": mem})
            lane = 1
        else:
            reason = second_lane_refusal(owners, facts(), settings, mem)
            if reason:
                held = ", ".join(owner.get("what", "unknown") for owner in owners.values())
                return None, "another BombCAD job holds it (%s), and a second lane may not run: %s" % (held, reason)
            lane = min(n for n in range(1, settings["lanes"] + 1) if n not in owners)
            shutil.rmtree(os.path.join(root, "lanes", str(lane)), ignore_errors=True)
            if holder is None:  # its holder ended without letting it go: held again, for the lanes
                acquire(lock, what)
        path = os.path.join(root, "lanes", str(lane))
        os.makedirs(path)
        write_owner(path, {"pid": os.getpid(), "since": time.time(), "what": what, "mem": mem})
        return lane, None


def leave_lane(root, settings, lane):
    """Lets this process's lane go, and the Mac's lock with it; or, if this process held the lock
    and another lane still runs, hands the lock to that lane's process."""
    lock = os.path.join(root, "lock")
    with lanes_mutex(root):
        release(os.path.join(root, "lanes", str(lane)))
        owner = lock_owner(lock)
        if owner is None or owner.get("pid") != os.getpid():
            return
        others = lane_owners(root, settings["lanes"])
        if others:
            heir = others[min(others)]
            write_owner(lock, {key: heir.get(key) for key in ("pid", "since", "what", "mem")})
        else:
            shutil.rmtree(lock, ignore_errors=True)


def tree_memory(pid, table=None):
    """The resident memory, in bytes, of process `pid` and all its descendants, together (by
    parent, not process group: the build system may start its compilers in groups of their own).
    `table` is `ps -Ao pid=,ppid=,rss=` output, read now if not given."""
    if table is None:
        try:
            table = subprocess.run(["ps", "-Ao", "pid=,ppid=,rss="], capture_output=True, text=True,
                                   timeout=20).stdout
        except (OSError, subprocess.SubprocessError):
            return 0
    children, resident = {}, {}
    for line in table.splitlines():
        fields = line.split()
        if len(fields) == 3 and all(field.isdigit() for field in fields):
            child, parent, kilobytes = (int(field) for field in fields)
            children.setdefault(parent, []).append(child)
            resident[child] = kilobytes * 1024
    total, pending, seen = 0, [pid], set()
    while pending:
        current = pending.pop()
        if current in seen:
            continue
        seen.add(current)
        total += resident.get(current, 0)
        pending += children.get(current, [])
    return total


def status(settings, seconds=2.0):
    """This Mac's load, GPU use and, on the other Mac, the lock, runners and quiet window."""
    first = gpu_times()
    time.sleep(seconds)
    second = gpu_times()
    deltas = {key: second[key] - first[key] for key in second if key in first and second[key] > first[key]}
    top = sorted(deltas.items(), key=lambda item: -item[1])[:3]
    root = os.path.join(os.path.expanduser("~"), ROOT)
    return dict(memory_facts(), **{
        "load": os.getloadavg()[0],
        "cores": os.cpu_count() or 1,
        "gpu": sum(deltas.values()) / (seconds * 1e9),
        "gpuTop": ["%s %.0f%%" % (key[1], 100 * value / (seconds * 1e9)) for key, value in top],
        "lock": lock_owner(os.path.join(root, "lock")),
        "lanes": list(lane_owners(root, settings["lanes"]).values()),
        "runners": busy_runners(settings["runners"]),
        "allRunners": busy_runners(all_runners()),
        "quiet": in_quiet_window(settings["quietUTC"]),
    })


# MARK: - Deciding

def unavailable(remote, settings, mem=None):
    """Why the other Mac should not take a job now, or None. A job declaring `mem` GB may take a
    second lane beside lanes whose jobs declared theirs (second_lane_refusal)."""
    if remote.get("lock"):
        lanes = {owner.get("lane", index): owner for index, owner in enumerate(remote.get("lanes") or [], 1)}
        if mem is None or remote["lock"].get("pid") not in {owner.get("pid") for owner in lanes.values()}:
            return "another BombCAD job holds it (%s)" % remote["lock"].get("what", "unknown")
        reason = second_lane_refusal(lanes, remote, settings, mem)
        if reason:
            return "another BombCAD job holds it (%s), and a second lane may not run: %s" % (
                ", ".join(owner.get("what", "unknown") for owner in lanes.values()), reason)
    if remote.get("runners"):
        return "its CI runners are busy (%s)" % ", ".join(remote["runners"])
    if remote.get("quiet"):
        return "it is Scrimply's nightly window (%s UTC)" % ", ".join(settings["quietUTC"])
    return None


def refusal(remote, settings, mem=None):
    """What `free` asks: unavailable(), and a load above maxLoadPerCore a core (laneLoadPerCore
    beside another lane, whose build is most of it)."""
    if remote is None:
        return "it did not answer"
    reason = unavailable(remote, settings, mem)
    if reason:
        return reason
    limit = settings["laneLoadPerCore"] if remote.get("lock") else settings["maxLoadPerCore"]
    if remote["load"] / remote["cores"] > limit:
        return "its load is %.1f on %d cores" % (remote["load"], remote["cores"])
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


def serve_check(settings, worktree, target, wait, command=None, mem=None):
    """On the other Mac: wait for a lane and for the runners, then run `make target` (or
    `command`, a list) in the lane's folder, from the worktree copied to worktrees/<worktree>, and
    clean up. A job declaring `mem` GB may take a second lane (take_lane)."""
    home = os.path.expanduser("~")
    root = os.path.join(home, ROOT)
    source = os.path.join(root, "worktrees", worktree)
    command = command or ["make", target]
    label = " ".join(command) if len(" ".join(command)) <= 60 else " ".join(command)[:57] + "..."
    what = "%s from %s%s" % (label, worktree, "" if mem is None else " (%s GB)" % mem)
    deadline = time.time() + wait
    said = None
    process = None
    lane = None

    def stop(signum, frame):
        if process is not None and process.poll() is None:
            os.killpg(process.pid, signal.SIGTERM)
        if lane is not None:
            leave_lane(root, settings, lane)
        shutil.rmtree(source, ignore_errors=True)
        sys.exit(128 + signum)

    for signum in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM):
        signal.signal(signum, stop)
    while True:
        remote = {"lock": None, "runners": busy_runners(settings["runners"]),
                  "quiet": in_quiet_window(settings["quietUTC"])}
        reason = unavailable(remote, settings)
        if reason is None:
            lane, reason = take_lane(root, settings, what, mem)
            if lane is not None:
                break
        if time.time() > deadline:
            print("remote: gave up waiting: %s" % reason, flush=True)
            shutil.rmtree(source, ignore_errors=True)
            return 75
        if reason != said:
            print("remote: waiting, since %s" % reason, flush=True)
            said = reason
        time.sleep(30)
    shared = lane_folder(root, lane)
    try:
        os.makedirs(shared, exist_ok=True)
        cache = os.path.join(shared, ".build")
        size = int(subprocess.run(["du", "-sk", cache], capture_output=True, text=True).stdout.split()[0] or 0) \
            if os.path.isdir(cache) else 0
        if size > settings["cacheGB"] * 1024 * 1024:
            print("remote: the build cache is %.1f GB, over %d GB: cleared" % (size / 1048576, settings["cacheGB"]),
                  flush=True)
            shutil.rmtree(cache, ignore_errors=True)
        # Into the lane's one folder, so that its paths, and the build cache, are the same each time.
        subprocess.run(["rsync", "-a", "--delete", "--exclude", "/.build", source + "/", shared + "/"], check=True)
        print("remote: %s on %s, in ~/%s/%s (lane %d of %d)" % (
            " ".join(command), os.uname()[1], ROOT, os.path.basename(shared), lane, settings["lanes"]), flush=True)
        started = time.time()
        process = subprocess.Popen(command, cwd=shared, start_new_session=True)
        # The job's processes' memory together, sampled: what a lane's declaration is checked against.
        peak = [0]

        def sample():
            while process.poll() is None:
                peak[0] = max(peak[0], tree_memory(process.pid))
                time.sleep(5)

        threading.Thread(target=sample, daemon=True).start()
        code = process.wait()
        gigabytes = peak[0] / 1024 ** 3
        print("remote: %s exited %d after %.0f s, its processes' memory peaking at %.1f GB%s" % (
            label, code, time.time() - started, gigabytes,
            "" if mem is None or gigabytes <= mem else ", over the %s GB it declared" % mem), flush=True)
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
        leave_lane(root, settings, lane)


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


def check_remote(host, settings, target, wait, command=None, mem=None):
    """Copies this worktree to the other Mac and runs `make target` there, or `command` (a list),
    declaring `mem` GB (which lets it take a second lane); its exit status, or 75 if the other Mac
    stayed taken for `wait` seconds."""
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
    ssh = SSH + ["-tt", "-q", host, "python3 %s/worktrees/%s/Scripts/remote.py serve-check --config %s --worktree %s "
                     "--target %s --wait %d%s%s" % (
                         ROOT, worktree, quote(json.dumps(settings)), worktree, target, int(wait),
                         "" if command is None else " --command " + quote(json.dumps(command)),
                         "" if mem is None else " --mem %d" % mem)]
    process = subprocess.Popen(ssh, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE)

    # Stopped here, the connection goes too, which hangs up the other end; left alone, SSH would
    # outlive this process and keep the other end waiting or running.
    def stop(signum, frame):
        process.terminate()
        sys.exit(128 + signum)

    previous = {signum: signal.signal(signum, stop) for signum in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM)}
    try:
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
    finally:
        if process.poll() is None:
            process.terminate()
        for signum, handler in previous.items():
            signal.signal(signum, handler)


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
        command = option("--command", None)
        mem = option("--mem", None)
        return serve_check(settings, option("--worktree", "worktree"), option("--target", "check"),
                           float(option("--wait", "7200")), command=json.loads(command) if command else None,
                           mem=int(mem) if mem is not None else None)
    host = os.environ.get("BOMBCAD_REMOTE_HOST") or settings["host"]
    if not host:
        print("No other Mac set: add \"host\" to %s." % CONFIG, file=sys.stderr)
        return 2
    target = next((a for a in arguments[1:] if not a.startswith("-") and arguments[arguments.index(a) - 1]
                   not in ("--wait", "--mem")), "check")
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
            for owner in remote.get("lanes") or []:
                print("  lane %s: %s" % (owner.get("lane"), owner.get("what", "unknown")))
            print("  memory %s%% free, pressure level %s; a %d GB job would %s" % (
                remote.get("freePercent"), remote.get("pressure"), settings["laneGB"],
                "be taken" if refusal(remote, settings, settings["laneGB"]) is None else
                "not: " + refusal(remote, settings, settings["laneGB"])))
        print("would run %s: %s" % choose(local, remote, settings))
        return 0
    if command == "free":
        # `free --mem GB`: whether a job declaring that much would be taken, in a second lane if need be.
        mem = option("--mem", None)
        reason = refusal(remote_status(host, settings), settings, int(mem) if mem is not None else None)
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
