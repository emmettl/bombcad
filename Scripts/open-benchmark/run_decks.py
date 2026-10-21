"""Run/import fixed benchmark histories and extract scorer-ready predictions. Stdlib only.
Use --help and Benchmarks/open/decks/README.md. No measurement is used to tune the input.
"""
import argparse
import bisect
import csv
import datetime
import importlib.util
import json
import math
from pathlib import Path
import subprocess
import sys

SPEC = importlib.util.spec_from_file_location('protocol', Path(__file__).with_name('protocol.py'))
protocol = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(protocol)


def write_new(path, obj):
    with Path(path).open('x', encoding='utf-8') as stream:
        json.dump(obj, stream, indent=2, allow_nan=False)
        stream.write('\n')


def selected(case=None, run=None):
    pairs = [(d, r) for cid in protocol.IDS if case is None or cid == case
             for d in [protocol.deck(cid)] for r in d['runs'] if run is None or r['id'] == run]
    if not pairs:
        raise ValueError('No matching case/run')
    return pairs


def filename(deck, run):
    return f"{deck['case_id']}--{run['id']}.csv"


def safe_path(root, name):
    path = (root / name).resolve()
    if path.parent != root.resolve() or Path(name).name != name:
        raise ValueError('Receipt paths must be filenames in the history folder')
    return path


def make_receipt(root, pairs, code, binary=None):
    receipt = {'format': 'open-blast-benchmark-history-receipt', 'format_version': 1,
               'protocol': protocol.PROTOCOL, 'code': code,
               'prepared': datetime.date.today().isoformat(), 'histories': [], 'decks': {},
               'requested_runs': [[d['case_id'], r['id']] for d, r in pairs]}
    if binary:
        receipt['binary_sha256'] = protocol.digest(binary)
    for deck, run in pairs:
        cid = deck['case_id']
        path = root / f'{cid}.deck.json'
        if not path.exists():
            write_new(path, deck)
        if json.loads(path.read_text()) != deck:
            raise ValueError('Deck differs from the frozen protocol')
        receipt['decks'][cid] = {'path': path.name, 'sha256': protocol.digest(path)}
        history = root / filename(deck, run)
        receipt['histories'].append({'case': cid, 'run': run['id'], 'path': history.name,
                                     'sha256': protocol.digest(history)})
    return receipt


def interpolate(trace, time, tolerance=2e-8):
    times = [t for t, _ in trace]
    if time < times[0] - tolerance or time > times[-1] + tolerance:
        raise ValueError('History does not cover the measurement window')
    if time <= times[0]:
        return trace[0][1]
    if time >= times[-1]:
        return trace[-1][1]
    i = bisect.bisect_right(times, time)
    a, b = trace[i-1], trace[i]
    return a[1] + (b[1]-a[1])*(time-a[0])/(b[0]-a[0])


def integral(trace, first, last):
    points = [(first, interpolate(trace, first))]
    points += [(t, p) for t, p in trace if first < t < last]
    points.append((last, interpolate(trace, last)))
    return sum((b[0]-a[0])*(a[1]+b[1])/2 for a, b in zip(points, points[1:]))


def incident(trace):
    # Deadband is fixed in the deck, not chosen from the predicted or reference peak.
    trace = [(t, 0.0 if abs(p) <= 0.1 else p) for t, p in trace]
    peak_i = max(range(len(trace)), key=lambda i: trace[i][1])
    peak = trace[peak_i][1]
    if peak <= 0 or trace[0][1] != 0:
        raise ValueError('Incident history needs an ambient baseline and a positive pulse')
    crossing = next((i for i in range(peak_i) if trace[i][1] <= peak/2 < trace[i+1][1]), None)
    if crossing is None:
        raise ValueError('No rising half-peak arrival')
    a, b = trace[crossing], trace[crossing+1]
    arrival = a[0]+(peak/2-a[1])*(b[0]-a[0])/(b[1]-a[1])
    if any(p <= 0 for _, p in trace[crossing+1:peak_i+1]):
        raise ValueError('Largest peak is not in the first arriving pulse')
    start_i = max(i for i in range(crossing+1) if trace[i][1] <= 0)
    a, b = trace[start_i], trace[start_i+1]
    first = a[0] if a[1] == 0 else a[0]-a[1]*(b[0]-a[0])/(b[1]-a[1])
    end_i = next((i for i in range(peak_i+1, len(trace)) if trace[i][1] <= 0), None)
    if end_i is None:
        raise ValueError('Positive phase is truncated; do not integrate to an arbitrary stop')
    a, b = trace[end_i-1], trace[end_i]
    last = b[0] if b[1] == 0 else a[0]-a[1]*(b[0]-a[0])/(b[1]-a[1])
    impulse = integral(trace, first, last)  # Pa*s numerically equals kPa*ms.
    return {'peak_incident_overpressure': peak/1000, 'incident_positive_impulse': impulse,
            'arrival_time': arrival*1000}, {'phase_start_s': first, 'phase_end_s': last}


