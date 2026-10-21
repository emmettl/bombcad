"""Version-one runnable decks and shared constants. Standard library only.
python3 -I Scripts/open-benchmark/protocol.py [--out DIR]
These are numerical controls, not revised measurements or BombCAD defaults.
"""
import argparse
import hashlib
import json
import math
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CASES = ROOT / 'Benchmarks/open/cases'
DECKS = ROOT / 'Benchmarks/open/decks'
PROTOCOL = 'ideal-gas-balloon-v1'
IDS = ('kb-surface-burst-free-field', 'ufc-closed-room-gas-pressure')


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def source_cells(counts, dx, centre, radius, mass):
    """8^3 midpoint volume fractions, then normalise to exact represented mass and energy."""
    weights = []
    ranges = [range(max(0, math.floor((c-radius)/dx)), min(n, math.ceil((c+radius)/dx)))
              for c, n in zip(centre, counts)]
    for k in ranges[2]:
        for j in ranges[1]:
            for i in ranges[0]:
                hits = sum(sum(((cell+(s+0.5)/8)*dx-c)**2
                               for cell, s, c in zip((i,j,k), (a,b,d), centre)) < radius**2
                           for a in range(8) for b in range(8) for d in range(8))
                if hits:
                    weights.append(([i,j,k], hits))
    total = sum(hits for _, hits in weights)
    if not total:
        raise ValueError('source unresolved by quadrature')
    return [{'index': index, 'density_kg_m3': 1.225 + mass*(1-1.225/1600)*hits/total/dx**3,
             'internal_energy_J_m3': 101325/0.4 + mass*4184000*hits/total/dx**3}
            for index, hits in weights]


def deck(case_id):
    case = json.loads((CASES / f'{case_id}.json').read_text())
    room = case_id == IDS[1]
    counts, dx = ([24]*3, 0.25) if room else ([128]*3, 0.5)
    runs = []
    for run in case['runs']:
        mass = run['charges'][0]['mass_kg']
        # Hemisphere of 100 kg -> full sphere of 200 kg -> one octant of 25 kg.
        represented = mass if room else mass/4
        sphere_mass = mass if room else mass*2
        centre = [3,3,3] if room else [0,0,0]
        radius = (3*sphere_mass/(4*math.pi*1600))**(1/3)
        runs.append({'id': run['id'], 'source': {
            'reference_charge_kg': mass, 'represented_charge_kg': represented,
            'centre_m': centre, 'radius_m': radius,
            'excess_energy_J': represented*4184000,
            'excess_mass_kg': represented*(1-1.225/1600)},
            'initial_cells': source_cells(counts, dx, centre, radius, represented),
            'gauges': [{'id': g['id'], 'position_m': g['position_m']} for g in run['gauges']]})
    return {'format': 'open-blast-benchmark-deck', 'format_version': 1, 'protocol': PROTOCOL,
            'case_id': case_id, 'case_sha256': digest(CASES / f'{case_id}.json'),
            'ambient': {'pressure_Pa': 101325, 'density_kg_m3': 1.225},
            'physics': {'eos': 'ideal-gas', 'gamma': 1.4, 'afterburning': False,
                        'gravity': False, 'radiation': False, 'mapped_start': False},
            'numerics': {'riemann_solver': 'HLLC', 'limiter_theta': 1.5, 'cfl': 0.45,
                         'startup_steps': 6, 'density_floor': 1e-6, 'pressure_floor_Pa': 1e-3},
            'mesh': {'counts': counts, 'cell_size_m': dx, 'origin_m': [0,0,0]},
            'boundaries': {'reflecting_faces': [0,1,2,3,4,5] if room else [0,2,4],
                           'other_faces': 'zero-gradient'},
            'sampling': {'interval_s': 0.00005, 'stop_s': 0.12 if room else 0.1,
                         'time_tolerance_s': 2e-8,
                         'observable': 'volume-mean-overpressure' if room else 'trilinear-cell-centre-overpressure'},
            'extraction': {'kind': 'room-window', 'window_s': [0.1,0.12]} if room else {
                'kind': 'first-positive-phase', 'arrival_peak_fraction': 0.5, 'zero_deadband_Pa': 0.1},
            'runs': runs}


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--out', type=Path, default=DECKS)
    args = ap.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    for case_id in IDS:
        (args.out/f'{case_id}.json').write_text(json.dumps(deck(case_id), indent=2)+'\n')


if __name__ == '__main__':
    main()
