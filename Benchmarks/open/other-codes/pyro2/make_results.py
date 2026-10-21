"""Writes Benchmarks/open/results/pyro2-4.5.1.json from the runs' summaries in outputs/.

Standard library only. Run run_free_field.py and run_closed_room.py first (see README.md).

    python3 -I make_results.py [--out PATH]
"""

import argparse
import json
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[3]
OUT = ROOT / "Benchmarks" / "open" / "results" / "pyro2-4.5.1.json"
FREE_FIELD = HERE / "outputs" / "free-field-dr10mm.json"
ROOM_FILES = "closed-room-dr20mm-*.json"  # one file per run, run in parallel
ARRIVAL_LEVEL = "0.5"  # the shock's mid-rise: the first time the overpressure reaches half its peak
ROOM_READ_MS = "80"


def free_field_entry(summary):
    p = summary["parameters"]
    predictions = []
    for quantity, key, scale in (("peak_incident_overpressure", "peak_Pa", 1e-3),
                                 ("incident_positive_impulse", "impulse_Pa_s", 1.0),
                                 ("arrival_time", None, 1e3)):
        for g in summary["gauges"]:
            value = g["arrival_s"][ARRIVAL_LEVEL] if key is None else g[key]
            unit = {"peak_incident_overpressure": "kPa", "incident_positive_impulse": "kPa*ms",
                    "arrival_time": "ms"}[quantity]
            predictions.append({"run": summary["run"], "gauge": g["gauge"], "quantity": quantity, "unit": unit,
                                "value": round(value * scale, 4 if quantity == "arrival_time" else 2)})
    configuration = (
        f"pyro2 {summary['code']['version']} compressible solver (second-order unsplit CTU, CGF Riemann "
        f"solver, fourth-order limiter, flattening, artificial viscosity 0.1, CFL 0.8). 1-D spherical: a "
        f"SphericalPolar wedge one cell wide about the equator with reflecting faces, the case's 100 kg "
        f"hemisphere on rigid ground run as the {p['sphere_mass_kg']:g} kg sphere it is half of, every gauge at "
        f"its distance from the charge's centre. Radial cells {p['dr_m'] * 1000:g} mm from r = {p['r_in_m']:.4f} m "
        f"(a reflecting wall inside the charge) to {p['r_out_m']:.2f} m (outflow). Charge: a constant-volume "
        f"balloon released at t = 0, its own mass at {p['charge_density_kg_m3']:g} kg/m^3 (radius "
        f"{p['charge_radius_m']:.4f} m) holding {p['specific_energy_J_kg'] / 1e6:g} MJ/kg "
        f"({p['energy_J'] / 1e6:.1f} MJ) as internal energy; one ideal gas, gamma {p['gamma']:g}, for products and air; "
        f"no JWL, no afterburning. Air at {p['ambient_pressure_Pa'] / 1e3:g} kPa and {p['ambient_temperature_C']:g} C "
        f"({p['ambient_density_kg_m3']:.4f} kg/m^3). Peak: the record's largest overpressure; impulse: the integral "
        f"over the contiguous stretch around the peak where the overpressure is positive; arrival: the first time "
        f"the overpressure reaches half its peak.")
    return {
        "case": summary["case"],
        "configuration": configuration,
        "recorded_in": "Benchmarks/open/other-codes/pyro2/outputs/free-field-dr10mm.json",
        "notes": [
            "Run by Benchmarks/open/other-codes/pyro2/run_free_field.py --dr 0.01; the README there gives the "
            "resolution study (40, 20, 10 mm, and 5 mm for the four nearest gauges) and how the arrival moves "
            "with the level that defines it.",
            "Time zero is the balloon's release: the whole charge at once, with no detonation front crossing it.",
        ],
        "predictions": predictions,
    }


def room_entry(summary):
    p = summary["parameters"]
    predictions = []
    for run in summary["runs"]:
        value = run["reads"][ROOM_READ_MS]["mean_overpressure_kPa"]
        predictions.append({"run": run["run"], "gauge": "room", "quantity": "quasi_static_gas_pressure",
                            "unit": "kPa", "value": round(value, 1)})
    first = summary["runs"][0]
    configuration = (
        f"pyro2 {summary['code']['version']} compressible solver, set up as for kb-surface-burst-free-field. Not the "
        f"case's cube: pyro2 has no 3-D grid, so a closed rigid adiabatic sphere of the room's volume "
        f"({first['room_volume_m3']:g} m^3, radius {first['room_sphere_radius_m']:.3f} m), 1-D spherical, the "
        f"charge at its centre as a constant-volume balloon of its own mass at {p['charge_density_kg_m3']:g} kg/m^3 "
        f"holding {p['specific_energy_J_kg'] / 1e6:g} MJ/kg; one ideal gas, gamma {p['gamma']:g}; no afterburning, "
        f"no heat loss. Radial cells about {first['dr_m'] * 1000:.1f} mm. The pressure is the room's volume-mean "
        f"pressure above ambient, read at {ROOM_READ_MS} ms.")
    return {
        "case": summary["case"],
        "configuration": configuration,
        "recorded_in": "Benchmarks/open/other-codes/pyro2/outputs/closed-room-dr20mm-*.json",
        "notes": [
            "Run by Benchmarks/open/other-codes/pyro2/run_closed_room.py --run ID --dr 0.02, one process per run.",
            "Without afterburning the mean pressure is fixed by the energy balance, (gamma - 1) times the charge's "
            "energy over the volume, less the kinetic energy still in the gas; the light charges come out at about "
            "half the curve, which includes the products burning in the room's air.",
            "The sphere focuses its reverberations on the centre where a cube would scatter them; the volume mean "
            "hardly feels that, but a gauge on a wall would.",
        ],
        "predictions": predictions,
    }


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--out", type=Path, default=OUT)
    parser.add_argument("--prepared", default="2026-10-20")
    args = parser.parse_args(argv)
    free_field = json.loads(FREE_FIELD.read_text())
    room = None
    for path in sorted((HERE / "outputs").glob(ROOM_FILES)):
        part = json.loads(path.read_text())
        if room is None:
            room = part
        else:
            room["runs"] += part["runs"]
    order = [f"{x}kg-m3" for x in ("0.25", "0.5", "1", "2", "4")]
    room["runs"].sort(key=lambda run: order.index(run["run"]))
    results = {
        "format": "open-blast-benchmark-results",
        "format_version": 1,
        "code": {"name": "pyro2", "version": free_field["code"]["version"],
                 "url": "https://github.com/python-hydro/pyro2"},
        "prepared": args.prepared,
        "notes": [
            "A second code's run of two cases, to test whether the open benchmark can be run by a code that is not "
            "BombCAD. pyro2 is an open educational finite-volume code (BSD-3-Clause), installed from PyPI as "
            f"pyro-hydro {free_field['code']['version']}; nothing in it was changed.",
            "The input scripts and the runs' summaries are in Benchmarks/open/other-codes/pyro2/; docs/open-benchmark.md "
            "says what the case format left open and what was decided.",
            "No parameter was tuned to the references: the charge is its mass, its density and 4.184 MJ/kg, the "
            "gas air's gamma.",
        ],
        "cases": [free_field_entry(free_field), room_entry(room)],
    }
    args.out.write_text(json.dumps(results, indent=2) + "\n")
    print(f"wrote {args.out}")


if __name__ == "__main__":
    main()
