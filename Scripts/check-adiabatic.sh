#!/bin/bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
output=${1:-$(mktemp -d "${TMPDIR:-/tmp}/bombcad-adiabatic-output.XXXXXX")}
scratch=$(mktemp -d "${TMPDIR:-/tmp}/bombcad-adiabatic-build.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$output" "$scratch/consumer"
case_args=()
if test -n "${2:-}"; then case_args=(--cases "$2"); fi
cp -R Fixtures/AdiabaticBenchmark/. "$scratch/consumer/"
cp Sources/BlastCore/FractionalGasTransport.swift "$scratch/consumer/Sources/AdiabaticAdapter/SourceTransport.swift"
revision=$(cat Fixtures/AdiabaticBenchmark/core-revision.txt)
source=${CONTINUUMKIT_BENCHMARK_SOURCE:-https://github.com/emmettl/ContinuumKit.git}
git clone --no-checkout --quiet "$source" "$scratch/ContinuumKit"
git -C "$scratch/ContinuumKit" checkout --quiet "$revision"
export CONTINUUMKIT_BENCHMARK_SOURCE="$scratch/ContinuumKit"
python3 "$scratch/ContinuumKit/Scripts/benchmark-metadata.py" --root "$root" \
    --repository https://github.com/emmettl/bombcad --output "$output/environment.json" --dependency "continuumkit=$revision" \
    Sources/BlastCore/FractionalGasTransport.swift Fixtures/AdiabaticBenchmark/Sources/AdiabaticAdapter/main.swift
swift run --package-path "$scratch/consumer" -c release -Xswiftc -warnings-as-errors \
    AdiabaticAdapter --output "$output" --metadata "$output/environment.json" "${case_args[@]}"
cp "$scratch/consumer/Package.resolved" "$output/consumer-Package.resolved"
echo "BombCAD matched single-volume benchmark: $output"
