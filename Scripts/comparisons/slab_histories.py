"""The contest slab's model histories against Schwer's three measured ones.

    python3 slab_histories.py RUNS

RUNS holds `blastbench slab --layers 4,8,16 [--load-scale 0.764] --history-csv RUNS` output
(time in ms, mid-span displacement in mm). Load 1a's runs are scored against Schwer's 1a and its
repeat 1aa, the lower shot's (0.764) against 1b, each over the measured record (from 5 ms to its
end): RMS difference, peak and its time, and the displacement at the record's end.
Measured from Fixtures/Schwer2015/displacement-histories.json (0.5 ms, medians over 1 ms).
"""
import glob
import json
import os
import re
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
FIXTURE = os.path.join(HERE, "..", "..", "Fixtures", "Schwer2015", "displacement-histories.json")


def main(directory):
    measured = {k: np.array(v) for k, v in json.load(open(FIXTURE))["histories"].items()}
    pairs = {"1": ["Load 1a (Slab-2)", "Load 1aa (Slab-4)"], "0.764": ["Load 1b (Slab-6)"]}
    rows = []
    for path in sorted(glob.glob(os.path.join(directory, "slab-*-strainRate-load*.csv"))):
        layers = int(re.search(r"slab-(\d+)-", path).group(1))
        load = re.search(r"load([\d.]+)\.csv", path).group(1)
        model = np.loadtxt(path, delimiter=",", skiprows=1)
        for name in pairs.get(load, []):
            m = measured[name]
            m = m[m[:, 0] >= 5]
            predicted = np.interp(m[:, 0], model[:, 0], model[:, 1])
            within = model[:, 0] <= m[-1, 0]
            peak = int(np.argmax(model[within, 1]))
            rows.append({
                "layers": layers, "load": load, "measured": name,
                "rms_mm": float(np.sqrt(np.mean((predicted - m[:, 1]) ** 2))),
                "mean_error_mm": float(np.mean(predicted - m[:, 1])),
                "peak_mm": float(model[within, 1][peak]), "peak_ms": float(model[within, 0][peak]),
                "measured_peak_mm": float(m[:, 1].max()), "measured_peak_ms": float(m[np.argmax(m[:, 1]), 0]),
                "end_ms": float(m[-1, 0]), "end_mm": float(predicted[-1]), "measured_end_mm": float(m[-1, 1]),
            })
    print("layers  load   against            RMS mm  mean mm   peak mm (at ms)      measured (at ms)    end mm / measured")
    for r in rows:
        print(f"{r['layers']:5}  {r['load']:>5}  {r['measured']:<18} {r['rms_mm']:6.1f}  {r['mean_error_mm']:+6.1f}   "
              f"{r['peak_mm']:6.1f} ({r['peak_ms']:4.1f})       {r['measured_peak_mm']:6.1f} ({r['measured_peak_ms']:4.1f})     "
              f"{r['end_mm']:5.1f} / {r['measured_end_mm']:5.1f} at {r['end_ms']:.1f} ms")
    return rows


if __name__ == "__main__":
    rows = main(sys.argv[1])
    if len(sys.argv) > 2:
        json.dump(rows, open(sys.argv[2], "w"), indent=1)
