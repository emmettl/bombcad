"""Digitise a vector log–log chart page without hand calibration: the axes are fitted to the
numeric tick labels' positions (pdftotext -bbox, in the same points as pdftocairo's SVG), and
each coloured curve is named by the number printed nearest its last point."""
import re
import subprocess
import sys
import xml.etree.ElementTree as ET

import numpy as np

sys.path.insert(0, __file__.rsplit("/", 1)[0])
import svgcurves  # noqa: E402


def words(pdf, page):
    html = subprocess.run(
        ["pdftotext", "-f", str(page), "-l", str(page), "-bbox", pdf, "-"], capture_output=True, text=True
    ).stdout
    out = []
    for m in re.finditer(r'<word xMin="([\d.]+)" yMin="([\d.]+)" xMax="([\d.]+)" yMax="([\d.]+)">([^<]*)</word>', html):
        x0, y0, x1, y1 = map(float, m.groups()[:4])
        out.append(((x0 + x1) / 2, (y0 + y1) / 2, m.group(5)))
    return out


def number(text):
    try:
        return float(text)
    except ValueError:
        return None


def fit_axis(pixels, values):
    b, a = np.polyfit(pixels, np.log10(values), 1)
    residual = np.abs(a + b * np.asarray(pixels) - np.log10(values)).max()
    return (lambda p: 10 ** (a + b * np.asarray(p))), float(residual)


def digitise(pdf, page, svg):
    strokes = svgcurves.strokes(svg)
    black = [s for s in strokes if s["stroke"] == "rgb(0%, 0%, 0%)" and len(s["points"]) >= 4]
    box = max(black, key=lambda s: np.ptp(s["points"][:, 0]) * np.ptp(s["points"][:, 1]))["points"]
    left, right, top, bottom = box[:, 0].min(), box[:, 0].max(), box[:, 1].min(), box[:, 1].max()
    ws = [(x, y, t, number(t)) for x, y, t in words(pdf, page)]
    ylabels = [(y, v) for x, y, t, v in ws if v and v > 0 and x < left - 2 and top - 8 <= y <= bottom + 8]
    xlabels = [(x, v) for x, y, t, v in ws if v and v > 0 and bottom + 2 < y < bottom + 20 and left - 15 <= x <= right + 15]
    ymap, yres = fit_axis(*zip(*ylabels))
    xmap, xres = fit_axis(*zip(*xlabels))
    inside = [(x, y, v) for x, y, t, v in ws if v is not None and left < x < right and top < y < bottom]
    curves = {}
    for s in strokes:
        if s["stroke"] in ("rgb(0%, 0%, 0%)",) or len(s["points"]) < 6:
            continue
        rgb = [float(c) for c in re.findall(r"([\d.]+)%", s["stroke"])]
        if len(rgb) == 3 and max(rgb) - min(rgb) < 5:  # greys: gridlines
            continue
        p = s["points"]
        end = p[np.argmax(p[:, 0])]
        label = min(inside, key=lambda w: (w[0] - end[0]) ** 2 + (w[1] - end[1]) ** 2)
        data = np.c_[xmap(p[:, 0]), ymap(p[:, 1])]
        data = data[np.argsort(data[:, 0])]
        curves[label[2]] = data
    return {"frame_pt": [left, right, top, bottom], "x_label_misfit_decades": xres, "y_label_misfit_decades": yres,
            "x_labels": len(xlabels), "y_labels": len(ylabels), "curves": curves}
