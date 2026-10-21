"""Writes Benchmarks/open/results/clawpack-5.14.0.json from the histories in histories/.

Standard library only. The histories were imported with the protocol's own tool
(Scripts/open-benchmark/run_decks.py import, which wrote histories/receipt.json and the deck
copies); this extracts them with the same tool and the deck's read rules, then replaces the
extractor's one-word configuration with what the runs actually were, since the free field is not
the deck's mesh. See README.md.

    python3 -I make_results.py [--out PATH]
"""

import argparse
import importlib.util
import json
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[3]
OUT = ROOT / 'Benchmarks' / 'open' / 'results' / 'clawpack-5.14.0.json'
HISTORIES = HERE / 'histories'
FREE_FIELD = HERE / 'outputs' / 'free-field-dx0.0625.json'
ROOM = 'room-n24-{run}.json'

spec = importlib.util.spec_from_file_location('run_decks', ROOT / 'Scripts/open-benchmark/run_decks.py')
run_decks = importlib.util.module_from_spec(spec)
spec.loader.exec_module(run_decks)


def free_field(case):
    s = json.loads(FREE_FIELD.read_text())
    p, b = s['parameters'], s['budget']
    case['configuration'] = (
        f"Clawpack {s['code']['version']} PyClaw ClassicClaw, unsplit wave propagation with transverse correction "
        f"waves, Roe solver with entropy fix (riemann.euler_4wave_2D), MC limiter, CFL {p['cfl_desired']:g} "
        f"(rejected above {p['cfl_max']:g}); the deck's density and pressure floors. NOT the deck's mesh: 2-D "
        f"axisymmetric r-z, {p['cell_m'] * 1000:g} mm square cells, {p['extent_m']:g} m in r and z; the axis "
        f"and the rigid ground reflect, the outer faces extrapolate (zero gradient). Geometric source terms of "
        f"cylindrical symmetry by a two-stage Runge-Kutta step, Godunov-split. The deck's balloon (1600 kg/m^3, "
        f"4.184 MJ/kg, gamma 1.4, released at t = 0, its mass and excess energy added to ambient air) built "
        f"by the deck's sampling rule on r-z cells, each midpoint sample weighted by its radius; the 100 kg "
        f"hemisphere, radius {p['charge_radius_m']:.4f} m. The deck's observable (pressure interpolated "
        f"between cell centres, clamped, so a ground gauge reads the first row of cells), 50 us samples to "
        f"{p['stop_s'] * 1000:g} ms, and its read rules.")
    case['recorded_in'] = 'Benchmarks/open/other-codes/clawpack/outputs/free-field-dx0.0625.json'
    case['notes'] = [
        'A deviation from ideal-gas-balloon-v1, not an import of it: the deck fixes a 3-D Cartesian octant on '
        '0.5 m cells and its discrete start; this is the same physics on a 2-D axisymmetric mesh.',
        'The hemisphere is centred on the rigid ground, so the ground is a plane of symmetry: the reflected '
        'wave is the mirror image of the incident one, and the exact solution is the free-air sphere\'s. The '
        'run tests a 2-D grid with the ground as a boundary, not a different physics.',
        f"The cylindrical source terms are not conservative: the domain gained {b['excess_energy_final_over_initial'] - 1:.2%} "
        f"of the charge's energy by the stop ({b['floor_energy_added_J'] / b['excess_energy_J_declared']:.3%} from the "
        "floors), most of it in the first millisecond; see the README's mesh study.",
    ] + case['notes']


def room(case):
    configs = {}
    for prediction in case['predictions']:
        configs[prediction['run']] = json.loads((HERE / 'outputs' / ROOM.format(run=prediction['run'])).read_text())
    s = next(iter(configs.values()))
    p = s['parameters']
    gains = [c['budget']['excess_energy_final_over_initial'] - 1 for c in configs.values()]
    case['configuration'] = (
        f"Clawpack {s['code']['version']} PyClaw ClassicClaw 3-D, unsplit wave propagation with transverse "
        f"increment and correction waves, Roe solver with entropy fix (riemann.euler_3D), MC limiter, CFL "
        f"{p['cfl_desired']:g} (rejected above {p['cfl_max']:g}); the deck's density and pressure floors. The "
        f"deck's mesh (the whole 6 m cube, 24 cells a side), walls on all six faces, the deck's initial_cells "
        f"as given, its volume-mean observable, 50 us samples to 120 ms, and its 100-120 ms window. Differs from "
        f"the deck only in the numerics it names for BombCAD's adapter (Roe and MC, not HLLC with limiter "
        f"theta 1.5; no startup steps).")
    case['recorded_in'] = 'Benchmarks/open/other-codes/clawpack/outputs/room-n24-*.json'
    case['notes'] = [
        f"Total energy rose by {min(gains):.3%} to {max(gains):.3%} of the charge's over the 120 ms, all of it "
        "from the deck's pressure floor in the near-vacuum at the charge's centre; the scheme itself conserves it.",
    ] + case['notes']


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--out', type=Path, default=OUT)
    args = ap.parse_args(argv)
    result, diagnostics = run_decks.extract(HISTORIES)
    for case in result['cases']:
        {'kb-surface-burst-free-field': free_field, 'ufc-closed-room-gas-pressure': room}[case['case']](case)
    result['code']['url'] = 'https://www.clawpack.org'
    result['notes'] = [
        'Clawpack 5.14.0 from PyPI (sdist sha256 b9f3208fe9e1d834122ae86e2af536a3010435d0d65e6629f360416ea9cffe89), '
        'built with gfortran 13.3 and used unchanged; the drivers are '
        'Benchmarks/open/other-codes/clawpack/blast_axi.py and room3d.py.',
        'The ideal-gas balloon of ideal-gas-balloon-v1: no afterburning, radiation, gravity or mapped start. '
        'Histories imported and extracted with Scripts/open-benchmark/run_decks.py; receipt and hashes in '
        'Benchmarks/open/other-codes/clawpack/histories/.',
    ]
    args.out.write_text(json.dumps(result, indent=2) + '\n')
    (HERE / 'outputs' / 'diagnostics.json').write_text(json.dumps(diagnostics, indent=1, sort_keys=True) + '\n')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
