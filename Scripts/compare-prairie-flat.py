#!/usr/bin/env python3
"""Compares `blastbench groundmotion`'s Prairie Flat run with Murrell's gauges (Fixtures/PrairieFlat).

    blastbench groundmotion --mass 453592 --dx 4 --ranges 25.6,42.67,67.06,100.58,121.92,170.69,252.98,350.52 \\
        --depths 0.457,1.524,3.048,5.182,9.144 --density 1600 --speed 387 --water-table 7.0 \\
        --saturated-speed 1859 --saturated-density 1950 --friction 30,35 --half-cell 0.5 --frame 1e-3 --out out/
    python3 Scripts/compare-prairie-flat.py out/groundmotion-dx4.000.json [--feed air|kb]

Inside the outrunning limit (84 to 400 ft) each model's peak downward velocity at each vertical
record's range and depth (velocity gauges, UV, and the accelerometers' integrals, AV) is set
against the record, and its arrival against the earliest arrival Murrell gives at that place; past
it (560 to 1,150 ft), where no arrivals were read, the peaks downward and outward against the
accelerometers' integrals. See docs/ground-shock.md#against-prairie-flat.
"""

import argparse
import json
import math
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUTRUNNING_FT = 560


def number(v):
    return v if isinstance(v, (int, float)) else None


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("run")
    parser.add_argument("--feed", choices=["air", "kb"], default="air")
    arguments = parser.parse_args()
    measured = json.load(open(os.path.join(ROOT, "Fixtures/PrairieFlat/ground-motion.json")))
    report = json.load(open(arguments.run))
    run = report["runs"][0]
    models = run["model" if arguments.feed == "air" else "kingery_bulmash"]

    def response(points, range_m, depth_m):
        point = min(points, key=lambda p: abs(p["range_m"] - range_m))
        if abs(point["range_m"] - range_m) > 1:
            return point, None
        r = min(point["responses"], key=lambda r: abs(r["depth_m"] - depth_m))
        return point, r if abs(r["depth_m"] - depth_m) < 0.05 else None

    gauges = measured["gauges"]
    # The earliest arrival read at each place, as Murrell built his shock front from.
    first = {}
    for g in gauges:
        a = number(g["arrival"])
        if a is not None and g.get("arrivalNote") != "c":
            key = (g["rangeFt"], g["depthFt"])
            first[key] = min(first.get(key, a), a)

    print(f"Fed by {'the air model' if arguments.feed == 'air' else 'Kingery–Bulmash'}; ratios are model / measured.")
    # The regime at each range, by the first model's points.
    name0 = next(iter(models))
    c1, h = report["wave_speed"], report.get("water_table_m", -1)
    c2 = report.get("saturated_speed", 0)
    print("\nAt the ground:")
    for p in models[name0]:
        r = p["range_m"]
        # The ground's own first arrival: the direct wave, or the head wave along the saturated soil.
        ground = p.get("ground_arrival_s")
        if ground is None:
            ground = r / c1
            if h > 0 and c2 > c1:
                ground = min(ground, r / c2 + 2 * h * math.sqrt(1 / c1**2 - 1 / c2**2))
        air = p.get("arrival_s")
        order = "the ground's wave first" if air and ground < air else "the air first"
        print(f"  {r / 0.3048:6.0f} ft: {p['peak_pa'] / 6894.76:6.1f} psi, arrives {1000 * (air or -1):6.1f} ms, "
              f"front {p['front_speed']:4.0f} m/s, {p['regime']}; the ground's wave at {1000 * ground:.1f} ms, {order}")

    for name, points in models.items():
        within_two, total, arrivals_ok, arrivals = 0, 0, 0, 0
        lines, beyond = [], []
        for g in gauges:
            point, r = response(points, g["range"], g["depth"])
            if r is None:
                continue
            down = number(g["velocityDown"])
            if g["gauge"] in ("UV", "AV") and g["rangeFt"] < OUTRUNNING_FT and down:
                ratio = r["velocity"] / down
                total += 1
                within_two += 0.5 <= ratio <= 2
                lines.append(f"    {g['rangeFt']:5} ft {g['depthFt']:4} ft {g['gauge']}: {r['velocity']:7.3f} / {down:7.3f} m/s = {ratio:5.2f}")
            if g["rangeFt"] >= OUTRUNNING_FT and g["gauge"] in ("AV", "AH"):
                if g["gauge"] == "AV" and down:
                    beyond.append(("down", g, r["velocity"], down))
                up = number(g["velocityUp"])
                if g["gauge"] == "AH" and up and r.get("horizontal") is not None:
                    beyond.append(("outward", g, r["horizontal"], up))
        for (rng, depth), a in sorted(first.items()):
            if rng >= OUTRUNNING_FT:
                continue
            point, r = response(points, rng * 0.3048, depth * 0.3048)
            if r is None or r.get("arrival_s") is None:
                continue
            arrivals += 1
            arrivals_ok += abs(r["arrival_s"] / a - 1) <= 0.1
            lines.append(f"    {rng:5} ft {depth:4} ft arrival: {1000 * r['arrival_s']:6.1f} / {1000 * a:6.1f} ms = {r['arrival_s'] / a:5.2f}")
        print(f"\n{name}: vertical within 2x at {within_two} of {total} records inside {OUTRUNNING_FT} ft"
              f" ({within_two / max(total, 1):.0%}); arrivals within 10% at {arrivals_ok} of {arrivals}")
        for line in lines:
            print(line)
        if beyond:
            logs = [math.log(m / s) for _, _, m, s in beyond if m > 0]
            within_three = sum(1 for _, _, m, s in beyond if 1 / 3 <= m / s <= 3)
            print(f"  beyond {OUTRUNNING_FT} ft: within 3x at {within_three} of {len(beyond)}; geometric mean ratio "
                  f"{math.exp(sum(logs) / len(logs)):.2f}" if logs else "")
            for kind, g, m, s in beyond:
                print(f"    {g['rangeFt']:5} ft {g['depthFt']:4} ft {kind:7}: {m:7.4f} / {s:7.4f} m/s = {m / s:5.2f}")


if __name__ == "__main__":
    main()
