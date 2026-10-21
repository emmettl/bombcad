"""A spherically symmetric blast in pyro2's compressible solver (SphericalPolar grid).

pyro2 (https://github.com/python-hydro/pyro2, PyPI package pyro-hydro) solves the Euler equations
on a 2-D (r, theta) grid with azimuthal symmetry. A narrow wedge about the equator, with reflecting
walls on both theta faces, holds a purely radial flow: in effect a 1-D spherical run. The inner
radius cannot be zero (pyro2's ghost cells must stay at r >= 0), so the grid starts at a small
r_in inside the charge with a reflecting wall there; the charge's mass and energy are put into the
shell r_in < r < r_c so that neither is lost to the hole.

The charge is a constant-volume "balloon": the charge's own mass at the charge's density, with
the stated specific energy as internal energy, in a single ideal gas of ratio gamma (pyro2's
compressible solver has one gamma for the whole domain). It is released at t = 0 everywhere at
once; there is no detonation front, no JWL products and no afterburning.

Nothing here is BombCAD's: the solver is pyro2's, called through its Python driver.
"""

import math

import numpy as np

from pyro import Pyro


def charge_radius(mass_kg, density_kg_m3):
    return (3.0 * mass_kg / (4.0 * math.pi * density_kg_m3)) ** (1.0 / 3.0)


NG = 4  # pyro2's ghost cells for the compressible solver


def grid_for(r_c, dr, r_out, r_in_target):
    """r_in, nx and r_out so that the charge's surface r_c falls on a cell face.

    r_in is the face nearest below r_in_target that is a whole number of cells below r_c, and at
    least five cells from the origin (pyro2's four ghost cells, and room for the wedge below).
    """
    k = math.floor((r_c - max(r_in_target, (NG + 1) * dr)) / dr + 1e-9)
    if k < 1:
        raise ValueError("the charge is less than one cell above r_in: refine dr or lower r_in")
    r_in = r_c - k * dr
    nx = math.ceil((r_out - r_in) / dr - 1e-9)
    return r_in, nx, r_in + nx * dr


class Blast:
    """One spherical run: build, step, and probe."""

    def __init__(self, *, mass_kg, charge_density, specific_energy, gamma, p0, rho0,
                 dr, r_out, outer_bc="outflow", r_in_target=0.05, ntheta=1, cfl=0.8,
                 limiter=2, cvisc=0.1, tmax=1.0, max_steps=10_000_000):
        self.mass_kg = mass_kg
        self.charge_density = charge_density
        self.specific_energy = specific_energy
        self.gamma = gamma
        self.p0 = p0
        self.rho0 = rho0
        self.r_c = charge_radius(mass_kg, charge_density)
        self.r_in, nx, self.r_out = grid_for(self.r_c, dr, r_out, r_in_target)
        self.dr = dr
        # The wedge: r * dtheta = dr at the innermost ghost cell's centre, so the theta-direction
        # CFL limit (pyro2 takes the minimum over ghost cells too) is never tighter than r's.
        dtheta = dr / (self.r_in - (NG - 0.5) * dr)
        half = 0.5 * ntheta * dtheta
        if half > 0.75:
            raise ValueError("wedge too wide; raise r_in_target or refine dr")

        self.pyro = Pyro("compressible")
        self.pyro.add_problem("balloon", self._init_data, problem_params={})
        self.pyro.initialize_problem("balloon", inputs_dict={
            "mesh.grid_type": "SphericalPolar",
            "mesh.nx": nx, "mesh.ny": ntheta,
            "mesh.xmin": self.r_in, "mesh.xmax": self.r_out,
            "mesh.ymin": 0.5 * math.pi - half, "mesh.ymax": 0.5 * math.pi + half,
            "mesh.xlboundary": "reflect", "mesh.xrboundary": outer_bc,
            "mesh.ylboundary": "reflect", "mesh.yrboundary": "reflect",
            "eos.gamma": gamma,
            "compressible.riemann": "CGF",  # pyro2 allows only CGF on SphericalPolar
            "compressible.limiter": limiter,
            "compressible.cvisc": cvisc,
            "compressible.use_flattening": 1,
            "compressible.grav": 0.0,
            "driver.cfl": cfl,
            "driver.tmax": tmax,
            "driver.max_steps": max_steps,
            "driver.init_tstep_factor": 0.01,
            "driver.max_dt_change": 2.0,
        })
        self.sim = self.pyro.get_sim()
        self.grid = self.sim.cc_data.grid
        g = self.grid
        self.j = g.jlo  # every theta row is the same; probe the first interior one
        self.xc = g.x  # cell centres, ghost cells included

    def _init_data(self, my_data, rp):
        g = my_data.grid
        dens = my_data.get_var("density")
        xmom = my_data.get_var("x-momentum")
        ymom = my_data.get_var("y-momentum")
        ener = my_data.get_var("energy")
        xmom[:, :] = 0.0
        ymom[:, :] = 0.0
        dens[:, :] = self.rho0
        ener[:, :] = self.p0 / (self.gamma - 1.0)
        # The shell r_in..r_c holds the whole charge: its mass and its energy, spread uniformly.
        shell_volume = 4.0 / 3.0 * math.pi * (self.r_c ** 3 - g.xmin ** 3)
        rho_c = self.mass_kg / shell_volume
        e_vol = self.mass_kg * self.specific_energy / shell_volume
        inside = g.x2d < self.r_c  # faces fall on r_c, so a cell is either inside or out
        dens[inside] = rho_c
        ener[inside] = e_vol
        self.rho_c = rho_c

    # --- state -------------------------------------------------------------------------------------

    @property
    def t(self):
        return self.sim.cc_data.t

    def step(self):
        self.pyro.single_step()

    def pressure_row(self):
        d = self.sim.cc_data
        rho = d.get_var("density")[:, self.j]
        mx = d.get_var("x-momentum")[:, self.j]
        my = d.get_var("y-momentum")[:, self.j]
        e = d.get_var("energy")[:, self.j]
        return (self.gamma - 1.0) * (e - 0.5 * (mx * mx + my * my) / rho)

    def probe_weights(self, radii):
        """Indices and weights to interpolate linearly in r between cell centres."""
        out = []
        for r in radii:
            i = int(np.searchsorted(self.xc, r)) - 1
            w = (r - self.xc[i]) / (self.xc[i + 1] - self.xc[i])
            out.append((i, w))
        return out

    def probe(self, weights):
        """Pressure at each probe, in Pa, from the conserved state alone (cheap)."""
        d = self.sim.cc_data
        j = self.j
        rho = d.get_var("density")
        mx = d.get_var("x-momentum")
        my = d.get_var("y-momentum")
        e = d.get_var("energy")
        values = []
        for i, w in weights:
            p = []
            for k in (i, i + 1):
                p.append((self.gamma - 1.0) * (e[k, j] - 0.5 * (mx[k, j] ** 2 + my[k, j] ** 2) / rho[k, j]))
            values.append((1.0 - w) * p[0] + w * p[1])
        return values

    def totals(self):
        """Volume-weighted means over the interior of the wedge: pressure, kinetic and total energy."""
        d = self.sim.cc_data
        g = self.grid
        V = g.V.v()
        rho = d.get_var("density").v()
        mx = d.get_var("x-momentum").v()
        my = d.get_var("y-momentum").v()
        e = d.get_var("energy").v()
        ke = 0.5 * (mx * mx + my * my) / rho
        p = (self.gamma - 1.0) * (e - ke)
        vol = V.sum()
        return {"mean_pressure_Pa": float((p * V).sum() / vol),
                "kinetic_energy_fraction": float((ke * V).sum() / (e * V).sum()),
                "total_energy_J_per_m3": float((e * V).sum() / vol),
                "mass_kg_per_m3": float((rho * V).sum() / vol)}


