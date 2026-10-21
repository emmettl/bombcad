"""The free field's mesh study and the room's, from the runs' summaries in outputs/.

Standard library only. Prints Markdown tables and writes outputs/mesh-study.json.

For each gauge and quantity: the value on each mesh, read by the deck's rule from the 50
microsecond samples; the observed order from the three finest meshes, p = log2((f4h - f2h) /
(f2h - fh)), when the changes keep their sign; and, where 0.5 <= p <= 4, the Richardson estimate
fh + (fh - f2h) / (2^p - 1). Beside them, pyro2's 1-D spherical run of the same balloon (10 mm,
its 50 microsecond history read by the same rule), the converged 1-D answer the 2-D run should
approach if the ground adds nothing.

    python3 -I mesh_study.py
"""

import csv
import importlib.util
import json
import math
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[3]
OUT = HERE / 'outputs'
QUANTITIES = (('peak_incident_overpressure', 'peak, kPa', 0),
              ('incident_positive_impulse', 'impulse, kPa ms', 0),
              ('arrival_time', 'arrival, ms', 2))

spec = importlib.util.spec_from_file_location('run_decks', ROOT / 'Scripts/open-benchmark/run_decks.py')
run_decks = importlib.util.module_from_spec(spec)
spec.loader.exec_module(run_decks)


def pyro2_reads():
    path = ROOT / 'Benchmarks/open/other-codes/pyro2/outputs/free-field-dr10mm-history.csv'
    with path.open() as stream:
        rows = list(csv.reader(stream))
    gauges = [h.split('_')[0] for h in rows[0][1:]]
    out = {}
    for col, gauge in enumerate(gauges, 1):
        trace = [(float(r[0]) / 1000, float(r[col]) * 1000) for r in rows[1:]]
        out[gauge] = run_decks.incident(trace)[0]
    return out


def order(values):
    """values: coarse to fine. The observed order and the Richardson estimate from the last three."""
    if len(values) < 3:
        return None, None
    a, b, c = values[-3:]
    if (b - a) == 0 or (c - b) == 0 or (b - a) * (c - b) < 0:
        return None, None
    p = math.log(abs(b - a) / abs(c - b), 2)
    if not 0.5 <= p <= 4:
        return p, None
    return p, c + (c - b) / (2 ** p - 1)


def series(prefix):
    runs = []
    for path in sorted(OUT.glob(f'{prefix}*.json')):
        summary = json.loads(path.read_text())
        runs.append(summary)
    return sorted(runs, key=lambda s: -s['parameters']['cell_m'])


def fmt(value, digits):
    return '–' if value is None else f'{value:,.{digits}f}'


def free_field():
    full = series('free-field-dx')
    near = series('near-dx')
    reference = pyro2_reads()
    report = {}
    lines = []
    for quantity, title, digits in QUANTITIES:
        lines.append(f'\n**{title}** (deck rule, 50 µs samples)\n')
        cells = [f"{s['parameters']['cell_m'] * 1000:g} mm" for s in full]
        near_cells = [f"{s['parameters']['cell_m'] * 1000:g} mm near" for s in near]
        lines.append('| Gauge | ' + ' | '.join(cells + near_cells) + ' | p | Richardson | pyro2 1-D 10 mm |')
        lines.append('|---' * (len(cells) + len(near_cells) + 4) + '|')
        for gauge in full[0]['gauges_at_samples']:
            values = [s['gauges_at_samples'][gauge].get(quantity) for s in full]
            near_values = [s['gauges_at_samples'][gauge].get(quantity) for s in near
                           if gauge in s['gauges_at_samples']]
            # The study's ladder: the full-domain meshes, then the near-field meshes finer than them.
            finest_full = full[-1]['parameters']['cell_m']
            ladder = values + [v for s, v in zip([s for s in near if gauge in s['gauges_at_samples']], near_values)
                               if s['parameters']['cell_m'] < finest_full]
            p, rich = order(ladder)
            ref = reference[gauge][quantity]
            report.setdefault(gauge, {})[quantity] = {
                'cells_m': [s['parameters']['cell_m'] for s in full],
                'values': values,
                'near_cells_m': [s['parameters']['cell_m'] for s in near if gauge in s['gauges_at_samples']],
                'near_values': near_values, 'observed_order': p, 'richardson': rich, 'pyro2_1d_10mm': ref}
            row = [fmt(v, digits) for v in values]
            row += [fmt(v, digits) for v in near_values] + ['–'] * (len(near) - len(near_values))
            lines.append(f'| {gauge} | ' + ' | '.join(row) + f' | {fmt(p, 2)} | {fmt(rich, digits)} | {fmt(ref, digits)} |')
    lines.append('\n**Energy** (the domain\'s total energy gained, as a share of the charge\'s 418.4 MJ, at the stop)\n')
    lines.append('| Run | Cells | Steps | Wall, s | Energy gained | of which floors |')
    lines.append('|---|---|---|---|---|---|')
    for s in full + near:
        b = s['budget']
        lines.append(f"| {s['label']} | {s['parameters']['cells'][0]}² | {s['steps']:,} | {s['wall_s']:,.0f} | "
                     f"{b['excess_energy_final_over_initial'] - 1:+.2%} | "
                     f"{b['floor_energy_added_J'] / b['excess_energy_J_declared']:.3%} |")
    return report, lines


def room():
    lines = ['\n**Room**: the 100–120 ms volume-mean overpressure, kPa (relative half-window drift)\n']
    runs = {}
    for path in sorted(OUT.glob('room-*.json')):
        s = json.loads(path.read_text())
        runs.setdefault(s['run'], {})[(s['parameters']['cells_per_side_of_cube'],
                                       'octant' in s['parameters']['geometry'])] = s
    meshes = sorted({k for r in runs.values() for k in r})
    header = [f"{n}³{' octant' if octant else ''}" for n, octant in meshes]
    lines.append('| Run | Energy bound | ' + ' | '.join(header) + ' |')
    lines.append('|---' * (len(header) + 2) + '|')
    report = {}
    for run in sorted(runs, key=lambda r: float(r.split('kg')[0])):
        cells = []
        for key in meshes:
            s = runs[run].get(key)
            cells.append('–' if s is None else f"{s['window_mean_kPa']:,.1f} ({s['relative_half_window_drift']:+.1e})")
            if s:
                report.setdefault(run, {})[f'{key[0]}{"-octant" if key[1] else ""}'] = {
                    'window_mean_kPa': s['window_mean_kPa'], 'drift': s['relative_half_window_drift'],
                    'energy_gain': s['budget']['excess_energy_final_over_initial'] - 1}
        bound = next(iter(runs[run].values()))['energy_bound_kPa']
        lines.append(f'| {run} | {bound:,.1f} | ' + ' | '.join(cells) + ' |')
    return report, lines


def main():
    ff, ff_lines = free_field()
    rm, rm_lines = room()
    print('\n'.join(ff_lines + rm_lines))
    (OUT / 'mesh-study.json').write_text(json.dumps({'free_field': ff, 'room': rm}, indent=1) + '\n')


if __name__ == '__main__':
    main()
