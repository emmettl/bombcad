"""ufc-closed-room-gas-pressure in pyro2, approximately: a closed rigid sphere of the room's volume.

pyro2's grids are 2-D (Cartesian, or spherical polar with azimuthal symmetry), so the case's closed
6 m cube cannot be modelled. This runs instead a closed, rigid, adiabatic sphere of the same
volume (216 m^3, radius 3.72 m) with the charge at its centre, 1-D spherical as in
run_free_field.py. The quasi-static pressure is read as the room's volume-mean pressure above
ambient; in an energy-conserving inviscid code that is (gamma - 1) times the internal energy per
volume, so it depends on the time it is read only through the kinetic energy still sloshing about.
The run records the mean pressure and the kinetic energy's share every 0.5 ms.

    python3 run_closed_room.py --run 0.25kg-m3 --dr 0.01
    python3 run_closed_room.py --all --dr 0.01
"""

import argparse
import json
import math
import time
from pathlib import Path

import pyro

from blast1d import Blast, NG, charge_radius

HERE = Path(__file__).resolve().parent
CASE = HERE.parents[1] / "cases" / "ufc-closed-room-gas-pressure.json"
READ_TIMES_MS = (10, 20, 30, 50, 80, 100)  # 80 ms is when BombCAD's entry read its room


def sphere_grid(mass, charge_density, volume, dr_target, r_in_target=0.05):
    """A cell size dr near dr_target for which both the charge's surface and the room's wall lie on
    cell faces, and the gridded volume (the sphere less its hollow core r < r_in) is the room's."""
    r_c = charge_radius(mass, charge_density)
    r_in = 0.0
    for _ in range(5):
        R = (3.0 * volume / (4.0 * math.pi) + r_in ** 3) ** (1.0 / 3.0)
        m = max(1, round((R - r_c) / dr_target))
        dr = (R - r_c) / m
        k = math.floor((r_c - max(r_in_target, (NG + 1) * dr)) / dr + 1e-9)
        r_in = r_c - k * dr
    return dr, R


