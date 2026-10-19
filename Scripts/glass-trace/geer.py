import struct, math, collections, re, sys
sys.path.insert(0, '.')
from dbf import read_dbf
BASE = "/Volumes/StudioData/bombcad/data/Beirut2020/GEER2021/DesignSafe_PRJ-3030/Facade damage assessment/Facade_damage"
GZ = (33.901461, 35.519020)  # lat, lon
def shapes(path):
    f = open(path, 'rb'); f.seek(100); out = []
    while True:
        h = f.read(8)
        if len(h) < 8: break
        n, length = struct.unpack('>II', h)
        rec = f.read(length * 2)
        t = struct.unpack('<i', rec[:4])[0]
        if t == 0: out.append(None); continue
        xmin, ymin, xmax, ymax = struct.unpack('<4d', rec[4:36])
        out.append(((xmin + xmax) / 2, (ymin + ymax) / 2))
    return out
def facades():
    _, rows = read_dbf(BASE + ".dbf")
    cs = shapes(BASE + ".shp")
    out = []
    for r, c in zip(rows, cs):
        if c is None: continue
        lon, lat = c
        dy = (lat - GZ[0]) * 111320.0
        dx = (lon - GZ[1]) * 111320.0 * math.cos(math.radians(GZ[0]))
        d = math.hypot(dx, dy)
        s = r['Facade_dam']
        m = re.match(r'^([Ww])-?(\d+)-(\d)(?:-(\d*))?$', s)
        if not m: continue
        az = float(m.group(2)); cls = int(m.group(3)); rate = m.group(4)
        rate = float(rate) if rate else None
        # facing: cosine between the facade's outward normal and the direction to the charge
        nx, ny = math.sin(math.radians(az)), math.cos(math.radians(az))
        tx, ty = -dx / d, -dy / d
        out.append(dict(d=d, cls=cls, rate=rate, lower=m.group(1) == 'w', az=az, facing=nx * tx + ny * ty))
    return out
if __name__ == "__main__":
    F = facades()
    print(len(F), "facades parsed")
    bands = [500, 750, 1000, 1250, 1500, 1750, 2000, 2500, 3000]
    def band(d):
        for a, b in zip(bands, bands[1:]):
            if a <= d < b: return (a, b)
    print("band        n   W0   W1   W2   W3 | W1 rate median (n) | W2 rate median (n) | lower share, its W1+ vs upper W1+")
    for a, b in zip(bands, bands[1:]):
        S = [f for f in F if a <= f['d'] < b]
        c = collections.Counter(f['cls'] for f in S); n = len(S)
        r1 = sorted(f['rate'] for f in S if f['cls'] == 1 and f['rate'] is not None)
        r2 = sorted(f['rate'] for f in S if f['cls'] == 2 and f['rate'] is not None)
        low = [f for f in S if f['lower']]; up = [f for f in S if not f['lower']]
        med = lambda x: x[len(x)//2] if x else float('nan')
        wp = lambda X: sum(1 for f in X if f['cls'] >= 1) / max(len(X), 1)
        print(f"{a:5}-{b:<5} {n:5} " + " ".join(f"{c[k]/n:.2f}" for k in range(4)) + f" | {med(r1):5.0f} ({len(r1):4}) | {med(r2):5.0f} ({len(r2):4}) | {len(low)/n:.2f}, {wp(low):.2f} vs {wp(up):.2f}")
    print()
    print("By facing (cos to charge): W1+ and W3 shares")
    for a, b in zip(bands, bands[1:]):
        S = [f for f in F if a <= f['d'] < b]
        row = []
        for lo, hi, name in [(0.5, 1.01, "facing"), (-0.5, 0.5, "side"), (-1.01, -0.5, "away")]:
            X = [f for f in S if lo <= f['facing'] < hi]
            if X: row.append(f"{name} {len(X):4} W1+ {sum(f['cls']>=1 for f in X)/len(X):.2f} W3 {sum(f['cls']>=3 for f in X)/len(X):.2f}")
        print(f"{a:5}-{b:<5} " + " | ".join(row))
