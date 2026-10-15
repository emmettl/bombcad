"""From the marker candidates (trace.py), pick one pressure a millisecond by the smoothest path,
leaving out markers on the curve's own impulse line (the impulse of the picked path, re-found
twice), then check the path's impulse against the impulse markers' last values."""
import sys, json
raw = json.load(open(sys.argv[1])); pmax, imax, tend = float(sys.argv[2]), float(sys.argv[3]), int(sys.argv[4])
nmins = json.loads(sys.argv[5])
out = {}
for name, pts in raw.items():
    nmin = nmins[name]
    cand = {}
    for t, p, i, n in pts:
        j = round(t)
        if abs(t - j) < 0.3 and 1 <= j <= tend: cand.setdefault(j, []).append((p, n))
    imp_line = None
    for it in range(3):
        best = {0: (0.0, [])}
        prev = None
        path = []
        last = None
        for j in range(1, tend + 1):
            cs = cand.get(j, [])
            if imp_line is not None:
                cs = [(p, n) for p, n in cs if abs(p - imp_line[j]) > 0.8]
            cs = [(p, n) for p, n in cs if n >= nmin]
            if last is not None and j > 8:
                cs = [(p, n) for p, n in cs if -12 <= p - last <= 3]
            if not cs: path.append(None); continue
            if last is None:
                p = max(cs, key=lambda c: c[1])[0]
            else:
                p = min(cs, key=lambda c: abs(c[0] - last) - 0.15 * min(c[1], 15))[0]
            path.append(p); last = p
        # fill gaps linearly
        vals = path[:]
        idx = [k for k, v in enumerate(vals) if v is not None]
        for k in range(len(vals)):
            if vals[k] is None:
                a = max([q for q in idx if q < k], default=None); b = min([q for q in idx if q > k], default=None)
                if a is None: vals[k] = vals[b]
                elif b is None: vals[k] = vals[a]
                else: vals[k] = vals[a] + (vals[b] - vals[a]) * (k - a) / (b - a)
        # impulse in psi-ms (trapezoid from 0 at t=0 with p(0) taken as p(1))
        I = [0.0]; pp = [vals[0]] + vals
        for k in range(1, len(pp)): I.append(I[-1] + 0.5 * (pp[k - 1] + pp[k]))
        imp_line = {j: I[j] / imax * pmax for j in range(len(I))}
    out[name] = {"t_ms": list(range(1, tend + 1)), "p_psi": [round(v, 2) for v in vals],
                 "gaps": [j + 1 for j, v in enumerate(path) if v is None], "impulse_psi_ms": round(I[-1], 1)}
print(json.dumps(out))
