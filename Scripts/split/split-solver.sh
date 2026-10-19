#!/usr/bin/env bash
# Splits the air solver's two largest files by subsystem (#21): Sources/BlastCore/BlastSolver.swift
# into `extension BlastSolver` files beside it, and Sources/BlastCore/Shaders/Solver.metal into the
# Solver*.metal files the shader library joins after it. Run it from a branch of a clean checkout:
#
#     Scripts/split/split-solver.sh
#
# It follows Scripts/split/solver-split.json and stops before changing anything if that plan no
# longer describes the two files (a member or kernel added, removed or renamed on main): run
# `python3 Scripts/split/split_solver.py inventory` to see the keys, place the new ones in the
# plan, commit it and run this again. Then it cuts the files, widens the access of what the new
# files share, adds the new shaders to ShaderLibrary's list, and formats and lints what it wrote.
#
# Running it again changes nothing. The Python half is Scripts/split/split_solver.py.
set -euo pipefail

root=$(git rev-parse --show-toplevel)
cd "$root"
python=(python3 Scripts/split/split_solver.py)

branch=$(git symbolic-ref --quiet --short HEAD || true)
if [[ -z "$branch" || "$branch" == main ]]; then
    echo "error: run this on a branch, not on ${branch:-a detached HEAD}" >&2
    exit 1
fi
if [[ -n "$(git status --porcelain -- Sources Scripts/check-affected.py)" ]]; then
    echo "error: Sources has changes not committed; start from a clean checkout" >&2
    exit 1
fi

"${python[@]}" check
"${python[@]}" split

changed=$(git status --porcelain -- Sources | awk '{print $2}' | grep '\.swift$' || true)
if [[ -n "$changed" ]]; then
    # shellcheck disable=SC2086
    swift format format --in-place $changed
    # shellcheck disable=SC2086
    swift format lint --strict $changed
fi
python3 Scripts/check-shader-mirrors.py
echo "done; run make build-strict and the digests (Scripts/split/README.md) before committing"
