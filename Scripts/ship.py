"""Land this branch on main: the one command a session uses to push its work.

    make ship                    # check, rebase, push
    make ship ARGS=--dry-run     # what it would do, running nothing
    make ship ARGS=--remote      # check-affected's build and tests on the mini (--local: here)

In order, each step's exit status checked and nothing piped:

1. Refuses a dirty tree (untracked files included: check-affected would build them), a rebase or
   merge in progress, a branch holding merge commits (a rebase drops them silently), or nothing to
   push. Run inside gpu-slot it refuses too: check-affected queues its own GPU steps.
2. `make format`; if that changed anything, stops and asks for it to be committed.
3. `make lint`, and `make build-strict` when the branch changes Swift, Metal or the package.
4. `python3 Scripts/check-affected.py`, bare (with `--remote` or `--local` if given).
5. `git fetch origin`, and a rebase onto origin/main if main has moved.
6. The diff check: `git diff origin/main...HEAD --stat` must hold only files that the branch's own
   commits changed, and the branch must not look like a commit made over a stale copy (as 459e15f8
   was): blocks that recent commits on main put in, taken out with the text before them back, or
   taken out of the code in two files (or one large block). Refused with the list;
   `--allow-reverts` passes the second when the removal is meant.
7. If main moved since the check, the check runs again only when the new commits on main touch one
   of the branch's files or a core file (check-affected's CORE); otherwise straight to the push.
8. `git push origin HEAD:main`; rejected as not a fast-forward, it fetches, rebases, checks the
   diff (and re-checks, by step 7) and pushes again, three times at most.
9. One line: what was pushed, the tier, and how long it all took.
"""

import argparse
import importlib.util
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
REMOTE = "origin"
BRANCH = "main"
# Push attempts after the first, and checks after the first, before giving up.
ATTEMPTS = 3
# The revert guard: a block of at least this many substantial lines, put in by one of the last
# RECENT_COMMITS commits on main to touch a file within RECENT_DAYS, that the branch takes out whole.
REVERT_BLOCK = 5
LARGE_BLOCK = 25
RECENT_COMMITS = 20
RECENT_DAYS = 4
CODE_FILE = re.compile(r"^(Sources|Tests)/.*\.(swift|metal)$")
CODE = re.compile(r"\.(swift|metal|h|c|m)$|^Package\.(swift|resolved)$")


