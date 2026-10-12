"""Rebuild the digitised fixtures from the source PDFs (on StudioData) into OUT.

    python3 make_fixtures.py DATA OUT

DATA is the folder holding UFC-3-340-02/, Schwer2015/, XuLu2016/ and Cooper1996/ (each with its
PDF); OUT receives one folder per source. Needs numpy and Pillow, and poppler's pdftocairo,
pdftoppm and pdftotext. Each step's method and error are in the fixtures' READMEs.
"""
import glob
import json
import os
import re
import subprocess
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import colour_curves  # noqa: E402
import dots  # noqa: E402
import trace  # noqa: E402
import vector_auto  # noqa: E402
import vector_chart  # noqa: E402

DATA, OUT = sys.argv[1], sys.argv[2]
WORK = os.path.join(OUT, ".work")
os.makedirs(WORK, exist_ok=True)


def pdf(source):
    return glob.glob(os.path.join(DATA, source, "*.pdf"))[0]


def svg(source, page):
    path = os.path.join(WORK, f"{source}-{page}.svg")
    if not os.path.exists(path):
        subprocess.run(["pdftocairo", "-f", str(page), "-l", str(page), "-svg", pdf(source), path], check=True)
    return path


def raster(source, page, dpi=220):
    stem = os.path.join(WORK, f"{source}-{page}-{dpi}")
    if not glob.glob(stem + "*"):
        subprocess.run(["pdftoppm", "-f", str(page), "-l", str(page), "-r", str(dpi), "-gray", pdf(source), stem], check=True)
    return glob.glob(stem + "*")[0]


def write(source, name, data):
    os.makedirs(os.path.join(OUT, source), exist_ok=True)
    text = json.dumps(data, indent=1)
    text = re.sub(r"\[\s*(-?[\d.e+-]+),\s*(-?[\d.e+-]+)\s*\]", r"[\1, \2]", text)  # pairs on one line
    with open(os.path.join(OUT, source, name), "w") as handle:
        handle.write(text + "\n")


# UFC 3-340-02, Figures 2-9 and 2-10 (vector): reflected pressure and impulse against angle.
specs = json.load(open(os.path.join(HERE, "ufc-reflection-specs.json")))
specs["UFC Fig 2-9"]["svg"] = svg("UFC-3-340-02", 161)
specs["UFC Fig 2-10"]["svg"] = svg("UFC-3-340-02", 162)
reflection = {}
for name, spec in specs.items():
    result = vector_chart.digitise(spec)
    reflection[name] = {
        "pdf_page": 161 if name.endswith("2-9") else 162,
        "gridline_misfit": result["gridline_misfit"],
        "curves": {c["label"]: c["sampled"] for c in result["curves"]},
    }
write("UFC-3-340-02", "oblique-reflection.json", {
    "source": "UFC 3-340-02 (2008), Figures 2-9 and 2-10",
    "x": "angle of incidence (degrees)",
    "y": {"UFC Fig 2-9": "peak reflected pressure P_r,alpha (psi)",
          "UFC Fig 2-10": "scaled reflected impulse i_r,alpha / W^(1/3) (psi ms / lb^(1/3))"},
    "curve_label": "scaled normal distance from the charge to the surface, H_c / W^(1/3) (ft / lb^(1/3))",
    "figures": reflection})

# UFC 3-340-02, Figures 2-153 to 2-163 (vector): vented gas impulse.
grid = [0.02, 0.03, 0.05, 0.07, 0.1, 0.15, 0.2, 0.3, 0.5, 0.7, 1, 1.5, 2, 3, 5, 7, 10]
vented = {}
for page in range(304, 315):
    title = subprocess.run(["pdftotext", "-f", str(page), "-l", str(page), pdf("UFC-3-340-02"), "-"],
                           capture_output=True, text=True).stdout.replace("\n", " ")
    m = re.search(r"Figure (2-1\d\d)\s+Scaled Gas Impulse \(W/Vf = ([\d.]+), ir /W1/3 = (\d+)\)", title)
    r = vector_auto.digitise(pdf("UFC-3-340-02"), page, svg("UFC-3-340-02", page))
    curves = {}
    for label, d in sorted(r["curves"].items()):
        xs = [g for g in grid if d[0, 0] * 0.98 <= g <= d[-1, 0] * 1.02]
        ys = 10 ** np.interp(np.log10(xs), np.log10(d[:, 0]), np.log10(d[:, 1]))
        name = ".03 (as printed; probably 0.3)" if label == 0.03 else ("%g" % label)
        curves[name] = [[g, float("%.4g" % y)] for g, y in zip(xs, ys)]
    vented["Figure " + m.group(1)] = {
        "pdf_page": page, "W_over_Vf": float(m.group(2)), "ir_over_W13": float(m.group(3)),
        "label_misfit_decades": [round(r["x_label_misfit_decades"], 5), round(r["y_label_misfit_decades"], 5)],
        "curves": curves}
