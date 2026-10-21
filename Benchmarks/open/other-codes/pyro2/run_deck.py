"""One run of an ideal-gas-balloon-v1 deck in pyro2, 1-D spherical, written as the decks' CSV history.

The decks (Benchmarks/open/decks/) fix the physics: one ideal gas of gamma 1.4, ambient air of
1.225 kg/m^3 at 101.325 kPa, and a balloon at rest that adds the deck's excess mass and excess
energy to the ambient state inside its sphere, released at t = 0. This keeps all of that and the
decks' read rules, with one stated deviation: the run is 1-D spherical on pyro2's spherical-polar
grid (blast1d.py), not the decks' 3-D Cartesian mesh.
- The free field (an octant on three mirror planes in the deck) is the whole 200 kg sphere, eight
  times the octant's represented mass and energy, each gauge at its distance from the centre. Its
  outer boundary is outflow, far enough that nothing it returns reaches a gauge in its positive
  phase.
- The room (a closed 6 m cube in the deck) is a closed rigid sphere of the cube's 216 m^3, the
  observable the volume-weighted mean pressure over all its cells.

Every step's sample is written at the solver's own time, from 0 to the deck's stop (pyro2 shortens
the last step to land on it); the steps are far shorter than the deck's 50 us.

    python -I run_deck.py --case kb-surface-burst-free-field --run 100kg --dr 0.01 --r-out 40 --out DIR
    python -I run_deck.py --case ufc-closed-room-gas-pressure --run 0.25kg-m3 --dr 0.02 --out DIR
"""

import argparse
import csv
import json
import math
import time
from pathlib import Path

import sys

import numpy as np

import pyro

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))  # blast1d beside this script, also under python -I

from blast1d import NG, Blast  # noqa: E402
DECKS = HERE.parents[1] / "decks"


class DeckBalloon(Blast):
    """blast1d's spherical run, with the deck's start: excess mass and energy on top of ambient."""

    def __init__(self, *, excess_mass, excess_energy, radius, **kwargs):
        self.excess_mass = excess_mass
        self.excess_energy = excess_energy
        self.deck_radius = radius
        super().__init__(**kwargs)

    def _init_data(self, my_data, rp):
        g = my_data.grid
        dens = my_data.get_var("density")
        ener = my_data.get_var("energy")
        my_data.get_var("x-momentum")[:, :] = 0.0
        my_data.get_var("y-momentum")[:, :] = 0.0
        dens[:, :] = self.rho0
        ener[:, :] = self.p0 / (self.gamma - 1.0)
        # The shell r_in < r < r_c holds the whole excess (blast1d puts r_c on a cell face).
        shell = 4.0 / 3.0 * math.pi * (self.r_c**3 - g.xmin**3)
        inside = g.x2d < self.r_c
        dens[inside] += self.excess_mass / shell
        ener[inside] += self.excess_energy / shell
        self.rho_c = float(dens[inside].max())


