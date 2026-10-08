#!/usr/bin/env python3
"""Require the complete dense/tiled/automatic scaling matrix and bounded field parity."""
import json
import math
from pathlib import Path
import sys

report = json.loads(Path(sys.argv[1]).read_text())
assert report["schemaVersion"] == 1
assert len(report["sourceRevision"]) == 40
assert report["device"] and report["system"]
rows = report["observations"]
expected = {(n, spacing, refinement, layout)
            for n in (2, 4, 8, 16) for spacing in (12, 28)
            for refinement in (1, 2) for layout in ("dense", "tiled", "automatic")}
actual = {(r["bodies"], r["spacingM"], r["refinement"], r["layout"]) for r in rows}
assert len(rows) == len(expected) and actual == expected
for r in rows:
    assert r["stable"] and r["steps"] == 8, r
    assert 0 <= r["maxRelativePressureError"] < 1e-5, r
    assert all(math.isfinite(r[key]) and r[key] > 0 for key in ("batchGPUS", "couplingGPUMedianS")), r
    assert r["solverBytes"] >= r["coupling"]["bytes"] > 0
    if r["coupling"]["layout"] == "tiled":
        assert 0 < r["coupling"]["activeTiles"] <= r["coupling"]["tileCapacity"]
for n, spacing, refinement, _ in expected:
    pair = {r["layout"]: r for r in rows
            if (r["bodies"], r["spacingM"], r["refinement"]) == (n, spacing, refinement)}
    assert pair["automatic"]["coupling"]["bytes"] <= pair["dense"]["coupling"]["bytes"]
print(f"PASS {len(rows)} scaling cases, bounded pressure parity and automatic storage choice")
