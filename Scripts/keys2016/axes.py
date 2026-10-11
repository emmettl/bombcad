"""Find a plot frame from grey (unsaturated) dark lines only, so coloured bars are ignored, and
print the ticks outside its axes."""
import sys

import numpy as np

import ppm


def grey_frame(image, level=380):
    a = image.astype(int)
    grey = (a.sum(2) < level) & (a.max(2) - a.min(2) < 50)
    h, w = grey.shape
    rows = [y for y in range(h) if grey[y].sum() > 0.45 * w]
    cols = [x for x in range(w) if grey[:, x].sum() > 0.45 * h]
    return grey, rows, cols


if __name__ == "__main__":
    image = ppm.read(sys.argv[1])
    grey, rows, cols = grey_frame(image)
    print("rows", rows, "cols", cols)
    if rows and cols:
        top, bottom, left = rows[0], rows[-1], cols[0]
        below = grey[bottom + 2 : bottom + 6].any(0)
        print("x ticks", [x for x in range(grey.shape[1]) if below[x]])
        beside = grey[:, max(0, left - 6) : left - 1].any(1)
        print("y ticks", [y for y in range(grey.shape[0]) if beside[y]])