def core_patterns():
    """check-affected's CORE list: files whose change on main means re-checking."""
    spec = importlib.util.spec_from_file_location("check_affected", Path(__file__).with_name("check-affected.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.CORE


class Refused(Exception):
    """Ship stops here: the message says why and what to do."""


def default_commands(where):
    check = [sys.executable, "Scripts/check-affected.py"] + ([f"--{where}"] if where else [])
    return {"format": ["make", "format"], "lint": ["make", "lint"], "build": ["make", "build-strict"],
            "check": check, "check-dry-run": check + ["--dry-run"]}


class Ship:
    def __init__(self, root=ROOT, commands=None, core=None, allow_reverts=False, out=None):
        self.root = Path(root)
        self.commands = commands or default_commands(None)
        self.core = core if core is not None else core_patterns()
        self.allow_reverts = allow_reverts
        self.out = out or (lambda text: print(text, flush=True))
        self.upstream = f"{REMOTE}/{BRANCH}"
        self.checks = 0
        self.check_seconds = 0.0
        self.rebases = 0
        self.pushes = 0

    # MARK: - Commands

    def git(self, *arguments, check=True):
        """git's standard output; a failure (when `check`) refuses with its message."""
        completed = subprocess.run(["git", *arguments], cwd=self.root, text=True, stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE)
        if check and completed.returncode:
            raise Refused(f"`git {' '.join(arguments)}` failed ({completed.returncode}): "
                          f"{completed.stderr.strip() or completed.stdout.strip()}")
        return completed.stdout

    def run(self, name):
        """Runs one of the gated steps with its output on this terminal; its exit status."""
        command = self.commands[name]
        self.out("+ " + " ".join(shlex.quote(part) for part in command))
        return subprocess.run(command, cwd=self.root).returncode

    def gate(self, name, why):
        status = self.run(name)
        if status:
            raise Refused(f"{why} failed (exit {status}); nothing was pushed")

    # MARK: - What the branch is

    def commits(self):
        return self.git("rev-list", "--reverse", f"{self.upstream}..HEAD").split()

    def own_files(self, commits):
        """Files the branch's own commits change."""
        files = set()
        for commit in commits:
            files.update(self.git("diff-tree", "--no-commit-id", "--name-only", "-r", commit).split("\n"))
        return {path for path in files if path}

    def dirty(self):
        return self.git("status", "--porcelain", "--untracked-files=normal").strip()

    def in_progress(self):
        for name in ("rebase-merge", "rebase-apply", "MERGE_HEAD", "CHERRY_PICK_HEAD"):
            path = Path(self.git("rev-parse", "--git-path", name).strip())
            if not path.is_absolute():
                path = self.root / path
            if path.exists():
                return name
        return None

    def preflight(self):
        if os.environ.get("GPU_SLOT_TICKET"):
            raise Refused("run `make ship` without gpu-slot: check-affected queues its own GPU steps, and held "
                          "in a slot it stays here and keeps the slot while it waits")
        if operation := self.in_progress():
            raise Refused(f"a {operation} is in progress; finish or abort it first")
        if status := self.dirty():
            raise Refused("the tree has uncommitted changes; commit or remove them first:\n" + status)
        commits = self.commits()
        if not commits:
            raise Refused(f"nothing to ship: HEAD is already on {self.upstream}")
        merges = self.git("rev-list", "--merges", f"{self.upstream}..HEAD").split()
        if merges:
            listed = "\n".join("  " + self.git("log", "-1", "--format=%h %s", merge).strip() for merge in merges)
            raise Refused("the branch holds merge commits, which a rebase drops silently; make them plain commits "
                          "(for example `git rebase origin/main`, then check `git log origin/main..HEAD`):\n"
                          + listed)
        return commits

    # MARK: - The diff check

    def diff_check(self, own):
        """Refuses unless the branch's three-dot diff holds only its own files and takes out no block
        a recent commit on main put in."""
        stat = self.git("diff", f"{self.upstream}...HEAD", "--stat")
        self.out(stat.rstrip())
        files = {path for path in self.git("diff", "--name-only", f"{self.upstream}...HEAD").split("\n") if path}
        extra = sorted(files - own)
        if extra:
            raise Refused("the diff against main holds files the branch's own commits don't change:\n"
                          + "\n".join("  " + path for path in extra))
        reverts = self.reverted_blocks(files)
        if reverts and not self.allow_reverts:
            raise Refused("the branch takes out blocks that recent commits on main put in (a commit made over a "
                          "stale copy?); check them, and pass --allow-reverts if they are meant:\n"
                          + "\n".join("  " + line for line in reverts))

    def reverted_blocks(self, files):
        """What the branch takes out of recent work on main, as lines to show; empty when nothing
        looks like a stale copy. A block counts when the branch removes at least REVERT_BLOCK of its
        substantial lines (three quarters of it), not moved elsewhere. It is reported when the text it
        replaced is back (a revert), or, for code, when blocks in two files are taken or one of
        LARGE_BLOCK lines: measured on 300 commits of main, that flags 459e15f8's stale copy in six
        files and one commit in 300 besides (a1a16aaf, a file split by script)."""
        removed, added = changed_lines(self.git("diff", "-U0", f"{self.upstream}...HEAD"))
        moved = set().union(*added.values()) if added else set()
        base = self.git("merge-base", "HEAD", self.upstream).strip()
        restored, code = [], []
        for path in sorted(files):
            gone = removed.get(path, set()) - moved
            if len(gone) < REVERT_BLOCK or path.startswith("docs/release-notes/"):
                continue
            head = {line.strip() for line in self.git("show", f"HEAD:{path}", check=False).splitlines()}
            recent = self.git("log", f"-{RECENT_COMMITS}", f"--since={RECENT_DAYS}.days", "--no-merges",
                              "--format=%H", base, "--", path).split()
            for commit in recent:
                hit = None
                for old, new in diff_hunks(self.git("show", "-U0", "--format=", commit, "--", path)):
                    taken = [line for line in new if line in gone]
                    if len(taken) >= REVERT_BLOCK and len(taken) * 4 >= len(new) * 3:
                        back = bool(old) and sum(line in head for line in old) * 4 >= len(old) * 3
                        hit = (len(taken), back)
                        break
                if hit:
                    subject = self.git("log", "-1", "--format=%h %s", commit).strip()
                    line = f"{path}: {hit[0]} lines from {subject}" + (", the text before it back" if hit[1] else "")
                    if hit[1]:
                        restored.append(line)
                    elif CODE_FILE.search(path):
                        code.append((hit[0], line))
                    break
        if restored or len(code) >= 2 or any(size >= LARGE_BLOCK for size, _ in code):
            return restored + [line for _, line in code]
        return []

    # MARK: - Main moving

    def fetch(self):
        self.git("fetch", REMOTE)

    def rebase(self, commits):
        """Rebases onto the upstream; refuses (after aborting) on a conflict or a dropped commit."""
        subjects = [self.git("log", "-1", "--format=%s", commit).strip() for commit in commits]
        completed = subprocess.run(["git", "rebase", self.upstream], cwd=self.root, text=True,
                                   stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        if completed.returncode:
            self.git("rebase", "--abort", check=False)
            raise Refused(f"the rebase onto {self.upstream} stopped (exit {completed.returncode}), and was aborted; "
                          f"rebase by hand, then run make ship again:\n{completed.stdout.strip()}")
        self.rebases += 1
        after = [self.git("log", "-1", "--format=%s", commit).strip() for commit in self.commits()]
        missing = [subject for subject in subjects if subject not in after]
        if missing:
            raise Refused("the rebase left out commits (already on main, or emptied); check `git log "
                          f"{self.upstream}..HEAD` and run make ship again:\n"
                          + "\n".join("  " + subject for subject in missing))
        return self.commits()

    def touching(self, since, own):
        """Files that commits on main since `since` changed and that matter to this branch: its own,
        and the core."""
        changed = {path for path in self.git("diff", "--name-only", since, self.upstream).split("\n") if path}
        return sorted(path for path in changed
                      if path in own or any(pattern.search(path) for pattern in self.core))

    def push(self):
        """(pushed, rejected as not a fast-forward, output)."""
        self.pushes += 1
        self.out(f"+ git push {REMOTE} HEAD:{BRANCH}")
        completed = subprocess.run(["git", "push", REMOTE, f"HEAD:{BRANCH}"], cwd=self.root, text=True,
                                   stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        self.out(completed.stdout.rstrip())
        stale = bool(re.search(r"non-fast-forward|fetch first|\[rejected\]", completed.stdout))
        return completed.returncode == 0, stale, completed.stdout

    def check(self):
        started = time.monotonic()
        self.gate("check", "check-affected")
        self.checks += 1
        self.check_seconds += time.monotonic() - started

    # MARK: - The whole thing

    def dry_run(self, commits, own):
        self.out(f"ship --dry-run: {len(commits)} commit(s) on {self.upstream}, {len(own)} file(s):")
        for commit in commits:
            self.out("  " + self.git("log", "-1", "--format=%h %s", commit).strip())
        swift = any(CODE.search(path) for path in own)
        self.out("would run: make format (and stop if it changes anything), make lint"
                 + (", make build-strict" if swift else " (no Swift or Metal: no build-strict)")
                 + ", then check-affected, bare:")
        status = self.run("check-dry-run")
        self.out(f"then: git fetch, rebase onto {self.upstream} if it moved, the diff check, "
                 f"git push {REMOTE} HEAD:{BRANCH}")
        return status

    def ship(self, dry_run=False):
        started = time.monotonic()
        commits = self.preflight()
        own = self.own_files(commits)
        if dry_run:
            return self.dry_run(commits, own)
        self.gate("format", "make format")
        if status := self.dirty():
            raise Refused("make format changed files; commit them (`git commit -am 'Format'`) and run make ship "
                          "again:\n" + status)
        self.gate("lint", "make lint")
        if any(CODE.search(path) for path in own):
            self.gate("build", "make build-strict")
        checked = self.git("merge-base", "HEAD", self.upstream).strip()
        self.check()
        rejected = 0
        while True:
            self.fetch()
            moved = self.git("rev-list", f"HEAD..{self.upstream}").split()
            if moved:
                self.out(f"ship: main moved by {len(moved)} commit(s); rebasing")
                commits = self.rebase(commits)
            self.diff_check(own)
            since_check = self.git("rev-list", f"{checked}..{self.upstream}").split()
            touched = self.touching(checked, own) if since_check else []
            if touched:
                if self.checks > ATTEMPTS:
                    raise Refused(f"main keeps changing this branch's files or the core ({self.checks} checks); "
                                  "nothing was pushed: run make ship again later")
                shown = ", ".join(touched[:6]) + (f" and {len(touched) - 6} more" if len(touched) > 6 else "")
                self.out(f"ship: main's new commits touch {shown}: checking again")
                checked = self.git("merge-base", "HEAD", self.upstream).strip()
                self.check()
                continue
            if not self.is_ancestor(self.upstream, "HEAD") or self.in_progress():
                raise Refused("HEAD is not on top of main after the rebase; nothing was pushed")
            pushed, stale, output = self.push()
            if pushed:
                break
            if not stale:
                raise Refused("git push failed, and not because main moved; nothing more was tried")
            rejected += 1
            if rejected > ATTEMPTS:
                raise Refused(f"main moved under {rejected} pushes; run make ship again")
            self.out("ship: main moved before the push; fetching and rebasing again")
            # A commit pushed meanwhile was checked against `checked`, which stays the base to compare.
        head = self.git("rev-parse", "--short", "HEAD").strip()
        self.out(f"ship: pushed {len(commits)} commit(s) to {BRANCH} at {head}: {self.checks} check(s) in "
                 f"{self.check_seconds:.0f} s, {self.rebases} rebase(s), {self.pushes} push(es), "
                 f"{time.monotonic() - started:.0f} s in all")
        return 0

    def is_ancestor(self, ancestor, descendant):
        return subprocess.run(["git", "merge-base", "--is-ancestor", ancestor, descendant], cwd=self.root,
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0


# MARK: - Diff parsing


def substantial(line):
    stripped = line.strip()
    return len(stripped) >= 8 and any(character.isalnum() for character in stripped)


def changed_lines(diff_text):
    """({path: removed lines}, {path: added lines}), stripped and substantial, from a -U0 diff."""
    removed, added, path = {}, {}, None
    for line in diff_text.splitlines():
        if line.startswith("+++ "):
            path = line[6:] if line.startswith("+++ b/") else None
        elif line.startswith("--- "):
            if line.startswith("--- a/"):
                path = line[6:]
        elif line.startswith("diff --git "):
            path = None
        elif path and line.startswith("-") and substantial(line[1:]):
            removed.setdefault(path, set()).add(line[1:].strip())
        elif path and line.startswith("+") and substantial(line[1:]):
            added.setdefault(path, set()).add(line[1:].strip())
    return removed, added


def diff_hunks(diff_text):
    """[(removed, added)] per hunk of a -U0 diff of one file, each its substantial lines, stripped."""
    hunks, old, new = [], [], []
    for line in diff_text.splitlines():
        if line.startswith("@@"):
            if old or new:
                hunks.append((old, new))
            old, new = [], []
        elif line.startswith("-") and not line.startswith("--- ") and substantial(line[1:]):
            old.append(line[1:].strip())
        elif line.startswith("+") and not line.startswith("+++ ") and substantial(line[1:]):
            new.append(line[1:].strip())
    if old or new:
        hunks.append((old, new))
    return hunks


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--dry-run", action="store_true", help="say what would run; change nothing")
    where = parser.add_mutually_exclusive_group()
    where.add_argument("--remote", action="store_true", help="check-affected's build and tests on the other Mac")
    where.add_argument("--local", action="store_true", help="check-affected's build and tests here")
    parser.add_argument("--allow-reverts", action="store_true",
                        help="push although the branch takes out blocks recent commits on main put in")
    options = parser.parse_args(argv)
    commands = default_commands("remote" if options.remote else "local" if options.local else None)
    try:
        return Ship(commands=commands, allow_reverts=options.allow_reverts).ship(dry_run=options.dry_run)
    except Refused as refusal:
        print(f"ship: refused: {refusal}", flush=True)
        return 1


if __name__ == "__main__":
    sys.exit(main())
