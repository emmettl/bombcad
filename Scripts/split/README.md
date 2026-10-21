# The BlastModel split

These tools move BombCAD's plain model (scenarios, structures, materials and the calculations
that run on the CPU) out of `BlastCore` into `BlastModel`, a module that imports no Metal and so
also builds and is tested on Linux. They do the move by script, so that it can be redone on
whatever `main` is when the window opens, and they stop rather than guess when `main` has changed
under them. The findings and the numbers are in the cloud report of 19 October 2026
(kept outside the repository at `$BOMBCAD_DATA/cloud-reports/2026-10-19/blastmodel-split.md`).

| File | What it is |
|---|---|
| `import-graph.py` | Maps `Sources/BlastCore` and `Tests/BlastCoreTests`: each file's imports, the types it declares and uses, and its class (`cpu`, `gpu` or `mixed`); `--write` records it in `classification.json`, `--check` fails when that record is stale |
| `blastcore_graph.py`, `swift_source.py` | The rules of that map and the reader of Swift source it uses (no compiler, so it runs anywhere) |
| `classification.json` | The map, for review: what moves, and for each mixed file what is cut out and why |
| `seams.json` | Behaviour-neutral edits beyond moving code; one, which moves a constant (`ShellSolver.fibresAcross`, 9) to `ShellMesh` |
| `overrides.json` | Declarations a Linux build showed must stay in BlastCore, each with its reason |
| `split-blastmodel.sh`, `split_blastmodel.py` | The split itself |
| `test-split.py` | The tools' own tests, on a made-up package |

## In the window

1. Branch from `main` and bring these tools in (the commit that adds `Scripts/split/`).
2. `python3 Scripts/split/import-graph.py --check`. If it fails, `main` has changed what moves:
   run it with `--write`, read the difference in `classification.json`, and commit it.
3. `Scripts/split/split-blastmodel.sh`. It stops before changing anything if a file it expects
   has moved or a seam no longer applies.
4. `swift package resolve`, to refresh `Package.resolved`'s origin hash for ContinuumKit
   0.1.0-alpha.29.
5. On the Mac: build every target, `make check-anywhere`, and compare the digests with `main`'s.
6. Commit, and push the branch for review.

After the split, the six plain types it had left in BlastCore for one coupling each
(`ThermalExposure` with the thermal march, `FreestandingMotion`, `TiledCoupling`,
`TerracedRowDamage`, `GPUStepRate` and `BuildProbe`) were moved by hand, each through a small
seam: a plain value in BlastModel where a GPU type was stored, or a protocol or delegating
initialiser that BlastCore's GPU type provides. `classification.json` still records them as the
split found them.

Running the script again changes nothing. `--no-seams` leaves the seam out, and with it about
ninety declarations that depend on it stay in BlastCore (rewrite the map with
`import-graph.py --write --no-seams` first).

On Linux, BlastModel's `import simd` reaches ContinuumKit's stand-in (its `Sources/LinuxSIMD`),
which follows Apple's simd bit for bit (but for the 3 × 3 inverse and the quaternions' sines,
cosines and arc tangents) and whose `SIMDParityTests` check it against Apple's on the
Mac. The split first installed a shim of its own with a parity test; both moved to ContinuumKit.

# The air solver's split (emmettl/bombcad-work#21)

`BlastSolver.swift` (4,500 lines) and `Shaders/Solver.metal` (3,700) are cut by subsystem. Each
member or declaration moves whole, with the comments above it, so kernel names, argument indices
and function constants are as they were. The plan is `solver-split.json`.

| File | What it is |
|---|---|
| `split_solver.py` | `inventory` (each member's or declaration's key and where the plan puts it), `check` (the plan against the tree), `refresh` (the plan brought up to date), `split`, and `editors` (who has been changing the two files) |
| `solver-split.json` | The plan: for each new file, what moves to it and a line on what it is; the rest stays. `base` is each file's blob when the plan was made |
| `split-solver.sh` | The split itself, on a branch of a clean checkout |
| `solver-digests.sh` | `blastbench digest` on uniform, refined and twice-refined air, recommended, gravity, terrain and the mapped start, to compare before and after |
| `test-solver-split.py` | The tools' own tests, on made-up sources |

What goes where:

