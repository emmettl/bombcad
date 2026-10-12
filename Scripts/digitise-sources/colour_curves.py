"""Digitise coloured curves on a raster chart: per pixel column, the median height of the
pixels of each curve's colour inside the plot area (outside any masked box, e.g. the legend).
The axes are calibrated by a least-squares line through the gridlines' pixel positions against
their values; the residual is reported."""
import numpy as np
from PIL import Image


def calibrate(pixels, values):
    pixels, values = np.asarray(pixels, float), np.asarray(values, float)
    slope, intercept = np.polyfit(pixels, values, 1)
    residual = np.abs(slope * pixels + intercept - values).max()
    return (lambda p: slope * np.asarray(p) + intercept), residual


def curves(path, masks, area, exclude=(), step=1):
    """`masks` name → function(r, g, b) → bool array; `area` (x0, x1, y0, y1) pixels inside the
    frame; `exclude` boxes (x0, x1, y0, y1) to ignore. Returns name → [(x_px, y_px, spread_px)],
    the spread being the height of the coloured pixels in the column (the line's width, or a
    spike's reach)."""
    a = np.array(Image.open(path).convert("RGB")).astype(int)
    r, g, b = a[..., 0], a[..., 1], a[..., 2]
    x0, x1, y0, y1 = area
    out = {}
    for name, test in masks.items():
        mask = test(r, g, b)
        for ex in exclude:
            mask[ex[2] : ex[3], ex[0] : ex[1]] = False
        points = []
        for x in range(x0, x1, step):
            ys = np.where(mask[y0:y1, x])[0] + y0
            if len(ys):
                points.append((x, float(np.median(ys)), float(ys.max() - ys.min() + 1)))
        out[name] = points
    return out
