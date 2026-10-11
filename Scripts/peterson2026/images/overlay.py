import json, glob, os, math
import numpy as np, cv2
import analyse as A, dic
OUT = "/Volumes/StudioData/bombcad/peterson-images"
tiles = []
for jf in sorted(glob.glob(f"{OUT}/json/*.json")):
    r = json.load(open(jf)); b = r["beam"]
    if r.get("t0") is None: continue
    fs = A.longest_run(b)
    g = r["geometry"]; s = g["scale"]; sx = r["support_x"]
    last = min(r["t0"] + 150, len(fs) - 1)
    img = cv2.cvtColor(dic.load(fs[last]), cv2.COLOR_GRAY2BGR)
    def draw(c, col, w):
        x = sx + c["x_mm"] / s
        y = g["bottom"] - c["height_mm"] / s if "height_mm" in c else (g["top"] + g["bottom"]) / 2
        L = c["length"] / s / 2; a = math.radians(c["angle"])
        p1 = (int(x - L * math.cos(a)), int(y + L * math.sin(a))); p2 = (int(x + L * math.cos(a)), int(y - L * math.sin(a)))
        cv2.line(img, p1, p2, col, w)
    if r.get("first_diagonal"):
        for c in r["first_diagonal"]["cracks"]: draw(c, (0, 200, 255), 2)
    if r.get("main_crack"):
        m = dict(r["main_crack"]["main"])
        st = r["main_crack"]["stations"][1]; m["height_mm"] = st["height_mm"]; m["x_mm"] = st["x_mm"]
        draw(m, (0, 0, 255), 1)
    cv2.circle(img, (int(sx), int(g["bottom"])), 5, (255, 0, 0), -1)
    cv2.circle(img, (int(g["load_x"]), int(g["top"])), 5, (255, 0, 0), -1)
    t = cv2.resize(img, (512, 256))
    cv2.putText(t, b, (5, 15), cv2.FONT_HERSHEY_SIMPLEX, 0.5, (255, 255, 255), 1)
    tiles.append(t)
while len(tiles) % 2: tiles.append(np.zeros_like(tiles[0]))
rows = [np.hstack(tiles[k:k + 2]) for k in range(0, len(tiles), 2)]
cv2.imwrite(f"{OUT}/overlay_a.png", np.vstack(rows[:4])); cv2.imwrite(f"{OUT}/overlay_b.png", np.vstack(rows[4:]))
