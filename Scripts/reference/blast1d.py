"""A one-dimensional spherical blast: a Lagrangian solver for a charge bursting in still air.

    python3 Scripts/reference/blast1d.py [--charge tnt|balloon] [--mass 1] [--cells 2000]
                                         [--reach 10] [--json OUT]

prints the peak overpressure, positive impulse, arrival time and positive duration at gauges from
0.3 to the reach in m/kg^(1/3), beside Brode's fit and Kingery–Bulmash's free-air burst.

The scheme is von Neumann and Richtmyer's (*J. Appl. Phys.* 21, 1950, 232) in spherical symmetry,
as R. D. Richtmyer and K. W. Morton, *Difference Methods for Initial-Value Problems* (2nd ed.,
1967), chapter 12, set it out: a staggered grid of shells, the nodes' velocities and radii advanced
by leapfrog under the pressure difference across each node's sphere, the shells' masses fixed, their
internal energy changed by the work p dV, and an artificial viscosity q = rho (c_q^2 du^2 + c_l c
|du|) in compression spreading each shock over a few shells (c_q 2, c_l 0.05). The linear term
damps weak shocks as they travel: beyond 10 m/kg^(1/3) the peak moves by about 5% for c_l from
0.02 to 0.05 (and 10-15% more at 0.15), while the impulse and arrival move by under 1%; without
it the shock rings and the peak overshoots. Shells of hot air drawn thin behind the shock are
joined in pairs, conserving mass, momentum and energy, so that they do not set the time step. Each shell keeps its material, so the
detonation products and the air never mix and need no interface treatment.

Two charges:

- `tnt`: TNT at 1,630 kg/m^3 detonated all at once (a constant-volume explosion), its products on
  the Jones–Wilkins–Lee equation of state with B. M. Dobratz and P. C. Crawford's parameters (*LLNL
  Explosives Handbook*, UCRL-52997 change 2, 1985): A 371.2 GPa, B 3.231 GPa, R1 4.15, R2 0.95,
  omega 0.30, E0 7.0 GPa (4.29 MJ/kg).
- `balloon`: an ideal-gas sphere (gamma 1.4 by default) holding the same energy as the charge, at
  the charge's density by default, the pressurised sphere of H. L. Brode, "Numerical solutions of
  spherical blast waves", *J. Appl. Phys.* 26 (1955) 766, and "Blast wave from a spherical charge",
  *Phys. Fluids* 2 (1959) 217.

The air is an ideal gas, gamma 1.4, 101,325 Pa and 1.225 kg/m^3: dissociation and the real gas's
lower gamma at high temperature are left out, which lowers the peaks close in (within about 1
m/kg^(1/3)) against measurement. Afterburning of the products in the air is left out too.

Gauges sit at fixed radii; each records the pressure of the shell containing it at every step. The
arrival is when the overpressure first reaches half its peak (the smeared shock's middle), the
positive phase runs from there until it first falls below ambient, and the impulse integrates the
overpressure over it.
"""

import argparse
import json
import math
import sys

import numpy as np

P0, RHO0_AIR, GAMMA_AIR = 101325.0, 1.225, 1.4
TNT_DENSITY = 1630.0
JWL_TNT = dict(A=371.2e9, B=3.231e9, R1=4.15, R2=0.95, omega=0.30, rho0=1630.0, E0=7.0e9)
TNT_ENERGY = JWL_TNT["E0"] / JWL_TNT["rho0"]  # J/kg, 4.29 MJ/kg


class IdealGas:
    def __init__(self, gamma):
        self.g = gamma

    def f(self, rho):
        """The cold part of p = f(rho) + G rho e (here none)."""
        return np.zeros_like(rho), np.zeros_like(rho)

    def grueneisen(self, rho):
        return np.full_like(rho, self.g - 1.0)


class JWL:
    def __init__(self, A, B, R1, R2, omega, rho0, E0):
        self.A, self.B, self.R1, self.R2, self.w, self.rho0, self.E0 = A, B, R1, R2, omega, rho0, E0

    def f(self, rho):
        """f(rho) and df/drho at constant e for p = f(rho) + omega rho e."""
        v = self.rho0 / rho
        ea, eb = np.exp(-self.R1 * v), np.exp(-self.R2 * v)
        f = self.A * (1.0 - self.w / (self.R1 * v)) * ea + self.B * (1.0 - self.w / (self.R2 * v)) * eb
        dfdv = (self.A * ea * (self.w / (self.R1 * v * v) - self.R1 + self.w / v)
                + self.B * eb * (self.w / (self.R2 * v * v) - self.R2 + self.w / v))
        return f, dfdv * (-v * v / self.rho0)

    def grueneisen(self, rho):
        return np.full_like(rho, self.w)


