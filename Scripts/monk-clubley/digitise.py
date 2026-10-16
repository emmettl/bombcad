"""Read Monk and Clubley's window trials (see Fixtures/MonkClubley/README.md) off the paper's figures.

    python3 Scripts/monk-clubley/digitise.py <paper.pdf> Fixtures/MonkClubley/windows.json

Needs numpy and poppler's pdfimages and pdftoppm. Figure 8 (reflected overpressure) is an
embedded image, 595 x 495 pixels; its inset, one trial over 0-20 ms, is traced column by column
(the darkness-weighted mean row of the line), and the main plot, all trials overlaid, gives the
median and extremes of each column. Figure 9b (break times) is drawn as vectors; page 5 is
rendered at 600 dpi and each red cross found by colour. The axes are set from tick marks found
in the images (the pixel rows and columns are below).
"""

import json
from itertools import combinations_with_replacement
import subprocess
import sys
import tempfile
from pathlib import Path

import numpy as np


def read_ppm(path):
    data = open(path, "rb").read()
    fields, pos = [], 0
    while len(fields) < 4:
        while data[pos : pos + 1].isspace():
            pos += 1
        if data[pos : pos + 1] == b"#":
            pos = data.index(b"\n", pos) + 1
            continue
        end = pos
        while not data[end : end + 1].isspace():
            end += 1
        fields.append(data[pos:end])
        pos = end
    pos += 1
    width, height = int(fields[1]), int(fields[2])
    return np.frombuffer(data[pos : pos + width * height * 3], np.uint8).reshape(height, width, 3)


def grey(image):
    return image.astype(float).mean(axis=2)


def figure8(image):
    """The inset's trace and the main plot's median and extremes, kPa against ms."""
    a = grey(image)
    # Inset: 0 ms at column 340, 20 ms at 476; 40 kPa at row 144, 0 at 224.5.
    inset = []
    for x in range(328, 476):
        column = 255 - a[140:244, x]
        column[column < 40] = 0
        if column.sum() == 0:
            continue
        rows = np.arange(140, 244)
        y = (rows * column).sum() / column.sum()
        inset.append([(x - 340) * 20 / 136, (224.5 - y) * 40 / 80.5])
    # Main plot: -10 ms at column 78.5, 110 ms at 511; 0 kPa at row 336, 5 kPa every 38.15 rows.
    # Below 8 kPa in the first 12 ms the impulse's dotted line crosses, so the search stops there.
    main = []
    for x in range(115, 186):
        t = (x - 114.5) * 120 / 432.5
        limit = 275 if t < 12 else 330
        rows = [y for y in range(25, limit) if a[y, x] < 120]
        if rows:
            p = lambda y: (336 - y) * 5 / 38.15
            main.append([t, p(float(np.median(rows))), p(max(rows)), p(min(rows))])
    return inset, main


def crosses(image):
    """Centres of the red crosses of figure 9b, with the rows of the y axis's ticks."""
    a = image.astype(int)
    red = (a[:, :, 0] > 180) & (a[:, :, 1] < 120) & (a[:, :, 2] < 120)
    red[1050:, 380:1300] = False  # the legend's cross
    seen = np.zeros_like(red)
    found = []
    for y0, x0 in zip(*np.nonzero(red)):
        if seen[y0, x0]:
            continue
        stack, points = [(y0, x0)], []
        seen[y0, x0] = True
        while stack:
            y, x = stack.pop()
            points.append((y, x))
            for dy in (-1, 0, 1):
                for dx in (-1, 0, 1):
                    yy, xx = y + dy, x + dx
                    if 0 <= yy < red.shape[0] and 0 <= xx < red.shape[1] and red[yy, xx] and not seen[yy, xx]:
                        seen[yy, xx] = True
                        stack.append((yy, xx))
        found.append(np.array(points))
    # Overlapping crosses: as many as the cluster's area holds single ones, placed where the sum
    # of a single cross's row profile, shifted to each, best matches the cluster's.
    single = next(p for p in found if np.ptp(p[:, 0]) < 50)
    template = np.bincount(single[:, 0] - single[:, 0].min())
    centres = []
    for points in found:
        ys, xs = points[:, 0], points[:, 1]
        top = ys.min()
        n = max(1, round(len(points) / len(single)))
        if n == 1:
            centres.append((xs.mean(), top + (len(template) - 1) / 2))
            continue
        counts = np.bincount(ys - top)
        span = len(counts) - len(template)
        best = None
        for offsets in combinations_with_replacement(range(span + 1), n):
            if offsets[0] != 0 or offsets[-1] != span:
                continue
            model = np.zeros(len(counts))
            for o in offsets:
                model[o : o + len(template)] += template
            # Pixels overlap where crosses do: compare where at least one cross lies, capped.
            error = ((np.minimum(model, counts.max()) - counts) ** 2).sum()
            if best is None or error < best[0]:
                best = (error, offsets)
        centres += [(xs.mean(), top + o + (len(template) - 1) / 2) for o in best[1]]
    return centres


def main():
    pdf, out = Path(sys.argv[1]), Path(sys.argv[2])
    with tempfile.TemporaryDirectory() as tmp:
        subprocess.run(["pdfimages", "-f", "4", "-l", "4", str(pdf), f"{tmp}/fig"], check=True)
        fig8 = read_ppm(sorted(Path(tmp).glob("fig-*.ppm"))[1])
        assert fig8.shape[:2] == (495, 595), fig8.shape
        subprocess.run(["pdftoppm", "-r", "600", "-f", "5", "-l", "5", str(pdf), f"{tmp}/page"], check=True)
        page = read_ppm(next(Path(tmp).glob("page-*.ppm")))
    h, w = page.shape[:2]
    fig9b = page[int(h * 0.04) : int(h * 0.27), int(w * 0.36) : int(w * 0.66)]
    inset, band = figure8(fig8)
    # Figure 9b: 0 ms at row 1435.5, 4 ms at 497.5; aspect ratio 1.0 at column 384, 2.0 at 1174.
    times = {}
    for x, y in crosses(fig9b):
        ratio = round(1 + (x - 384) / 790, 1)
        times.setdefault(f"1:{ratio:g}", []).append(round((1435.5 - y) / 234.5, 2))
    fixture = json.loads(out.read_text())
    fixture["breakTimes_ms"] = {k: sorted(v, reverse=True) for k, v in sorted(times.items())}
    # The inset at every 0.2 ms, interpolated between its columns (0.147 ms apart).
    ts, ps = np.array([t for t, _ in inset]), np.array([p for _, p in inset])
    fixture["reflectedPressure"]["oneTrial"] = [
        [round(t, 1), round(float(np.interp(t, ts, ps)), 1)] for t in np.arange(0, 8.01, 0.2)
    ]
    fixture["reflectedPressure"]["allTrials"] = [
        [round(t, 2), round(m, 1), round(lo, 1), round(hi, 1)] for t, m, lo, hi in band if t <= 10
    ]
    out.write_text(json.dumps(fixture, indent=2) + "\n")
    print(json.dumps(fixture["breakTimes_ms"]))


if __name__ == "__main__":
    main()
