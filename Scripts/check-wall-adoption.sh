#!/bin/bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
test -z "$(git status --porcelain)"
output=${1:-$(mktemp -d "${TMPDIR:-/tmp}/bombcad-wall-adoption-output.XXXXXX")}
mkdir -p "$output"
revision=$(git rev-parse HEAD)
baseline=089d0a25475a3de8c541dd1a6531c7503e60163c
scratch=$(mktemp -d "${TMPDIR:-/tmp}/bombcad-wall-adoption-build.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
python3 - "$root" "$output" "$baseline" <<'PY'
import json,hashlib,platform,subprocess,sys
from pathlib import Path
root,output=map(Path,sys.argv[1:3]);baseline=sys.argv[3]
def git(*args):return subprocess.check_output(['git',*args],cwd=root,text=True).strip()
paths=git('ls-files','Sources/BlastCore','Fixtures/WallAdoptionBenchmark','Scripts/check-wall-adoption.sh','Scripts/verify-wall-adoption-output.py','Package.swift','Package.resolved').splitlines()
pin=next(p['state'] for p in json.loads((root/'Package.resolved').read_text())['pins'] if p['identity']=='continuumkit')
env={'corePin':pin,'schemaVersion':1,'candidate':git('rev-parse','HEAD'),'baseline':baseline,'workingTreeDirty':bool(git('status','--porcelain')),'sourceHashes':{p:hashlib.sha256((root/p).read_bytes()).hexdigest() for p in paths},'hardware':subprocess.check_output(['sysctl','-n','machdep.cpu.brand_string'],text=True).strip(),'os':platform.platform(),'swift':subprocess.check_output(['swift','--version'],text=True).strip(),'scope':'clean current app and immutable pre-adoption numerical source, with identical explicitly copied comparison fixture'}
(output/'environment.json').write_text(json.dumps(env,indent=2,sort_keys=True)+'\n')
PY
for variant in original shared; do
  git clone --no-local --quiet "$root" "$scratch/$variant"
  if test "$variant" = original; then
    git -C "$scratch/$variant" checkout --quiet "$baseline"
    cp -R "$root/Fixtures/WallAdoptionBenchmark" "$scratch/$variant/Fixtures/"
  fi
  # The baseline's only added files are this identical comparison fixture.
  test -z "$(git -C "$scratch/$variant" status --porcelain -- Sources Package.swift Package.resolved)"
  mkdir -p "$output/$variant"
  export BOMBCAD_WALL_OUTPUT="$output/$variant"
  # Preserve the frozen baseline, including its existing compiler warnings. Both
  # variants use identical build flags; application lint/build gates run separately.
  swift run --package-path "$scratch/$variant/Fixtures/WallAdoptionBenchmark" -c release \
    -Xswiftc -enable-testing WallAdoptionAdapter
  cp "$scratch/$variant/Fixtures/WallAdoptionBenchmark/Package.resolved" "$output/$variant/consumer-Package.resolved"
done
python3 Scripts/verify-wall-adoption-output.py "$output"
python3 Scripts/test-wall-adoption-gate.py "$output"