def _volumes(r):
    return 4.0 / 3.0 * math.pi * (r[1:] ** 3 - r[:-1] ** 3)


def run(charge="tnt", mass=1.0, cells_charge=200, air_cell=None, reach=10.0, gauges=None,
        balloon_gamma=1.4, balloon_density=TNT_DENSITY, energy=TNT_ENERGY, cfl=0.3,
        cq=2.0, cl=0.05, history_every=1, merge=True):
    """Run to the time the shock passes the furthest gauge; returns a dict of gauge results
    (scaled by mass^(1/3)) and the energy budget. `reach` and `gauges` in m/kg^(1/3)."""
    w3 = mass ** (1.0 / 3.0)
    rc = (3.0 * mass / (4.0 * math.pi * (TNT_DENSITY if charge == "tnt" else balloon_density))) ** (1.0 / 3.0)
    gauges = np.array(gauges if gauges is not None else
                      [z for z in (0.3, 0.4, 0.5, 0.75, 1, 1.5, 2, 3, 4, 5, 6, 8, 10, 15, 20) if z <= reach])
    r_gauge = gauges * w3
    r_out = (reach * 1.15 + 0.5) * w3
    air_cell = air_cell or 2.0e-3 * w3
    n_air = int(math.ceil((r_out - rc) / air_cell))
    r = np.concatenate([np.linspace(0.0, rc, cells_charge + 1), rc + air_cell * np.arange(1, n_air + 1)])
    nc = len(r) - 1
    is_charge = np.arange(nc) < cells_charge

    if charge == "tnt":
        prod = JWL(**JWL_TNT)
        rho_c, e_c = TNT_DENSITY, energy
    elif charge == "balloon":
        prod = IdealGas(balloon_gamma)
        rho_c, e_c = balloon_density, energy
    else:
        raise ValueError(charge)
    air = IdealGas(GAMMA_AIR)
    vol = _volumes(r)
    rho = np.where(is_charge, rho_c, RHO0_AIR)
    m = rho * vol
    e = np.where(is_charge, e_c, P0 / ((GAMMA_AIR - 1.0) * RHO0_AIR))
    u = np.zeros(nc + 1)
    node_mass = np.zeros(nc + 1)
    node_mass[:-1] += 0.5 * m
    node_mass[1:] += 0.5 * m

    def eos(rho, e, is_charge):
        fa, da = air.f(rho)
        fp, dp = prod.f(rho)
        f = np.where(is_charge, fp, fa)
        df = np.where(is_charge, dp, da)
        G = np.where(is_charge, prod.grueneisen(rho), air.grueneisen(rho))
        p = f + G * rho * e
        c2 = df + G * e + G * p / rho
        return p, f, G, np.sqrt(np.maximum(c2, 1e-12))

    p, _, _, c = eos(rho, e, is_charge)
    e_total0 = float(np.sum(m * e))
    t = 0.0
    hist_t, hist_p = [], []
    # The shock reaches the outer gauge at about Kingery–Bulmash's free-air arrival; run a margin
    # past it, long enough for the positive phase there.
    import kingery_bulmash as kb
    zmax = float(gauges.max())
    t_end = (float(kb.free_air(np.array([min(zmax, 22.0)]))["arrival_time"][0])
             + 2.5 * float(kb.free_air(np.array([min(zmax, 22.0)]))["positive_duration"][0])) * w3
    step = 0
    while t < t_end:
        dr = np.diff(r)
        du = np.diff(u)
        q = np.where(du < 0.0, rho * (cq * cq * du * du + cl * c * np.abs(du)), 0.0)
        lim = dr / (c + 2.0 * cq * cq * np.abs(np.minimum(du, 0.0)) + 1e-30)
        dt = cfl * float(np.min(lim))
        dt = min(dt, t_end - t) if t_end - t > 0 else dt
        # Nodes: M du/dt = -4 pi r^2 (p + q)_right + 4 pi r^2 (p + q)_left; the centre and the
        # outer boundary (a wall far beyond the shock) are held.
        pq = p + q
        force = np.zeros(nc + 1)
        area = 4.0 * math.pi * r * r
        force[1:-1] = -area[1:-1] * (pq[1:] - pq[:-1])
        u[1:-1] += dt * force[1:-1] / node_mass[1:-1]
        r_new = r + dt * u
        vol_new = _volumes(r_new)
        rho_new = m / vol_new
        dv = 1.0 / rho_new - 1.0 / rho
        # Energy: e1 = e0 - ((p0 + p1)/2 + q) dv, with p1 = f(rho1) + G rho1 e1, solved for e1.
        _, f1, G1, _ = eos(rho_new, e, is_charge)
        e = (e - (0.5 * (p + f1) + q) * dv) / (1.0 + 0.5 * G1 * rho_new * dv)
        r, rho = r_new, rho_new
        p, _, _, c = eos(rho, e, is_charge)
        t += dt
        step += 1
        if step % history_every == 0:
            cell = np.clip(np.searchsorted(r, r_gauge) - 1, 0, nc - 1)
            hist_t.append(t)
            hist_p.append(p[cell] - P0)
        if merge and step % 50 == 0:
            r, u, m, e, rho, node_mass, is_charge = _merge(r, u, m, e, rho, node_mass, is_charge,
                                                           air_cell, p)
            nc = len(m)
            p, _, _, c = eos(rho, e, is_charge)
        if r[-2] > r_out * 1.5:
            break
    ke = float(np.sum(0.5 * node_mass * u * u))
    e_total = float(np.sum(m * e)) + ke
    hist_t = np.array(hist_t)
    hist_p = np.array(hist_p)
    results = []
    for k, z in enumerate(gauges):
        ph = hist_p[:, k]
        peak = float(ph.max())
        i_peak = int(ph.argmax())
        if peak <= 0.0:  # nothing arrived
            results.append(dict(z=float(z), peak_overpressure=peak, impulse=0.0, arrival_time=float("nan"),
                                positive_duration=float("nan"), complete=False))
            continue
        i_arr = int(np.nonzero(ph >= 0.5 * peak)[0][0])
        # Arrival interpolated between the steps either side of half the peak.
        if i_arr > 0:
            f = (0.5 * peak - ph[i_arr - 1]) / (ph[i_arr] - ph[i_arr - 1])
            t_arr = float(hist_t[i_arr - 1] + f * (hist_t[i_arr] - hist_t[i_arr - 1]))
        else:
            t_arr = float(hist_t[0])
        below = np.nonzero(ph[i_peak:] < 0.0)[0]
        complete = len(below) > 0
        i_end = i_peak + (int(below[0]) if complete else len(ph) - 1 - i_peak)
        # The impulse counts the smeared rise before the arrival too: from the first positive
        # sample.
        i0 = int(np.nonzero(ph > 0.0)[0][0])
        pos_t, pos_p = hist_t[i0:i_end], ph[i0:i_end]
        impulse = float(np.sum(0.5 * (pos_p[1:] + pos_p[:-1]) * np.diff(pos_t))) if len(pos_t) > 1 else 0.0
        t_zero = float(hist_t[i_end]) if complete else float("nan")
        results.append(dict(z=float(z), peak_overpressure=peak, impulse=impulse / w3,
                            arrival_time=t_arr / w3,
                            positive_duration=(t_zero - t_arr) / w3, complete=complete))
    return dict(charge=charge, mass=mass, energy_per_kg=energy, scaled=True,
                charge_density=TNT_DENSITY if charge == "tnt" else balloon_density,
                cells_charge=cells_charge, air_cell=air_cell / w3,
                steps=step, energy_initial=e_total0, energy_final=e_total,
                energy_error=(e_total - e_total0) / e_total0, gauges=results)


