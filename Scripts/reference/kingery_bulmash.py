"""Kingery–Bulmash blast parameters for TNT, from the published polynomial fits.

    python3 Scripts/reference/kingery_bulmash.py [Z ...]

prints the parameters of a hemispherical surface burst and of a spherical free-air burst at each
scaled distance Z (m/kg^(1/3)); with no arguments, a table from 0.1 to 40.

The fits are C. N. Kingery and G. Bulmash, *Airblast parameters from TNT spherical air burst and
hemispherical surface burst*, ARBRL-TR-02555, US Army Ballistic Research Laboratory, 1984, in the
form the report gives them: with T = log10(Z), U = K0 + K1 T, the parameter is 10^(sum C_i U^i).
The coefficients are those of the hemispherical surface burst in metric units (kPa, ms, m,
kg^(1/3)) as the United Nations SaferGuard Kingery–Bulmash calculator and IATG 01.80 carry them
(the cloud session that wrote this could not reach the report itself; see
docs/reference-calculations.md for how they were checked). They hold from Z = 0.0674 to 40
m/kg^(1/3), the positive duration from 0.178.

A spherical free-air burst of W is taken as a hemispherical surface burst of W / 1.8, the
reflection factor of UFC 3-340-02 (2008) §2-13.3 for a burst on the ground: Kingery and
Bulmash's own free-air fits are not used, so the free-air values are as good as that factor.

Units here are SI: pressures in Pa, scaled impulses in Pa s/kg^(1/3), scaled times in s/kg^(1/3),
the shock front's speed in m/s. Outside the fits' range every value is NaN, never extrapolated.
"""

import math
import sys

import numpy as np

# (Z range in m/kg^(1/3), K0, K1, C0..Cn); values in the report's units before conversion.
INCIDENT_PRESSURE = [  # kPa
    ((0.0674, 40.0), -0.214362789151, 1.35034249993, [
        2.78076916577, -1.6958988741, -0.154159376846, 0.514060730593, 0.0988534365274,
        -0.293912623038, -0.0268112345019, 0.109097496421, 0.00162846756311,
        -0.0214631030242, 0.0001456723382, 0.00167847752266])]
REFLECTED_PRESSURE = [  # kPa
    ((0.0674, 40.0), -0.240657322658, 1.36637719229, [
        3.40283217581, -2.21030870597, -0.218536586295, 0.895319589372, 0.24989009775,
        -0.569249436807, -0.11791682383, 0.224131161411, 0.0245620259375, -0.0455116002694,
        -0.00190930738887, 0.00361471193389])]
INCIDENT_IMPULSE = [  # kPa ms / kg^(1/3)
    ((0.0674, 0.955), 2.06761908721, 3.0760329666, [
        2.52455620925, -0.502992763686, 0.171335645235, 0.0450176963051, -0.0118964626402]),
    ((0.955, 40.0), -1.94708846747, 2.40697745406, [
        1.67281645863, -0.384519026965, -0.0260816706301, 0.00595798753822, 0.014544526107,
        -0.00663289334734, -0.00284189327204, 0.0013644816227])]
REFLECTED_IMPULSE = [  # kPa ms / kg^(1/3)
    ((0.0674, 40.0), -0.246208804814, 1.33422049854, [
        2.70588058103, -0.949516092853, 0.112136118689, -0.0250659183287])]
ARRIVAL_TIME = [  # ms / kg^(1/3)
    ((0.0674, 40.0), -0.202425716178, 1.37784223635, [
        -0.0591634288046, 1.35706496258, 0.052492798645, -0.196563954086, -0.0601770052288,
        0.0696360270891, 0.0215297490092, -0.0161658930785, -0.00232531970294,
        0.00147752067524])]
POSITIVE_DURATION = [  # ms / kg^(1/3)
    ((0.178, 1.01), 1.92946154068, 5.25099193925, [
        -0.614227603559, 0.130143717675, 0.134872511954, 0.0391574276906, -0.00475933664702,
        -0.00428144598008]),
    # K0's sign is restored here: the transcription read +2.12492525216, which leaves the curve
    # at 1e-13 ms by Z = 1.5 and joins neither neighbour; with -2.12492525216 it meets them
    # within 1.5% at 1.01 and 0.9% at 2.78, and U spans about -2 to 2 as in every other piece.
    ((1.01, 2.78), -2.12492525216, 9.2996288611, [
        0.315409245784, -0.0297944268976, 0.030632954288, 0.0183405574086, -0.0173964666211,
        -0.00106321963633, 0.00562060030977, 0.0001618217499, -0.0006860188944]),
    ((2.78, 40.0), -3.53626218091, 3.46349745571, [
        0.686906642409, 0.0933035304009, -0.0005849420883, -0.00226884995013,
        -0.00295908591505, 0.00148029868929])]