write("UFC-3-340-02", "vented-gas-impulse.json", {
    "source": "UFC 3-340-02 (2008), Figures 2-153 to 2-163",
    "x": "scaled vent area A / Vf^(2/3)",
    "y": "scaled gas impulse i_g / W^(1/3) (psi ms / lb^(1/3))",
    "chart_parameters": "W/Vf (lb/ft^3), charge weight over free volume; ir/W^(1/3), scaled reflected impulse on the vent (psi ms / lb^(1/3))",
    "curve_label": "W_F / W^(1/3), scaled mass of the frangible vent cover (psf / lb^(1/3))",
    "figures": vented})

# UFC 3-340-02, Figures 2-8 and 2-16 (raster): negative phase, traced along anchors.
names = {"Ps": ("negative incident overpressure P_s-", "psi", "left"),
         "Pr": ("negative reflected overpressure P_r-", "psi", "left"),
         "is": ("scaled negative incident impulse i_s- / W^(1/3)", "psi ms / lb^(1/3)", "left"),
         "ir": ("scaled negative reflected impulse i_r- / W^(1/3)", "psi ms / lb^(1/3)", "left"),
         "t0": ("scaled negative phase duration t_0- / W^(1/3)", "ms / lb^(1/3)", "right"),
         "Lw": ("scaled negative wavelength L_w- / W^(1/3)", "ft / lb^(1/3)", "right")}
zgrid = [round(v, 3) for v in 10 ** np.arange(-1, 2.0001, 0.05)]


def median5(y):
    padded = np.r_[y[:2], y, y[-2:]]
    return np.array([np.median(padded[i : i + 5]) for i in range(len(y))])


negative = {}
for figure, page, frame, left, right, anchors, offset, method in (
    ("UFC Fig 2-8 (spherical, free air)", 160, (353.5, 1516.5, 405, 1227), (1, 100), (0.1, 10),
     "ufc-2-8-anchors-crop.json", (300, 350), {"ir": "guided", "Lw": "guided"}),
    ("UFC Fig 2-16 (hemispherical, on the surface)", 167, (419, 1494.5, 389, 1463), (1, 1000), (0.1, 100),
     "ufc-2-16-anchors.json", None, {}),
):
    image = trace.load(raster("UFC-3-340-02", page))
    an = json.load(open(os.path.join(HERE, anchors)))
    curves = {}
    for key, points in an.items():
        if offset:
            pts = [(x + offset[0], y + offset[1]) for x, y in points]
            t = (trace.guided(image, pts, reach=8) if method.get(key) == "guided"
                 else trace.follow(image, pts, reach=8, pull=0.5))
        else:
            pts = [(2 * x, 2 * y) for x, y in points]
            t = trace.guided(image, pts, reach=12 if key in ("Lw", "Ps") else (10 if key == "is" else 14))
        t = np.c_[t[:, 0], median5(t[:, 1])]
        name, unit, axis = names[key]
        data = trace.to_data(t, frame, (0.1, 100), left if axis == "left" else right)
        z = [g for g in zgrid if data[:, 0].min() <= g <= data[:, 0].max()]
        v = 10 ** np.interp(np.log10(z), np.log10(data[:, 0]), np.log10(data[:, 1]))
        curves[key] = {"quantity": name, "unit": unit, "axis": axis,
                       "sampled": [[a, float("%.3g" % b)] for a, b in zip(z, v)]}
    negative[figure] = {"pdf_page": page, "curves": curves}
write("UFC-3-340-02", "negative-phase.json", {
    "source": "UFC 3-340-02 (2008), Figures 2-8 and 2-16",
    "x": "scaled distance Z = R / W^(1/3) (ft / lb^(1/3))", "figures": negative})

# Schwer (2015), Figure 4 (raster, colours): measured mid-span deflection, three shots.
image = os.path.join(WORK, "schwer-fig4.png")
if not os.path.exists(image):
    subprocess.run(["pdfimages", "-f", "4", "-l", "4", "-png", pdf("Schwer2015"), os.path.join(WORK, "schwer")], check=True)
    os.rename(os.path.join(WORK, "schwer-000.png"), image)
