#!/bin/bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
test -z "$(git -C "$root" status --porcelain)"
output=${1:-$(mktemp -d "${TMPDIR:-/tmp}/bombcad-qr-coupled-output.XXXXXX")}
scratch=$(mktemp -d "${TMPDIR:-/tmp}/bombcad-qr-coupled-build.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$output"
test ! -e "$output/original.json"
python3 - "$root" "$output" <<'PYMETA'
import hashlib,json,platform,shutil,subprocess,sys
from pathlib import Path
r,o=map(Path,sys.argv[1:])
paths=subprocess.check_output(['git','ls-files','Package.swift','Package.resolved','Sources/BlastCore','Fixtures/QRReconstructionAdoption','Fixtures/EulerAdoptionBenchmark/References','Scripts/check-grouped-gas-reference.py','Scripts/prepare-qr-coupled-capture.py','Scripts/verify-qr-coupled-output.py','Scripts/verify-qr-coupled-source.py','Scripts/test-qr-coupled-gate.py','Scripts/check-qr-coupled-adoption.sh'],cwd=r,text=True).splitlines()
env={'schemaVersion':1,'candidate':subprocess.check_output(['git','rev-parse','HEAD'],cwd=r,text=True).strip(),'workingTreeDirty':False,'sourceHashes':{p:hashlib.sha256((r/p).read_bytes()).hexdigest() for p in paths},'hardware':subprocess.check_output(['sysctl','-n','machdep.cpu.brand_string'],text=True).strip(),'swift':subprocess.check_output(['swift','--version'],text=True).strip(),'os':platform.platform(),'flags':['-c','release'],'scope':'complete selected actual production CPU studies; no empirical blast validation'}
(o/'environment.json').write_text(json.dumps(env,indent=2,sort_keys=True)+'\n')
for path in paths:
 target=o/'source'/path;target.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(r/path,target)
PYMETA
for variant in original shared; do
  build="$scratch/$variant"
  python3 "$root/Scripts/prepare-qr-coupled-capture.py" --variant "$variant" --output "$build"
  mkdir -p "$output/$variant/source"
  cp -R "$build/Sources" "$output/$variant/source/Sources"
  cp "$build/Package.swift" "$output/$variant/source/Package.swift"
  cp "$build/bindings.json" "$output/$variant/bindings.json"
  swift build --package-path "$build" -c release > "$output/$variant/build.log" 2>&1
  binary=$(swift build --package-path "$build" -c release --show-bin-path)/CoupledCapture
  "$binary" > "$output/$variant.json"
  cp "$build/Package.resolved" "$output/$variant/Package.resolved"
  otool -L "$binary" > "$output/$variant/linkage.txt"
done
python3 "$root/Scripts/verify-qr-coupled-source.py" "$output"
for variant in original shared; do
  python3 "$root/Scripts/verify-qr-coupled-output.py" "$output/$variant.json" --output "$output/$variant-reference.json"
done
python3 "$root/Scripts/test-qr-coupled-gate.py" "$output"
