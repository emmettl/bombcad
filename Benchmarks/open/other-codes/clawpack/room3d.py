"""ufc-closed-room-gas-pressure as a 3-D Cartesian run of the closed cube, in PyClaw.

The ideal-gas-balloon-v1 deck on its own terms: on the deck's mesh (24 cells a side) the
initial state is the deck's sparse cells, read from the deck; on a finer mesh it is the same
construction (protocol.source_cells) on that mesh. Every face reflects (PyClaw wall). The
observable is the deck's: the volume-mean pressure over every cell, above ambient, at the deck's
50 microsecond targets to 120 ms, written as the deck's CSV with the gauge id `room`.

--octant solves the cube's eighth [3, 6]^3 with walls on the three planes through the charge's
centre: the room and its source are symmetric about them, so the volume mean is the same.

    python room3d.py --run 1kg-m3 --cells 24 --label room-n24-1kg-m3 [--history-dir DIR]
    python room3d.py --run 1kg-m3 --cells 48 --octant --label room-n48-octant-1kg-m3

Needs clawpack (PyClaw) and NumPy; see README.md.
"""

import argparse
import csv
import json
import math
import platform
import sys
import time

import numpy as np
import clawpack
from clawpack import pyclaw, riemann

from blast_axi import HERE, Floors, protocol, run_decks