SHOCK_VELOCITY = [  # km/s
    ((0.0674, 40.0), -0.202425716178, 1.37784223635, [
        -0.06621072854, -0.698029762594, 0.158916781906, 0.443812098136, -0.113402023921,
        -0.369887075049, 0.129230567449, 0.19857981197, -0.0867636217397, -0.0620391900135,
        0.0307482926566, 0.0102657234407, -0.00546533250772, -0.000693180974,
        0.0003847494916])]

# Report units to SI.
KPA, MS, KPA_MS, KM_S = 1e3, 1e-3, 1.0, 1e3  # kPa ms = Pa s

FITS = {
    "incident_pressure": (INCIDENT_PRESSURE, KPA),
    "reflected_pressure": (REFLECTED_PRESSURE, KPA),
    "incident_impulse": (INCIDENT_IMPULSE, KPA_MS),
    "reflected_impulse": (REFLECTED_IMPULSE, KPA_MS),
    "arrival_time": (ARRIVAL_TIME, MS),
    "positive_duration": (POSITIVE_DURATION, MS),
    "shock_velocity": (SHOCK_VELOCITY, KM_S),
}
# Which parameters scale with W^(1/3) (impulses and times); the others are functions of Z alone.
SCALED = {"incident_impulse", "reflected_impulse", "arrival_time", "positive_duration"}
SURFACE_FACTOR = 1.8  # UFC 3-340-02 §2-13.3: a surface burst acts as a free-air burst of 1.8 W.
Z_MIN, Z_MAX = 0.0674, 40.0


def _evaluate(pieces, z):
    """The fit at z: an array for an array, a float for a number."""
    shape = np.shape(z)
    z = np.asarray(z, dtype=float).reshape(-1)
    out = np.full(z.shape, np.nan)
    for (lo, hi), k0, k1, c in pieces:
        inside = (z >= lo) & (z <= hi) & np.isnan(out)
        if np.any(inside):
            u = k0 + k1 * np.log10(z[inside])
            out[inside] = 10.0 ** np.polynomial.polynomial.polyval(u, c)
    return float(out[0]) if shape == () else out.reshape(shape)


def hemispherical(z):
    """Each parameter of a hemispherical TNT surface burst at scaled distance z (m/kg^(1/3)),
    SI units, scaled ones per kg^(1/3) of the charge."""
    return {name: _evaluate(pieces, z) * unit for name, (pieces, unit) in FITS.items()}


def free_air(z):
    """The same for a spherical free-air burst of W, as a surface burst of W / 1.8: per kg^(1/3) of
    the free-air charge W."""
    f = SURFACE_FACTOR ** (1.0 / 3.0)
    surface = hemispherical(np.asarray(z, dtype=float) * f)
    return {k: (v / f if k in SCALED else v) for k, v in surface.items()}


def parameters(z, burst="surface"):
    if burst == "surface":
        return hemispherical(z)
    if burst == "free":
        return free_air(z)
    raise ValueError(f"burst must be 'surface' or 'free', not {burst!r}")


def at(distance, mass, burst="surface"):
    """Dimensional parameters at `distance` m from `mass` kg of TNT: Pa, Pa s, s and m/s."""
    w3 = float(mass) ** (1.0 / 3.0)
    scaled = parameters(np.asarray(distance, dtype=float) / w3, burst)
    return {k: (v * w3 if k in SCALED else v) for k, v in scaled.items()}


def main(argv):
    zs = [float(a) for a in argv] or [0.1, 0.2, 0.3, 0.5, 0.75, 1, 1.5, 2, 3, 4, 6, 10, 20, 40]
    for burst in ("surface", "free"):
        p = parameters(np.array(zs), burst)
        print(f"{'Hemispherical surface' if burst == 'surface' else 'Spherical free-air'} burst "
              "of TNT (Kingery-Bulmash 1984), per kg^(1/3)")
        print(f"{'Z m/kg^1/3':>10} {'Pso kPa':>10} {'Pr kPa':>10} {'is kPa ms':>10} "
              f"{'ir kPa ms':>10} {'ta ms':>8} {'td ms':>8} {'U m/s':>8}")
        for i, z in enumerate(zs):
            def v(k, scale=1.0):
                x = p[k][i] * scale
                return "-" if math.isnan(x) else f"{x:.4g}"
            print(f"{z:>10.4g} {v('incident_pressure', 1e-3):>10} {v('reflected_pressure', 1e-3):>10} "
                  f"{v('incident_impulse', 1.0):>10} {v('reflected_impulse', 1.0):>10} "
                  f"{v('arrival_time', 1e3):>8} {v('positive_duration', 1e3):>8} "
                  f"{v('shock_velocity'):>8}")
        print()


if __name__ == "__main__":
    main(sys.argv[1:])
