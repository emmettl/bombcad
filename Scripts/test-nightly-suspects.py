"""Exercise the nightly full check's report: failures named, suspects since the last green."""

import importlib.util
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location("suspects", Path(__file__).with_name("nightly-suspects.py"))
suspects = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(suspects)


class SuspectsTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.repo = self.directory.name
        env = dict(os.environ, GIT_AUTHOR_NAME="A", GIT_AUTHOR_EMAIL="a@x", GIT_COMMITTER_NAME="A",
                   GIT_COMMITTER_EMAIL="a@x")
        self.git = lambda *a: subprocess.run(["git", "-C", self.repo] + list(a), check=True, env=env,
                                             capture_output=True, text=True).stdout.strip()
        self.git("init", "-q")
        self.commits = []
        for subject in ["First", "Second", "Third"]:
            Path(self.repo, subject).write_text(subject)
            self.git("add", subject)
            self.git("commit", "-q", "-m", subject)
            self.commits.append(self.git("rev-parse", "HEAD"))

    def test_failures_are_named_once_each(self):
        log = "\n".join([
            '✘ Test "A slab bends" recorded an issue at X.swift:3:1: Expectation failed',
            '✘ Test "A slab bends" failed after 2.0 seconds with 1 issue.',
            "Sources/A.swift:12:5: error: cannot find 'x' in scope",
            "make: *** [test] Error 1",
        ])
        self.assertEqual(suspects.failures(log), [
            "A slab bends", "Sources/A.swift:12:5: error: cannot find 'x' in scope", "make: *** [test] Error 1"])

    def test_suspects_are_the_commits_since_the_last_green(self):
        found = suspects.suspects(self.repo, self.commits[0])
        self.assertEqual([line.split(" ", 1)[1] for line in found], ["Third (A)", "Second (A)"])
        self.assertEqual(suspects.suspects(self.repo, self.commits[2]), [])
        self.assertIsNone(suspects.suspects(self.repo, ""))
        self.assertIsNone(suspects.suspects(self.repo, "0" * 40))

    def test_a_pass_moves_the_marker_and_a_failure_does_not(self):
        marker = Path(self.repo, "marker")
        marker.write_text(self.commits[0])
        log = Path(self.repo, "log")
        log.write_text('✘ Test "Broken" failed after 1 seconds with 1 issue.\n')
        summary = Path(self.repo, "summary")
        suspects.main(["--outcome", "failure", "--log", str(log), "--marker", str(marker), "--summary",
                       str(summary), "--repo", self.repo])
        text = summary.read_text()
        self.assertIn("FAILED", text)
        self.assertIn("Broken", text)
        self.assertIn("the 2 commits since the last green", text)
        self.assertEqual(marker.read_text().strip(), self.commits[0])
        suspects.main(["--outcome", "success", "--log", str(log), "--marker", str(marker), "--repo", self.repo])
        self.assertEqual(marker.read_text().strip(), self.commits[2])


if __name__ == "__main__":
    unittest.main()
