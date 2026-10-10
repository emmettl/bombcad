#!/bin/bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
output=${1:-$(mktemp -d "${TMPDIR:-/tmp}/bombcad-adiabatic-output.XXXXXX")}
scratch=$(mktemp -d "${TMPDIR:-/tmp}/bombcad-adiabatic-build.XXXXXX")
trap 'task_status=$?; rm -rf "$scratch"; exit "$task_status"' EXIT
mkdir -p "$output" "$scratch/consumer"
case_file=${2:-}
if test -n "$case_file"; then set -- --cases "$case_file"; else set --; fi
cp -R Fixtures/AdiabaticBenchmark/. "$scratch/consumer/"
python3 Scripts/verify-adiabatic-packet-source.py
revision=$(cat Fixtures/AdiabaticBenchmark/core-revision.txt)
source=${CONTINUUMKIT_BENCHMARK_SOURCE:-https://github.com/emmettl/ContinuumKit.git}
git clone --no-checkout --quiet "$source" "$scratch/ContinuumKit"
git -C "$scratch/ContinuumKit" checkout --quiet "$revision"
export CONTINUUMKIT_BENCHMARK_SOURCE="$scratch/ContinuumKit"
python3 "$scratch/ContinuumKit/Scripts/benchmark-metadata.py" --root "$root" \
    --repository https://github.com/emmettl/bombcad --output "$output/environment.json" --dependency "continuumkit=$revision" \
    Fixtures/AdiabaticBenchmark/Sources/AdiabaticAdapter/SourceTransport.swift Fixtures/AdiabaticBenchmark/Sources/AdiabaticAdapter/main.swift
swift run --package-path "$scratch/consumer" -c release -Xswiftc -warnings-as-errors \
    AdiabaticAdapter --output "$output" --metadata "$output/environment.json" "$@"
python3 Scripts/verify-adiabatic-output.py "$output"
cp "$scratch/consumer/Package.resolved" "$output/consumer-Package.resolved"
echo "BombCAD matched single-volume benchmark: $output"
bash Scripts/check-shared-adiabatic.sh "$output/shared" "$output/cases.json"
python3 Scripts/verify-shared-adiabatic-continuity.py "$output"
