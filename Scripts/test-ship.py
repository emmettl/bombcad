"""make ship (Scripts/ship.py) on temporary repositories: a bare one as origin, a clone as the
worktree and another as the rest of the sessions, pushing to main meanwhile. The gated steps are
made-up commands that count their runs; nothing reaches the network."""

import importlib.util
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

SPEC = importlib.util.spec_from_file_location("ship", Path(__file__).with_name("ship.py"))
ship = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(ship)

BLOCK = "".join(f"    let important{index} = computeSomething({index})\n" for index in range(6))


def git(root, *arguments):
    return subprocess.run(["git", *arguments], cwd=root, check=True, text=True, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE).stdout


class Repositories:
    """origin (bare), `work` (this session's clone, on a branch) and `other` (another session)."""

    def __init__(self, directory):
        self.directory = Path(directory)
        self.origin = self.directory / "origin.git"
        subprocess.run(["git", "init", "--quiet", "--bare", "--initial-branch=main", str(self.origin)], check=True)
        self.other = self.clone("other")
        self.write(self.other, "a.txt", "one\ntwo\nthree\n")
        self.write(self.other, "notes.txt", "notes\n")
        self.write(self.other, "Sources/BlastCore/BlastSolver.swift", "final class BlastSolver {}\n")
        self.write(self.other, "Sources/BlastCore/Footing.swift", "struct Footing {}\n" + "\n" * 10 + "// end\n")
        self.commit(self.other, "Start")
        git(self.other, "push", "--quiet", "origin", "HEAD:main")
        self.work = self.clone("work")
        git(self.work, "checkout", "--quiet", "-b", "feature")

    def clone(self, name):
        path = self.directory / name
        subprocess.run(["git", "clone", "--quiet", str(self.origin), str(path)], check=True,
                       stderr=subprocess.DEVNULL)
        git(path, "config", "user.name", "Test")
        git(path, "config", "user.email", "test@example.com")
        git(path, "config", "commit.gpgsign", "false")
        return path

    def write(self, root, path, text):
        (root / path).parent.mkdir(parents=True, exist_ok=True)
        (root / path).write_text(text)

    def commit(self, root, message):
        git(root, "add", "-A")
        git(root, "commit", "--quiet", "-m", message)

    def push_other(self, path, text, message="Another session's work"):
        """Another session lands a commit on main."""
        git(self.other, "pull", "--quiet", "--rebase", "origin", "main")
        self.write(self.other, path, text)
        self.commit(self.other, message)
        git(self.other, "push", "--quiet", "origin", "HEAD:main")

    def main_head(self):
        return git(self.origin, "rev-parse", "main").strip()


class Counter:
    """A made-up step: a command that appends to a file each time it runs, and exits `status`."""

    def __init__(self, directory, name, status=0, touch=None):
        self.path = Path(directory) / f"{name}.count"
        script = f"open({str(self.path)!r}, 'a').write('x\\n')"
        if touch:
            script += f"; open({str(touch)!r}, 'a').write('formatted\\n')"
        script += f"; raise SystemExit({status})"
        self.command = [sys.executable, "-c", script]

    @property
    def runs(self):
        return len(self.path.read_text().splitlines()) if self.path.exists() else 0


class ShipTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.directory = Path(directory.name)
        self.repos = Repositories(self.directory)
        self.lines = []
        self.counters = {name: Counter(self.directory, name) for name in ("format", "lint", "build", "check",
                                                                           "check-dry-run")}
        environment = mock.patch.dict(os.environ, {"GPU_SLOT_TICKET": ""})
        environment.start()
        self.addCleanup(environment.stop)

    def make(self, cls=None, **arguments):
        commands = {name: counter.command for name, counter in self.counters.items()}
        return (cls or ship.Ship)(root=self.repos.work, commands=commands,
                                  core=[re.compile(r"^Sources/BlastCore/BlastSolver")],
                                  out=self.lines.append, **arguments)

    def branch_commit(self, path="a.txt", text="one\ntwo\nthree\nfour\n", message="My work"):
        self.repos.write(self.repos.work, path, text)
        self.repos.commit(self.repos.work, message)

    def refused(self, shipper, words):
        with self.assertRaises(ship.Refused) as raised:
            shipper.ship()
        self.assertIn(words, str(raised.exception))
        return str(raised.exception)

    def test_a_clean_branch_is_checked_and_pushed(self):
        self.branch_commit()
        self.assertEqual(self.make().ship(), 0)
        self.assertEqual(self.repos.main_head(), git(self.repos.work, "rev-parse", "HEAD").strip())
        self.assertEqual([self.counters[name].runs for name in ("format", "lint", "build", "check")], [1, 1, 0, 1])
        self.assertTrue(self.lines[-1].startswith("ship: pushed 1 commit(s) to main"), self.lines[-1])
        self.assertTrue(any("a.txt" in line and "|" in line for line in self.lines), "the --stat is shown")

    def test_swift_changes_get_the_strict_build(self):
        self.branch_commit("Sources/BlastCore/Footing.swift", "struct Footing { let x = 1 }\n")
        self.assertEqual(self.make().ship(), 0)
        self.assertEqual(self.counters["build"].runs, 1)

    def test_a_dirty_tree_an_untracked_file_and_nothing_to_push_are_refused(self):
        self.refused(self.make(), "nothing to ship")
        self.branch_commit()
        (self.repos.work / "stray.txt").write_text("x\n")
        self.refused(self.make(), "uncommitted changes")
        (self.repos.work / "stray.txt").unlink()
        (self.repos.work / "a.txt").write_text("edited\n")
        self.refused(self.make(), "uncommitted changes")
        self.assertEqual(self.counters["check"].runs, 0)

    def test_merge_commits_are_refused(self):
        self.branch_commit()
        self.repos.push_other("notes.txt", "more notes\n")
        git(self.repos.work, "fetch", "--quiet")
        git(self.repos.work, "merge", "--quiet", "--no-edit", "origin/main")
        self.refused(self.make(), "merge commits")

    def test_inside_gpu_slot_it_refuses(self):
        self.branch_commit()
        with mock.patch.dict(os.environ, {"GPU_SLOT_TICKET": "slot.1"}):
            self.refused(self.make(), "without gpu-slot")

    def test_a_format_that_changes_files_stops_it(self):
        self.branch_commit()
        self.counters["format"] = Counter(self.directory, "format", touch=self.repos.work / "a.txt")
        message = self.refused(self.make(), "make format changed files")
        self.assertIn("a.txt", message)
        self.assertEqual(self.counters["check"].runs, 0)
        self.assertNotEqual(self.repos.main_head(), git(self.repos.work, "rev-parse", "HEAD").strip())

    def test_a_failed_lint_or_check_pushes_nothing(self):
        self.branch_commit()
        before = self.repos.main_head()
        for name in ("lint", "check"):
            with self.subTest(step=name):
                self.counters[name] = Counter(self.directory, name + "-failing", status=2)
                self.refused(self.make(), "failed (exit 2)")
                self.assertEqual(self.repos.main_head(), before)
                self.counters[name] = Counter(self.directory, name)

    def moving(self, path, text):
        """A Ship whose check lets another session push to main meanwhile, the first time."""
        repos = self.repos

        class Moving(ship.Ship):
            def check(inner):
                super().check()
                if inner.checks == 1:
                    repos.push_other(path, text)
        return self.make(Moving)

    def test_main_moving_elsewhere_pushes_without_checking_again(self):
        self.branch_commit()
        self.assertEqual(self.moving("notes.txt", "more notes\n").ship(), 0)
        self.assertEqual(self.counters["check"].runs, 1)
        log = git(self.repos.origin, "log", "--format=%s", "main").split("\n")
        self.assertEqual(log[:2], ["My work", "Another session's work"])

    def test_main_moving_over_the_branchs_files_checks_again(self):
        self.branch_commit("Sources/BlastCore/Footing.swift",
                           "struct Footing { let x = 1 }\n" + "\n" * 10 + "// end\n")
        moving = self.moving("Sources/BlastCore/Footing.swift", "struct Footing {}\n" + "\n" * 10 + "// the end\n")
        self.assertEqual(moving.ship(), 0)
        self.assertEqual(self.counters["check"].runs, 2)
        self.assertTrue(any("checking again" in line for line in self.lines))

    def test_main_moving_over_the_core_checks_again(self):
        self.branch_commit()
        self.assertEqual(self.moving("Sources/BlastCore/BlastSolver.swift", "final class BlastSolver { }\n").ship(), 0)
        self.assertEqual(self.counters["check"].runs, 2)

    def test_a_conflicting_rebase_is_aborted(self):
        self.branch_commit()
        before = git(self.repos.work, "rev-parse", "HEAD").strip()
        self.refused(self.moving("a.txt", "one\ntwo\nthree\nFOUR\n"), "rebase")
        self.assertIsNone(self.make().in_progress())
        self.assertEqual(git(self.repos.work, "rev-parse", "HEAD").strip(), before)
        self.assertEqual(git(self.repos.origin, "log", "-1", "--format=%s", "main").strip(), "Another session's work")

    def test_a_push_rejected_as_not_a_fast_forward_is_tried_again(self):
        self.branch_commit()
        repos = self.repos

        class Raced(ship.Ship):
            def push(inner):
                if inner.pushes == 0:
                    repos.push_other("notes.txt", "raced\n")
                return super().push()
        shipper = self.make(Raced)
        self.assertEqual(shipper.ship(), 0)
        self.assertEqual(shipper.pushes, 2)
        self.assertEqual(self.counters["check"].runs, 1)
        self.assertEqual(git(self.repos.origin, "log", "-1", "--format=%s", "main").strip(), "My work")

    def test_a_stale_copy_taking_out_recent_blocks_is_refused(self):
        # Another session adds blocks to two files; this session's commit, made over a stale copy of
        # both, takes them out.
        footing, solver = "Sources/BlastCore/Footing.swift", "Sources/BlastCore/BlastSolver.swift"
        self.repos.push_other(footing, "struct Footing {\n" + BLOCK + "}\n", "The block")
        self.repos.push_other(solver, "final class BlastSolver {\n" + BLOCK.replace("let", "var") + "}\n",
                              "The other block")
        git(self.repos.work, "pull", "--quiet", "--rebase", "origin", "main")
        self.repos.write(self.repos.work, solver, "final class BlastSolver {}\n")
        self.branch_commit(footing, "struct Footing {\n    let mine = 1\n}\n", "Stale copy")
        message = self.refused(self.make(), "stale copy")
        self.assertIn("Footing.swift: 6 lines from", message)
        self.assertIn("The other block", message)
        self.assertEqual(self.make(allow_reverts=True).ship(), 0)

    def test_putting_back_the_text_a_recent_commit_replaced_is_refused(self):
        notes = "".join(f"The old wording of line {index}, as it was.\n" for index in range(6))
        self.repos.push_other("notes.txt", notes, "Old wording")
        self.repos.push_other("notes.txt", notes.replace("old", "new"), "New wording")
        git(self.repos.work, "pull", "--quiet", "--rebase", "origin", "main")
        self.branch_commit("notes.txt", notes + "And mine.\n", "Stale notes")
        self.assertIn("the text before it back", self.refused(self.make(), "stale copy"))

    def test_taking_out_one_recent_block_of_code_is_a_refactor(self):
        footing = "Sources/BlastCore/Footing.swift"
        self.repos.push_other(footing, "struct Footing {\n" + BLOCK + "}\n", "The block")
        git(self.repos.work, "pull", "--quiet", "--rebase", "origin", "main")
        self.branch_commit(footing, "struct Footing {\n    let simpler = 1\n}\n", "Simpler")
        self.assertEqual(self.make().ship(), 0)

    def test_moving_a_block_is_not_taking_it_out(self):
        footing = "Sources/BlastCore/Footing.swift"
        self.repos.push_other(footing, "struct Footing {\n" + BLOCK + "}\n", "The block")
        git(self.repos.work, "pull", "--quiet", "--rebase", "origin", "main")
        self.branch_commit(footing, "struct Footing {\n}\n", "Move it")
        self.branch_commit("Sources/BlastCore/Other.swift", "struct Other {\n" + BLOCK + "}\n", "To here")
        self.assertEqual(self.make().ship(), 0)

    def test_the_diff_check_refuses_files_not_the_branchs_own(self):
        self.branch_commit()
        with self.assertRaises(ship.Refused) as raised:
            self.make().diff_check(set())
        self.assertIn("a.txt", str(raised.exception))

    def test_a_dry_run_changes_nothing(self):
        self.branch_commit("Sources/BlastCore/Footing.swift", "struct Footing { let x = 1 }\n")
        before = self.repos.main_head()
        self.assertEqual(self.make().ship(dry_run=True), 0)
        self.assertEqual(self.repos.main_head(), before)
        self.assertEqual([self.counters[name].runs for name in ("format", "lint", "build", "check", "check-dry-run")],
                         [0, 0, 0, 0, 1])
        self.assertTrue(any("make build-strict" in line for line in self.lines))

    def test_the_options_reach_check_affected(self):
        self.assertEqual(ship.default_commands("remote")["check"][-1], "--remote")
        self.assertEqual(ship.default_commands("local")["check-dry-run"][-2:], ["--local", "--dry-run"])
        self.assertEqual(ship.default_commands(None)["check"][-1], "Scripts/check-affected.py")


class DiffParsingTests(unittest.TestCase):
    def test_changed_and_added_lines(self):
        diff = ("diff --git a/x.swift b/x.swift\n--- a/x.swift\n+++ b/x.swift\n@@ -1,2 +1 @@\n"
                "-    let removedLine = 1\n-}\n+    let addedLine = 2\n")
        removed, added = ship.changed_lines(diff)
        self.assertEqual(removed, {"x.swift": {"let removedLine = 1"}})
        self.assertEqual(added, {"x.swift": {"let addedLine = 2"}})
        hunks = ship.diff_hunks("@@ -0,0 +1,3 @@\n+    let first = 1\n+}\n+    let second = 2\n@@ -9 +9 @@\n"
                                "-    let before = 0\n+x\n")
        self.assertEqual(hunks, [([], ["let first = 1", "let second = 2"]), (["let before = 0"], [])])


if __name__ == "__main__":
    unittest.main()
