#!/usr/bin/env bash
# Moves the plain model out of BlastCore into BlastModel, a module without Metal that also builds
# on Linux. Run it from a branch of a clean checkout:
#
#     Scripts/split/split-blastmodel.sh [--no-seams]
#
# It follows Scripts/split/classification.json, the map Scripts/split/import-graph.py writes, and
# stops before changing anything if that map no longer describes the tree (a file moved or
# changed on main): rewrite the map, review it, commit it and run this again. Then it
#
# 1. makes the behaviour-neutral edits in Scripts/split/seams.json (--no-seams leaves them out);
# 2. splits each mixed file, the GPU-side code going to a new file left in BlastCore;
# 3. moves the CPU-only files and tests with `git mv`;
# 4. adds the BlastModel and BlastModelTests targets to Package.swift (BlastCore depends on and
#    re-exports BlastModel), the imports, `package` access where BlastCore uses an internal
#    declaration, the Linux simd shim, and the new paths in the Makefile and the documents.
#
# Running it again changes nothing. The Python half is Scripts/split/split_blastmodel.py.
set -euo pipefail

root=$(git rev-parse --show-toplevel)
cd "$root"
python=(python3 Scripts/split/split_blastmodel.py)

branch=$(git symbolic-ref --quiet --short HEAD || true)
if [[ -z "$branch" || "$branch" == main ]]; then
    echo "error: run this on a branch, not on ${branch:-a detached HEAD}" >&2
    exit 1
fi

"${python[@]}" prepare "$@"

moves=$("${python[@]}" moves "$@")
count=0
while read -r source destination; do
    [[ -n "$source" ]] || continue
    if [[ ! -e "$source" && -e "$destination" ]]; then
        continue
    fi
    if [[ ! -e "$source" ]]; then
        echo "error: $source is not there, nor at $destination; has it moved on main?" >&2
        exit 1
    fi
    if [[ -e "$destination" ]]; then
        echo "error: both $source and $destination exist" >&2
        exit 1
    fi
    mkdir -p "$(dirname "$destination")"
    git mv "$source" "$destination"
    count=$((count + 1))
done <<< "$moves"
echo "moved $count files"

"${python[@]}" finish "$@"
echo "done; build on the Mac, run make check-anywhere and compare the digests before committing"