def run_one(case, run, args, p0, rho0):
    charge = run["charges"][0]
    mass = charge["tnt_equivalent_mass_kg"]
    volume = 1.0
    for lo, hi in zip(case["geometry"]["obstacles"][0]["min_m"], case["geometry"]["obstacles"][0]["max_m"]):
        volume *= hi - lo
    dr, R = sphere_grid(mass, args.charge_density, volume, args.dr)
    tmax = max(READ_TIMES_MS) / 1e3
    blast = Blast(mass_kg=mass, charge_density=args.charge_density, specific_energy=args.specific_energy,
                  gamma=args.gamma, p0=p0, rho0=rho0, dr=dr, r_out=R - 1e-9, outer_bc="reflect", tmax=tmax)
    # The volume the grid holds (one theta cell, so the wedge's share cancels in the means).
    grid_volume = 4.0 / 3.0 * math.pi * (blast.r_out ** 3 - blast.r_in ** 3)
    history = []
    next_record = 0.0
    start = time.time()
    while True:
        if blast.t >= next_record - 1e-12:
            tot = blast.totals()
            history.append({"t_ms": round(blast.t * 1e3, 4),
                            "mean_overpressure_kPa": (tot["mean_pressure_Pa"] - p0) / 1e3,
                            "kinetic_energy_fraction": tot["kinetic_energy_fraction"],
                            "total_energy_J_per_m3": tot["total_energy_J_per_m3"]})
            next_record += 5e-4
        if blast.sim.finished():
            break
        blast.step()
    elapsed = time.time() - start
    tot = blast.totals()
    history.append({"t_ms": round(blast.t * 1e3, 4), "mean_overpressure_kPa": (tot["mean_pressure_Pa"] - p0) / 1e3,
                    "kinetic_energy_fraction": tot["kinetic_energy_fraction"],
                    "total_energy_J_per_m3": tot["total_energy_J_per_m3"]})
    reads = {}
    for t_ms in READ_TIMES_MS:
        row = min(history, key=lambda h: abs(h["t_ms"] - t_ms))
        reads[str(t_ms)] = {"mean_overpressure_kPa": row["mean_overpressure_kPa"],
                            "kinetic_energy_fraction": row["kinetic_energy_fraction"]}
    e_charge = mass * args.specific_energy
    v_charge = 4.0 / 3.0 * math.pi * blast.r_c ** 3
    ideal = ((args.gamma - 1.0) * e_charge - p0 * v_charge) / volume / 1e3
    energy_drift = history[-1]["total_energy_J_per_m3"] / history[0]["total_energy_J_per_m3"] - 1.0
    return {
        "run": run["id"], "mass_kg": mass, "charge_radius_m": blast.r_c, "dr_m": dr, "r_in_m": blast.r_in,
        "room_sphere_radius_m": blast.r_out, "gridded_volume_m3": grid_volume, "room_volume_m3": volume,
        "steps": blast.sim.n, "wall_s": round(elapsed, 1),
        "energy_balance_overpressure_kPa": ideal,
        "relative_energy_drift": energy_drift,
        "reads": reads,
        "history_every_0.5ms": history,
    }


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--run", action="append", help="run id (repeatable)")
    parser.add_argument("--all", action="store_true")
    parser.add_argument("--dr", type=float, default=0.01, help="radial cell size, m (adjusted to fit)")
    parser.add_argument("--gamma", type=float, default=1.4)
    parser.add_argument("--charge-density", type=float, default=1600.0, help="kg/m^3")
    parser.add_argument("--specific-energy", type=float, default=4.184e6, help="J/kg")
    parser.add_argument("--temperature", type=float, default=15.0, help="ambient, deg C")
    parser.add_argument("--label", default=None)
    args = parser.parse_args(argv)

    case = json.loads(CASE.read_text())
    p0 = case["environment"]["ambient_pressure_kPa"] * 1e3
    rho0 = p0 / (287.05 * (args.temperature + 273.15))
    runs = [r for r in case["runs"] if args.all or (args.run and r["id"] in args.run)]
    if not runs:
        parser.error("give --run ID or --all")
    out = {
        "case": case["id"],
        "code": {"name": "pyro2", "package": "pyro-hydro", "version": pyro.__version__,
                 "solver": "compressible (2nd-order unsplit CTU, CGF Riemann solver)"},
        "parameters": {
            "geometry": "closed rigid sphere of the room's volume, 1-D spherical (SphericalPolar wedge, "
                        "one theta cell, reflecting faces); the case's cube is not modelled",
            "charge_density_kg_m3": args.charge_density, "specific_energy_J_kg": args.specific_energy,
            "gamma": args.gamma, "ambient_pressure_Pa": p0, "ambient_temperature_C": args.temperature,
            "ambient_density_kg_m3": rho0, "afterburning": False, "heat_loss": False,
            "read": "volume-mean pressure above ambient over the gridded sphere",
        },
        "runs": [],
    }
    for run in runs:
        result = run_one(case, run, args, p0, rho0)
        out["runs"].append(result)
        reads = ", ".join(f"{t} ms {v['mean_overpressure_kPa']:.0f} kPa (KE {v['kinetic_energy_fraction']:.3f})"
                          for t, v in result["reads"].items())
        print(f"{run['id']}: energy balance {result['energy_balance_overpressure_kPa']:.0f} kPa; {reads}; "
              f"drift {result['relative_energy_drift']:.2e}; {result['steps']} steps {result['wall_s']} s", flush=True)
    label = args.label or f"closed-room-dr{args.dr * 1000:g}mm"
    out_dir = HERE / "outputs"
    out_dir.mkdir(exist_ok=True)
    (out_dir / f"{label}.json").write_text(json.dumps(out, indent=1) + "\n")


if __name__ == "__main__":
    main()
