"""Digitise the average reflected pressure histories of Reynolds (2015) Figs 9 and 10 from the
thesis's embedded raster images: markers found by gray level after erosion, one a millisecond."""
import sys, json, numpy as np
from PIL import Image
def components(m, k):
    r = k // 2; e = m.copy()
    for dy in range(-r, r + 1):
        for dx in range(-r, r + 1):
            e &= np.roll(np.roll(m, dy, 0), dx, 1)
    H, W = e.shape; seen = np.zeros_like(e); out = []
    for y0, x0 in zip(*np.nonzero(e)):
        if seen[y0, x0]: continue
        st = [(y0, x0)]; seen[y0, x0] = True; pts = []
        while st:
            y, x = st.pop(); pts.append((y, x))
            for dy, dx in ((1,0),(-1,0),(0,1),(0,-1)):
                yy, xx = y + dy, x + dx
                if 0 <= yy < H and 0 <= xx < W and e[yy, xx] and not seen[yy, xx]:
                    seen[yy, xx] = True; st.append((yy, xx))
        a = np.array(pts); out.append((a[:, 1].mean(), a[:, 0].mean(), len(pts)))
    return out
def run(img, frame, tmax, pmax, imax, legend, classes):
    L, R, T, B = frame
    g = np.asarray(Image.open(img).convert("L")).astype(int)
    pxms = (R - L) / tmax
    res = {}
    for name, (lo, hi, k, nmin) in classes.items():
        m = (g >= lo) & (g <= hi)
        m[:, :L + 3] = False; m[:, R - 1:] = False; m[:T + 2] = False; m[B - 1:] = False
        x0, x1, y0, y1 = legend; m[y0:y1, x0:x1] = False
        pts = []
        for x, y, n in components(m, k):
            t = (x - L) / pxms
            pts.append((t, (B - y) / (B - T) * pmax, (B - y) / (B - T) * imax, n))
        res[name] = pts
    return res
if __name__ == "__main__":
    print(json.dumps(run(sys.argv[1], json.loads(sys.argv[2]), float(sys.argv[3]), float(sys.argv[4]),
        float(sys.argv[5]), json.loads(sys.argv[6]), json.loads(sys.argv[7]))))
