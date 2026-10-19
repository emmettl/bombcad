#!/usr/bin/env bash
# The digests the air solver's split must leave alone: `blastbench digest` (hashes of short runs of
# the open ground, a street, a wall and the wall as shells) on uniform, refined and twice-refined
# air, with the recommended options, gravity, terrain and the mapped start. Run it from a checkout
# whose release build is current, inside gpu-slot, once before the split and once after:
#
#     gpu-slot Scripts/split/solver-digests.sh /Volumes/StudioData/bombcad/solver-split/before.txt
#     diff before.txt after.txt
set -euo pipefail

out=${1:?usage: solver-digests.sh <output file>}
root=$(git rev-parse --show-toplevel)
bench="$root/.build/release/blastbench"
[[ -x "$bench" ]] || { echo "error: no release build at $bench (swift build -c release --product blastbench)" >&2; exit 1; }
: > "$out"
while read -r args; do
    echo "== digest $args" >> "$out"
    # shellcheck disable=SC2086
    (cd "$root" && "$bench" digest $args) 2>&1 | grep -v '^[[:space:]]*$' >> "$out"
done <<'VARIANTS'

--refine 2
--refine 2 --refine-levels 2
--recommended
--recommended --refine 2
--gravity
--terrain hill
--terrain slope --refine 2
--mapped
VARIANTS
echo "wrote $out"
