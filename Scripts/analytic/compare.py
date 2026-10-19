"""BombCAD's air solver against the exact Sod and Sedov–Taylor solutions.

The solver's profile is a CSV file: a header row naming the columns, then one row per cell.
The position column is `x` (Sod, along the tube) or `r` (Sedov, along a ray from the charge);
`rho` is required and `u` and `p` are used when present. Lines starting with `#` are ignored.

    python3 Scripts/analytic/compare.py sod profile.csv --time 0.2 [--x0 0.5] [--gamma 1.4]
    python3 Scripts/analytic/compare.py sedov profile.csv --time T --energy E [--rho0 1]
                                        [--j 3] [--gamma 1.4] [--ambient-pressure 0]
    python3 Scripts/analytic/compare.py --self-test

Sod's problem is Toro's test 1 (left 1, 0, 1; right 0.125, 0, 0.1) unless --left/--right give
other states as rho,u,p. Both print the mean (L1) errors over the cells, the waves' positions
against the exact ones in cells, and the same scores for a textbook second-order scheme on the
same grid (Scripts/analytic/godunov.py) to read them against. For Sedov the energy is the
whole blast's (the full sphere's, not an octant's), and the profile's energy is summed only
when it runs from the centre with u and p, assuming spherical (or cylindrical, planar) symmetry.
"""

import argparse
import csv
import math
import os
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import godunov  # noqa: E402
import riemann  # noqa: E402
import sedov as sedov_solution  # noqa: E402


def read_profile(path):
    """Columns from a profile CSV, as a dict of lists of floats."""
    with open(path, newline="") as f:
        rows = [line for line in f if line.strip() and not line.lstrip().startswith("#")]
    reader = csv.DictReader(rows)
    cols = {name.strip(): [] for name in reader.fieldnames}
    for row in reader:
        for k, v in row.items():
            cols[k.strip()].append(float(v))
    return cols