def _merge(r, u, m, e, rho, node_mass, is_charge, target, p):
    """Join neighbouring shells of air that have thinned below half of `target` far
    behind the shock (inside 0.6 of its radius), conserving mass, momentum and total energy (the
    removed node's kinetic energy that the merge cannot keep goes into the joined shell's internal
    energy). In spherical expansion the hot air next to the products is drawn into ever thinner
    shells, which would otherwise set the time step."""
    shock = r[int(np.argmax(p)) + 1]
    dr = np.diff(r)
    thin = (dr < 0.5 * target) & (r[1:] < 0.6 * shock)
    pairs = []
    j = 0
    n = len(m)
    while j < n - 1:
        if thin[j] and thin[j + 1] and not is_charge[j] and not is_charge[j + 1]:
            pairs.append(j)
            j += 2
        else:
            j += 1
    if not pairs:
        return r, u, m, e, rho, node_mass, is_charge
    u, node_mass = u.copy(), node_mass.copy()
    m, e = m.copy(), e.copy()
    remove = []
    for j in pairs:
        k = j + 1  # the node between shells j and j+1
        mj, mk = m[j], m[j + 1]
        ke_before = 0.5 * (node_mass[j] * u[j] ** 2 + node_mass[k] * u[k] ** 2 + node_mass[k + 1] * u[k + 1] ** 2)
        mom_k = node_mass[k] * u[k]
        a, b = 0.5 * mk, 0.5 * mj  # the removed node's mass, shared to its neighbours
        u[j] = (node_mass[j] * u[j] + mom_k * a / (a + b)) / (node_mass[j] + a)
        u[k + 1] = (node_mass[k + 1] * u[k + 1] + mom_k * b / (a + b)) / (node_mass[k + 1] + b)
        node_mass[j] += a
        node_mass[k + 1] += b
        ke_after = 0.5 * (node_mass[j] * u[j] ** 2 + node_mass[k + 1] * u[k + 1] ** 2)
        e[j] = (mj * e[j] + mk * e[j + 1] + (ke_before - ke_after)) / (mj + mk)
        m[j] = mj + mk
        remove.append(j)
    cells = np.array(remove) + 1
    nodes = np.array(remove) + 1
    m = np.delete(m, cells)
    e = np.delete(e, cells)
    is_charge = np.delete(is_charge, cells)
    r = np.delete(r, nodes)
    u = np.delete(u, nodes)
    node_mass = np.delete(node_mass, nodes)
    rho = m / _volumes(r)
    return r, u, m, e, rho, node_mass, is_charge