def read_history(path, deck, run):
    traces = {g['id']: [] for g in run['gauges']}
    with path.open(newline='') as stream:
        reader = csv.DictReader(stream)
        if reader.fieldnames != ['case', 'run', 'gauge', 'time_s', 'overpressure_Pa']:
            raise ValueError('Wrong CSV columns/order')
        for row in reader:
            if None in row or None in row.values() or row['case'] != deck['case_id'] or row['run'] != run['id'] or row['gauge'] not in traces:
                raise ValueError('Unexpected case, run, gauge, or malformed row')
            t, p = float(row['time_s']), float(row['overpressure_Pa'])
            if not math.isfinite(t) or not math.isfinite(p) or t < 0 or p < -101325.1:
                raise ValueError('Non-finite or nonphysical pressure/time')
            traces[row['gauge']].append((t, p))
    sampling = deck['sampling']
    tol = sampling['time_tolerance_s']
    reference_times = None
    for trace in traces.values():
        if len(trace) < 2 or abs(trace[0][0]) > tol or abs(trace[-1][0]-sampling['stop_s']) > tol:
            raise ValueError('Incomplete history or wrong stop time')
        if any(not 0 < b[0]-a[0] <= sampling['interval_s']+2*tol for a, b in zip(trace, trace[1:])):
            raise ValueError('Nonmonotone, duplicate, or undersampled history')
        times = [t for t, _ in trace]
        if reference_times is not None and times != reference_times:
            raise ValueError('Gauges must share sample times')
        reference_times = times
    return traces


