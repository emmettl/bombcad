#!/usr/bin/env python3
"""Generate planned first-phase fields on a PC, resuming completed cases.

The Mac prepares each initial state; the PC integrates it. Raw results stay on the
PC and only training arrays/provenance return. --reference gates every selected
case against an existing Metal dataset before it is included in the new dataset.
"""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import time

from generate import generate
from remote import deploy
from compare_dataset import compare


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('host')
    p.add_argument('--dataset', type=Path, required=True)
    p.add_argument('--scratch', type=Path, required=True)
    p.add_argument('--reference', type=Path, required=True)
    p.add_argument('--scenebench', type=Path, required=True)
    p.add_argument('--only', help='comma-separated case IDs')
    p.add_argument('--limit', type=int)
    a = p.parse_args()
    spec = importlib.util.spec_from_file_location('field_plan', Path(__file__).parents[1] / 'ml/field-runs.py')
    plan = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(plan)
    data = json.loads(Path(plan.LIST).read_text())
    runs = data['sets']['main']
    if a.only:
        wanted = set(a.only.split(','))
        runs = [r for r in runs if r['id'] in wanted]
        if {r['id'] for r in runs} != wanted:
            raise ValueError('unknown requested case ID')
    if a.limit:
        runs = runs[:a.limit]
    a.scratch.mkdir(parents=True, exist_ok=True)
    (a.dataset / 'runs').mkdir(parents=True, exist_ok=True)
    source = a.scratch / 'solver.cu'
    source.write_text(generate())
    revision = subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip()
    for run in runs:
        name = run['id']
        target = a.dataset / 'runs' / name
        receipt = a.dataset / (name + '.json')
        if plan.done(target) and receipt.exists():
            saved = json.loads(receipt.read_text())
            if saved.get('comparison', {}).get('passed'):
                print(name + ': already accepted', flush=True)
                continue
        if target.exists():
            raise ValueError(f'unaccepted existing output: {target}')
        started = time.monotonic()
        # Unique attempts retain incomplete runs for inspection without treating them as complete.
        attempt = a.scratch / (name + '-' + str(time.time_ns()))
        attempt.mkdir()
        job = attempt / 'input'
        layout = data['layouts'][run['layout']]
        command = [plan.GPU_SLOT, '--mem', str(run['estimate']['memGB']), str(a.scenebench.resolve())]
        command += plan.field_arguments(run, layout, plan.inputs_for(run['layout'], layout), str(job))
        command += ['--first-phase', '--cuda-job', '--cuda-source', str(source.resolve())]
        print(name + ': preparing initial state', flush=True)
        with (attempt / 'export.log').open('w') as log:
            subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, check=True,
                           env=dict(os.environ, BOMBCAD_SOURCE_REVISION=revision))
        result = attempt / 'result'
        report = deploy(a.host, job, result, dataset_only=True)
        comparison = compare(a.reference / 'runs' / name, result / 'dataset')
        record = {'id': name, 'revision': revision, 'totalSeconds': time.monotonic() - started,
                  'result': report, 'comparison': comparison,
                  'deployment': json.loads((result / 'deployment.json').read_text())}
        receipt.write_text(json.dumps(record, indent=2) + '\n')
        print(json.dumps(record), flush=True)
        if not comparison['passed']:
            raise ValueError(name + ': failed Metal comparison; batch stopped')
        shutil.copytree(result / 'dataset', target)
        plan.index(str(a.dataset))
        # The PC retains the raw input/output audit trail. Drop only this attempt's local buffers.
        shutil.rmtree(job)
    print(f'{len(plan.index(str(a.dataset)))} accepted runs in {a.dataset}', flush=True)


if __name__ == '__main__':
    main()
