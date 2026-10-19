#!/usr/bin/env bash
# Replays the current branch's commits over the air solver's split, so that a change made to
# BlastSolver.swift or Solver.metal before the split lands in the files the split made:
#
#     Scripts/split/port-over-solver-split.sh <the split's commit on main>
#
# The branch must first sit on the commit just before the split (`git rebase <split>^`, resolving
# any conflicts there as usual) and hold no merges. Then each of its commits is cut by the same
# plan in a temporary worktree (what the commit adds that the plan does not name goes with what is
# above it) and committed again, on the split, as `<branch>-split`, with its message and author.
# The branch itself is left as it is. What the split's commit holds beyond the script's cut of its
# parent (comments fixed by hand) is applied to each commit too.
set -euo pipefail

split=${1:?usage: port-over-solver-split.sh <the split commit>}
root=$(git rev-parse --show-toplevel)
cd "$root"
branch=$(git symbolic-ref --quiet --short HEAD || true)
[[ -n "$branch" ]] || { echo "error: not on a branch" >&2; exit 1; }
split=$(git rev-parse --verify "$split^{commit}")
base=$(git rev-parse "$split^")
if ! git merge-base --is-ancestor "$base" HEAD; then
    echo "error: $branch does not sit on $base (the split's parent); git rebase $base first" >&2
    exit 1
fi
if [[ -n "$(git rev-list --merges "$base..HEAD")" ]]; then
    echo "error: $branch has merges since $base; rebase it onto $base first" >&2
    exit 1
fi
if git show-ref --quiet "refs/heads/$branch-split"; then
    echo "error: $branch-split exists already" >&2
    exit 1
fi

scratch=$(mktemp -d "${TMPDIR:-/tmp}/solver-port.XXXXXX")
work="$scratch/tree"
cleanup() { git worktree remove --force "$work" 2>/dev/null || true; rm -rf "$scratch"; }
trap cleanup EXIT
git worktree add --quiet --detach "$work" "$base"
tools=("$root/Scripts/split/split_solver.py")

# The tree the script makes of a commit: its own tree, cut, formatted (and the split's edits by
# hand, once they are known).
cut_tree() {
    git -C "$work" checkout --quiet --force --detach "$1"
    git -C "$work" clean --quiet -fd -- Sources
    python3 "${tools[@]}" split --root "$work" --lenient > "$scratch/log" || { cat "$scratch/log" >&2; exit 1; }
    local changed
    changed=$(git -C "$work" status --porcelain -- Sources | awk '{print $2}' | grep '\.swift$' || true)
    if [[ -n "$changed" ]]; then
        (cd "$work" && echo "$changed" | xargs swift format format --in-place)
    fi
    git -C "$work" add -A
    if [[ -s "$scratch/by-hand.patch" ]]; then
        git -C "$work" apply --3way "$scratch/by-hand.patch" > /dev/null 2>&1 \
            || { echo "error: the split's own edits do not apply to $1; port it by hand" >&2; exit 1; }
        git -C "$work" add -A
    fi
    git -C "$work" write-tree
}

# What the split's commit has beyond the script's cut of its parent (comments fixed by hand, a
# conflict resolved): applied again to each commit's cut.
git diff --binary "$(cut_tree "$base")" "$split^{tree}" > "$scratch/by-hand.patch"
if [[ -s "$scratch/by-hand.patch" ]]; then
    echo "the split's commit differs from the script's cut in $(grep -c '^diff --git' "$scratch/by-hand.patch") file(s); applying that to each commit"
fi

parent=$split
for commit in $(git rev-list --reverse "$base..HEAD"); do
    tree=$(cut_tree "$commit")
    parent=$(
        GIT_AUTHOR_NAME=$(git log -1 --format=%an "$commit") \
        GIT_AUTHOR_EMAIL=$(git log -1 --format=%ae "$commit") \
        GIT_AUTHOR_DATE=$(git log -1 --format=%aD "$commit") \
        git commit-tree "$tree" -p "$parent" -F <(git log -1 --format=%B "$commit"))
    echo "  $(git log -1 --format='%h %s' "$commit" | cut -c1-90)"
done
git branch "$branch-split" "$parent"
echo "made $branch-split; build it, then point $branch at it (git reset --keep $branch-split)"
