import csv, math, collections, sys
K, M = 2.86e-53, 7.0
import os
T = os.environ.get("GLASS_TRACE", "/Volumes/StudioData/bombcad/glass-trace/trace.csv")
def load(run_wanted):
    sides = collections.defaultdict(list)  # match -> rows
    with open(T) as f:
        for r in csv.DictReader(f):
            if int(r['run']) != run_wanted: continue
            sides[int(r['match'])].append(r)
    matches = {}
    with open(T + ".matches.csv") as f:
        for r in csv.DictReader(f): matches[int(r['match'])] = r
    return sides, matches
def side_outcome(rows, strength=1.0, lost_breaks=True, area_eff=1.0):
    panes = broken = 0.0; lognone = 0.0; peak = imp = 0.0; lost = 0.0
    for r in rows:
        n = float(r['count']); s = float(r['stress60_pa']); A = float(r['width']) * float(r['height'])
        L = r['lost'] == '1'
        p = 1.0 if (L and lost_breaks) else (1 - math.exp(-K * A * area_eff * (s / strength) ** M) if s > 0 else 0)
        panes += n; broken += n * p; lognone += n * math.log(max(1 - p, 1e-300))
        peak = max(peak, float(r['peak_pa'])); imp = max(imp, float(r['impulse_pas'])); lost += n * (1 if L else 0)
    return dict(frac=broken / panes if panes else 0, some=1 - math.exp(lognone), peak=peak, imp=imp, panes=panes, lost=lost / panes if panes else 0)
bands = [500, 750, 1000, 1250, 1500, 1750, 2000, 2500, 3000]
if __name__ == "__main__":
    run = int(sys.argv[1]) if len(sys.argv) > 1 else 1
    sides, matches = load(run)
    out = {}
    for k, rows in sides.items(): out[k] = side_outcome(rows)
    print(f"run {run}: {len(out)} matched facades with strips")
    print("band   n | model frac, some, blown(0.9) | GEER W1+ W3")
    for a, b in zip(bands, bands[1:]):
        ks = [k for k in out if a <= float(matches[k]['distance']) < b]
        if not ks: continue
        n = len(ks)
        fr = sum(out[k]['frac'] for k in ks) / n; so = sum(out[k]['some'] for k in ks) / n
        bl = sum(out[k]['frac'] >= 0.9 for k in ks) / n
        g1 = sum(int(matches[k]['class']) >= 1 for k in ks) / n; g3 = sum(int(matches[k]['class']) >= 3 for k in ks) / n
        print(f"{a}-{b} {n:5} | {fr:.2f} {so:.2f} {bl:.2f} | {g1:.2f} {g3:.2f}")
