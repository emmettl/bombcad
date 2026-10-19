"""The reflected pressure coefficient of an ideal-gas shock striking a rigid plane at an angle.

    python3 Scripts/reference/oblique.py [incident overpressure kPa ...]

prints C_r = (peak reflected overpressure) / (peak incident overpressure) against the angle of
incidence alpha (0 head-on, 90 grazing), the quantity UFC 3-340-02 (2008) charts in Figure 2-193
for TNT.

Below the angle at which regular reflection ceases (the detachment criterion) the coefficient is
von Neumann's two-shock theory for an ideal gas, gamma = 1.4: in the frame of the point where the
incident shock meets the surface, air arrives along the surface at M1 = M_s / sin(alpha), is turned
towards the surface by the incident shock, and is turned back parallel to it by the reflected one
(weak solution); Liepmann and Roshko, *Elements of Gasdynamics* (1957), §4.11–4.13, and Ben-Dor,
*Shock Wave Reflection Phenomena* (2nd ed., 2007), chapter 1. At alpha = 0 it is the normal
reflection of the Rankine–Hugoniot relations, C_r = 2 (7 p0 + 4 p_s) / (7 p0 + p_s).

Beyond detachment the reflection is a Mach reflection, which two-shock theory does not describe.
There the coefficient is taken to fall linearly in angle from its value at detachment to 1 at
grazing incidence. That is an approximation of the trend UFC's chart shows, not a theory of the
Mach stem, and it omits the rise just past the critical angle that UFC's chart has for strong
shocks; docs/reference-calculations.md compares both regions with UFC 3-340-02's Figure 2-9.

Being ideal-gas theory, it does not hold for strong shocks close in, where real air's dissociation
raises the head-on coefficient above the ideal gas's limit of 8 (Kingery–Bulmash's reflected
pressure exceeds it within about 1 m/kg^(1/3)).
"""

import json
import math
import os
import sys

GAMMA = 1.4


def _deflection(mach, beta, g=GAMMA):
    """Flow deflection through an oblique shock at angle beta to a flow of Mach number mach."""
    m2 = mach * mach
    s2 = math.sin(beta) ** 2
    num = 2.0 / math.tan(beta) * (m2 * s2 - 1.0)
    den = m2 * (g + math.cos(2.0 * beta)) + 2.0
    return math.atan(num / den)


def _pressure_ratio(mn, g=GAMMA):
    return 1.0 + 2.0 * g / (g + 1.0) * (mn * mn - 1.0)


def _downstream_mach(mach, beta, g=GAMMA):
    mn1 = mach * math.sin(beta)
    mn2 = math.sqrt((1.0 + 0.5 * (g - 1.0) * mn1 * mn1) / (g * mn1 * mn1 - 0.5 * (g - 1.0)))
    return mn2 / math.sin(beta - _deflection(mach, beta, g))


def _max_deflection(mach, g=GAMMA):
    """The largest deflection an attached oblique shock can give, and its shock angle."""
    lo, hi = math.asin(1.0 / mach), 0.5 * math.pi
    for _ in range(200):  # golden-section search on a unimodal function
        a = hi - 0.618033988749895 * (hi - lo)
        b = lo + 0.618033988749895 * (hi - lo)
        if _deflection(mach, a, g) < _deflection(mach, b, g):
            lo = a
        else:
            hi = b
    beta = 0.5 * (lo + hi)
    return _deflection(mach, beta, g), beta


def normal_coefficient(ratio, g=GAMMA):
    """Head-on reflection, C_r for an incident overpressure of `ratio` times ambient."""
    # Rankine–Hugoniot for any gamma: p_r / p_s overpressures.
    return 2.0 + (g + 1.0) * ratio / ((g - 1.0) * ratio + 2.0 * g)


def regular(ratio, alpha, g=GAMMA):
    """Two-shock theory's C_r at angle of incidence alpha (radians), or None where regular
    reflection is impossible (beyond detachment)."""
    if alpha <= 1e-9:
        return normal_coefficient(ratio, g)
    if alpha >= 0.5 * math.pi:
        return 1.0
    ms = math.sqrt(1.0 + (g + 1.0) / (2.0 * g) * ratio)
    m1 = ms / math.sin(alpha)
    theta = _deflection(m1, alpha, g)
    p21 = _pressure_ratio(ms, g)
    m2 = _downstream_mach(m1, alpha, g)
    if m2 <= 1.0:
        return None
    theta_max, beta_max = _max_deflection(m2, g)
    if theta > theta_max:
        return None
    lo, hi = math.asin(1.0 / m2), beta_max  # weak branch: deflection rises with beta here
    for _ in range(200):
        mid = 0.5 * (lo + hi)
        if _deflection(m2, mid, g) < theta:
            lo = mid
        else:
            hi = mid
    beta2 = 0.5 * (lo + hi)
    p32 = _pressure_ratio(m2 * math.sin(beta2), g)
    return (p32 * p21 - 1.0) / ratio


