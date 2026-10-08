#!/usr/bin/env python3
"""Reject metadata-only or partial output even if an old shell reports a false success."""
import csv
import json
from pathlib import Path
import sys

root = Path(sys.argv[1])
cases = json.loads((root / 'cases.json').read_text())
results = json.loads((root / 'results.json').read_text())
conformance = json.loads((root / 'conformance.json').read_text())
assert cases and len({c['id'] for c in cases}) == len(cases), 'Invalid case collection'
assert len(conformance) == len(cases) and all(c['status'] == 'passed' for c in conformance), 'Conformance failed'
assert len(results) == 4 * len(cases), 'Missing refinement runs'
for index, case in enumerate(cases):
    series = [r for r in results if r['caseSpecification'] == case]
    assert sorted(r['steps'] for r in series) == [16, 32, 64, 128], 'Missing resolutions'
    for result in series:
        assert result['schemaVersion'] == 1 and result['status'] == 'supported' and result['errors'], 'Invalid result'
        assert len(result['samples']) == result['steps'] + 1, 'Incomplete JSON history'
        path = root / f"case-{index}-n{result['steps']}.csv"
        with path.open(newline='') as stream:
            rows = list(csv.DictReader(stream))
        assert len(rows) == result['steps'] + 1, 'Incomplete CSV history'
        for row, sample in zip(rows, result['samples']):
            for column, key in [('time_s', 'timeS'), ('volume_m3', 'volumeM3'),
                                ('internal_energy_j', 'energyJ'), ('pressure_pa', 'pressurePa'),
                                ('work_by_reservoir_j', 'workByReservoirJ')]:
                assert float(row[column]) == sample[key], 'CSV and JSON differ'
print(f"PASS complete reports: {len(cases)} cases, {len(results)} runs and matching JSON/CSV histories")
