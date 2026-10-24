"""Where this checkout's SwiftPM build lives: `make build-dir` prints it, `make clean-build` removes it.

    python3 Scripts/build-dir.py [path]   # the build folder, after linking .build to it
    python3 Scripts/build-dir.py clean    # this checkout's build folder removed, and the link
    python3 Scripts/build-dir.py list     # the build folders under $BOMBCAD_DATA/builds, and whose

On the Studio, where /Volumes/StudioData/bombcad exists, a checkout on another disk (the boot
disk's worktrees under .claude/worktrees/, 1.5 to 2.5 GB of build each, filled it on 23 and 24
October 2026) builds into $BOMBCAD_DATA/builds/<folder name>-<hash of its path>, and its `.build`
is a symbolic link there. Everything that names `.build` (the Makefile, the scripts, the tests,
the docs' commands, a bare `swift build` or `swift test`) then reaches that folder by the same path
as before, so SwiftPM's build stays incremental whichever of them builds. Passing the folder itself
as `--scratch-path` would not: SwiftPM records the paths it was given, and a build alternating
between two spellings of one folder plans everything afresh ("Stale file ... outside of the allowed
root paths").

Everywhere else (CI, the mini and its lanes, the PCs, the MacBook) `.build` is an ordinary folder,
as it always was; so too for a checkout already on StudioData (the release, perf and digest-cache
worktrees), where moving it would gain nothing. BOMBCAD_BUILDS names another parent folder, or set
empty keeps `.build` an ordinary folder.

A checkout whose `.build` is still a folder on the boot disk has it moved across on the next build
(a copy, so that the build stays incremental), unless SwiftPM is building in it then: it is left
for the next time. A `.build` linked somewhere else on StudioData by hand is left as it is.
"""

import fcntl
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time

STUDIO = Path("/Volumes/StudioData/bombcad")
ROOT = Path(__file__).resolve().parents[1]
LINK = ".build"
# Where a `.build` folder waits while it is replaced by the link (removed straight after).
MOVING = ".build.moving"
# Recorded in each build folder: the checkout it belongs to (for `list`).
CHECKOUT = ".bombcad-checkout"
SWIFTPM = {"swift-build", "swift-test", "swift-run", "swift-package"}


def say(text):
    print(f"build-dir: {text}", file=sys.stderr, flush=True)


def builds_folder(environment=os.environ):
    """The parent of the checkouts' build folders, or None where `.build` stays a folder."""
    if "BOMBCAD_BUILDS" in environment:
        return Path(environment["BOMBCAD_BUILDS"]) if environment["BOMBCAD_BUILDS"] else None
    if STUDIO.is_dir():
        return Path(environment.get("BOMBCAD_DATA") or STUDIO) / "builds"
    return None


def name(root):
    """A checkout's build folder's name: its own folder's name and a short hash of its path."""
    root = Path(root).resolve()
    return f"{root.name}-{hashlib.sha256(str(root).encode()).hexdigest()[:8]}"


def existing_ancestor(path):
    path = Path(path)
    while not path.exists() and path != path.parent:
        path = path.parent
    return path


def same_volume(a, b):
    return os.stat(existing_ancestor(a)).st_dev == os.stat(existing_ancestor(b)).st_dev


def planned(root, builds=None):
    """The folder `root` builds into through its `.build` link, or None where `.build` stays an
    ordinary folder (no StudioData, or the checkout is on it already)."""
    builds = builds_folder() if builds is None else builds
    if builds is None or same_volume(root, builds):
        return None
    return Path(builds) / name(root)


def inside(path, folder):
    """Whether `path` is `folder` or in it, and not in a checkout nested in it (the main checkout
    holds the worktrees under .claude/)."""
    return (path == folder or path.startswith(folder + "/")) and not path.startswith(folder + "/.claude/")


def busy(folder, built=None):
    """The pids of processes using `folder`'s build (a checkout's): SwiftPM's, and programs run
    from its `.build` (a blastbench run reads its resource bundles there), whose arguments name the
    checkout (or `built`, its build folder) or whose working directory is in it."""
    folder = str(Path(folder).resolve())
    built = str(Path(built).resolve()) if built else None
    try:
        listing = subprocess.run(["ps", "-axo", "pid=,command="], capture_output=True, text=True).stdout
    except OSError:
        return []
    found = []
    for line in listing.splitlines():
        pid, _, command = line.strip().partition(" ")
        words = command.split()
        if not words or not pid.isdigit() or int(pid) == os.getpid():
            continue
        if os.path.basename(words[0]) not in SWIFTPM and "/.build/" not in words[0] \
                and not words[0].startswith(".build/") and not (built and inside(words[0], built)):
            continue
        if any(inside(part, folder) or (built and inside(part, built)) for word in words for part in word.split("=")):
            found.append(int(pid))
            continue
        try:
            cwd = subprocess.run(["lsof", "-a", "-p", pid, "-d", "cwd", "-Fn"], capture_output=True, text=True).stdout
        except OSError:
            return [0]  # can't tell: as good as busy
        if any(inside(entry[1:], folder) for entry in cwd.splitlines() if entry.startswith("n")):
            found.append(int(pid))
    return found


