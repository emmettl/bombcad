# Writes a made-up district: no real place or map data.
import math, sys
out = sys.argv[1]
M = 6_371_008.8 * math.pi / 180  # metres per degree
lon0, lat0 = 0.0, 0.0
def ll(x, y):  # local metres from (lon0, lat0) to lon, lat
    return lon0 + x / (M * math.cos(math.radians(lat0))), lat0 + y / M
nodes, ways, rels = [], [], []
nid = [1]
def node(x, y):
    lon, lat = ll(x, y); i = nid[0]; nid[0] += 1
    nodes.append(f'  <node id="{i}" lat="{lat:.7f}" lon="{lon:.7f}"/>'); return i
def rect(x, y, w, h):
    ids = [node(x, y), node(x + w, y), node(x + w, y + h), node(x, y + h)]
    return ids + [ids[0]]
wid = [100]
def way(refs, tags):
    i = wid[0]; wid[0] += 1
    body = "".join(f'<nd ref="{r}"/>' for r in refs) + "".join(f'<tag k="{k}" v="{v}"/>' for k, v in tags)
    ways.append(f'  <way id="{i}">{body}</way>'); return i
# A 7 x 7 grid of blocks 100 m apart about (600, 600): footprints 24 x 16 m.
n = 0
for j in range(7):
    for i in range(7):
        x, y = 300 + 100 * i, 300 + 100 * j
        kind = "apartments" if (i + j) % 3 == 0 else "house" if (i + j) % 3 == 1 else "yes"
        tags = [("building", kind)]
        if n % 4 == 0: tags.append(("height", str(8 + (n % 5) * 6)))
        elif n % 4 == 1: tags.append(("building:levels", str(2 + n % 6)))
        if n % 7 == 3: tags.append(("building:material", "brick"))
        way(rect(x, y, 24, 16), tags)
        n += 1
# A warehouse and a courtyard block (a multipolygon with a hole), and a building part (left out).
way(rect(1060, 560, 60, 30), [("building", "warehouse"), ("height", "9")])
outer = way(rect(560, 1060, 50, 50), [])
inner = way(rect(575, 1075, 20, 20), [])
rels.append(f'  <relation id="900"><member type="way" ref="{outer}" role="outer"/><member type="way" ref="{inner}" role="inner"/>'
            '<tag k="type" v="multipolygon"/><tag k="building" v="office"/><tag k="building:levels" v="6"/></relation>')
way(rect(605, 605, 6, 6), [("building:part", "yes"), ("height", "30")])
lo, la = ll(0, 0); hi_lo, hi_la = ll(1200, 1200)
with open(f"{out}/district.osm", "w") as f:
    f.write('<?xml version="1.0" encoding="UTF-8"?>\n<!-- Made up for BombCAD\'s tests: not a real place or real map data. -->\n')
    f.write(f'<osm version="0.6" generator="BombCAD tests">\n  <bounds minlat="{la:.7f}" minlon="{lo:.7f}" maxlat="{hi_la:.7f}" maxlon="{hi_lo:.7f}"/>\n')
    f.write("\n".join(nodes + ways + rels) + "\n</osm>\n")
# Ground: 0.0003° cells (about 33 m) over -0.0015..0.0123, a slope up to the north-east with a hill,
# and sea (below 1 m) along the south-west edge.
step, cols, rows = 0.0003, 47, 47
x0, y0 = -0.0015, -0.0015
lines = [f"ncols {cols}", f"nrows {rows}", f"xllcorner {x0}", f"yllcorner {y0}", f"cellsize {step}", "NODATA_value -9999"]
for r in range(rows - 1, -1, -1):
    vals = []
    for c in range(cols):
        lon, lat = x0 + (c + 0.5) * step, y0 + (r + 0.5) * step
        x, y = lon * M, lat * M
        z = 2 + 0.01 * (x + y) + 12 * math.exp(-((x - 900) ** 2 + (y - 400) ** 2) / (2 * 120 ** 2))
        if x + y < 250: z = 0.2
        vals.append(f"{z:.2f}")
    lines.append(" ".join(vals))
open(f"{out}/ground.asc", "w").write("\n".join(lines) + "\n")
# Building heights: 0.001° cells (about 110 m), 6 to 21 m, rising to the north.
step, cols, rows = 0.001, 14, 14
lines = [f"ncols {cols}", f"nrows {rows}", f"xllcorner {x0}", f"yllcorner {y0}", f"cellsize {step}", "NODATA_value -9999"]
for r in range(rows - 1, -1, -1):
    lines.append(" ".join(f"{6 + 15 * r / (rows - 1):.1f}" for c in range(cols)))
open(f"{out}/heights.asc", "w").write("\n".join(lines) + "\n")
print(n + 3, "ways,", len(nodes), "nodes")
