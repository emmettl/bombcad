#!/bin/bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
test -z "$(git -C "$root" status --porcelain)"
output=${1:-$(mktemp -d "${TMPDIR:-/tmp}/bombcad-qr-adoption-output.XXXXXX")}
scratch=$(mktemp -d "${TMPDIR:-/tmp}/bombcad-qr-adoption-build.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$output"
test ! -e "$output/original.json"
python3 - "$root" "$output" <<'PYMETA'
import hashlib,json,platform,shutil,subprocess,sys
from pathlib import Path
r,o=map(Path,sys.argv[1:])
paths=subprocess.check_output(['git','ls-files','Package.swift','Package.resolved','Sources/BlastCore/FiniteVolumePressureFit.swift','Sources/BlastCore/ConservedGasReconstruction.swift','Sources/BlastCore/FractionalGasTransport.swift','Fixtures/QRReconstructionAdoption','Scripts/prepare-qr-reconstruction-capture.py','Scripts/verify-qr-reconstruction-output.py','Scripts/test-qr-reconstruction-gate.py','Scripts/check-qr-reconstruction-adoption.sh'],cwd=r,text=True).splitlines()
data={'schemaVersion':1,'candidate':subprocess.check_output(['git','rev-parse','HEAD'],cwd=r,text=True).strip(),'workingTreeDirty':False,'sourceHashes':{p:hashlib.sha256((r/p).read_bytes()).hexdigest() for p in paths},'hardware':subprocess.check_output(['sysctl','-n','machdep.cpu.brand_string'],text=True).strip(),'swift':subprocess.check_output(['swift','--version'],text=True).strip(),'os':platform.platform(),'flags':['-c','release','-Xswiftc','-warnings-as-errors'],'scope':'source-bound actual original/shared reconstruction and native rounded policy; no global positivity/empirical claim'}
(o/'environment.json').write_text(json.dumps(data,indent=2,sort_keys=True)+'\n')
for path in paths:
 target=o/'source'/path;target.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(r/path,target)
PYMETA
for variant in original shared; do
  build="$scratch/$variant"
  python3 "$root/Scripts/prepare-qr-reconstruction-capture.py" --variant "$variant" --output "$build"
  mkdir -p "$output/$variant/source"
  cp -R "$build/Sources" "$output/$variant/source/Sources"
  cp "$build/Package.swift" "$output/$variant/source/Package.swift"
  cp "$build/bindings.json" "$output/$variant/bindings.json"
  BOMBCAD_QR_VARIANT="$variant" swift build --package-path "$build" -c release -Xswiftc -warnings-as-errors
  binary=$(BOMBCAD_QR_VARIANT="$variant" swift build --package-path "$build" -c release --show-bin-path)/ReconstructionCapture
  BOMBCAD_QR_VARIANT="$variant" "$binary" "$output/$variant.json"
  cp "$build/Package.resolved" "$output/$variant/Package.resolved"
  otool -L "$binary" > "$output/$variant/linkage.txt"
  if grep -Eq '/(Metal|MetalKit|AppKit|SwiftUI)\.framework/' "$output/$variant/linkage.txt"; then
    echo 'Reconstruction capture unexpectedly links an application/UI/GPU framework' >&2
    exit 1
  fi
done
for variant in original shared; do
  python3 "$root/Scripts/verify-qr-reconstruction-output.py" "$output/$variant.json" --output "$output/$variant-reference.json" --producer "$output"
done
python3 "$root/Scripts/test-qr-reconstruction-gate.py" "$output"
