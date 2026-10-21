"""kb-surface-burst-free-field as a 2-D axisymmetric surface burst over rigid ground, in PyClaw.

The ideal-gas-balloon-v1 deck's physics on an r-z grid: x is the radius from the charge's
vertical axis, y the height above the ground. The axis (x = 0) and the ground (y = 0) reflect;
the outer faces copy the adjacent cell (PyClaw's extrap, the deck's zero-gradient outflow).
The geometric source terms of cylindrical symmetry are added each step by the two-stage
Runge-Kutta step of PyClaw's shock-bubble example. Gauges are read with the deck's rule, every
step and at the deck's 50 microsecond targets, and the targets are written as the deck's CSV.

    python blast_axi.py --dx 0.125 --label free-field-dx125mm [--history-dir DIR]
    python blast_axi.py --dx 0.03125 --extent 14 --tmax 0.018 --gauges Z0.75 Z1 Z1.5 Z2 --label ...

Needs clawpack (PyClaw) and NumPy; see README.md.
"""

import argparse
import csv
import importlib.util
import json
import math
import platform
import sys
import time
from pathlib import Path

import numpy as np
import clawpack
from clawpack import pyclaw, riemann

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[3]
CASE_ID = 'kb-surface-burst-free-field'
RUN_ID = '100kg'


