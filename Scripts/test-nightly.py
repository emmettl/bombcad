"""Exercise the nightly comparison without running the solver."""

import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location("nightly", Path(__file__).with_name("nightly.py"))
nightly = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(nightly)


class NightlyTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.history = self.root / "history"
        self.out = self.root / "out"
        self.out.mkdir()
        self.entry = nightly.Entry("beam", ["beam"], "result")

    def night(self, name, output, seconds=10.0, status="ok"):
        directory = self.history / name
        directory.mkdir(parents=True)
        (directory / "beam.txt").write_text(output)
        record = {"commands": {"beam": {"status": status, "seconds": seconds}}}
        (directory / "run.json").write_text(json.dumps(record))

    def test_masks_wall_times_but_not_results(self):
        self.assertEqual(nightly.mask_times("peak 97 mm, run took 12.3 s"), "peak 97 mm, run took # s")
        self.assertEqual(nightly.mask_times("170 ms simulated, 0.2 s"), "170 ms simulated, # s")

    def test_compares_with_last_successful_night(self):
        self.night("20261001T010000Z-aaaaaaa", "peak 97 mm, 40.1 s\n")
        self.night("20261002T010000Z-bbbbbbb", "garbage\n", status="exit 1")
        (self.out / "beam.txt").write_text("peak 97 mm, 44.0 s\n")
        previous = nightly.previous_runs(self.history, "beam")
        self.assertEqual([directory.name for directory, _, _ in previous], ["20261001T010000Z-aaaaaaa"])
        self.assertEqual(nightly.compare_result(self.entry, self.out, previous), "")
        (self.out / "beam.txt").write_text("peak 98 mm, 44.0 s\n")
        self.assertIn("+peak 98 mm", nightly.compare_result(self.entry, self.out, previous))

    def test_flags_slow_runs_only_with_enough_history(self):
        for day, seconds in [(1, 100.0), (2, 104.0)]:
            self.night(f"2026100{day}T010000Z-aaaaaaa", "x\n", seconds)
        self.assertEqual(nightly.compare_time(200.0, nightly.previous_runs(self.history, "beam")), (None, False))
        self.night("20261003T010000Z-aaaaaaa", "x\n", 102.0)
        previous = nightly.previous_runs(self.history, "beam")
        self.assertEqual(nightly.compare_time(118.0, previous), (102.0, False))
        self.assertEqual(nightly.compare_time(130.0, previous), (102.0, True))


if __name__ == "__main__":
    unittest.main()
