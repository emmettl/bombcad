import math, collections, sys
from gtrace import load, side_outcome
run = int(sys.argv[1]) if len(sys.argv) > 1 else 1
sides, matches = load(run)
out = {k: side_outcome(rows) for k, rows in sides.items()}
ks = sorted(out)
print("GEER class shares by the side's peak net load in the run (kPa):")
edges = [0, 1, 2, 3, 5, 7, 10, 15, 20, 30, 50, 1e9]
print(" peak kPa        n   W0   W1   W2   W3 | model frac  some")
for a, b in zip(edges, edges[1:]):
    S = [k for k in ks if a <= out[k]['peak'] / 1000 < b]
    if len(S) < 20: continue
    c = collections.Counter(int(matches[k]['class']) for k in S); n = len(S)
    fr = sum(out[k]['frac'] for k in S) / n; so = sum(out[k]['some'] for k in S) / n
    print(f" {a:4}-{b if b<1e8 else 'inf':<5} {n:6} " + " ".join(f"{c[i]/n:.2f}" for i in range(4)) + f" | {fr:.2f}  {so:.2f}")
print()
print("by impulse (Pa s):")
edges = [0, 25, 50, 75, 100, 150, 200, 300, 500, 1e9]
for a, b in zip(edges, edges[1:]):
    S = [k for k in ks if a <= out[k]['imp'] < b]
    if len(S) < 20: continue
    c = collections.Counter(int(matches[k]['class']) for k in S); n = len(S)
    fr = sum(out[k]['frac'] for k in S) / n
    print(f" {a:4}-{b if b<1e8 else 'inf':<5} {n:6} " + " ".join(f"{c[i]/n:.2f}" for i in range(4)) + f" | {fr:.2f}")
