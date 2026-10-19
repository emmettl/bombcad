import math
from gtrace import load, side_outcome, bands
def Phi(x): return 0.5 * (1 + math.erf(x / math.sqrt(2)))
def fit(xs, ys):
    best = None
    for i in range(300):
        mu = math.log(1) + i * 0.02  # ln x50 from 0 to 6
        for j in range(1, 80):
            b = j * 0.025
            ll = 0
            for x, y in zip(xs, ys):
                p = min(max(Phi((math.log(x) - mu) / b), 1e-9), 1 - 1e-9)
                ll += math.log(p) if y else math.log(1 - p)
            if best is None or ll > best[0]: best = (ll, mu, b)
    return best
data = {}
for run in (0, 1, 2):
    sides, matches = load(run)
    data[run] = ({k: side_outcome(r) for k, r in sides.items()}, matches)
out, matches = data[1]
ks = sorted(out)
for name, q, f in [("W3", 3, lambda o: o['peak'] / 1000), ("W2+", 2, lambda o: o['peak'] / 1000), ("W1+", 1, lambda o: o['peak'] / 1000), ("W3 by impulse", 3, lambda o: o['imp'])]:
    xs = [f(out[k]) for k in ks]; ys = [int(matches[k]['class']) >= q for k in ks]
    ll, mu, b = fit(xs, ys)
    print(f"{name}: median {math.exp(mu):.1f} {'kPa' if 'impulse' not in name else 'Pa s'}, beta {b:.2f}, loglik {ll:.0f}")
    if name == "W3": W3 = (mu, b)
    if name == "W1+": W1 = (mu, b)
print()
print("W3 by band from the peak fragility (fitted on 0.5 kt), each run's loads, against GEER:")
print("band       0.2kt 0.5kt 1.1kt | GEER W3 | W1+ fitted 0.5kt | GEER W1+")
for a, b in zip(bands, bands[1:]):
    row = []
    for run in (0, 1, 2):
        o, m = data[run]
        S = [k for k in o if a <= float(m[k]['distance']) < b]
        if not S: row.append(float('nan')); continue
        row.append(sum(Phi((math.log(o[k]['peak'] / 1000) - W3[0]) / W3[1]) for k in S) / len(S))
    o, m = data[1]; S = [k for k in o if a <= float(m[k]['distance']) < b]
    if not S: continue
    g3 = sum(int(m[k]['class']) >= 3 for k in S) / len(S); g1 = sum(int(m[k]['class']) >= 1 for k in S) / len(S)
    w1 = sum(Phi((math.log(o[k]['peak'] / 1000) - W1[0]) / W1[1]) for k in S) / len(S)
    print(f"{a}-{b}  " + " ".join(f"{x:.2f}" for x in row) + f" | {g3:.2f} | {w1:.2f} | {g1:.2f}  (n {len(S)})")