def write_profile(path, cols):
    names = list(cols)
    with open(path, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(names)
        for i in range(len(cols[names[0]])):
            w.writerow([repr(cols[n][i]) for n in names])


def crossing(xs, values, level, from_right=True):
    """Position where values cross level, interpolated, scanning from the right (or left)."""
    idx = range(len(xs) - 1, 0, -1) if from_right else range(1, len(xs))
    for i in idx:
        a, b = (i - 1, i)
        va, vb = values[a], values[b]
        if (va - level) * (vb - level) <= 0 and va != vb:
            return xs[a] + (level - va) / (vb - va) * (xs[b] - xs[a])
    return None


def front_radius(rs, rhos, threshold=2.0):
    """Outermost cell centre whose density exceeds threshold (the Swift Sedov test's rule)."""
    front = None
    for r, rho in zip(rs, rhos):
        if rho > threshold:
            front = r
    return front


# Sod ------------------------------------------------------------------------------------------


def sod_scores(cols, sol, t, x0):
    xs, rho = cols["x"], cols["rho"]
    n = len(xs)
    exact = sol.profile(xs, t, x0)
    out = {"cells": n, "L1 rho": sum(abs(rho[i] - exact[i].rho) for i in range(n)) / n}
    if "u" in cols:
        out["L1 u"] = sum(abs(cols["u"][i] - exact[i].u) for i in range(n)) / n
    if "p" in cols:
        out["L1 p"] = sum(abs(cols["p"][i] - exact[i].p) for i in range(n)) / n
    dx = (xs[-1] - xs[0]) / (n - 1)
    speeds = sol.wave_speeds()
    R = sol.right
    if "right_shock" in speeds:
        level = 0.5 * (sol.rho_star_right + R.rho)
        at = crossing(xs, rho, level, from_right=True)
        out["shock (cells)"] = None if at is None else (at - (x0 + speeds["right_shock"] * t)) / dx
    level = 0.5 * (sol.rho_star_left + sol.rho_star_right)
    # The contact is the crossing nearest its exact position.
    exact_contact = x0 + speeds["contact"] * t
    near = [i for i in range(n) if abs(xs[i] - exact_contact) < 0.1 * (xs[-1] - xs[0])]
    if near:
        sub_x = [xs[i] for i in near]
        sub_r = [rho[i] for i in near]
        at = crossing(sub_x, sub_r, level, from_right=True)
        out["contact (cells)"] = None if at is None else (at - exact_contact) / dx
    return out


def sod_yardstick(xs, sol, t, x0, gamma):
    dx = (xs[-1] - xs[0]) / (len(xs) - 1)
    L, R = sol.left, sol.right
    rho = [L.rho if x < x0 else R.rho for x in xs]
    u = [L.u if x < x0 else R.u for x in xs]
    p = [L.p if x < x0 else R.p for x in xs]
    r, v, pp = godunov.run(rho, u, p, dx, t, gamma=gamma, j=1)
    return sod_scores({"x": xs, "rho": r, "u": v, "p": pp}, sol, t, x0)


# Sedov ----------------------------------------------------------------------------------------


def sedov_scores(cols, s, E, rho0, t, p_amb=0.0):
    rs, rho = cols["r"], cols["rho"]
    n = len(rs)
    r2, _, _, rho2, _ = s.shock_state(E, rho0, t)
    dx = (rs[-1] - rs[0]) / (n - 1)
    inside = [i for i in range(n) if rs[i] <= 1.2 * r2]
    exact = {i: s.profile(rs[i], E, rho0, t) for i in inside}
    out = {"cells": n, "exact r2": r2}
    out["L1 rho / rho0 (r < 1.2 r2)"] = sum(abs(rho[i] - exact[i][1]) for i in inside) / len(inside) / rho0
    front = front_radius(rs, rho, 2.0 * rho0)
    out["front, rho > 2 rho0 (cells)"] = None if front is None else (front - r2) / dx
    out["front / r2"] = None if front is None else front / r2
    peak = max(range(n), key=lambda i: rho[i])
    out["peak rho / (6 rho0 at gamma 1.4: rho2)"] = rho[peak] / rho2
    out["peak at / r2"] = rs[peak] / r2
    if "u" in cols and "p" in cols and rs[0] < 1.01 * dx:
        g, j = s.gamma, s.j
        total = 0.0
        for i in range(n):
            lo, hi = max(rs[i] - 0.5 * dx, 0.0), rs[i] + 0.5 * dx
            vol = sedov_solution.AREA[j] * (hi**j - lo**j) / j
            total += vol * (0.5 * rho[i] * cols["u"][i] ** 2 + (cols["p"][i] - p_amb) / (g - 1))
        out["energy / E"] = total / E
    return out


def sedov_yardstick(rs, s, E, rho0, t, p_amb):
    """The textbook scheme from a hot core of 3.5 cells, the Swift test's source size."""
    n = len(rs)
    dx = (rs[-1] - rs[0]) / (n - 1)
    j, g = s.j, s.gamma
    core = [i for i in range(n) if rs[i] < 3.5 * dx]
    vol = sedov_solution.AREA[j] * ((len(core) * dx) ** j) / j
    p_core = (g - 1) * E / vol
    rho = [rho0] * n
    p = [p_core if i in core else max(p_amb, 1e-9 * p_core) for i in range(n)]
    r, v, pp = godunov.run(rho, [0.0] * n, p, dx, t, gamma=g, j=j)
    return sedov_scores({"r": rs, "rho": r, "u": v, "p": pp}, s, E, rho0, t, p_amb)


# Output ---------------------------------------------------------------------------------------


def show(title, scores, yardstick=None):
    print(title)
    width = max(len(k) for k in scores)
    print(f"  {'':<{width}}  {'BombCAD':>10}" + (f"  {'MUSCL-HLLC':>10}" if yardstick else ""))
    for k, v in scores.items():
        line = f"  {k:<{width}}  {fmt(v):>10}"
        if yardstick:
            line += f"  {fmt(yardstick.get(k)):>10}"
        print(line)


def fmt(v):
    if v is None:
        return "-"
    if isinstance(v, int):
        return str(v)
    return f"{v:.4g}"


def parse_state(text):
    rho, u, p = (float(v) for v in text.split(","))
    return riemann.State(rho, u, p)


# Self-test ------------------------------------------------------------------------------------


def cell_average_sod(sol, n, t, x0=0.5, sub=16):
    """Exact cell averages of Sod's density on n cells of a unit tube: the best any scheme does."""
    xs = [(i + 0.5) / n for i in range(n)]
    rho = []
    for x in xs:
        pts = [x + ((k + 0.5) / sub - 0.5) / n for k in range(sub)]
        rho.append(sum(st.rho for st in sol.profile(pts, t, x0)) / sub)
    return xs, rho


def self_test():
    failures = []

    def check(cond, what):
        print(("  ok    " if cond else "  FAIL  ") + what)
        if not cond:
            failures.append(what)

    sol = riemann.solve(*riemann.SOD, gamma=riemann.SOD_GAMMA)
    with tempfile.TemporaryDirectory() as folder:
        # The exact cell averages, written and read back as a solver's profile would be.
        xs, rho = cell_average_sod(sol, 400, 0.2)
        path = os.path.join(folder, "sod.csv")
        write_profile(path, {"x": xs, "rho": rho})
        got = sod_scores(read_profile(path), sol, 0.2, 0.5)
        check(got["L1 rho"] < 2e-4, f"exact cell averages score L1 {got['L1 rho']:.2e} < 2e-4")
        check(abs(got["shock (cells)"]) < 0.5, f"and put the shock {got['shock (cells)']:+.2f} cells off")
        # A profile whose shock runs five cells ahead is caught.
        shifted = cell_average_sod(sol, 400, 0.2 + 5 / 400 / 1.75216)[1]
        moved = sod_scores({"x": xs, "rho": shifted}, sol, 0.2, 0.5)
        check(4 < moved["shock (cells)"] < 6, f"a shock five cells ahead reads {moved['shock (cells)']:+.2f}")
        # The yardstick scheme scores what a second-order scheme should on 200 cells.
        xs2 = [(i + 0.5) / 200 for i in range(200)]
        yard = sod_yardstick(xs2, sol, 0.2, 0.5, 1.4)
        check(0.001 < yard["L1 rho"] < 0.006, f"MUSCL-HLLC on 200 cells scores L1 {yard['L1 rho']:.4f}")
        check(abs(yard["shock (cells)"]) < 1.5, f"and its shock is {yard['shock (cells)']:+.2f} cells off")

        # Sedov: the exact profile sampled along a ray, read back.
        s = sedov_solution.Sedov(1.4, 3)
        E, rho0 = 1.0, 1.0
        t = s.time_at_radius(0.6, E, rho0)
        rs = [(i + 0.5) / 400 for i in range(400)]
        prof = [s.profile(r, E, rho0, t) for r in rs]
        path = os.path.join(folder, "sedov.csv")
        write_profile(path, {"r": rs, "u": [q[0] for q in prof], "rho": [q[1] for q in prof],
                             "p": [q[2] for q in prof]})
        got = sedov_scores(read_profile(path), s, E, rho0, t)
        check(abs(got["front / r2"] - 1) < 2 / 400 / 0.6,
              f"the exact Sedov profile's front is at {got['front / r2']:.4f} r2")
        check(abs(got["energy / E"] - 1) < 0.02, f"and holds {got['energy / E']:.4f} of the energy")
        yard = sedov_yardstick([(i + 0.5) / 100 for i in range(100)], s, E, rho0, t, 0.0)
        check(abs(yard["front / r2"] - 1) < 0.05, f"MUSCL-HLLC on 100 cells: front at {yard['front / r2']:.3f} r2")
        check(abs(yard["energy / E"] - 1) < 0.01, f"and keeps {yard['energy / E']:.4f} of the energy")
    print("self-test " + ("passed" if not failures else f"FAILED ({len(failures)})"))
    return 0 if not failures else 1


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("problem", nargs="?", choices=["sod", "sedov"])
    ap.add_argument("profile", nargs="?")
    ap.add_argument("--self-test", action="store_true")
    ap.add_argument("--time", type=float)
    ap.add_argument("--gamma", type=float, default=1.4)
    ap.add_argument("--x0", type=float, default=0.5, help="Sod: the diaphragm's position")
    ap.add_argument("--left", type=parse_state, help="Sod: rho,u,p on the left")
    ap.add_argument("--right", type=parse_state, help="Sod: rho,u,p on the right")
    ap.add_argument("--energy", type=float, help="Sedov: the whole blast's energy")
    ap.add_argument("--rho0", type=float, default=1.0)
    ap.add_argument("--j", type=int, default=3, help="Sedov: 1 planar, 2 cylindrical, 3 spherical")
    ap.add_argument("--ambient-pressure", type=float, default=0.0)
    ap.add_argument("--no-yardstick", action="store_true", help="skip the textbook scheme's run")
    args = ap.parse_args(argv)
    if args.self_test:
        return self_test()
    if not args.problem or not args.profile or args.time is None:
        ap.error("give a problem, a profile and --time, or --self-test")
    cols = read_profile(args.profile)
    if args.problem == "sod":
        left, right = riemann.SOD
        sol = riemann.solve(args.left or left, args.right or right, gamma=args.gamma)
        scores = sod_scores(cols, sol, args.time, args.x0)
        yard = None if args.no_yardstick else sod_yardstick(cols["x"], sol, args.time, args.x0, args.gamma)
        show(f"Sod at t = {args.time}, p* {sol.p_star:.5f}, u* {sol.u_star:.5f}", scores, yard)
    else:
        if args.energy is None:
            ap.error("sedov needs --energy")
        s = sedov_solution.Sedov(args.gamma, args.j)
        scores = sedov_scores(cols, s, args.energy, args.rho0, args.time, args.ambient_pressure)
        yard = None if args.no_yardstick else sedov_yardstick(
            cols["r"], s, args.energy, args.rho0, args.time, args.ambient_pressure)
        show(f"Sedov (j = {args.j}, gamma {args.gamma}, alpha {s.alpha:.5f}) at t = {args.time}", scores, yard)
    return 0


if __name__ == "__main__":
    sys.exit(main())
