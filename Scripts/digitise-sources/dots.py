"""Filled data markers on a scanned chart, and a skew-aware frame.

Markers are found as solid dark blobs: pixels whose `size` × `size` neighbourhood is all but
dark (thin lines and text are not), grouped into connected cores whose centroids are taken.
The frame's four edges are each fitted with a straight line through the first dark pixel met
scanning in from outside, so a slightly rotated scan is mapped correctly (bilinearly between
the fitted corners).
"""
from collections import deque

import numpy as np
from PIL import Image


def load(path):
    return np.array(Image.open(path).convert("L")).astype(int)


def blobs(image, area, size=15, fill=0.95, threshold=150):
    x0, x1, y0, y1 = area
    dark = (image[y0:y1, x0:x1] < threshold).astype(int)
    integral = np.pad(dark, ((1, 0), (1, 0))).cumsum(0).cumsum(1)
    h, w = dark.shape
    r = size // 2
    core = np.zeros_like(dark, bool)
    for y in range(r, h - r):
        sums = integral[y + r + 1, 2 * r + 1 :] - integral[y - r, 2 * r + 1 :] - integral[y + r + 1, : w - 2 * r] + integral[y - r, : w - 2 * r]
        core[y, r : w - r] = sums >= fill * size * size
    seen = np.zeros_like(core)
    out = []
    for y, x in zip(*np.nonzero(core)):
        if seen[y, x]:
            continue
        queue, members = deque([(y, x)]), []
        seen[y, x] = True
        while queue:
            cy, cx = queue.popleft()
            members.append((cy, cx))
            for dy, dx in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                ny, nx = cy + dy, cx + dx
                if 0 <= ny < h and 0 <= nx < w and core[ny, nx] and not seen[ny, nx]:
                    seen[ny, nx] = True
                    queue.append((ny, nx))
        m = np.array(members)
        out.append((m[:, 1].mean() + x0, m[:, 0].mean() + y0, len(m)))
    return out


def edge(image, area, side, threshold=150):
    """Fit the frame edge on `side` ('left', 'right', 'top', 'bottom') inside `area`: the first
    dark pixel met scanning in from that side, per row or column, then a robust line fit."""
    x0, x1, y0, y1 = area
    dark = image[y0:y1, x0:x1] < threshold
    pts = []
    if side in ("left", "right"):
        for y in range(dark.shape[0]):
            xs = np.nonzero(dark[y])[0]
            if len(xs):
                pts.append((y + y0, (xs[0] if side == "left" else xs[-1]) + x0))
    else:
        for x in range(dark.shape[1]):
            ys = np.nonzero(dark[:, x])[0]
            if len(ys):
                pts.append((x + x0, (ys[0] if side == "top" else ys[-1]) + y0))
    p = np.array(pts, float)
    # Keep the points on the dominant line: within 3 px of the median, refit twice.
    keep = np.abs(p[:, 1] - np.median(p[:, 1])) < 6
    for _ in range(2):
        k, c = np.polyfit(p[keep, 0], p[keep, 1], 1)
        keep = np.abs(p[:, 1] - (k * p[:, 0] + c)) < 3
    return k, c, keep.sum()


def frame_map(left, right, top, bottom, xlim, ylim, xlog=True, ylog=True):
    """Map pixels to data through the frame given by four fitted edges (x = k y + c for left and
    right, y = k x + c for top and bottom)."""

    def u(x, y):  # fraction across, between the left and right edges at this height
        xl = left[0] * y + left[1]
        xr = right[0] * y + right[1]
        return (x - xl) / (xr - xl)

    def v(x, y):  # fraction up, between the bottom and top edges at this column
        yb = bottom[0] * x + bottom[1]
        yt = top[0] * x + top[1]
        return (yb - y) / (yb - yt)

    def scale(f, lim, log):
        return 10 ** (np.log10(lim[0]) + f * np.log10(lim[1] / lim[0])) if log else lim[0] + f * (lim[1] - lim[0])

    return lambda x, y: (scale(u(x, y), xlim, xlog), scale(v(x, y), ylim, ylog))
