"""The learned field model's split and input encoding, without PyTorch.

train_field.py imports PyTorch at the top, though its split, its standardisation and its runs'
features are NumPy alone, so a stand-in module takes PyTorch's place when it is not installed (CI,
the PCs' WSL2 before their venv). The tests:

- the strict split (`--holdout-layouts beirut,made-*-s6`) holds out every Beirut run and each
  made-up style's sixth layout, 75 runs, and no held-out layout is trained on; the rounds by run
  share their layouts between the two sides, as docs/learned-models.md says;
- the standardisation's statistics, and the mask's cells left out by the run's own targets;
- the encoding parity fixture (Fixtures/LearnedField/parity), which BlastModelTests' `LearnedField`
  tests check `LearnedField.networkInputs` against: train_field.py's features of one run's
  `inputs.npy`, standardised and padded to a multiple of 16 as judge_field.py's `predict` pads
  them, on a plan of 37 × 23 (neither a multiple of 16), with Kingery–Bulmash's values under their
  clamps. `python3 -I Scripts/ml/test-field-model.py --write-fixture` writes it again.
"""

import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile
import types
import unittest

import numpy as np

HERE = Path(__file__).parent
REPOSITORY = HERE.parent.parent
FIXTURE = REPOSITORY / "Fixtures" / "LearnedField" / "parity"


def stand_in_torch():
    """PyTorch, or a stand-in with what train_field.py's module level touches."""
    try:
        import torch  # noqa: F401
        return
    except ImportError:
        pass
    torch = types.ModuleType("torch")
    nn = types.ModuleType("torch.nn")
    functional = types.ModuleType("torch.nn.functional")
    nn.Module = object
    nn.functional = functional
    torch.nn = nn
    sys.modules.update({"torch": torch, "torch.nn": nn, "torch.nn.functional": functional})


def load(name, file):
    spec = importlib.util.spec_from_file_location(name, HERE / file)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


stand_in_torch()
train_field = load("train_field", "train_field.py")
field_runs = load("field_runs", "field-runs.py")

EXPORT_CHANNELS = ["height", "ground", "distance", "logScaledDistance", "kingeryBulmashPeak",
                   "kingeryBulmashImpulse"]


def write_run(folder, raw, targets, mask, run_id="parity", layout="parity"):
    os.makedirs(folder, exist_ok=True)
    np.save(os.path.join(folder, "inputs.npy"), raw.astype("<f4"))
    np.save(os.path.join(folder, "targets.npy"), targets.astype("<f4"))
    np.save(os.path.join(folder, "mask.npy"), mask.astype("<f4"))
    with open(os.path.join(folder, "meta.json"), "w") as handle:
        json.dump({"id": run_id, "layout": layout, "stable": True,
                   "inputs": [{"name": n} for n in EXPORT_CHANNELS],
                   "targets": [{"name": "peakOverpressure"}, {"name": "impulse"}]}, handle)


def parity_raw(rows=37, columns=23):
    """field-export's six channels over a plan, with the edge cases the encoding clamps."""
    rng = np.random.default_rng(67)
    height = np.where(rng.random((rows, columns)) < 0.3, rng.uniform(0.001, 90, (rows, columns)), 0)
    height[0, :3] = [1e-3, 2.0, 0.0]
    ground = rng.uniform(-40, 60, (rows, columns))
    j, i = np.mgrid[0:rows, 0:columns]
    distance = np.hypot((i + 0.5) * 4 - 22.0, (j + 0.5) * 4 - 121.0)
    root = 120_000 ** (1 / 3)
    log_z = np.log(np.maximum(distance, 2.0) / root)
    peak = np.exp(rng.uniform(-2, 13, (rows, columns)))
    peak[1, :4] = [0.0, 0.5, 1.0, 1.0000001]
    impulse = np.exp(rng.uniform(-20, 8, (rows, columns)))
    impulse[2, :4] = [0.0, 1e-9, 1e-6, 2e-6]
    return np.stack([height, ground, distance, log_z, peak, impulse]).astype(np.float32)


def parity():
    """The fixture's arrays: (raw, stats, standardised and padded inputs, Kingery–Bulmash's log peak)."""
    raw = parity_raw()
    rows, columns = raw.shape[1:]
    with tempfile.TemporaryDirectory() as scratch:
        write_run(scratch, raw, np.full((2, rows, columns), 100.0), np.ones((rows, columns)))
        run = train_field.load_run(scratch)
    stats = train_field.statistics([run])
    # As judge_field.predict: (x - mean) / std in float32, then padded north and east by
    # repeating the edge (F.pad's "replicate") to a multiple of 2^depth.
    mean = np.array(stats["mean"], dtype=np.float32)[:, None, None]
    std = np.array(stats["std"], dtype=np.float32)[:, None, None]
    x = ((run["x"] - mean) / std).astype(np.float32)
    multiple = 16
    x = np.pad(x, ((0, 0), (0, (-rows) % multiple), (0, (-columns) % multiple)), mode="edge")
    return raw, stats, x, run["kb"][0]


def write_fixture(folder):
    raw, stats, x, kb = parity()
    os.makedirs(folder, exist_ok=True)
    np.save(os.path.join(folder, "raw.npy"), raw.astype("<f4"))
    np.save(os.path.join(folder, "inputs.npy"), x.astype("<f4"))
    np.save(os.path.join(folder, "kb-log-peak.npy"), kb.astype("<f4"))
    with open(os.path.join(folder, "stats.json"), "w") as handle:
        json.dump({"about": "train_field.statistics of raw.npy's run; written by Scripts/ml/test-field-model.py "
                            "--write-fixture", "multiple": 16, "stats": stats}, handle, indent=1)
        handle.write("\n")