def detachment_angle(ratio, g=GAMMA):
    """The largest angle of incidence (radians) at which regular reflection exists."""
    lo, hi = 0.0, 0.5 * math.pi - 1e-9
    if regular(ratio, hi, g) is not None:
        return hi
    for _ in range(60):
        mid = 0.5 * (lo + hi)
        if regular(ratio, mid, g) is None:
            hi = mid
        else:
            lo = mid
    return lo


def coefficient(ratio, alpha, g=GAMMA):
    """C_r at angle of incidence alpha (radians) for an incident overpressure `ratio` times ambient:
    two-shock theory to detachment, then linear in angle to 1 at grazing incidence."""
    c = regular(ratio, alpha, g)
    if c is not None:
        return c
    a_d = detachment_angle(ratio, g)
    c_d = regular(ratio, a_d, g)
    f = (alpha - a_d) / (0.5 * math.pi - a_d)
    return c_d + (1.0 - c_d) * f


FIGURE_2_9 = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "Fixtures",
                          "UFC-3-340-02", "oblique-reflection.json")
PSI = 6894.757
FT_LB = 0.3048 / 0.45359237 ** (1.0 / 3.0)  # 1 ft/lb^(1/3) in m/kg^(1/3), 0.3967
_UFC = None


def _ufc_curves():
    """UFC 3-340-02's Figure 2-9 (digitised in the fixture) turned back into C_r: at each scaled
    normal distance H and angle alpha, its P_r,alpha over Kingery–Bulmash's free-air incident
    pressure at the slant range H / cos(alpha). Each curve gives (alpha, p_s, C_r) points."""
    global _UFC
    if _UFC is None:
        import numpy as np
        import kingery_bulmash as kb
        with open(FIGURE_2_9) as f:
            curves = json.load(f)["figures"]["UFC Fig 2-9"]["curves"]
        _UFC = []
        for label, points in curves.items():
            rows = []
            for deg, pr_psi in points:
                if deg > 80:  # the curves' last points sit on the axis, unreadable as ratios
                    continue
                z = float(label) * FT_LB / math.cos(math.radians(deg))
                ps = float(kb.free_air(np.array([z]))["incident_pressure"][0])
                if not math.isnan(ps):
                    rows.append((math.radians(deg), ps, pr_psi * PSI / ps))
            _UFC.append(rows)
    return _UFC


def ufc_coefficient(pressure, alpha):
    """C_r as UFC 3-340-02 implies it, for an incident overpressure `pressure` (Pa) at angle of
    incidence alpha (radians, 0 to 80 degrees), read from its Figure 2-9 and Kingery–Bulmash
    (`_ufc_curves`), interpolated in alpha along each curve and in log pressure across them; NaN
    outside the curves' pressures. This stands in for Figure 2-193, which the cloud session that
    wrote it did not have."""
    samples = []
    for rows in _ufc_curves():
        for (a0, p0_, c0), (a1, p1, c1) in zip(rows, rows[1:]):
            if a0 <= alpha <= a1:
                f = (alpha - a0) / (a1 - a0) if a1 > a0 else 0.0
                samples.append((math.log(p0_) + f * (math.log(p1) - math.log(p0_)), c0 + f * (c1 - c0)))
                break
    samples.sort()
    x = math.log(pressure)
    for (x0, c0), (x1, c1) in zip(samples, samples[1:]):
        if x0 <= x <= x1:
            return c0 + (x - x0) / (x1 - x0) * (c1 - c0)
    return float("nan")


def main(argv):
    p0 = 101.325
    pressures = [float(a) for a in argv] or [1, 10, 50, 100, 300, 1000, 3000]
    print("C_r against angle of incidence (deg), ideal gas gamma 1.4; * past detachment")
    print("    deg " + "".join(f"{p:>9.4g}" for p in pressures) + "   (incident overpressure, kPa)")
    for deg in range(0, 91, 5):
        row = []
        for p in pressures:
            ratio = p / p0
            c = coefficient(ratio, math.radians(deg))
            mark = "*" if regular(ratio, math.radians(deg)) is None else " "
            row.append(f"{c:>8.3f}{mark}")
        print(f"{deg:>7} " + "".join(row))
    print("detach " + "".join(f"{math.degrees(detachment_angle(p / p0)):>8.1f} " for p in pressures))
    print()
    print("C_r as UFC 3-340-02 implies it (Figure 2-9 over Kingery-Bulmash), to 80 deg")
    for deg in range(0, 81, 5):
        row = [ufc_coefficient(p * 1e3, math.radians(deg)) for p in pressures]
        print(f"{deg:>7} " + "".join("        - " if math.isnan(c) else f"{c:>8.3f}  " for c in row))


if __name__ == "__main__":
    main(sys.argv[1:])
