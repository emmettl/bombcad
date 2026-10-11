"""Peterson et al. (2026): crack angle and timing, strut crushing, and the shear crack's opening and
slip, read from the high-speed frames by dense optical flow (OpenCV Farneback) from the frame
before impact. Writes one JSON record per beam and a few images to check by eye."""
import json, os, sys
import numpy as np, cv2
from PIL import Image
from skimage import measure
import dic

FPS = 6000.0
SPAN_A = {"04d": 48.0, "1d": 120.0, "2d": 240.0}  # mm from the left support to the load
OUT = "/Volumes/StudioData/bombcad/peterson-images"

def longest_run(beam):
    d = os.path.join(dic.ROOT, beam)
    sub = [s for s in os.listdir(d) if s.lower().startswith("test")][0]
    fs = sorted(f for f in os.listdir(os.path.join(d, sub)) if f.endswith(".tif"))
    nums = [int(f[-10:-4]) for f in fs]
    runs, cur = [], [0]
    for k in range(1, len(fs)):
        if nums[k] - nums[k - 1] == 1: cur.append(k)
        else: runs.append(cur); cur = [k]
    runs.append(cur)
    # the earliest run long enough to hold the impact (D_1d_NoS_1 has a later run too, and
    # D_2d_NoS_2 a few stray frames first)
    best = next((r for r in runs if len(r) >= 60), max(runs, key=len))
    return [os.path.join(d, sub, fs[k]) for k in best]

def geometry(ref):
    """Beam top and bottom rows (bright speckle against the dark background), the scale (mm/px)
    from its 150 mm depth, and the loading cylinder's centre column."""
    img = ref.astype(float)
    cols = slice(int(img.shape[1] * 0.05), int(img.shape[1] * 0.6))
    # texture: the speckle's small-scale variation, row by row (pencil lines are smooth along a row)
    tex = np.abs(np.diff(img[:, cols], axis=1)).mean(axis=1)
    tex = cv2.GaussianBlur(tex.reshape(-1, 1), (1, 7), 0).ravel()
    level = 0.5 * np.median(tex[np.argsort(tex)[-200:]])
    rows = np.nonzero(tex > level)[0]
    top, bottom = int(rows.min()), int(rows.max())
    scale = 150.0 / (bottom - top)
    # the cylinder: bright, just above the top face
    band = img[max(top - 70, 0):top - 8, :]
    bright = cv2.GaussianBlur(band.mean(axis=0).reshape(1, -1), (9, 1), 0).ravel()
    lit = bright > bright.min() + 0.5 * (bright.max() - bright.min())
    # the widest lit run of columns is the cylinder; its middle is where it bears
    runs, start = [], None
    for x, on in enumerate(lit):
        if on and start is None: start = x
        if not on and start is not None: runs.append((start, x)); start = None
    if start is not None: runs.append((start, len(lit)))
    a, b = max(runs, key=lambda r: r[1] - r[0])
    load_x = int((a + b) / 2)
    # the beam's left end: first column of speckle in the beam's middle band
    mid = img[top + 20:bottom - 20, :].std(axis=0)
    left = int(np.argmax(mid > 0.5 * np.median(mid[:600])))
    return dict(top=top, bottom=bottom, scale=scale, load_x=load_x, left=left)

def painted(ref):
    """The speckled area of interest: where the reference frame has fine texture."""
    f = ref.astype(np.float32)
    m = cv2.GaussianBlur(f, (0, 0), 3)
    sd = np.sqrt(np.maximum(cv2.GaussianBlur(f * f, (0, 0), 3) - m * m, 0))
    mask = sd > 0.5 * np.median(sd[sd > np.percentile(sd, 60)])
    return cv2.erode(mask.astype(np.uint8), np.ones((15, 15), np.uint8)).astype(bool)

def components(e1, g, threshold, min_len_mm):
    mask = (e1 > threshold) & g["aoi"]
    mask[: g["top"] + 4] = False; mask[g["bottom"] - 4:] = False
    lab = measure.label(mask, connectivity=2)
    out = []
    for r in measure.regionprops(lab):
        if r.area < 15: continue
        ys, xs = r.coords[:, 0], r.coords[:, 1]
        pts = np.stack([xs - xs.mean(), -(ys - ys.mean())], 1).astype(float)
        w, v = np.linalg.eigh(pts.T @ pts / len(pts))
        axis = v[:, 1]
        length = 4 * np.sqrt(w[1]) * g["scale"]  # mm, ~ full length of a uniform line
        if length < min_len_mm: continue
        ang = np.degrees(np.arctan2(axis[1], axis[0])) % 180  # 0-180, from +x (right), up positive
        out.append(dict(length=float(length), angle=float(ang), x=float(xs.mean()), y=float(ys.mean()),
                        ymin=int(ys.min()), ymax=int(ys.max()), xmin=int(xs.min()), xmax=int(xs.max()),
                        area=int(r.area), label=int(r.label)))
    return out, lab