| Swift (`extension BlastSolver`) | Metal (joined after `Solver.metal`, in this order) |
|---|---|
| `BlastSolver.swift`: the stored properties, the initialiser, the types they hold (430 lines) | `Solver.metal`: the shared types and constants, function constants, equation of state, reconstruction, fluxes, gravity's and cut cells' helpers, the readers of refined air (1,350) |
| `+Stepping`: batches, the sweeps' encoding and uniforms, per-cell kernels, tiles, command buffers' GPU time (940) | `SolverSweep`: `sweepCell`, `sweep`, `sweepTiles` (590) |
| `+Coupling`: structures' coupling, envelopes, contact, debris, settling (640) | `SolverCutCells`: redistribution, terrain and structures (360) |
| `+State`: initial conditions, restart and clock, cells, totals, peaks (380) | `SolverCongestion`: obstacles' drag and turbulence (120) |
| `+Venting`, `+Envelopes`: venting; the envelope recorders (360, 310) | `SolverStep`: tiles woken and collected, the step's length, gauges (350) |
| `+Refinement`: levels, pools, regrid, fine deposits (300) | `SolverEnvelopes`: exposure plane, faces' exposure, components (460) |
| `+Mask`: the solid mask and remasking (250) | `SolverVenting`: panes, walls, breaches, rooms (400) |
| `+AirModels`: gravity, mixing, periodic sides, species (190) | `SolverVisualization` (60) |
| `+CutCells`, `+Gauges`, `+Visualization`, `+ExperimentalBoxes` (150, 150, 60, 420) | |

Two things change besides the moves. Swift's `private` reaches extensions in the same file only,
so a `private` declaration another of the new files uses becomes internal, and a `private(set)`
property another file sets becomes `internal(set)`: about 170, nearly all the stored buffers and
pipelines (`split` lists them). And ShaderLibrary's list (`ShaderLibrary.make`) names the new
Metal files right after `Solver`: the library is one source, the files joined in order, so `check`
proves that each file uses only what an earlier one, or an earlier line of its own, defines.
check-affected's core files take `BlastSolver+*.swift` too, and comments naming a moved kernel or
function "in Solver.metal" or "in BlastSolver.swift" are pointed at its new file (`split` lists
the mentions it could not rewrite, to read).

Git records no renames, and no new file holds half of the old one, so `git mv` would buy nothing:
each old file keeps its name and with it `git log`, and `git blame -C -C` follows the moved lines.

In the window:

1. On `main` before the cut, with a current release build:
   `gpu-slot Scripts/split/solver-digests.sh $BOMBCAD_DATA/solver-split/before.txt`.
2. Branch, and `python3 Scripts/split/split_solver.py check`. If it fails, `main` has added,
   removed or renamed a member or declaration: `refresh` places each new one with what is above
   it and drops what is gone; read the plan's difference (move a new member to a better file by
   hand if need be; `inventory` lists the keys) and commit it. A change inside a member needs
   nothing: it moves with the member.
3. `Scripts/split/split-solver.sh` (it formats and lints what it wrote and runs the shader mirrors'
   check).
4. `make build-strict`, a release build, and `solver-digests.sh … after.txt`: the digests must
   be the same. Then `make check-affected` (the shaders make it the full check).
5. Commit, push, and ask the sessions that edit the two files (`split_solver.py editors`) to rebase.
   A branch's change to a moved member rebases as a conflict on the old file; apply it to the
   member in its new file.

# Narrowing what the splits widened (emmettl/bombcad-work#87)

`narrow_access.py package` takes each of BlastModel's `package` declarations back to internal,
builds the package with its tests, and gives `package` back to exactly those the build's errors
point at, round after round until it builds (`--state` keeps the rounds' result between runs). On
19 October 2026 it took 792 of 1,724 back to internal: the other 932 are used from BlastCore, the
app, the benches or their tests. `test-narrow-access.py` tests its reading of the errors.

`narrow_access.py private` did the same for the 158 `private` declarations the solver split
widened (its `split` log's `widened` lines) and put none back: each is used, or set, from another
of the `BlastSolver+*.swift` files, which Swift's `private` cannot reach. They stay internal, as
the split left them. On 20 October each was still named in two files or more.

Since then (20 October), what is still `package` was checked again: in BlastModel, the 5
declarations added after the narrowing are all used from BlastCore or the benches; of the rest,
only 11 have a name no other module mentions, all types that a `package` signature names. In
BlastCore, the 4 `package` members are `ShellSolver`'s witnesses for BlastModel's
`TerracedRowShells`, and must be as wide as the protocol.

`@_exported import BlastModel` (BlastCore/BlastModelExports.swift) stays: explicit imports would
add `import BlastModel` to about 290 files (counted 20 October) in six targets and two test
targets, and a dependency to each in Package.swift, for no change in what builds or how it runs,
at the cost of a rebase for every session with a branch open. Worth revisiting if BlastModel and
BlastCore are ever versioned apart, or when the package adopts Swift 6's internal imports by
default.