def extract(root):
    receipt = json.loads((root/'receipt.json').read_text())
    if receipt.get('format') != 'open-blast-benchmark-history-receipt' or receipt.get('format_version') != 1 or receipt.get('protocol') != protocol.PROTOCOL:
        raise ValueError('Unsupported receipt')
    code = receipt['code']
    if not isinstance(code, dict) or not all(isinstance(code.get(k), str) and code[k].strip() for k in ['name', 'version']):
        raise ValueError('Code name/version required')
    if set(code) - {'name','version','commit','url'} or not all(isinstance(v, str) for v in code.values()):
        raise ValueError('Unsupported code metadata')
    datetime.date.fromisoformat(receipt['prepared'])
    wanted = {tuple(pair) for pair in receipt['requested_runs']}
    if not wanted or len(wanted) != len(receipt['requested_runs']):
        raise ValueError('Missing or duplicate requested run')
    canonical = {(d['case_id'], r['id']): (d, r) for d, r in selected()}
    seen, cases, diagnostics = set(), {}, {}
    for record in receipt['histories']:
        key = (record['case'], record['run'])
        if key not in canonical or key not in wanted or key in seen:
            raise ValueError('Unexpected or duplicate history')
        seen.add(key)
        deck, run = canonical[key]
        entry = receipt['decks'][key[0]]
        deck_path = safe_path(root, entry['path'])
        if protocol.digest(deck_path) != entry['sha256'] or json.loads(deck_path.read_text()) != deck:
            raise ValueError('Deck hash/content differs from frozen protocol')
        path = safe_path(root, record['path'])
        if protocol.digest(path) != record['sha256']:
            raise ValueError('History hash mismatch')
        traces = read_history(path, deck, run)
        case = cases.setdefault(key[0], {'case': key[0], 'configuration': protocol.PROTOCOL,
                                       'predictions': [], 'notes': []})
        case['notes'].append(f"{key[1]}: deck sha256 {entry['sha256']}; history sha256 {record['sha256']}")
        for gauge, trace in traces.items():
            if deck['extraction']['kind'] == 'room-window':
                a, b = deck['extraction']['window_s']
                mean = integral(trace, a, b)/(b-a)
                if mean <= 0:
                    raise ValueError('Non-positive room mean')
                middle = (a+b)/2
                drift = (integral(trace, middle, b)-integral(trace, a, middle))*2/(b-a)/mean
                values = {'quasi_static_gas_pressure': mean/1000}
                info = {'window_s': [a,b], 'relative_half_window_drift': drift}
                case['notes'].append(f"{key[1]}: fixed 100-120 ms room proxy; relative half-window drift {drift:.6g}; not an assertion of equilibrium")
            else:
                values, info = incident(trace)
            diagnostics['/'.join((*key,gauge))] = info
            for quantity, value in values.items():
                unit = 'ms' if quantity == 'arrival_time' else 'kPa*ms' if quantity.endswith('impulse') else 'kPa'
                case['predictions'].append({'run': key[1], 'gauge': gauge, 'quantity': quantity,
                                            'unit': unit, 'value': value})
    if seen != wanted:
        raise ValueError('Receipt is incomplete')
    notes = ['Frozen ideal-gas balloon control; no afterburning, radiation, gravity or mapped start. Not the historical BombCAD entry.']
    if 'binary_sha256' in receipt:
        notes.append('Binary sha256 '+receipt['binary_sha256'])
    return {'format': 'open-blast-benchmark-results', 'format_version': 1, 'code': code,
            'prepared': receipt['prepared'], 'notes': notes, 'cases': list(cases.values())}, diagnostics


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__)
    sub = ap.add_subparsers(dest='command', required=True)
    for command in ['run', 'import']:
        p = sub.add_parser(command)
        p.add_argument('--out' if command == 'run' else '--histories', type=Path, required=True, dest='root')
        p.add_argument('--case', choices=protocol.IDS)
        p.add_argument('--run')
        p.add_argument('--code-name', default='BombCAD' if command == 'run' else None, required=command == 'import')
        p.add_argument('--code-version', required=True)
        p.add_argument('--code-commit')
        if command == 'run':
            p.add_argument('--binary', type=Path, required=True)
    p = sub.add_parser('extract')
    p.add_argument('--histories', type=Path, required=True, dest='root')
    p.add_argument('--out', type=Path, required=True)
    p.add_argument('--diagnostics', type=Path)
    args = ap.parse_args(argv)
    try:
        if args.command == 'extract':
            result, diagnostics = extract(args.root)
            if args.diagnostics and args.diagnostics.exists():
                raise ValueError('Refusing to overwrite diagnostics')
            write_new(args.out, result)
            if args.diagnostics:
                write_new(args.diagnostics, diagnostics)
        else:
            pairs = selected(args.case, args.run)
            if (args.root/'receipt.json').exists():
                raise ValueError('Refusing to overwrite receipt')
            code = {'name': args.code_name, 'version': args.code_version}
            if args.code_commit:
                code['commit'] = args.code_commit
            if args.command == 'run':
                args.root.mkdir(parents=True, exist_ok=False)
                for deck, run in pairs:
                    deck_path = args.root/f"{deck['case_id']}.deck.json"
                    if not deck_path.exists():
                        write_new(deck_path, deck)
                    command = [str(args.binary.resolve()), 'open-benchmark', '--deck', str(deck_path.resolve()),
                               '--run', run['id'], '--out', str((args.root/filename(deck,run)).resolve())]
                    with (args.root/(filename(deck,run)+'.log')).open('x') as log:
                        subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, check=True)
            receipt = make_receipt(args.root, pairs, code, args.binary if args.command == 'run' else None)
            write_new(args.root/'receipt.json', receipt)
            # Refuse a successful import/run receipt for incomplete or malformed histories.
            try:
                extract(args.root)
            except (ValueError, KeyError):
                (args.root/'receipt.json').unlink()
                raise
        return 0
    except (ValueError, KeyError, TypeError, OSError, subprocess.CalledProcessError) as error:
        print(f'benchmark: {error}', file=sys.stderr)
        return 2


if __name__ == '__main__':
    sys.exit(main())
