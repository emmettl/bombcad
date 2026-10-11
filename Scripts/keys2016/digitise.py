"""Read stacked debris histograms (mass per longitudinal bin) from Keys's thesis figures.

The frame is found as the longest dark row and column lines; its edges are the axes' limits,
given per figure from the printed tick labels. Each bin's height is the topmost non-white pixel
inside the frame over the middle half of the bin, so the stacked colours and the outlines of
'Unknown' (white, outlined) segments both count. Bars are followed up from the x axis and end at
the first white gap taller than 3% of the frame, so a legend drawn over a short bar is skipped;
figures whose 'Unknown' boxes are open (no inner lines) are read top down instead, bottom up only
under their legend.
"""
import numpy as np

import ppm


def frame(image, dark_level=300):
    dark = image.astype(int).sum(2) < dark_level
    h, w = dark.shape
    rows = [i for i, c in enumerate(dark.sum(1)) if c > 0.4 * w]
    top, bottom = min(rows), max(rows)
    # Frame: the left axis is the first long dark column; the right edge is where the x axis's
    # continuous line ends (a legend box beside the plot is separate from it).
    left = next(i for i, c in enumerate(dark.sum(0)) if c > 0.6 * (bottom - top))
    right, gap = left, 0
    for c in range(left + 1, w):
        if dark[bottom - 1 : bottom + 2, c].any():
            right, gap = c, 0
        else:
            gap += 1
            if gap > 4:
                break
    return dark, left, right, top, bottom


def bars(path, x_range, y_range, width=0.5, frame_box=None, top_down=False, legend=None):
    image = ppm.read(path)
    dark, left, right, top, bottom = frame(image)
    if frame_box:
        left, right, top, bottom = frame_box
    ink = image.astype(int).sum(2) < 690  # anything not white
    x0, x1 = x_range
    y0, y1 = y_range
    out = []
    edges = np.arange(x0, x1, width)
    for edge in edges:
        centre = left + (edge + width / 2 - x0) / (x1 - x0) * (right - left)
        half = 0.25 * width / (x1 - x0) * (right - left)
        columns = range(int(round(centre - half)), int(round(centre + half)) + 1)
        tops = []
        gap_limit = max(4, int(0.03 * (bottom - top)))
        under_legend = legend is not None and legend[0] <= edge < legend[1]
        for c in columns:
            if top_down and not under_legend:
                # Open white 'Unknown' boxes with no inner lines: take the topmost ink.
                rows = np.where(ink[top + 2 : bottom - 1, c])[0]
                tops.append(top + 2 + rows[0] if len(rows) else bottom)
                continue
            # Walk up from the x axis; the bar ends at the first white gap taller than the
            # stacked segments' outlines leave, so a legend box above a short bar is ignored.
            last, gap = bottom, 0
            for r in range(bottom - 1, top + 1, -1):
                if ink[r, c]:
                    last, gap = r, 0
                else:
                    gap += 1
                    if gap > gap_limit:
                        break
            tops.append(last)
        top_pixel = int(np.median(tops))
        mass = y0 + (bottom - top_pixel) / (bottom - top) * (y1 - y0)
        out.append((float(edge), float(edge + width), round(max(mass, 0.0), 1)))
    return out, (left, right, top, bottom)
