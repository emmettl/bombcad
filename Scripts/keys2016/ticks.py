"""Print a histogram's frame (from the digitiser) and the tick marks just outside its x and y
axes, to check each figure's calibration."""
import sys

import numpy as np

import digitise
import ppm

image = ppm.read(sys.argv[1])
dark, left, right, top, bottom = digitise.frame(image)
print("frame", left, right, top, bottom)
d = image.astype(int).sum(2) < 450
below = d[bottom + 2 : bottom + 6, :].any(0)
xs = [x for x in range(left - 2, min(d.shape[1], right + 40)) if below[x]]
print("x ticks", xs)
beside = d[:, max(0, left - 6) : left - 1].any(1)
print("y ticks", [y for y in range(max(0, top - 3), bottom + 3) if beside[y]])