def sphere_grid(r_c, volume, dr_target, r_in_target=0.05):
    """A cell size near dr_target for which the charge's surface and the wall lie on faces and the
    gridded shell r_in < r < R holds exactly the room's volume."""
    r_in = 0.0
    for _ in range(8):
        R = (3.0 * volume / (4.0 * math.pi) + r_in**3) ** (1.0 / 3.0)
        m = max(1, round((R - r_c) / dr_target))
        dr = (R - r_c) / m
        k = math.floor((r_c - max(r_in_target, (NG + 1) * dr)) / dr + 1e-9)
        r_in = r_c - k * dr
    return dr, R


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--case", required=True)
    ap.add_argument("--run", required=True)
    ap.add_argument("--dr", type=float, required=True, help="radial cell, m")
    ap.add_argument("--r-out", type=float, default=40.0, help="free field: outflow boundary, m")
    ap.add_argument("--out", type=Path, required=True, help="history folder")
    ap.add_argument("--decks", type=Path, default=DECKS, help="the decks' folder")
    args = ap.parse_args(argv)

    deck = json.loads((args.decks / f"{args.case}.json").read_text())
    run = next(r for r in deck["runs"] if r["id"] == args.run)
    source = run["source"]
    gamma = deck["physics"]["gamma"]
    p0 = deck["ambient"]["pressure_Pa"]
    rho0 = deck["ambient"]["density_kg_m3"]
    stop = deck["sampling"]["stop_s"]
    room = deck["extraction"]["kind"] == "room-window"
    # Mirror planes in the deck: the represented charge is that share of the sphere.
    share = 2 ** len(deck["boundaries"]["reflecting_faces"]) if not room else 1
    excess_mass = source["excess_mass_kg"] * share
    excess_energy = source["excess_energy_J"] * share
    radius = source["radius_m"]
    common = dict(excess_mass=excess_mass, excess_energy=excess_energy, radius=radius,
                  mass_kg=source["represented_charge_kg"] * share, charge_density=1600.0,
                  specific_energy=4.184e6, gamma=gamma, p0=p0, rho0=rho0, tmax=stop)
    if room:
        volume = math.prod(deck["mesh"]["counts"]) * deck["mesh"]["cell_size_m"] ** 3
        dr, R = sphere_grid(radius, volume, args.dr)
        blast = DeckBalloon(dr=dr, r_out=R - 1e-9, outer_bc="reflect", **common)
        gauges = ["room"]
    else:
        blast = DeckBalloon(dr=args.dr, r_out=args.r_out, outer_bc="outflow", **common)
        centre = np.array(source["centre_m"], dtype=float)
        gauges = [g["id"] for g in run["gauges"]]
        radii = [float(np.linalg.norm(np.array(g["position_m"]) - centre)) for g in run["gauges"]]
        weights = blast.probe_weights(radii)
    assert abs(blast.r_c - radius) < 1e-9 * radius, (blast.r_c, radius)

    def sample():
        if room:
            return [blast.totals()["mean_pressure_Pa"] - p0]
        return [p - p0 for p in blast.probe(weights)]

    args.out.mkdir(parents=True, exist_ok=True)
    times, rows = [0.0], [sample()]
    largest_dt = 0.0
    started = time.time()
    while not blast.sim.finished():
        t0 = blast.t
        blast.step()
        largest_dt = max(largest_dt, blast.t - t0)
        times.append(blast.t)
        rows.append(sample())
    wall = time.time() - started
    if abs(times[-1] - stop) > deck["sampling"]["time_tolerance_s"]:
        raise SystemExit(f"stopped at {times[-1]!r}, not {stop}")
    if largest_dt > deck["sampling"]["interval_s"]:
        raise SystemExit(f"a step of {largest_dt} s is longer than the deck's sampling interval")
    times[-1] = stop
    path = args.out / f"{args.case}--{args.run}.csv"
    with path.open("x", newline="") as stream:
        writer = csv.writer(stream)
        writer.writerow(["case", "run", "gauge", "time_s", "overpressure_Pa"])
        for t, row in zip(times, rows):
            for gauge, value in zip(gauges, row):
                writer.writerow([args.case, args.run, gauge, repr(float(t)), repr(float(value))])
    totals = blast.totals()
    summary = {
        "case": args.case, "run": args.run, "pyro2": pyro.__version__,
        "geometry": "1-D spherical (SphericalPolar wedge, one theta cell, reflecting theta faces)",
        "dr_m": blast.dr, "r_in_m": blast.r_in, "r_out_m": blast.r_out,
        "outer_bc": "reflect" if room else "outflow", "sphere_excess_mass_kg": excess_mass,
        "sphere_excess_energy_J": excess_energy, "charge_radius_m": blast.r_c, "steps": len(times) - 1,
        "largest_step_s": largest_dt, "wall_s": round(wall, 1),
        "final_mean_overpressure_Pa": totals["mean_pressure_Pa"] - p0,
        "final_kinetic_energy_fraction": totals["kinetic_energy_fraction"],
    }
    if not room:
        summary["gauge_radii_m"] = dict(zip(gauges, radii))
    (args.out / f"{args.case}--{args.run}.summary.json").write_text(json.dumps(summary, indent=1) + "\n")
    print(json.dumps(summary))


if __name__ == "__main__":
    main()