def positive_phase(t, dp):
    """Peak, arrival and the positive phase of one overpressure record (t in s, dp in Pa).

    The peak is the record's largest overpressure. The positive phase is the contiguous stretch
    around the peak where dp > 0, its ends found by linear interpolation of the zero crossings;
    the impulse is the trapezoidal integral of dp over it. Arrival is given three ways: the first
    time dp reaches 1%, 10% and 50% of the peak (linear interpolation between samples).
    """
    t = np.asarray(t)
    dp = np.asarray(dp)
    k = int(np.argmax(dp))
    peak = float(dp[k])
    # start: last sample before the peak at or below zero, counting as zero the round-off
    # (about 1e-14 Pa) the undisturbed air can carry ahead of the shock
    below = np.nonzero(dp[:k] <= 1e-9 * peak)[0]
    a = int(below[-1]) if below.size else 0
    after = np.nonzero(dp[k:] <= 0.0)[0]
    if after.size == 0:
        raise ValueError("the record ends inside the positive phase; run longer")
    b = k + int(after[0])

    def cross(i0, i1, level):
        return float(t[i0] + (level - dp[i0]) * (t[i1] - t[i0]) / (dp[i1] - dp[i0]))

    if below.size == 0:
        t_start = float(t[0])
    else:
        t_start = max(float(t[a]), cross(a, a + 1, 0.0))
    t_end = cross(b - 1, b, 0.0)
    ts = np.concatenate(([t_start], t[a + 1:b], [t_end]))
    ps = np.concatenate(([0.0], dp[a + 1:b], [0.0]))
    impulse = float(np.trapezoid(ps, ts))
    arrivals = {}
    for frac in (0.01, 0.1, 0.5):
        level = frac * peak
        i = int(np.nonzero(dp[:k + 1] >= level)[0][0])
        arrivals[f"{frac:g}"] = cross(i - 1, i, level) if i > 0 else float(t[0])
    # A record whose phase ends then goes positive again within it would be a reflection; report
    # the largest overpressure after the end so a reader can see whether one came back.
    later = float(dp[b:].max()) if b < dp.size else 0.0
    return {"peak_Pa": peak, "t_peak_s": float(t[k]), "t_start_s": t_start, "t_end_s": t_end,
            "duration_s": t_end - t_start, "impulse_Pa_s": impulse, "arrival_s": arrivals,
            "largest_overpressure_after_phase_Pa": later}