class Lock:
    """One change to a checkout's link at a time (two `make` targets started together)."""

    def __init__(self, target):
        Path(target).parent.mkdir(parents=True, exist_ok=True)
        self.path = Path(target).with_name(Path(target).name + ".lock")

    def __enter__(self):
        self.handle = open(self.path, "w")
        fcntl.flock(self.handle, fcntl.LOCK_EX)
        return self

    def __exit__(self, *exception):
        fcntl.flock(self.handle, fcntl.LOCK_UN)
        self.handle.close()


def size_gb(folder):
    try:
        listing = subprocess.run(["du", "-sk", str(folder)], capture_output=True, text=True).stdout.split()
        return int(listing[0]) / 1024 ** 2
    except (OSError, ValueError, IndexError):
        return 0.0


def link_to(link, target):
    link.symlink_to(target, target_is_directory=True)


def move_in(root, link, target):
    """A `.build` folder copied to `target` and replaced by a link to it; False if SwiftPM is
    building in it now."""
    pids = busy(root)
    if pids:
        say(f"{link} is a folder on this disk, but SwiftPM or a program from it is running (pid {', '.join(map(str, pids))}): "
            f"left there; the next build moves it to {target}")
        return False
    started = time.monotonic()
    say(f"moving {link} ({size_gb(link):.1f} GB) to {target}, once; the build stays incremental")
    partial = target.with_name(target.name + ".partial")
    shutil.rmtree(partial, ignore_errors=True)
    shutil.copytree(link, partial, symlinks=True)
    moving = root / MOVING
    shutil.rmtree(moving, ignore_errors=True)
    link.rename(moving)
    if target.exists() or target.is_symlink():
        stale = target.with_name(target.name + ".stale")
        shutil.rmtree(stale, ignore_errors=True)
        target.rename(stale)
        shutil.rmtree(stale, ignore_errors=True)
    partial.rename(target)
    link_to(link, target)
    shutil.rmtree(moving, ignore_errors=True)
    say(f"moved in {time.monotonic() - started:.0f} s")
    return True


def ensure(root=ROOT, builds=None):
    """This checkout's build folder, `.build` linked to it first where builds go to StudioData. Never
    stops a build: on any trouble it says so and leaves `.build` as it is."""
    root = Path(root).resolve()
    link = root / LINK
    try:
        target = planned(root, builds)
        if target is None:
            return link
        if link.is_symlink() and link.resolve() == target.resolve() and target.is_dir():
            return target
        with Lock(target):
            if link.is_symlink():
                pointed = link.resolve()
                if pointed == target.resolve() and target.is_dir():
                    return target
                if pointed.is_dir() and same_volume(pointed, target.parent):
                    return pointed  # linked by hand, on StudioData: left as it is
                link.unlink()
            elif link.is_dir():
                if not move_in(root, link, target):
                    return link
                record(root, target)
                return target
            elif link.exists():
                say(f"{link} is a file, not a folder or a link: left as it is")
                return link
            target.mkdir(parents=True, exist_ok=True)
            link_to(link, target)
            record(root, target)
            shutil.rmtree(root / MOVING, ignore_errors=True)
            return target
    except OSError as error:
        say(f"could not link {link} to StudioData ({error}); building in {link} as it is")
        return link


def record(root, target):
    try:
        (target / CHECKOUT).write_text(str(root) + "\n")
    except OSError:
        pass


def clean(root=ROOT, builds=None):
    """This checkout's build removed: the folder `.build` links to, and the link; or `.build` itself."""
    root = Path(root).resolve()
    link = root / LINK
    target = planned(root, builds)
    pids = busy(root, link.resolve() if link.is_symlink() else target)
    if pids:
        say(f"SwiftPM or a program from {link} is running (pid {', '.join(map(str, pids))}): nothing removed")
        return 1
    folders = []
    if link.is_symlink():
        folders.append(link.resolve())
        link.unlink()
    elif link.is_dir():
        folders.append(link)
    if target is not None and target.exists() and target.resolve() not in [path.resolve() for path in folders]:
        folders.append(target)
    for folder in folders:
        gigabytes = size_gb(folder)
        shutil.rmtree(folder, ignore_errors=True)
        print(f"removed {folder} ({gigabytes:.1f} GB)")
    if not folders:
        print(f"no build folder for {root}")
    shutil.rmtree(root / MOVING, ignore_errors=True)
    return 0


def listing(builds=None):
    """The build folders under the builds folder: name, checkout, and whether that is still there."""
    builds = builds_folder() if builds is None else builds
    if builds is None or not Path(builds).is_dir():
        print("no builds folder here: each checkout builds in its own .build")
        return 0
    for folder in sorted(path for path in Path(builds).iterdir() if path.is_dir()):
        try:
            checkout = (folder / CHECKOUT).read_text().strip()
        except OSError:
            checkout = "?"
        gone = checkout != "?" and not (Path(checkout) / "Package.swift").exists()
        print("\t".join([folder.name, checkout] + (["(checkout gone)"] if gone else [])))
    return 0


def main(arguments):
    command = arguments[0] if arguments else "path"
    if command == "path":
        print(ensure())
        return 0
    if command == "clean":
        return clean()
    if command == "list":
        return listing()
    print(__doc__.split("\n\n")[1], file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
