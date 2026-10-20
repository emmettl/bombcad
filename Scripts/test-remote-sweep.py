"""Tests of remote-sweep.py's cases and comparison: python3 Scripts/test-remote-sweep.py"""

import importlib.util
import json
import os
import tempfile
import unittest

here = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("remote_sweep", os.path.join(here, "remote-sweep.py"))
sweep = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sweep)


class CaseTests(unittest.TestCase):
    def test_inputs_repo_and_out_are_taken_to_the_hosts_copies(self):
        args = ["protect", "--osm", "{repo}/Fixtures/a.osm", "--inputs", "/data/in/protect.json",
                "--confirm", "/data/loads", "--out", "{out}/plans.json", "--centre", "1,2"]
        mapped = sweep.localize(args, ["/data/in/", "/data/loads"], "/home/x/src", "/home/x/runs/a", "/home/x/inputs/s")
        self.assertEqual(mapped, [
            "protect", "--osm", "/home/x/src/Fixtures/a.osm", "--inputs", "/home/x/inputs/s/in/protect.json",
            "--confirm", "/home/x/inputs/s/loads", "--out", "/home/x/runs/a/plans.json", "--centre", "1,2"])
        # Here, the inputs stay where they are.
        self.assertEqual(sweep.localize(["/data/loads"], ["/data/loads"], "/r", "/o", None), ["/data/loads"])


class CompareTests(unittest.TestCase):
    def test_numbers_within_the_tolerance_agree_and_beyond_it_do_not(self):
        self.assertEqual(sweep.same_json({"a": [1.0, 2.0]}, {"a": [1.0, 2.0 * (1 + 1e-12)]}, 1e-9), [])
        self.assertEqual(len(sweep.same_json({"a": 1.0}, {"a": 1.1}, 1e-9)), 1)
        self.assertEqual(len(sweep.same_json({"a": 1}, {"b": 1}, 1e-9)), 1)

    def test_two_sweeps_compare_file_by_file_times_left_out(self):
        with tempfile.TemporaryDirectory() as folder:
            for side, (plans, log) in {"a": ({"cost": 10.0}, "Chances in 25.7 s\n204 sides"),
                                       "b": ({"cost": 10.0}, "Chances in 9.1 s\n204 sides")}.items():
                os.makedirs(os.path.join(folder, side, "one"))
                json.dump({"cases": [{"case": "one"}]}, open(os.path.join(folder, side, "sweep.json"), "w"))
                json.dump(plans, open(os.path.join(folder, side, "one", "plans.json"), "w"))
                open(os.path.join(folder, side, "one", "log.txt"), "w").write(log)
            self.assertEqual(sweep.compare([os.path.join(folder, "a"), os.path.join(folder, "b")]), 0)
            open(os.path.join(folder, "b", "one", "log.txt"), "w").write("Chances in 9.1 s\n205 sides")
            self.assertEqual(sweep.compare([os.path.join(folder, "a"), os.path.join(folder, "b")]), 1)


if __name__ == "__main__":
    unittest.main()
