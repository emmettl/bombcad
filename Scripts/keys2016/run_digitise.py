"""Digitise the longitudinal debris histograms of Keys (2016) for the A panels (and MW1, AA)
and write debris.json with per-bin masses and summary statistics.

    python3 run_digitise.py PAGES OUT.json

PAGES holds the figures' images as pdfimages writes them (see README.md). Frames are set by
hand from each figure's axis lines and checked against its tick marks (ticks.py, axes.py).
"""
import json
import re
import sys

import numpy as np

import digitise

FIGURES = [
    # id, figure, page, image, panel, load, x range, y range, bin, frame (left, right, top, bottom),
    # and options for the reader
    ("WR1A", "4.17c", 149, "q149-002", "A", "41 kg TNT at 10.6 m, 110 kPa", (-2, 4), (0, 120), 0.5, (54, 512, 11, 288)),
    ("WR1B", "4.20c", 152, "q152-002", "A", "41 kg TNT at 13 m, 72 kPa", (-2, 6), (0, 120), 0.5, (57, 685, 11, 297)),
    ("WR1C", "4.22c", 155, "q155-002", "A (weak mortar)", "41 kg TNT at 15 m, 55 kPa", (-4, 3.5), (0, 80), 0.5, (51, 668, 6, 204)),
    ("WR2C", "4.30c", 168, "q168-002", "A", "41 kg TNT at 15 m, 55 kPa", (-2, 4), (0, 120), 0.5, (70, 628, 12, 350)),
    ("MW1", "4.6", 134, "q134-001", "A, unmortared", "ABT 4.9 m section, 110 kPa, 200 ms", (0, 50), (0, 45), 1.0, (42, 838, 7, 199), {"top_down": True, "legend": (40, 50)}),
    ("MW2", "4.12", 142, "q142-001", "A", "ABT 4.9 m section, 110 kPa, 200 ms", (0, 45), (0, 45), 1.0, (46, 839, 8, 196)),
    ("BWL1A", "4.39", 183, "q183-001", "A", "ABT 4.9 m section, 110 kPa, 200 ms", (0, 50), (0, 50), 1.0, (65, 664, 11, 311)),
    ("BWL2C", "4.58c", 211, "q211-002", "A", "ABT 10.2 m section, 55 kPa, 150 ms", (0, 14), (0, 80), 0.5, (53, 478, 12, 319)),
    ("BWL3B", "4.73c", 233, "q233-002", "AA (2 m wide)", "ABT 10.2 m section, 55 kPa, 150 ms", (0, 15), (0, 120), 0.5, (59, 423, 7, 372)),
]


def stats(bins):
    centres = np.array([(a + b) / 2 for a, b, _ in bins])
    mass = np.array([m for _, _, m in bins])
    total = mass.sum()
    cumulative = np.cumsum(mass) / total

    def quantile(q):
        return float(centres[np.searchsorted(cumulative, q)])

    reached = [b for a, b, m in bins if m > 0]
    return {
        "total_kg": round(float(total), 1),
        "mean_m": round(float((centres * mass).sum() / total), 2),
        "median_m": quantile(0.5),
        "p90_m": quantile(0.9),
        "furthest_bin_end_m": max(reached),
    }


pages = sys.argv[1] if len(sys.argv) > 1 else "pages"
target = sys.argv[2] if len(sys.argv) > 2 else "debris.json"
out = []
for sid, figure, page, image, panel, load, xr, yr, width, box, *options in FIGURES:
    bins, _ = digitise.bars(f"{pages}/{image}.ppm", xr, yr, width, frame_box=box, **(options[0] if options else {}))
    entry = {"id": sid, "figure": figure, "pdf_page": page, "panel": panel, "load": load, "bin_m": width}
    entry.update(stats(bins))
    entry["first_bin_m"] = bins[0][0]
    entry["masses_kg"] = [m for _, _, m in bins]
    out.append(entry)
    print(sid, {k: v for k, v in entry.items() if k != "masses_kg"})
text = json.dumps(
    {"source": "R. A. Keys, PhD thesis, University of Southampton, 2016 (eprint 413951)", "structures": out}, indent=1
)
# One line per histogram.
text = re.sub(r"\[\s*([-0-9.,\s]+?)\s*\]", lambda m: "[" + re.sub(r"\s+", " ", m.group(1)) + "]", text)
open(target, "w").write(text + "\n")