def residual(ref, img, f):
    h, w = ref.shape
    gx, gy = np.meshgrid(np.arange(w, dtype=np.float32), np.arange(h, dtype=np.float32))
    back = cv2.remap(img, gx + f[..., 0], gy + f[..., 1], cv2.INTER_LINEAR)
    return cv2.GaussianBlur(np.abs(back.astype(np.float32) - ref.astype(np.float32)), (0, 0), 3)

def sample(f, x, y):
    return np.array([cv2.getRectSubPix(f[..., c], (1, 1), (float(x), float(y)))[0, 0] for c in (0, 1)])

def analyse(beam):
    fs = longest_run(beam)
    kind = beam.split("_")[1]
    ref = dic.load(fs[0]); g = geometry(ref); g["aoi"] = painted(ref)
    s = g["scale"]; a_px = SPAN_A[kind] / s
    support_x = g["load_x"] - a_px
    # the impact: when the top of the beam under the load first moves 0.3 px
    rec = []
    t0 = None
    flows = {}
    for i, f in enumerate(fs):
        fl = dic.flow(ref, dic.load(f))
        lx = g["load_x"]
        top_v = float(fl[g["top"] + 6:g["top"] + 20, int(lx - 15):int(lx + 15), 1].mean())
        if t0 is None and top_v > 0.3: t0 = max(i - 1, 0)
        flows[i] = fl
        rec.append(top_v)
        if t0 is not None and i - t0 > 150: break
    n = len(flows)
    if t0 is None:
        rec = dict(beam=beam, frames=len(fs), t0=None, note="no impact within the recording")
        with open(f"{OUT}/json/{beam}.json", "w") as fh: json.dump(rec, fh, indent=1)
        return rec
    ms = lambda i: (i - t0) / FPS * 1000.0
    first_any = first_diag = None
    crush_load = crush_support = None
    squash_load = squash_support = None
    run_load = run_sup = 0
    history = []
    zone = lambda cx, cy, rx, ry: (slice(int(max(cy - ry, 0)), int(cy + ry)), slice(int(max(cx - rx, 0)), int(cx + rx)))
    # 30 mm either side of the load and the support, from 10 to 40 mm in from the face (clear of the
    # contact's own edge)
    load_zone = zone(g["load_x"], g["top"] + 25 / s, 30 / s, 15 / s)
    sup_zone = zone(support_x, g["bottom"] - 25 / s, 30 / s, 15 / s)
    base_res = None
    labs = {}
    for i in range(t0, n):
        fl = flows[i]; img = dic.load(fs[i])
        e1, e2, ang = dic.major_strain(fl)
        comps, lab = components(e1, g, 0.03, 15.0)
        labs[i] = lab
        res = residual(ref, img, fl)
        if base_res is None: base_res = float(np.percentile(res[g["top"]:g["bottom"]], 99))
        def spalled(z):
            r = res[z]; return float((r > max(3 * base_res, 40)).mean())
        sl, ss = spalled(load_zone), spalled(sup_zone)
        # crushing as compression: 30 px (about 9 mm2) or more strained past -1.5% in the zone, away
        # from any crack (whose flow discontinuity also reads as compression beside it), held for
        # three frames, from the second frame after the impact
        clear = g["aoi"] & ~cv2.dilate((e1 > 0.03).astype(np.uint8), np.ones((15, 15), np.uint8)).astype(bool)
        def squashed(z): return int(((e2[z] < -0.015) & clear[z]).sum()) >= 30
        if i >= t0 + 2:
            run_load = run_load + 1 if squashed(load_zone) else 0
            run_sup = run_sup + 1 if squashed(sup_zone) else 0
            if squash_load is None and run_load >= 3: squash_load = i - 2
            if squash_support is None and run_sup >= 3: squash_support = i - 2
        if crush_load is None and sl > 0.15: crush_load = i
        if crush_support is None and ss > 0.15: crush_support = i
        for c in comps:
            c["frame"] = i; c["ms"] = ms(i)
            c["x_mm"] = (c["x"] - support_x) * s  # from the left support
            c["height_mm"] = (g["bottom"] - c["y"]) * s
            incl = c["angle"] if c["angle"] <= 90 else 180 - c["angle"]
            c["inclination"] = incl
            c["rises_towards"] = "right" if c["angle"] < 90 else "left"
        if first_any is None and comps: first_any = (i, comps)
        diag = [c for c in comps if 20 <= c["inclination"] <= 75 and c["length"] >= 20]
        if first_diag is None and diag: first_diag = (i, diag)
        history.append(dict(frame=i, ms=ms(i), spall_load=sl, spall_support=ss, cracks=len(comps)))
    # the main inclined crack at the end, for its opening and slip through time
    last = n - 1
    e1, _, _ = dic.major_strain(flows[last])
    comps, lab = components(e1, g, 0.05, 20.0)
    incl = [c for c in comps if 20 <= min(c["angle"], 180 - c["angle"]) <= 80]
    kin = None
    if incl:
        main = max(incl, key=lambda c: c["length"])
        ys, xs = np.nonzero(lab == main["label"])
        pts = np.stack([xs, ys], 1).astype(float); cen = pts.mean(0)
        w, v = np.linalg.eigh(np.cov((pts - cen).T)); t = v[:, 1]; nrm = np.array([-t[1], t[0]])
        proj = (pts - cen) @ t
        stations = []
        for q in (0.25, 0.5, 0.75):
            p = cen + t * np.quantile(proj, q)
            d = 12.0  # px either side, beyond the flow's 21 px window's half
            series = []
            for i in range(t0, n):
                du = sample(flows[i], *(p + nrm * d)) - sample(flows[i], *(p - nrm * d))
                du = du * s
                series.append(dict(ms=ms(i), opening=float(abs(du @ nrm)), slip=float(abs(du @ t))))
            stations.append(dict(at=q, x_mm=float((p[0] - support_x) * s), height_mm=float((g["bottom"] - p[1]) * s), series=series))
        mine = lab == main["label"]
        appeared = None
        for i in range(t0, n):
            li = labs[i]
            hit = li[mine & (li > 0)]
            if hit.size and np.bincount(hit).max() > 0.2 * mine.sum() * 0.25:
                appeared = ms(i); break
        main_out = {k: main[k] for k in ("length", "angle")}
        main_out["appeared_ms"] = appeared
        main_out["inclination"] = float(min(main["angle"], 180 - main["angle"]))
        main_out["x_mm"] = float((main["x"] - support_x) * s)
        main_out["span"] = "short" if main_out["x_mm"] < SPAN_A[kind] else "long"
        kin = dict(main=main_out, stations=stations)
    aoi = g.pop("aoi")
    rec = dict(beam=beam, frames=len(fs), t0=t0, geometry={k: float(v) for k, v in g.items()},
               support_x=float(support_x),
               first_crack=None if not first_any else dict(ms=ms(first_any[0]), cracks=first_any[1]),
               first_diagonal=None if not first_diag else dict(ms=ms(first_diag[0]), cracks=first_diag[1]),
               crush_load_ms=None if crush_load is None else ms(crush_load),
               crush_support_ms=None if crush_support is None else ms(crush_support),
               squash_load_ms=None if squash_load is None else ms(squash_load),
               squash_support_ms=None if squash_support is None else ms(squash_support),
               main_crack=kin, history=history)
    with open(f"{OUT}/json/{beam}.json", "w") as fh: json.dump(rec, fh, indent=1)
    tiles = []
    for k in range(16):
        i = min(t0 + 1 + k, n - 1)
        e1, _, _ = dic.major_strain(flows[i])
        t = (np.clip(np.where(aoi, e1, 0)[g["top"]:g["bottom"], :] / 0.1, 0, 1) * 255).astype(np.uint8)
        t = cv2.resize(t, (t.shape[1] // 2, t.shape[0] // 2))
        cv2.putText(t, "%.2f ms" % ms(i), (5, 15), cv2.FONT_HERSHEY_SIMPLEX, 0.45, 255, 1)
        tiles.append(t)
    cv2.imwrite(f"{OUT}/check/{beam}_sequence.png", np.vstack([np.hstack(tiles[r * 2:r * 2 + 2]) for r in range(8)]))
    # images to check by eye: the end frame with the zones, and the major strain at the first diagonal
    vis = cv2.cvtColor(dic.load(fs[last]), cv2.COLOR_GRAY2BGR)
    for z, col in ((load_zone, (0, 0, 255)), (sup_zone, (0, 255, 0))):
        cv2.rectangle(vis, (z[1].start, z[0].start), (z[1].stop, z[0].stop), col, 1)
    cv2.line(vis, (int(support_x), g["bottom"]), (int(support_x), g["bottom"] + 20), (255, 0, 0), 2)
    cv2.line(vis, (g["load_x"], g["top"] - 20), (g["load_x"], g["top"]), (255, 0, 0), 2)
    cv2.imwrite(f"{OUT}/check/{beam}_end.png", vis)
    if first_diag:
        e1, _, _ = dic.major_strain(flows[first_diag[0]])
        cv2.imwrite(f"{OUT}/check/{beam}_firstdiag.png", (np.clip(e1 / 0.1, 0, 1) * 255).astype(np.uint8))
    return rec

if __name__ == "__main__":
    os.makedirs(f"{OUT}/json", exist_ok=True); os.makedirs(f"{OUT}/check", exist_ok=True)
    for b in sys.argv[1:]:
        r = analyse(b)
        if r.get("t0") is None: print(b, r["note"]); continue
        fd = r["first_diagonal"]
        print(b, "t0", r["t0"], "first crack", None if not r["first_crack"] else round(r["first_crack"]["ms"], 2),
              "first diagonal", None if not fd else (round(fd["ms"], 2), [(round(c["inclination"]), c["rises_towards"], round(c["x_mm"]), round(c["length"])) for c in fd["cracks"]]),
              "crush load/support", r["crush_load_ms"], r["crush_support_ms"], "squash", r["squash_load_ms"], r["squash_support_ms"],
              "main", None if not r["main_crack"] else {k: (round(v, 1) if isinstance(v, float) else v) for k, v in r["main_crack"]["main"].items()}, flush=True)
