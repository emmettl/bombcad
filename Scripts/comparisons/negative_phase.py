"""The air solver's negative phase against UFC 3-340-02 Figure 2-16 (hemispherical surface burst).

    python3 negative_phase.py HISTORIES [MASS_KG]

HISTORIES holds the gauge histories `blastbench validate --histories DIR --until 0.25` writes
(time in ms, overpressure in Pa, one file per gauge, named by its scaled distance in m/kg^(1/3)).
For each gauge: the positive phase ends where the pressure first falls below ambient after its
peak; the negative phase runs from there until it rises back above ambient for good (a rise
shorter than 5 ms, the second shock close in, does not end it; if the record ends first, that is
reported); its depth, duration and impulse (the integral of the underpressure) are set
beside the chart's at the same scaled distance, interpolated in log–log from
Fixtures/UFC-3-340-02/negative-phase.json.
"""
import glob
import json
import os
import re
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
FIXTURE = os.path.join(HERE, "..", "..", "Fixtures", "UFC-3-340-02", "negative-phase.json")
PSI = 6894.757
M_PER_FT = 0.3048
KG_PER_LB = 0.45359237


def chart(curve, z_ft):
    data = np.array(curve["sampled"])
    if not data[0, 0] <= z_ft <= data[-1, 0]:
        return None
    return float(10 ** np.interp(np.log10(z_ft), np.log10(data[:, 0]), np.log10(data[:, 1])))


def negative_phase(t_ms, p_pa, blip_ms=5.0):
    peak = int(np.argmax(p_pa))
    below = np.nonzero(p_pa[peak:] < 0)[0]
    if not len(below):
        return None
    start = peak + below[0]
    # A rise above ambient shorter than `blip_ms` (the second shock, close in) does not end it.
    end, i, closed = len(p_pa) - 1, start, False
    while i < len(p_pa):
        above = np.nonzero(p_pa[i:] >= 0)[0]
        if not len(above):
            break
        rise = i + above[0]
        after = np.nonzero(p_pa[rise:] < 0)[0]
        if len(after) and t_ms[rise + after[0]] - t_ms[rise] < blip_ms:
            i = rise + after[0]
            continue
        end, closed = rise, True
        break
    seg_t, seg_p = t_ms[start : end + 1], p_pa[start : end + 1]
    impulse = -np.trapezoid(np.minimum(seg_p, 0), seg_t) / 1000  # Pa s
    return {
        "start_ms": float(t_ms[start]), "end_ms": float(t_ms[end]), "closed": closed,
        "depth_kpa": float(-seg_p.min() / 1000), "duration_ms": float(t_ms[end] - t_ms[start]),
        "impulse_pa_s": float(impulse), "positive_impulse_pa_s": float(np.trapezoid(np.maximum(p_pa[: start + 1], 0), t_ms[: start + 1]) / 1000),
    }


def main(directory, mass_kg=100.0):
    w_lb = mass_kg / KG_PER_LB
    cube = w_lb ** (1 / 3)
    ft_per_scaled_m = (1 / M_PER_FT) / (1 / KG_PER_LB) ** (1 / 3)  # (m/kg^1/3) -> (ft/lb^1/3)
    figure = json.load(open(FIXTURE))["figures"]["UFC Fig 2-16 (hemispherical, on the surface)"]["curves"]
    rows = []
    for path in sorted(glob.glob(os.path.join(directory, "validate-*-Z=*.csv"))):
        z = float(re.search(r"Z=(\d+\.\d+)", path).group(1))
        dx = re.search(r"dx([\d.]+)", path).group(1)
        d = np.loadtxt(path, delimiter=",", skiprows=1)
        phase = negative_phase(d[:, 0], d[:, 1])
        if phase is None:
            continue
        z_ft = z * ft_per_scaled_m
        ref = {
            "depth_kpa": (chart(figure["Ps"], z_ft) or np.nan) * PSI / 1000,
            "duration_ms": (chart(figure["t0"], z_ft) or np.nan) * cube,
            "impulse_pa_s": (chart(figure["is"], z_ft) or np.nan) * cube * PSI / 1000,
        }
        rows.append({"Z_m": z, "Z_ft": round(z_ft, 3), "dx": dx, "model": phase, "chart": ref})
    print(f"{mass_kg:g} kg on the ground; UFC Fig 2-16 at the same scaled distance (model / chart)")
    print("   Z      dx   underpressure kPa       duration ms             impulse Pa s        closed")
    for r in rows:
        m, c = r["model"], r["chart"]
        cells = []
        for key in ("depth_kpa", "duration_ms", "impulse_pa_s"):
            ratio = m[key] / c[key] if c[key] and np.isfinite(c[key]) else np.nan
            cells.append(f"{m[key]:7.2f} / {c[key]:7.2f} ({100 * ratio:4.0f}%)")
        print(f"{r['Z_m']:5.2f}  {r['dx']:>5}  " + "  ".join(cells) + f"   {m['closed']}")
    return rows


if __name__ == "__main__":
    rows = main(sys.argv[1], float(sys.argv[2]) if len(sys.argv) > 2 else 100.0)
    if len(sys.argv) > 3:
        json.dump(rows, open(sys.argv[3], "w"), indent=1)
