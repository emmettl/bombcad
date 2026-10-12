"""Trace curves on scanned (raster) charts.

Each curve is followed column by column from a seed: at each step the next column's dark runs
are found, and the one whose centre is nearest the position extrapolated from the last few
points (within `reach` pixels) is taken. Seeds sit where a curve is alone, and the trace runs
towards where curves merge or cross, so a crossing is passed on the extrapolated slope. The
frame maps pixels to data on log or linear axes.
"""
import numpy as np
from PIL import Image, ImageDraw


def runs(column, threshold=128):
    dark = column < threshold
    out, start = [], None
    for i, d in enumerate(list(dark) + [False]):
        if d and start is None:
            start = i
        if not d and start is not None:
            out.append((start + i - 1) / 2)
            start = None
    return out


def trace(image, seed, direction, stop, step=2, reach=7, history=6, threshold=128, gap=8):
    """`seed` (x, y) pixels, `direction` ±1 along x, `stop` the x to stop at. The search widens
    with the curve's slope, and up to `gap` steps without a dark run nearby are bridged on the
    extrapolated slope (a crossing, or a break in the scan)."""
    x, y0 = seed
    candidates = runs(image[:, int(x)], threshold)
    y = min(candidates, key=lambda c: abs(c - y0))
    points = [(x, y)]
    missed = 0
    slope = 0.0
    while (stop - x) * direction > 0:
        x += direction * step
        if len(points) >= 2:
            k = min(history, len(points) - 1)
            slope = (points[-1][1] - points[-1 - k][1]) / (points[-1][0] - points[-1 - k][0])
            predicted = points[-1][1] + slope * (x - points[-1][0])
        else:
            predicted = points[-1][1]
        width = reach + 1.5 * abs(slope) * step * (missed + 1)
        candidates = [c for c in runs(image[:, int(x)], threshold) if abs(c - predicted) <= width]
        if not candidates:
            missed += 1
            if missed > gap:
                break
            continue
        missed = 0
        points.append((x, min(candidates, key=lambda c: abs(c - predicted))))
    return np.array(points[::direction])


def to_data(points, frame, xlim, ylim, xlog=True, ylog=True):
    left, right, top, bottom = frame
    fx = (points[:, 0] - left) / (right - left)
    fy = (bottom - points[:, 1]) / (bottom - top)

    def scale(f, lim, log):
        return 10 ** (np.log10(lim[0]) + f * np.log10(lim[1] / lim[0])) if log else lim[0] + f * (lim[1] - lim[0])

    return np.c_[scale(fx, xlim, xlog), scale(fy, ylim, ylog)]


def overlay(path, traces, out):
    im = Image.open(path).convert("RGB")
    draw = ImageDraw.Draw(im)
    colours = ["red", "blue", "green", "orange", "magenta", "cyan", "purple", "brown"]
    for n, t in enumerate(traces):
        draw.line([tuple(p) for p in t], fill=colours[n % len(colours)], width=3)
    im.resize((im.width // 2, im.height // 2)).save(out)


def load(path):
    return np.array(Image.open(path).convert("L")).astype(int)


def guided(image, anchors, step=2, reach=10, threshold=128):
    """Follow a curve along a rough path: at each column, the dark run nearest the path through
    `anchors` (pixels, read by eye; within `reach`). Anchors decide which line is meant where
    lines cross; the values come from the drawn line itself."""
    anchors = np.array(sorted(anchors))
    points = []
    for x in np.arange(anchors[0, 0], anchors[-1, 0] + 1, step):
        expected = np.interp(x, anchors[:, 0], anchors[:, 1])
        candidates = [c for c in runs(image[:, int(x)], threshold) if abs(c - expected) <= reach]
        if candidates:
            points.append((x, min(candidates, key=lambda c: abs(c - expected))))
    return np.array(points)


def follow(image, anchors, step=2, reach=10, pull=0.3, threshold=128, history=5):
    """As `guided`, but the line's own course leads: the next point is expected on the slope of
    the last few found, and of the dark runs within `reach` of that the one nearest it, plus
    `pull` times its distance from the anchors' path, is taken; the anchors only break ties
    where lines cross or touch. Starts at the dark run nearest the first anchor."""
    anchors = np.array(sorted(anchors))
    path = lambda x: np.interp(x, anchors[:, 0], anchors[:, 1])
    points = []
    for x in np.arange(anchors[0, 0], anchors[-1, 0] + 1, step):
        recent = [p for p in points[-history:] if x - p[0] <= 12 * step]
        if len(recent) >= 2:
            slope = (recent[-1][1] - recent[0][1]) / (recent[-1][0] - recent[0][0])
            expected = recent[-1][1] + slope * (x - recent[-1][0])
            width = reach + abs(slope) * step
        else:
            expected, width = path(x), 2 * reach
        candidates = [c for c in runs(image[:, int(x)], threshold) if abs(c - expected) <= width]
        if candidates:
            points.append((x, min(candidates, key=lambda c: abs(c - expected) + pull * abs(c - path(x)))))
    return np.array(points)
