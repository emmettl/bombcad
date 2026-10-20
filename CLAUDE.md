# Working on BombCAD

Rules for every session and agent. Keep them lean: the aim is throughput with little ceremony.

## What to work on

- The work is tracked as issues in the private repository
  [emmettl/bombcad-work](https://github.com/emmettl/bombcad-work/issues). The milestones are the
  order of work: **Now**, then **Next**, then **Later**, with **Big bets** apart. Each issue's
  plan is its comment "Implementation plan". `PLAN.md` there says why the order is what it is.
- **Take work yourself.** When you finish, take the top unclaimed issue in Now, or else in Next,
  that suits you and doesn't collide on the same files. Claim it, comment your plan in a line,
  and go. Ask the orchestrator only for a conflict or a decision.
- `claim list | check | take | note | done | drop` works the issues; on this Mac it is
  `/Volumes/StudioData/bombcad/orchestrator/claim.gh` until `~/.local/bin/claim` is updated. In
  commits, write `emmettl/bombcad-work#N`, never a bare `#N`: this repository is public, and a
  bare number links its own issues.
- End each stage with something a user gets, or with a recorded stop (a dated section in the
  model's doc, and a comment on the issue). Defaults are the user's decision: propose, with the
  numbers, and don't change one yourself.

## Where code goes

- **Platform dependencies only where they are needed.** Code that needs no Metal, AppKit or
  SwiftUI goes in `Sources/BlastModel`, and its tests in `Tests/BlastModelTests`, so it builds and
  tests on Linux (CI, and the PCs' WSL2). GPU code stays in BlastCore; the app in BombCAD.
- Changing a shader struct means updating its Swift mirror and Render.metal's copy as well.

## Landing a change

- `make ship` runs the whole sequence below, and refuses a branch that would silently revert
  someone else's recent work (`--allow-reverts` if that's intended). By hand, it is:
  1. `make format && make lint`, then `make build-strict` with no warnings;
  2. plain `make check-affected`. Never wrap it in gpu-slot, and **never pipe it** (`| tail`
     makes `&&` test tail's exit status, not the check's);
  3. `git fetch origin && git rebase origin/main`;
  4. `git diff origin/main...HEAD --stat` showing only your own files;
  5. `git push origin HEAD:main`, chained with `&&`.
- `make ship` checks solver and shader changes by the affected suites plus bit-identical
  digests; the nightly full check catches the rest and names the suspect commits. A change meant
  to move results fails the digests: land it with `make ship ARGS=--full`, and give the reason in
  the commit message.
- User-visible changes add a fragment in `docs/release-notes/next/`
  (`python3 Scripts/release-notes.py add <topic>`). Don't edit `docs/roadmap.md`: the
  orchestrator refreshes it from the tracker.

## The machines

- Wrap GPU work (blastbench, GPU tests) in `~/.local/bin/gpu-slot --mem <GB>`. Keep any one run
  under about 1.5 hours, and send sweeps to the mini. No multi-hour runs for cosmetic output
  (doc images): re-render from checkpoints.
- Kill only your own processes, by pid or task id. Never `pkill` or `killall` a pattern.
- Scratch and large outputs go on `/Volumes/StudioData/bombcad/`, not the boot disk.

## Never

- Commit secrets, private data or PDFs (cite sources instead). Use anything from Kinney–Graham.
- Open a folder named `blind/`, or anything about the sealed Vasudevan blind test.
- Edit Edgerton or Codex branches, or change system or security settings.
- Publish a release, tag ContinuumKit, delete branches or worktrees, or install software
  without the user's word. Hand the user the exact command instead.