gx = [103, 141, 179, 217, 255, 293, 332, 370, 408, 446, 484, 522, 560]
gy = [66, 111, 155, 200, 244, 289, 333, 377, 422, 466, 511]
tx, rx = colour_curves.calibrate([64.5] + gx + [597.5], [0] + [5 * k for k in range(1, 14)] + [70])
ty, ry = colour_curves.calibrate([554.5] + gy[::-1] + [21.5], [0] + [10 * k for k in range(1, 12)] + [120])
masks = {"Load 1a (Slab-2)": lambda r, g, b: (r > 170) & (g < 90) & (b < 90),
         "Load 1aa (Slab-4)": lambda r, g, b: (b > 130) & (r < 120) & (g < 120) & (b - r > 50),
         "Load 1b (Slab-6)": lambda r, g, b: (r < 70) & (g < 70) & (b < 70)}
found = colour_curves.curves(image, masks, (67, 596, 23, 553), exclude=[(275, 490, 345, 432)])
histories = {}
for name, points in found.items():
    p = np.array(points)
    t, d = tx(p[:, 0]), ty(p[:, 1])
    g = np.arange(np.ceil(t[0] * 2) / 2, np.floor(t[-1] * 2) / 2 + 1e-9, 0.5)
    histories[name] = [[round(float(x), 2), round(float(np.median(d[np.abs(t - x) <= 0.5])), 1)]
                       for x in g if np.any(np.abs(t - x) <= 0.5)]
write("Schwer2015", "displacement-histories.json", {
    "source": "L. E. Schwer, SMiRT-23 (2015), Paper 015, Figure 4",
    "quantity": "measured central displacement of the unloaded face (mm) against time (ms)",
    "method": "per pixel column, the median height of the curve's colour; every 0.5 ms, the median over ±0.5 ms",
    "calibration_residual": {"time_ms": round(float(rx), 3), "deflection_mm": round(float(ry), 3)},
    "histories": histories})

# Xu and Lu (2016), Figure 6 (raster, colour): measured deflection and applied force.
page9 = os.path.join(WORK, "xulu-p9.png")
if not os.path.exists(page9):
    subprocess.run(["pdftoppm", "-f", "9", "-l", "9", "-r", "300", "-png", pdf("XuLu2016"), os.path.join(WORK, "xulu-p9")], check=True)
    os.rename(glob.glob(os.path.join(WORK, "xulu-p9-*.png"))[0], page9)
from PIL import Image  # noqa: E402

page = Image.open(page9)
s = 300 / 80
left_panel, right_panel = os.path.join(WORK, "xulu-left.png"), os.path.join(WORK, "xulu-right.png")
page.crop((int(80 * s), int(525 * s), int(330 * s), int(655 * s))).save(left_panel)
page.crop((int(330 * s), int(525 * s), int(600 * s), int(655 * s))).save(right_panel)
green = {"exp": lambda r, g, b: (g > 150) & (g - r > 15) & (g - b > 40)}
tl, _ = colour_curves.calibrate([158, 800], [0, 80])
yin, _ = colour_curves.calibrate([453, 47], [0, 4.5])
p = np.array(colour_curves.curves(left_panel, green, (160, 798, 40, 452), exclude=[(470, 775, 265, 452)])["exp"])
deflection = [[round(float(a), 2), round(float(b) * 25.4, 1)] for a, b in zip(tl(p[:, 0]), yin(p[:, 1]))]
tr, _ = colour_curves.calibrate([170, 805], [0, 60])
ykip, _ = colour_curves.calibrate([450, 46], [0, 30])
q = np.array(colour_curves.curves(right_panel, green, (172, 803, 40, 449), exclude=[(458, 790, 40, 215)])["exp"])
force = [[round(float(a), 2), round(float(b) * 4.44822, 1)] for a, b in zip(tr(q[:, 0]), ykip(q[:, 1]))]


def every(series, step):
    t = np.array([a for a, _ in series])
    v = np.array([b for _, b in series])
    g = np.arange(np.ceil(t[0] / step) * step, t[-1] + 1e-9, step)
    return [[round(float(x), 2), round(float(np.median(v[np.abs(t - x) <= step])), 1)] for x in g if np.any(np.abs(t - x) <= step)]


write("XuLu2016", "contest-slab-figure-6.json", {
    "source": "J. Xu and Y. Lu, ACI SP-306 (2016), Figure 6",
    "deflection": {"quantity": "the experiment's ('exp.') central deflection, mm, read on the figure's inch axis",
                   "series": every(deflection, 0.5)},
    "applied_force": {"quantity": "the applied blast force on the quarter-slab model, kN, read on the figure's kip axis",
                      "series": every(force, 0.25)}})