CASE_ID = 'ufc-closed-room-gas-pressure'


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--run', required=True)
    ap.add_argument('--cells', type=int, default=24, help='cells along each side of the whole cube')
    ap.add_argument('--octant', action='store_true')
    ap.add_argument('--label', required=True)
    ap.add_argument('--history-dir')
    # MC failed here: Roe's update leaves near-vacuum cells at the centre during the over-expansion,
    # and a floored density holding its energy runs the time step down to nanoseconds.
    ap.add_argument('--limiter', choices=['mc', 'minmod'], default='minmod')
    args = ap.parse_args(argv)

    deck = protocol.deck(CASE_ID)
    run = next(r for r in deck['runs'] if r['id'] == args.run)
    gamma = deck['physics']['gamma']
    p0 = deck['ambient']['pressure_Pa']
    rho0 = deck['ambient']['density_kg_m3']
    stop = deck['sampling']['stop_s']
    interval = deck['sampling']['interval_s']
    side = deck['mesh']['counts'][0] * deck['mesh']['cell_size_m']
    n = args.cells
    dx = side / n
    if args.octant and n % 2:
        ap.error('an octant needs an even number of cells')
    if args.history_dir and args.octant:
        ap.error('the deck-format history is written from whole-cube runs only')

    src = run['source']
    if n == deck['mesh']['counts'][0]:
        cells = run['initial_cells']
        provenance = 'the deck\'s initial_cells'
    else:
        cells = protocol.source_cells([n] * 3, dx, src['centre_m'], src['radius_m'], src['represented_charge_kg'])
        provenance = 'protocol.source_cells on this mesh'

    lo = n // 2 if args.octant else 0
    m = n - lo
    solver = pyclaw.ClawSolver3D(riemann.euler_3D)
    solver.num_waves = 3
    solver.num_eqn = 5
    solver.limiters = pyclaw.limiters.tvd.MC if args.limiter == 'mc' else pyclaw.limiters.tvd.minmod
    solver.dimensional_split = False
    solver.transverse_waves = solver.trans_cor
    solver.cfl_desired = deck['numerics']['cfl']
    solver.cfl_max = 0.5
    solver.dt_initial = solver.dt = 1e-7   # dt_initial alone is applied only by pyclaw.Controller
    solver.max_steps = 10 ** 7
    # PyClaw accepts a step unless cfl > cfl_max, which a NaN never is: reject those too.
    solver.accept_reject_step = lambda state: math.isfinite(solver.cfl.get_cached_max()) and \
        solver.cfl.get_cached_max() <= solver.cfl_max
    for d in range(3):
        solver.bc_lower[d] = solver.bc_upper[d] = pyclaw.BC.wall
    dims = [pyclaw.Dimension(lo * dx, side, m, name=name) for name in 'xyz']
    domain = pyclaw.Domain(dims)
    state = pyclaw.State(domain, 5, 0)
    state.problem_data['gamma'] = gamma
    state.problem_data['gamma1'] = gamma - 1
    state.q[0] = rho0
    state.q[1:4] = 0.0
    state.q[4] = p0 / (gamma - 1)
    placed = 0
    for cell in cells:
        i, j, k = (c - lo for c in cell['index'])
        if min(i, j, k) < 0:
            continue
        state.q[0, i, j, k] = cell['density_kg_m3']
        state.q[4, i, j, k] = cell['internal_energy_J_m3']
        placed += 1
    volume = np.full(state.q.shape[1:], dx ** 3)
    floors = Floors(deck['numerics']['density_floor'], deck['numerics']['pressure_floor_Pa'], volume, source=None)
    solver.step_source = floors
    solver.source_split = 1
    solution = pyclaw.Solution(state, domain)
    solver.setup(solution)

    def mean_overpressure(q):
        kinetic = 0.5 * (q[1] ** 2 + q[2] ** 2 + q[3] ** 2) / q[0]
        return float(((gamma - 1) * (q[4] - kinetic)).mean() - p0), float(kinetic.sum() / q[4].sum())

    room_volume = (m * dx) ** 3
    energy0 = float(state.q[4].sum() * dx ** 3)
    excess0 = energy0 - p0 / (gamma - 1) * room_volume
    declared = src['excess_energy_J'] * (room_volume / side ** 3)
    targets = [k * interval for k in range(int(round(stop / interval)) + 1)]
    first, share = mean_overpressure(state.q)
    samples = [(0.0, first)]
    kinetic_share = {}
    started = time.time()
    for k, target in enumerate(targets[1:], 1):
        solver.evolve_to_time(solution, target)
        value, share = mean_overpressure(state.q)
        samples.append((solution.t, value))
        if k % 200 == 0:
            kinetic_share[f'{target * 1e3:.0f}ms'] = share
            if not np.isfinite(state.q).all():
                raise SystemExit(f'non-finite state at t = {solution.t}')
            print(f'{args.label}: t = {solution.t * 1e3:.1f} ms, {solver.status["numsteps"]} steps, '
                  f'{time.time() - started:.0f} s', flush=True)
    wall = time.time() - started
    energy1 = float(state.q[4].sum() * dx ** 3)

    a, b = deck['extraction']['window_s']
    mean = run_decks.integral(samples, a, b) / (b - a)
    middle = (a + b) / 2
    drift = (run_decks.integral(samples, middle, b) - run_decks.integral(samples, a, middle)) * 2 / (b - a) / mean
    summary = {
        'case': CASE_ID, 'run': args.run, 'label': args.label,
        'code': {'name': 'Clawpack (PyClaw)', 'version': clawpack.__version__},
        'python': platform.python_version(), 'numpy': np.__version__,
        'parameters': {
            'geometry': ('octant [3, 6]^3 of the cube, walls on its six faces' if args.octant
                         else 'the whole 6 m cube, walls on its six faces'),
            'cells_per_side_of_cube': n, 'cell_m': dx, 'cells': [m] * 3, 'initial_state': provenance,
            'source_cells_placed': placed,
            'riemann_solver': 'euler_3D (Roe, entropy fix)', 'limiter': {'mc': 'MC', 'minmod': 'minmod'}[args.limiter], 'dimensional_split': False,
            'transverse_waves': 22, 'cfl_desired': solver.cfl_desired, 'cfl_max': solver.cfl_max,
            'density_floor_kg_m3': floors.rho_floor, 'pressure_floor_Pa': floors.p_floor,
        },
        'budget': {
            'excess_energy_J_initial': excess0, 'excess_energy_J_declared': declared,
            'total_energy_final_over_initial': energy1 / energy0,
            'excess_energy_final_over_initial': (energy1 - energy0 + excess0) / excess0,
            'floor_mass_added_kg': floors.mass, 'floor_energy_added_J': floors.energy,
            'floored_cell_steps': floors.cells,
        },
        'energy_bound_kPa': (gamma - 1) * src['excess_energy_J'] / side ** 3 / 1000,
        'initial_mean_overpressure_kPa': first / 1000,
        'mean_overpressure_kPa': {f'{t * 1e3:.0f}ms': run_decks.interpolate(samples, t) / 1000
                                  for t in (0.01, 0.03, 0.08, 0.1, 0.12)},
        'kinetic_share_of_energy': kinetic_share,
        'window_mean_kPa': mean / 1000, 'relative_half_window_drift': drift,
        'steps': solver.status['numsteps'], 'wall_s': round(wall, 1),
    }
    out = HERE / 'outputs' / f'{args.label}.json'
    out.parent.mkdir(exist_ok=True)
    out.write_text(json.dumps(summary, indent=1) + '\n')
    if args.history_dir:
        from pathlib import Path
        folder = Path(args.history_dir)
        folder.mkdir(parents=True, exist_ok=True)
        with (folder / f'{CASE_ID}--{args.run}.csv').open('x', newline='') as stream:
            writer = csv.writer(stream, lineterminator='\n')
            writer.writerow(['case', 'run', 'gauge', 'time_s', 'overpressure_Pa'])
            for t, value in samples:
                writer.writerow([CASE_ID, args.run, 'room', repr(t), repr(value)])
    print(f'{args.label}: done, {solver.status["numsteps"]} steps, {wall:.0f} s, window mean {mean / 1000:.1f} kPa',
          flush=True)
    return 0


if __name__ == '__main__':
    sys.exit(main())
