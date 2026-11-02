"""The reference corpus's selector (corpus.py): its weights reader, distances, greedy choice and fixed
list. Skipped without NumPy (the Studio's ML venv has it)."""

import importlib.util
import json
import re
import struct
import tempfile
import unittest
from pathlib import Path

try:
    import numpy as np
except ImportError:  # pragma: no cover
    np = None

HERE = Path(__file__).parent


def load():
    spec = importlib.util.spec_from_file_location("corpus", HERE / "corpus.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


@unittest.skipIf(np is None, "NumPy is not installed")
class CorpusTests(unittest.TestCase):
    def setUp(self):
        self.corpus = load()

    def test_weights_read_as_train_response_writes_them(self):
        # One network, 2 inputs -> 3 -> 1, float32, as train_response.export lays it out.
        w1 = np.arange(6, dtype=np.float32).reshape(3, 2) / 10
        b1 = np.array([0.1, -0.2, 0.3], dtype=np.float32)
        w2 = np.array([[1.0, -1.0, 0.5]], dtype=np.float32)
        b2 = np.array([0.25], dtype=np.float32)
        header = {"format": "bclr", "version": 2, "dtype": "float32", "networks": {"building": {
            "inputs": 2, "mean": [1.0, 2.0], "std": [2.0, 1.0], "outputs": ["a"],
            "layers": [{"inputs": 2, "outputs": 3, "offset": 0}, {"inputs": 3, "outputs": 1, "offset": 9}]}}}
        text = json.dumps(header).encode()
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "w.bclr"
            path.write_bytes(b"BCLR" + struct.pack("<II", 2, len(text)) + text +
                             b"".join(a.tobytes() for a in (w1, b1, w2, b2)))
            net = self.corpus.read_bclr(path)["building"]
        x = np.array([[3.0, 1.0]])
        z = (x - [1.0, 2.0]) / [2.0, 1.0]
        h = z @ w1.T + b1
        h = h / (1 + np.exp(-h))
        np.testing.assert_allclose(net(x), h @ w2.T + b2, rtol=1e-6)

    def test_nearest_distances(self):
        ref = np.array([[0.0, 0.0], [3.0, 4.0]])
        q = np.array([[0.0, 1.0], [3.0, 5.0], [10.0, 4.0]])
        np.testing.assert_allclose(self.corpus.nearest(q, ref), [1.0, 1.0, 7.0], rtol=1e-6)

    def test_greedy_takes_value_over_cost_and_discounts_what_it_has_seen(self):
        # a and b are alike (rows at the same place) and worth the most; c is apart and worth less.
        # Once a is taken, b's rows are seen, so c comes next though b alone is worth more.
        def unit(value, at):
            z = np.full((4, 2), at, dtype=np.float32)
            return {"building": (np.full(4, value), np.ones(4), 1.0, z)}
        values = {"a": unit(5.0, 0.0), "b": unit(4.0, 0.0), "c": unit(2.0, 10.0)}
        costs = {"a": 1.0, "b": 1.0, "c": 1.0}
        picks = self.corpus.greedy(list(values), values, costs, 2.0, {"building": 1.0})
        self.assertEqual([p[0] for p in picks], ["a", "c"])

    def test_greedy_keeps_to_the_budget(self):
        z = np.zeros((1, 1), dtype=np.float32)
        values = {k: {"side": (np.ones(1), np.ones(1), 1.0, z + i * 5)} for i, k in enumerate("abc")}
        picks = self.corpus.greedy(list(values), values, {"a": 3.0, "b": 2.0, "c": 2.0}, 4.0, {"side": 1.0})
        self.assertLessEqual(sum({"a": 3.0, "b": 2.0, "c": 2.0}[p] for p, _ in picks), 4.0)
        self.assertEqual(len(picks), 2)

    def test_fixed_list_takes_one_of_each_kind_first(self):
        plan = {"candidates": [{"id": "%s%d" % (k, n), "kind": k} for k in "xyz" for n in range(2)]}
        costs = {c["id"]: 1.0 for c in plan["candidates"]}
        picks = self.corpus.fixed_list(plan, costs, 3.0)
        self.assertEqual(sorted(p[0] for p in picks), ["x", "y", "z"])
        self.assertTrue(all(p.endswith("0") for p in picks))

    def test_cost_reads_time_and_stages(self):
        with tempfile.TemporaryDirectory() as folder:
            log = Path(folder) / "probe.log"
            log.write_text(
                "Frame 0: charge (1, 2), 0.1 t, yield within ×2.00; rows 1 components, 1 sides, 1 buildings; "
                "inputs 0.10 s, damage 0.20 s, glass 0.30 s, walls 0.40 s\n"
                "      12.50 real        40.00 user         2.00 sys\n   243449856  maximum resident set size\n")
            c = self.corpus.cost(log)
        self.assertEqual(c["cpu"], 42.0)
        self.assertEqual(c["stages"], [(0.1, 0.2, 0.3, 0.4)])
        self.assertAlmostEqual(c["gb"], 0.243449856)


class RangesFollowTheWeights(unittest.TestCase):
    """LiveResponseRangeTests' ranges are written for the built-in weights; `make ci-test` says at once
    when the weights change and the ranges do not (the scenes themselves are checked in `swift test`)."""

    def test_the_ranges_name_the_built_in_weights(self):
        root = HERE.parent.parent
        ranges = (root / "Tests" / "BlastModelTests" / "LiveResponseRanges.swift").read_text()

        def sha(path, name):
            match = re.search(r'%s(?:: String\?)? = "([0-9a-f]{64})"' % name, path.read_text()[:4000])
            return match.group(1) if match else None
        sources = root / "Sources" / "BlastModel"
        self.assertEqual(sha(sources / "LiveResponse+Embedded.swift", "embeddedSHA256"),
                         re.search(r'trainedSHA256\s*=\s*"([0-9a-f]{64})"', ranges).group(1),
                         "the built-in weights changed: run Scripts/ml/corpus.py ranges")
        thrown = sources / "LiveResponse+Thrown.swift"
        if thrown.exists():
            self.assertEqual(sha(thrown, "embeddedThrownSHA256"),
                             re.search(r'trainedThrownSHA256: String\?\s*=\s*"([0-9a-f]{64})"', ranges).group(1),
                             "the glass thrown's weights changed: run Scripts/ml/corpus.py ranges --thrown …")


if __name__ == "__main__":
    unittest.main()