def brode(z):
    """Brode's peak overpressure of a spherical TNT burst in free air, Pa, at z m/kg^(1/3):
    6.7 / z^3 + 1 bar above 10 bar and 0.975 / z + 1.455 / z^2 + 5.85 / z^3 - 0.019 bar from 0.1 to
    10 bar (H. L. Brode, 1955, as A. S. Smith and G. Hetherington, *Blast and Ballistic Loading of
    Structures*, 1994, §2.5, give it); NaN below 0.1 bar."""
    z = np.asarray(z, dtype=float)
    near = 6.7 / z**3 + 1.0
    far = 0.975 / z + 1.455 / z**2 + 5.85 / z**3 - 0.019
    bar = np.where(near > 10.0, near, far)
    return np.where(bar >= 0.1, bar * 1e5, np.nan)


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--charge", default="tnt", choices=["tnt", "balloon"])
    ap.add_argument("--mass", type=float, default=1.0)
    ap.add_argument("--cells", type=int, default=200, help="shells across the charge")
    ap.add_argument("--air-cell", type=float, default=2.0e-3, help="air shell, m/kg^(1/3)")
    ap.add_argument("--reach", type=float, default=10.0, help="furthest gauge, m/kg^(1/3)")
    ap.add_argument("--energy", type=float, default=TNT_ENERGY,
                    help="J/kg (TNT's JWL E0, 4.29 MJ/kg, by default; BombCAD's balloon takes 4.184)")
    ap.add_argument("--density", type=float, default=TNT_DENSITY,
                    help="the balloon's density, kg/m^3 (BombCAD's takes 1600)")
    ap.add_argument("--gamma", type=float, default=1.4, help="the balloon gas's gamma")
    ap.add_argument("--json", help="write the results here")
    a = ap.parse_args(argv)
    import kingery_bulmash as kb
    res = run(a.charge, a.mass, a.cells, a.air_cell * a.mass ** (1 / 3), a.reach,
              balloon_gamma=a.gamma, balloon_density=a.density, energy=a.energy)
    print(f"{a.charge}, {a.mass} kg, {a.cells} shells in the charge, air shells {a.air_cell * 1e3:g} "
          f"mm/kg^(1/3), {res['steps']} steps, energy kept within {res['energy_error']:.2e}")
    print(f"{'Z':>6} {'peak kPa':>9} {'/Brode':>7} {'/KB':>6} {'is kPa ms':>10} {'/KB':>6} "
          f"{'ta ms':>7} {'/KB':>6} {'td ms':>7} {'/KB':>6}")
    for g in res["gauges"]:
        k = kb.free_air(np.array([g["z"]]))
        b = brode(g["z"])
        print(f"{g['z']:>6.3g} {g['peak_overpressure'] / 1e3:>9.4g} {g['peak_overpressure'] / b:>7.3f} "
              f"{g['peak_overpressure'] / k['incident_pressure'][0]:>6.3f} {g['impulse']:>10.4g} "
              f"{g['impulse'] / k['incident_impulse'][0]:>6.3f} {g['arrival_time'] * 1e3:>7.4g} "
              f"{g['arrival_time'] / k['arrival_time'][0]:>6.3f} {g['positive_duration'] * 1e3:>7.4g} "
              f"{g['positive_duration'] / k['positive_duration'][0]:>6.3f}")
    if a.json:
        with open(a.json, "w") as f:
            json.dump(res, f, indent=1)


if __name__ == "__main__":
    main(sys.argv[1:])