class SplitTests(unittest.TestCase):
    def setUp(self):
        with open(HERE / "field-runs.json") as handle:
            self.plan = json.load(handle)
        self.runs = [{"id": r["id"], "layout": r["layout"]} for r in self.plan["sets"]["main"]]
        self.layout = {r["id"]: r["layout"] for r in self.runs}

    def test_the_strict_split_holds_out_whole_layouts(self):
        held = train_field.split(self.runs, 0.2, None, "run", 0, ["beirut", "made-*-s6"])
        self.assertEqual(len(held), 75)
        trained = {r["id"] for r in self.runs} - set(held)
        self.assertEqual({self.layout[r] for r in held} & {self.layout[r] for r in trained}, set())
        self.assertTrue(all(self.layout[r] != "beirut" for r in trained))
        self.assertEqual(sum(self.layout[r] == "beirut" for r in held), 50)

    def test_the_rounds_by_run_share_their_layouts(self):
        # Rounds 1 and 2 (`--split-by run`): a held-out run's buildings were trained on at other
        # yields and places, Beirut's among them; only the layout split is a new district.
        held = train_field.split(self.runs, 0.2, None, "run", 0)
        trained = {r["id"] for r in self.runs} - set(held)
        shared = {self.layout[r] for r in held} & {self.layout[r] for r in trained}
        self.assertIn("beirut", shared)
        by_layout = train_field.split(self.runs, 0.2, None, "layout", 0)
        trained = {r["id"] for r in self.runs} - set(by_layout)
        self.assertEqual({self.layout[r] for r in by_layout} & {self.layout[r] for r in trained}, set())


class EncodingTests(unittest.TestCase):
    def test_statistics(self):
        raw = parity_raw()
        rows, columns = raw.shape[1:]
        with tempfile.TemporaryDirectory() as scratch:
            write_run(scratch, raw, np.full((2, rows, columns), 100.0), np.ones((rows, columns)))
            run = train_field.load_run(scratch)
        stats = train_field.statistics([run])
        # The footprint stays 0 or 1; the others are their own channel's.
        self.assertEqual((stats["mean"][1], stats["std"][1]), (0.0, 1.0))
        self.assertAlmostEqual(stats["mean"][0], float(raw[0].mean()), places=4)
        self.assertEqual(run["x"][1].max(), 1.0)
        self.assertEqual(float(run["x"][1][0, 0]), 1.0)  # a block 1 mm tall is a footprint
        # Kingery–Bulmash's peak is held at 1 Pa and its impulse at 1 µPa s before the logs.
        self.assertEqual(run["kb"][0][1, :3].tolist(), [0.0, 0.0, 0.0])
        self.assertAlmostEqual(float(run["kb"][1][2, 0]), np.log(1e-6), places=5)

    def test_the_mask_leaves_out_what_the_run_itself_gives_under_10_pa(self):
        # The judge's strips are the cells this mask keeps, so they are chosen by the run's own
        # field; the app's (`LearnedField.PeakMap.open`) by the network's peak instead.
        raw = parity_raw()
        rows, columns = raw.shape[1:]
        targets = np.full((2, rows, columns), 100.0)
        targets[0, 5, 5] = 9.0
        targets[1, 6, 6] = 1e-4
        with tempfile.TemporaryDirectory() as scratch:
            write_run(scratch, raw, targets, np.ones((rows, columns)))
            run = train_field.load_run(scratch)
        self.assertFalse(run["mask"][5, 5] or run["mask"][6, 6])
        self.assertEqual(int(run["mask"].sum()), rows * columns - 2)

    def test_the_parity_fixture_is_current(self):
        # Within float32's rounding: NumPy's float32 log is not the same to the bit on every build.
        again = "rerun python3 -I Scripts/ml/test-field-model.py --write-fixture"
        with tempfile.TemporaryDirectory() as scratch:
            write_fixture(scratch)
            for name in ("raw.npy", "inputs.npy", "kb-log-peak.npy"):
                ours, committed = np.load(os.path.join(scratch, name)), np.load(FIXTURE / name)
                self.assertEqual(ours.shape, committed.shape, name)
                self.assertTrue(np.allclose(ours, committed, rtol=1e-6, atol=1e-6), "%s: %s" % (name, again))
            with open(os.path.join(scratch, "stats.json")) as a, open(FIXTURE / "stats.json") as b:
                ours, committed = json.load(a)["stats"], json.load(b)["stats"]
            for key in ("mean", "std"):
                self.assertTrue(np.allclose(ours[key], committed[key], rtol=1e-6), "stats.json: %s" % again)

    def test_the_fixture_pads_by_repeating_the_north_and_east_edges(self):
        x = np.load(FIXTURE / "inputs.npy")
        raw = np.load(FIXTURE / "raw.npy")
        self.assertEqual(x.shape, (6, 48, 32))
        self.assertTrue(np.array_equal(x[:, 37:, :], np.repeat(x[:, 36:37, :], 11, axis=1)))
        self.assertTrue(np.array_equal(x[:, :, 23:], np.repeat(x[:, :, 22:23], 9, axis=2)))
        self.assertEqual(raw.shape, (6, 37, 23))


if __name__ == "__main__":
    if sys.argv[1:] == ["--write-fixture"]:
        write_fixture(FIXTURE)
        print("wrote %s" % FIXTURE)
        sys.exit(0)
    unittest.main()
