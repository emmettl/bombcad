"""kb-surface-burst-free-field in pyro2: a 1-D spherical run of the mirrored charge.

The case's 100 kg hemisphere on rigid ground is half of a 200 kg sphere in free air (the ground is
the sphere's plane of symmetry), so the run is a 200 kg sphere and every gauge sits at its
distance from the charge's centre. Writes the gauges' peak, impulse and arrival, the run's
parameters and a thinned pressure history to outputs/.

    python3 run_free_field.py --dr 0.005            # the entry's run
    python3 run_free_field.py --dr 0.02 --label coarse
"""

import argparse
import json
import math
import time
from pathlib import Path

import numpy as np

import pyro

from blast1d import Blast, positive_phase

HERE = Path(__file__).resolve().parent
CASE = HERE.parents[1] / "cases" / "kb-surface-burst-free-field.json"


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--dr", type=float, default=0.005, help="radial cell size, m")
    parser.add_argument("--r-out", type=float, default=36.0, help="outer (outflow) boundary, m")
    parser.add_argument("--tmax", type=float, default=0.075, help="end time, s")
    parser.add_argument("--gamma", type=float, default=1.4)
    parser.add_argument("--charge-density", type=float, default=1600.0, help="kg/m^3")
    parser.add_argument("--specific-energy", type=float, default=4.184e6, help="J/kg")
    parser.add_argument("--temperature", type=float, default=15.0, help="ambient, deg C")
    parser.add_argument("--gauges", nargs="*", help="only these gauge ids (default: all)")
    parser.add_argument("--label", default=None)
    args = parser.parse_args(argv)

    case = json.loads(CASE.read_text())
    run = case["runs"][0]
    charge = run["charges"][0]
    p0 = case["environment"]["ambient_pressure_kPa"] * 1e3
    rho0 = p0 / (287.05 * (args.temperature + 273.15))
    # Hemisphere on the ground -> the full sphere it is half of.
    mass = 2.0 * charge["tnt_equivalent_mass_kg"]
    centre = np.array(charge["centre_m"], dtype=float)
    gauges = [(g["id"], float(np.linalg.norm(np.array(g["position_m"]) - centre))) for g in run["gauges"]
              if not args.gauges or g["id"] in args.gauges]

    blast = Blast(mass_kg=mass, charge_density=args.charge_density, specific_energy=args.specific_energy,
                  gamma=args.gamma, p0=p0, rho0=rho0, dr=args.dr, r_out=args.r_out, tmax=args.tmax)
    weights = blast.probe_weights([r for _, r in gauges])
    times = [0.0]
    records = [blast.probe(weights)]
    start = time.time()
    while not blast.sim.finished():
        blast.step()
        times.append(blast.t)
        records.append(blast.probe(weights))
    elapsed = time.time() - start
    times = np.array(times)
    dp = np.array(records) - p0

    gauges_out = []
    for k, (gid, r) in enumerate(gauges):
        phase = positive_phase(times, dp[:, k])
        gauges_out.append({"gauge": gid, "radius_m": r, **phase})

    label = args.label or f"free-field-dr{args.dr * 1000:g}mm"
    out_dir = HERE / "outputs"
    out_dir.mkdir(exist_ok=True)
    summary = {
        "case": case["id"], "run": run["id"],
        "code": {"name": "pyro2", "package": "pyro-hydro", "version": pyro.__version__,
                 "solver": "compressible (2nd-order unsplit CTU, CGF Riemann solver)"},
        "parameters": {
            "geometry": "1-D spherical: SphericalPolar wedge about the equator, reflecting theta faces",
            "sphere_mass_kg": mass, "charge_density_kg_m3": args.charge_density,
            "charge_radius_m": blast.r_c, "specific_energy_J_kg": args.specific_energy,
            "energy_J": mass * args.specific_energy, "gamma": args.gamma,
            "ambient_pressure_Pa": p0, "ambient_temperature_C": args.temperature,
            "ambient_density_kg_m3": rho0, "initial_charge_density_in_shell_kg_m3": blast.rho_c,
            "initial_charge_pressure_Pa": (args.gamma - 1) * mass * args.specific_energy
            / (4 / 3 * math.pi * (blast.r_c ** 3 - blast.r_in ** 3)),
            "dr_m": args.dr, "r_in_m": blast.r_in, "r_out_m": blast.r_out, "outer_bc": "outflow",
            "cfl": 0.8, "tmax_s": args.tmax, "steps": len(times) - 1, "wall_s": round(elapsed, 1),
        },
        "gauges": gauges_out,
    }
    (out_dir / f"{label}.json").write_text(json.dumps(summary, indent=2) + "\n")
    # A thinned history (every 0.05 ms), for anyone who wants to look at the pulse shapes.
    grid_t = np.arange(0.0, times[-1], 5e-5)
    cols = [np.interp(grid_t, times, dp[:, k]) / 1e3 for k in range(len(gauges))]
    header = "t_ms," + ",".join(f"{gid}_dp_kPa" for gid, _ in gauges)
    rows = np.column_stack([grid_t * 1e3] + cols)
    np.savetxt(out_dir / f"{label}-history.csv", rows, delimiter=",", header=header, comments="",
               fmt="%.4g")
    for g in gauges_out:
        print(f"{g['gauge']:>6} r={g['radius_m']:7.3f} m  peak {g['peak_Pa'] / 1e3:8.1f} kPa  "
              f"impulse {g['impulse_Pa_s']:7.1f} Pa s  arrival {g['arrival_s']['0.5'] * 1e3:6.2f} ms  "
              f"t+ {g['duration_s'] * 1e3:6.2f} ms  after {g['largest_overpressure_after_phase_Pa'] / 1e3:6.2f} kPa")
    print(f"{len(times) - 1} steps, {elapsed:.0f} s")


if __name__ == "__main__":
    main()
