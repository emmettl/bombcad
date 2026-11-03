#!/bin/zsh
# Times the explorer's Beirut dragged on an iPad's own GPU (emmettl/bombcad-work#119; `LiveBench`,
# docs/spatial-viewer.md): installs dist/BombCAD-iPad-device.app (Scripts/build-ipad-viewer.sh
# --device release), launches it with BOMBCAD_VIEWER_LIVE_BENCH=1, waits for its report and copies
# it back. The iPad must be unlocked, and stay awake (the app keeps its screen on while it runs).
# Beirut's file and the wave's weights are downloaded by the app from their releases, checked
# against their pinned SHA-256, unless --copy sends this Mac's copies into its Documents first.
#   Scripts/ipad-live-bench.sh <devicectl id> <out.txt> [--copy <beirut.json> <weights.bcfw>] [--sustain s]
set -uo pipefail
cd "$(dirname "$0")/.."
device=$1
out=$2
shift 2
sustain=60
copy=()
while [ $# -gt 0 ]; do
  case "$1" in
    --copy) copy=("$2" "$3"); shift 3 ;;
    --sustain) sustain=$2; shift 2 ;;
    *) echo "Unknown option $1" >&2; exit 1 ;;
  esac
done
app=dev.bombcad.viewer
container=(--device "$device" --domain-type appDataContainer --domain-identifier "$app")

xcrun devicectl device install app --device "$device" dist/BombCAD-iPad-device.app || exit 1
for file in "${copy[@]}"; do
  xcrun devicectl device copy to "${container[@]}" --source "$file" \
    --destination "Documents/$(basename "$file")" >/dev/null || exit 1
done
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
fetch() {
  xcrun devicectl device copy from "${container[@]}" --source "Documents/$1" \
    --destination "$scratch/$1" >/dev/null 2>&1
}
# A report left from before is not this run's.
fetch live-bench.txt && cp "$scratch/live-bench.txt" "$scratch/before.txt" || : >"$scratch/before.txt"
xcrun devicectl device process launch --device "$device" --terminate-existing \
  -e "{\"BOMBCAD_VIEWER_LIVE_BENCH\":\"1\",\"BOMBCAD_VIEWER_LIVE_BENCH_SUSTAIN\":\"$sustain\"}" "$app" || exit 1
# The bench takes a few minutes, most of it the full estimate on let-go; at most 30.
for attempt in {1..180}; do
  sleep 10
  if fetch live-bench.txt && ! cmp -s "$scratch/live-bench.txt" "$scratch/before.txt"; then
    cp "$scratch/live-bench.txt" "$out"
    cat "$out"
    exit 0
  fi
  if [ $attempt -gt 2 ] && fetch live-bench.log && grep -q "live-bench failed" "$scratch/live-bench.log"; then
    cat "$scratch/live-bench.log"
    exit 1
  fi
done
echo "No report after 30 minutes; the log so far:" >&2
fetch live-bench.log && cat "$scratch/live-bench.log"
exit 1