# Cooper (1996): Table 27.2 (transcribed), Figure 27.13 (dots), Figures 27.15-27.18 (traced).
table = [("Baratol", 0.128, 137), ("Composition B", 0.0554, 265), ("Cyclotol (75/25)", 0.0493, 316),
         ("H-6", 0.0690, 227), ("HBX-1", 0.0639, 227), ("HBX-3", 0.0808, 219), ("Pentolite (50/50)", 0.0620, 255),
         ("PTX-1", 0.0554, 249), ("PTX-2", 0.0568, 284), ("TNT", 0.0779, 190), ("Composition A-3", 0.0549, 305),
         ("RDX/Wax (95/5)", 0.0531, 279), ("Tetryl", 0.0681, 226)]
a = dots.load(raster("Cooper1996", 412, 300))
L = dots.edge(a, (830, 900, 1080, 2120), "left")
R = dots.edge(a, (1740, 1830, 1080, 2120), "right")
T = dots.edge(a, (900, 1760, 1040, 1110), "top")
B = dots.edge(a, (900, 1760, 2100, 2190), "bottom")
f = dots.frame_map(L, R, T, B, (0.1, 10), (1, 1000))
marks = sorted([f(x, y) for x, y, n in dots.blobs(a, (880, 1830, 1090, 2160))])
an = json.load(open(os.path.join(HERE, "cooper-drag-anchors.json")))
mach = [round(v, 3) for v in 10 ** np.arange(-1, 1.0001, 0.05)]
drag = {}
for fig, spec in an.items():
    page = spec["page"]
    image = trace.load(raster("Cooper1996", page, 300))
    dark = image < 150
    bottom = dots.edge(image, *{"27.15": ((770, 1870, 2120, 2200),), "27.16": ((710, 1750, 772, 852),),
                                 "27.17": ((710, 1750, 2188, 2268),), "27.18": ((790, 1850, 826, 906),)}[fig], "bottom")
    top = dots.edge(image, *{"27.15": ((770, 1870, 1571, 1651),), "27.16": ((710, 1750, 246, 326),),
                              "27.17": ((710, 1750, 1665, 1745),), "27.18": ((790, 1850, 246, 326),)}[fig], "top")
    cols = []
    for x in range(560, 2100):
        yb = int(round(bottom[0] * x + bottom[1]))
        if dark[yb + 5 : yb + 22, x].sum() >= 8:
            cols.append(x)
    groups = []
    for x in cols:
        if groups and x - groups[-1][-1] <= 2:
            groups[-1].append(x)
        else:
            groups.append([x])
    ticks = [float(np.mean(g)) for g in groups]
    expected = np.log10([0.1 * k for k in range(1, 10)] + list(range(1, 10)) + [10])
    slope, intercept = np.polyfit(expected, ticks, 1)
    s = bottom[0]

    def to_data(x, y):
        x0 = x + s * ((bottom[0] * x + bottom[1]) - y)
        yb, yt = bottom[0] * x0 + bottom[1], top[0] * x0 + top[1]
        return 10 ** ((x0 - intercept) / slope), 2.5 * (yb - y) / (yb - yt)

    for name, anchors in spec["curves"].items():
        t = trace.follow(image, [(4 * x, 4 * y) for x, y in anchors], reach=8, pull=0.5)
        d = np.array([to_data(x, y) for x, y in t])
        d = d[np.argsort(d[:, 0])]
        m = [g for g in mach if d[0, 0] <= g <= d[-1, 0]]
        drag[name] = {"figure": fig, "tick_residual_px": round(float(np.abs(np.polyval([slope, intercept], expected) - ticks).max()), 1),
                      "sampled": [[g, round(float(np.interp(np.log10(g), np.log10(d[:, 0]), d[:, 1])), 3)] for g in m]}
write("Cooper1996", "fragments.json", {
    "source": "P. W. Cooper, Explosives Engineering, Wiley-VCH, 1996 (book page = PDF page - 16)",
    "table_27_2": {"title": "Values of Mott coefficient B for mild steel cylinders (book p. 397)",
                   "columns": ["explosive", "B (lb^(1/2) in^(-7/16))", "P_CJ (kbar)"],
                   "rows": [list(r) for r in table]},
    "figure_27_13": {"title": "N(m), number of fragments heavier than m, against m (g), for a cast iron aerial bomb: the experimental points (book p. 396)",
                     "points": [[float("%.3g" % m), float("%.3g" % n)] for m, n in marks]},
    "figures_27_15_to_27_18": {"title": "Drag coefficient against Mach number (Hoerner's data; book pp. 400-402)",
                               "curves": drag}})
print("done")
