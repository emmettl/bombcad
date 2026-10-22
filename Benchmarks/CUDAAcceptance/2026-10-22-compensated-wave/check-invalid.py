"""Check early refusal only; never launches a valid wave experiment."""
import json
from pathlib import Path
import subprocess
import sys

exe = str(Path(sys.argv[1]).resolve())
rows = []
for index, arguments in enumerate([
    ['--compensated', 'invalid'], ['--compensated'], ['--discard-compensation'],
    ['--only-case', 'invalid'], ['--only-case'],
    ['--fine', '--only-case', 'a1-n128-full'],
]):
    destination = Path('/private/tmp/bombcad-compensated-cli-refusal-' + str(index))
    assert not destination.exists(), destination
    command = [exe, 'acoustic-phase', '--out', str(destination), *arguments]
    result = subprocess.run(command, capture_output=True, text=True, timeout=60)
    row = dict(command=command, returncode=result.returncode, stdout=result.stdout,
               stderr=result.stderr, outputCreated=destination.exists())
    rows.append(row)
    assert result.returncode != 0 and not destination.exists(), row
print(json.dumps(dict(status='complete', checks=rows), indent=2))