def load_run_decks():
    spec = importlib.util.spec_from_file_location('run_decks', ROOT / 'Scripts/open-benchmark/run_decks.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


run_decks = load_run_decks()
protocol = run_decks.protocol


def axisymmetric_source(nr, nz, dx, radius, mass, density, specific_energy, ambient_density, samples=8):
    """The deck's source rule on r-z cells: midpoint samples strictly inside the sphere, each
    weighted by its radius (the volume it stands for), normalised over all source cells; then the
    represented mass's excess and its energy spread by those weights over the cells' volumes."""
    cells = []
    top = min(nr, math.ceil(radius / dx)), min(nz, math.ceil(radius / dx))
    offsets = (np.arange(samples) + 0.5) / samples
    for i in range(top[0]):
        rs = (i + offsets) * dx
        for j in range(top[1]):
            zs = (j + offsets) * dx
            inside = rs[:, None] ** 2 + zs[None, :] ** 2 < radius ** 2
            weight = float((inside * rs[:, None]).sum())
            if weight:
                cells.append((i, j, weight))
    total = sum(w for _, _, w in cells)
    out = []
    for i, j, w in cells:
        volume = 2 * math.pi * (i + 0.5) * dx * dx * dx
        share = w / total
        out.append((i, j, mass * (1 - ambient_density / density) * share / volume,
                    mass * specific_energy * share / volume))
    return out


def step_euler_radial(solver, state, dt):
    """Geometric source terms of cylindrical symmetry, x the radius: two-stage Runge-Kutta, as in
    clawpack/pyclaw/examples/euler_2d/shock_bubble_interaction.py with the axes exchanged."""
    gamma = state.problem_data['gamma']
    q = state.q
    rad = state.aux[0]

    def rates(q):
        rho = q[0]
        u = q[1] / rho
        v = q[2] / rho
        press = (gamma - 1.0) * (q[3] - 0.5 * rho * (u ** 2 + v ** 2))
        return np.stack([q[1], rho * u * u, rho * u * v, u * (q[3] + press)]) / rad

    qstar = q - 0.5 * dt * rates(q)
    q -= dt * rates(qstar)


class Floors:
    """The deck's density and pressure floors, applied after each step's source term. Roe's
    linearisation can overshoot to negative pressure in the near-vacuum the balloon leaves at
    its centre; the floors keep the next step's Riemann problems physical. What they add is
    counted, so the run can say how much mass and energy came from them."""

    def __init__(self, rho_floor, p_floor, volume, source=step_euler_radial):
        self.rho_floor, self.p_floor, self.volume, self.source = rho_floor, p_floor, volume, source
        self.mass = self.energy = 0.0
        self.cells = 0

    def __call__(self, solver, state, dt):
        if self.source:
            self.source(solver, state, dt)
        gamma = state.problem_data['gamma']
        q = state.q
        energy_index = q.shape[0] - 1
        thin = q[0] < self.rho_floor
        if thin.any():
            self.mass += float(((self.rho_floor - q[0][thin]) * self.volume[thin]).sum())
            q[0][thin] = self.rho_floor
        kinetic = 0.5 * (q[1:energy_index] ** 2).sum(axis=0) / q[0]
        low = q[energy_index] - kinetic < self.p_floor / (gamma - 1)
        if low.any():
            energy = self.p_floor / (gamma - 1) + kinetic[low]
            self.energy += float(((energy - q[energy_index][low]) * self.volume[low]).sum())
            self.cells += int(low.sum())
            q[energy_index][low] = energy


class Gauges:
    """The deck's observable on r-z cells: pressure (not conserved state) interpolated between
    cell centres, the fractional cell coordinate position/dx - 0.5, each neighbour clamped to
    the domain. A ground gauge (z = 0) reads the first row of cells."""

    def __init__(self, gauges, dx, nr, nz, gamma, p0):
        self.ids = [g['id'] for g in gauges]
        self.gamma, self.p0 = gamma, p0
        self.stencils = []
        for g in gauges:
            r = math.hypot(g['position_m'][0], g['position_m'][1])
            z = g['position_m'][2]
            stencil = []
            for coord, n in ((r, nr), (z, nz)):
                f = coord / dx - 0.5
                lo = math.floor(f)
                w = f - lo
                stencil.append([(min(max(lo, 0), n - 1), 1 - w), (min(max(lo + 1, 0), n - 1), w)])
            self.stencils.append([(i, j, wi * wj) for i, wi in stencil[0] for j, wj in stencil[1]])

    def read(self, q):
        values = []
        for stencil in self.stencils:
            p = 0.0
            for i, j, w in stencil:
                rho, mr, mz, e = q[0, i, j], q[1, i, j], q[2, i, j], q[3, i, j]
                p += w * (self.gamma - 1) * (e - 0.5 * (mr * mr + mz * mz) / rho)
            values.append(p - self.p0)
        return values


def totals(state, dx):
    """Mass and total energy in the domain, each cell 2 pi r dr dz."""
    volume = 2 * math.pi * state.aux[0] * dx * dx
    return float((state.q[0] * volume).sum()), float((state.q[3] * volume).sum())


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--dx', type=float, required=True, help='cell size in r and z, m')
    ap.add_argument('--extent', type=float, default=48.0, help='domain size in r and in z, m')
    ap.add_argument('--tmax', type=float, help='stop, s (default: the deck\'s)')
    ap.add_argument('--gauges', nargs='*', help='gauge ids (default: all)')
    ap.add_argument('--solver', choices=['roe', 'hlle'], default='roe')
    ap.add_argument('--label', required=True)
    ap.add_argument('--history-dir', type=Path, help='write the deck-format CSV here (full runs only)')
    ap.add_argument('--steps-csv', type=Path, help='write every step\'s gauge pressures here')
    ap.add_argument('--directions', action='store_true',
                    help='also read each gauge\'s distance at 45 degrees above the ground and on the axis')
    ap.add_argument('--startup-steps', type=int, default=0,
                    help='first-order steps before second order (the deck names 6 for BombCAD\'s adapter)')
    args = ap.parse_args(argv)

    deck = protocol.deck(CASE_ID)
    run = next(r for r in deck['runs'] if r['id'] == RUN_ID)
    gamma = deck['physics']['gamma']
    p0 = deck['ambient']['pressure_Pa']
    rho0 = deck['ambient']['density_kg_m3']
    stop = deck['sampling']['stop_s'] if args.tmax is None else args.tmax
    interval = deck['sampling']['interval_s']
    gauges = [g for g in run['gauges'] if not args.gauges or g['id'] in args.gauges]
    full = stop == deck['sampling']['stop_s'] and len(gauges) == len(run['gauges'])
    if args.history_dir and not full:
        ap.error('a deck-format history needs every gauge and the deck\'s stop')

    # The hemisphere on rigid ground: the upper half of the 200 kg sphere, 100 kg, all 2 pi of it.
    src = run['source']
    hemisphere_mass = src['reference_charge_kg']
    radius = src['radius_m']
    n = int(round(args.extent / args.dx))
    if abs(n * args.dx - args.extent) > 1e-9:
        ap.error('--extent must be a whole number of cells')

    rs = riemann.euler_4wave_2D if args.solver == 'roe' else riemann.euler_hlle_2D
    solver = pyclaw.ClawSolver2D(rs)
    solver.num_waves = 4 if args.solver == 'roe' else 2
    solver.num_eqn = 4
    solver.limiters = pyclaw.limiters.tvd.MC
    solver.source_split = 1
    solver.cfl_desired = deck['numerics']['cfl']
    solver.cfl_max = 0.5
    solver.dt_initial = solver.dt = 1e-7   # dt_initial alone is applied only by pyclaw.Controller
    solver.dimensional_split = False   # PyClaw's default (True) failed: see README
    solver.transverse_waves = 2
    solver.max_steps = 10 ** 7
    # PyClaw accepts a step unless cfl > cfl_max, which a NaN never is: reject those too.
    solver.accept_reject_step = lambda state: math.isfinite(solver.cfl.get_cached_max()) and \
        solver.cfl.get_cached_max() <= solver.cfl_max
    solver.bc_lower[0] = pyclaw.BC.wall      # the axis
    solver.bc_upper[0] = pyclaw.BC.extrap
    solver.bc_lower[1] = pyclaw.BC.wall      # the ground
    solver.bc_upper[1] = pyclaw.BC.extrap
    solver.aux_bc_lower[0] = solver.aux_bc_upper[0] = pyclaw.BC.extrap
    solver.aux_bc_lower[1] = solver.aux_bc_upper[1] = pyclaw.BC.extrap

    domain = pyclaw.Domain([pyclaw.Dimension(0.0, args.extent, n, name='r'),
                            pyclaw.Dimension(0.0, args.extent, n, name='z')])
    state = pyclaw.State(domain, 4, 1)
    state.problem_data['gamma'] = gamma
    state.problem_data['gamma1'] = gamma - 1
    state.aux[0] = state.grid.c_centers[0]
    state.q[0] = rho0
    state.q[1] = state.q[2] = 0.0
    state.q[3] = p0 / (gamma - 1)
    cells = axisymmetric_source(n, n, args.dx, radius, hemisphere_mass, 1600.0, 4184000.0, rho0)
    for i, j, drho, de in cells:
        state.q[0, i, j] += drho
        state.q[3, i, j] += de
    solution = pyclaw.Solution(state, domain)
    floors = Floors(deck['numerics']['density_floor'], deck['numerics']['pressure_floor_Pa'],
                    2 * math.pi * state.aux[0] * args.dx * args.dx)
    solver.step_source = floors
    mass0, energy0 = totals(state, args.dx)
    ambient_volume = math.pi * args.extent ** 3
    excess_mass = mass0 - rho0 * ambient_volume
    excess_energy = energy0 - p0 / (gamma - 1) * ambient_volume

    extra = []
    if args.directions:
        # Off the ground: the same distance from the charge, at 45 degrees and straight up the axis.
        for g in gauges:
            d = g['position_m'][0]
            extra.append({'id': f"{g['id']}@45deg", 'position_m': [d / math.sqrt(2), 0, d / math.sqrt(2)]})
            extra.append({'id': f"{g['id']}@axis", 'position_m': [0, 0, d]})
    probe = Gauges(gauges + extra, args.dx, n, n, gamma, p0)
    main_ids = [g['id'] for g in gauges]
    steps = [(0.0, probe.read(state.q))]

    def before_step(solver, state):
        # PyClaw reads the order from _method, built at setup; a startup step is first order.
        solver._method[1] = 1 if solver.status['numsteps'] < args.startup_steps else 2
        if state.t > steps[-1][0]:
            steps.append((state.t, probe.read(state.q)))

    solver.before_step = before_step
    solver.setup(solution)

    targets = [k * interval for k in range(int(round(stop / interval)) + 1)]
    samples = [(0.0, probe.read(state.q))]
    budget = []
    started = time.time()
    for k, target in enumerate(targets[1:], 1):
        solver.evolve_to_time(solution, target)
        values = probe.read(state.q)
        samples.append((solution.t, values))
        if solution.t > steps[-1][0]:
            steps.append((solution.t, values))
        if k % 20 == 0 or k == len(targets) - 1:
            mass, energy = totals(state, args.dx)
            budget.append({'t_s': solution.t, 'mass_kg': mass, 'energy_J': energy})
            if not np.isfinite(state.q).all() or state.q[0].min() <= 0:
                raise SystemExit(f'non-physical state at t = {solution.t}')
        if k % 200 == 0:
            print(f'{args.label}: t = {solution.t * 1e3:.2f} ms, {solver.status["numsteps"]} steps, '
                  f'{time.time() - started:.0f} s', flush=True)
    wall = time.time() - started

    def reads(trace, ids=main_ids):
        out = {}
        for idx, gid in enumerate(probe.ids):
            if gid not in ids:
                continue
            series = [(t, v[idx]) for t, v in trace]
            try:
                values, info = run_decks.incident(series)
                out[gid] = {**values, **info, 'max_overpressure_kPa': max(p for _, p in series) / 1000}
            except ValueError as error:
                out[gid] = {'error': str(error), 'max_overpressure_kPa': max(p for _, p in series) / 1000}
        return out

    q = state.q
    rho = q[0]
    pressure = (gamma - 1) * (q[3] - 0.5 * (q[1] ** 2 + q[2] ** 2) / rho)
    summary = {
        'case': CASE_ID, 'run': RUN_ID, 'label': args.label,
        'code': {'name': 'Clawpack (PyClaw)', 'version': clawpack.__version__},
        'python': platform.python_version(), 'numpy': np.__version__,
        'parameters': {
            'geometry': '2-D axisymmetric r-z, x = radius, y = height; axis and ground reflecting (PyClaw wall), outer faces extrap',
            'cell_m': args.dx, 'cells': [n, n], 'extent_m': args.extent, 'stop_s': stop,
            'riemann_solver': 'euler_4wave_2D (Roe, entropy fix)' if args.solver == 'roe' else 'euler_hlle_2D',
            'limiter': 'MC', 'transverse_waves': 2, 'first_order_startup_steps': args.startup_steps, 'cfl_desired': solver.cfl_desired, 'cfl_max': solver.cfl_max,
            'source_split': 'Godunov, geometric source by two-stage Runge-Kutta',
            'dimensional_split': False,
            'density_floor_kg_m3': floors.rho_floor, 'pressure_floor_Pa': floors.p_floor,
            'gamma': gamma, 'ambient_pressure_Pa': p0, 'ambient_density_kg_m3': rho0,
            'hemisphere_mass_kg': hemisphere_mass, 'charge_radius_m': radius,
            'source_cells': len(cells), 'sample_interval_s': interval,
        },
        'budget': {
            'excess_mass_kg_initial': excess_mass,
            'excess_mass_kg_declared': hemisphere_mass * (1 - rho0 / 1600),
            'excess_energy_J_initial': excess_energy,
            'excess_energy_J_declared': hemisphere_mass * 4184000,
            'total_mass_final_over_initial': budget[-1]['mass_kg'] / mass0,
            'total_energy_final_over_initial': budget[-1]['energy_J'] / energy0,
            'excess_energy_final_over_initial': (budget[-1]['energy_J'] - energy0 + excess_energy) / excess_energy,
            'floor_mass_added_kg': floors.mass, 'floor_energy_added_J': floors.energy,
            'floored_cell_steps': floors.cells,
            'max_overpressure_at_outer_faces_final_Pa': float(max(pressure[-1, :].max(), pressure[:, -1].max()) - p0),
        },
        'steps': solver.status['numsteps'], 'wall_s': round(wall, 1),
        'excess_energy_over_declared': [[round(b['t_s'], 6), (b['energy_J'] - energy0 + excess_energy) / excess_energy]
                                         for b in budget],
        'gauges_at_samples': reads(samples),
        'gauges_every_step': reads(steps),
        **({'directions_at_samples': reads(samples, [g['id'] for g in extra]),
            'directions_every_step': reads(steps, [g['id'] for g in extra])} if extra else {}),
    }
    out = HERE / 'outputs' / f'{args.label}.json'
    out.parent.mkdir(exist_ok=True)
    out.write_text(json.dumps(summary, indent=1) + '\n')
    if args.steps_csv:
        with args.steps_csv.open('w', newline='') as stream:
            writer = csv.writer(stream)
            writer.writerow(['time_s'] + probe.ids)
            for t, values in steps:
                writer.writerow([repr(float(t))] + [repr(float(v)) for v in values])
    if args.history_dir:
        args.history_dir.mkdir(parents=True, exist_ok=True)
        with (args.history_dir / f'{CASE_ID}--{RUN_ID}.csv').open('x', newline='') as stream:
            writer = csv.writer(stream, lineterminator='\n')
            writer.writerow(['case', 'run', 'gauge', 'time_s', 'overpressure_Pa'])
            for t, values in samples:
                for gid, value in zip(main_ids, values):
                    writer.writerow([CASE_ID, RUN_ID, gid, repr(float(t)), repr(float(value))])
    print(f'{args.label}: done, {solver.status["numsteps"]} steps, {wall:.0f} s', flush=True)
    return 0


if __name__ == '__main__':
    sys.exit(main())
