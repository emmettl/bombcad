import math, collections, sys, re
from gtrace import load, side_outcome
from dbf import read_dbf
from geer import shapes, BASE, GZ
_, rows = read_dbf(BASE + ".dbf"); cs = shapes(BASE + ".shp")
def facing(i):
    lon, lat = cs[i]; dy = (lat - GZ[0]) * 111320.0; dx = (lon - GZ[1]) * 111320.0 * math.cos(math.radians(GZ[0]))
    d = math.hypot(dx, dy); m = re.match(r'^[Ww]-?(\d+)-', rows[i]['Facade_dam'])
    if not m: return None
    az = math.radians(float(m.group(1))); return (math.sin(az) * -dx + math.cos(az) * -dy) / d
run = int(sys.argv[1]) if len(sys.argv) > 1 else 1
sides, matches = load(run)
out = {k: side_outcome(r) for k, r in sides.items()}
print("by distance and facing: n, model median peak kPa, model frac, GEER W1+, W3")
for a, b in [(750, 1000), (1000, 1250), (1250, 1500), (1500, 1750)]:
    for lo, hi, name in [(0.5, 1.01, "facing"), (-0.5, 0.5, "side"), (-1.01, -0.5, "away")]:
        S = [k for k in out if a <= float(matches[k]['distance']) < b and (f := facing(int(matches[k]['record']))) is not None and lo <= f < hi]
        if len(S) < 10: continue
        pk = sorted(out[k]['peak'] for k in S)[len(S)//2] / 1000
        fr = sum(out[k]['frac'] for k in S) / len(S)
        g1 = sum(int(matches[k]['class']) >= 1 for k in S) / len(S); g3 = sum(int(matches[k]['class']) >= 3 for k in S) / len(S)
        print(f"{a}-{b} {name:6} {len(S):5}  peak {pk:5.1f}  frac {fr:.2f} | GEER {g1:.2f} {g3:.2f}")
