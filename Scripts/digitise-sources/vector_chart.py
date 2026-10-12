"""Digitise vector charts: each coloured curve's drawing commands mapped through the chart frame.

A chart is given by its SVG page (pdftocairo), the frame's data limits (linear or log axes) and
the legend's colour → label mapping. The frame is the black rectangle with the largest area;
the calibration is checked against the grey gridlines at the values given in `checks`, and the
largest misfit (in data units, relative for a log axis) is reported as the reading error.
"""
import json
import sys

import numpy as np

sys.path.insert(0, __file__.rsplit("/", 1)[0])
import svgcurves  # noqa: E402


def frame(strokes):
    best = None
    for s in strokes:
        p = s["points"]
        if s["stroke"] != "rgb(0%, 0%, 0%)" or len(p) < 4:
            continue
        box = (p[:, 0].min(), p[:, 0].max(), p[:, 1].min(), p[:, 1].max())
        area = (box[1] - box[0]) * (box[3] - box[2])
        if best is None or area > best[0]:
            best = (area, box)
    return best[1]


def mapper(box, xlim, ylim, xlog, ylog):
    left, right, top, bottom = box

    def axis(v, a, b, lo, hi, log):
        f = (v - a) / (b - a)
        return 10 ** (np.log10(lo) + f * (np.log10(hi) - np.log10(lo))) if log else lo + f * (hi - lo)

    return lambda p: np.c_[
        axis(p[:, 0], left, right, xlim[0], xlim[1], xlog), axis(p[:, 1], bottom, top, ylim[0], ylim[1], ylog)
    ]


def digitise(spec):
    strokes = svgcurves.strokes(spec["svg"])
    box = frame(strokes)
    to_data = mapper(box, spec["x"], spec["y"], spec.get("xlog", False), spec.get("ylog", False))
    # Gridline check: horizontal grey lines' heights against the nearest expected value.
    grey = [s for s in strokes if s["stroke"] not in spec["legend"] and s["stroke"] != "rgb(0%, 0%, 0%)"]
    misfit = 0.0
    for value in spec.get("checks", []):
        heights = [to_data(s["points"])[0, 1] for s in grey if np.ptp(s["points"][:, 1]) < 0.01]
        nearest = min(heights, key=lambda h: abs(np.log10(h / value)) if spec.get("ylog") else abs(h - value))
        misfit = max(misfit, abs(nearest / value - 1) if spec.get("ylog") else abs(nearest - value))
    curves = []
    for colour, label in spec["legend"].items():
        paths = [s["points"] for s in strokes if s["stroke"] == colour and len(s["points"]) > 4]
        if not paths:
            continue
        p = to_data(max(paths, key=len))
        p = p[np.argsort(p[:, 0])]
        curve = {"label": label, "points": [[round(float(a), 4), float("%.5g" % b)] for a, b in p]}
        if "sample" in spec:
            xs = [x for x in spec["sample"] if p[0, 0] - 0.5 <= x <= p[-1, 0] + 0.5]
            ys = np.interp(xs, p[:, 0], np.log10(p[:, 1])) if spec.get("ylog") else np.interp(xs, p[:, 0], p[:, 1])
            curve["sampled"] = [[x, float("%.4g" % (10**y if spec.get("ylog") else y))] for x, y in zip(xs, ys)]
        curves.append(curve)
    return {"frame_pt": [round(float(v), 2) for v in box], "gridline_misfit": round(misfit, 4), "curves": curves}


if __name__ == "__main__":
    specs = json.load(open(sys.argv[1]))
    out = {name: digitise(spec) for name, spec in specs.items()}
    json.dump(out, open(sys.argv[2], "w"), indent=1)
    for name, result in out.items():
        print(name, "frame", result["frame_pt"], "misfit", result["gridline_misfit"], "curves", len(result["curves"]))
