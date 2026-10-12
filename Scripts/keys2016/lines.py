"""Print an image's long dark rows and columns, and the tick marks under its x axis, to set a
figure's frame by hand."""
import sys

import numpy as np

import ppm

image = ppm.read(sys.argv[1]).astype(int)
level = int(sys.argv[2]) if len(sys.argv) > 2 else 400
dark = image.sum(2) < level
h, w = dark.shape


def runs(values):
    out, start = [], None
    for i, v in enumerate(list(values) + [False]):
        if v and start is None:
            start = i
        if not v and start is not None:
            out.append((start, i - 1))
            start = None
    return out


print("size", w, h)
for y in range(h):
    long = [r for r in runs(dark[y]) if r[1] - r[0] > 0.25 * w]
    if long:
        print("row", y, long)
for x in range(w):
    long = [r for r in runs(dark[:, x]) if r[1] - r[0] > 0.4 * h]
    if long:
        print("col", x, long)
