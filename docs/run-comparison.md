# Saved runs and comparison

Complete a stable simulation, then choose **Keep Run…** beside the chart. Give the result a
unique name. **Compare** opens a view of retained runs, with up to four pressure or deflection
traces overlaid. Choose a reference run to see absolute peak differences. Runs can be renamed
(press Return in the name field), exported to CSV, removed and restored with **Undo last removal**.
Names are trimmed, must be nonempty and at most 120 characters, and must be unique without
regard to case. A rejected rename shows its reason beside the field and leaves the draft
available to correct; the saved run stays unchanged.

Keeping a run is explicit. Advancing, pausing or resetting the simulation does not automatically
add result data or mark a project changed. Keeping, renaming and removing results do; native
project saving and autosave include those choices. Changing inputs or selecting another preset
keeps earlier named runs. Opening a different project restores that project's run collection.

## Restore a baseline and run experiments

**Use this run’s inputs** restores the selected run's geometry, materials and numerical settings
at time zero, framing the restored scene. The saved-run collection and document identity stay
intact. Restoration is one undo step; Undo/Redo now also restore grid, numerical options,
structural element-size preference and duration alongside the scene. Camera and playback speed
are presentation preferences rather than historical simulation inputs.

**Sweep…**, beside the chart, runs one to eight cases sequentially at unlimited playback. Reset
first if the current simulation has advanced. Choose either primary-charge masses (comma-separated
kg TNT) or air-grid resolutions, plus a unique result-name prefix. Other charges and all other
inputs stay at baseline values. Every case is validated before the first starts, including source
resampling, numerical bounds, estimated air-memory budget and space in the 16-run collection.

Grid cases resample attached imports independently from the original source baseline, retaining
part materials. Detached geometry and its structural element size remain unchanged. A source
that cannot safely regenerate rejects the plan before any case runs. Unsupported masses, duplicate
values, duplicate result names and insufficient run slots are reported without overwriting results.

Successful cases are captured automatically using the normal saved-run codec. Completion,
cancellation or failure restores the original editor inputs and playback speed at time zero;
already completed results remain available for comparison. **Cancel sweep** or Reset (Command-R)
stops the queue. Closing the configuration dialog leaves it running, with cancellation available
beside the chart. Closing the document cancels its sweep; replacing/reverting the document prevents
a cancelled task from restoring old inputs over the replacement.

During a sweep, project snapshots and autosave retain the original editor scene and numerical
settings, plus completed results. Temporary case inputs are excluded from the persisted editor
state. Input edits, run restoration, result renaming/removal and undo are disabled while the sweep
owns the simulation. Cases create no individual editor undo steps, and existing undo history
survives. The sweep plan/progress are transient; reopening restores completed results, not a queue
or a running simulation.

## Sharing a sweep with another Mac

A sweep can share its cases with other Apple silicon Macs, such as a Mac mini on the desk. In
Settings, under Sweeps on other Macs, add each by its SSH host name or alias, use Test beside it,
and turn on Share sweeps with these Macs. The sweep dialog then offers to share each sweep with
them. SSH must log in without a password, with a key, as for any batch connection. A host saved
by an earlier version, when there could be only one, moves into the list the first time this
version opens. The models alongside a run, [fragments](fragments.md), [thermal radiation](thermal-radiation.md)
and [ground shock](ground-shock.md), can each run on any Mac in the list.

**What happens.** At a sweep's start, BombCAD connects to every Mac in the list at once, over
SSH. The first time for each build it copies its own executable and resource bundles to
`~/Library/Caches/BombCAD/remote/<hash>` on each (the three newest builds are kept), so the
other Macs always run this solver and nothing need be installed there; a copy counts only once
it is whole and signed, so one cut short is sent again. It then starts `BombCAD worker` on each,
which takes cases over its SSH connection one at a time and answers with progress and results;
no port is opened. A returned run is kept only if its input fingerprint matches the case's, so
the other Mac is known to have run exactly that case. It records its own device, so the Compare
view shows which Mac ran what.

**Who runs what.** Cases wait largest first, by cells times steps. Each Mac's speed is a ratio
against this one: how many times longer it takes over a case. Until measured it is taken as 3.5
(the CI Mac mini's M4 against an M4 Max), and it is measured from the cases each Mac has
finished and from those at least a tenth done. The fastest Mac, this one on a tie, takes the
largest case. Every other Mac, this one included when another is faster, takes the smallest
case it should finish no later than the others need for the rest: the waiting work shared among
this Mac and the other Macs at work (each joining once its own case is done, at its own speed,
as if cases could be divided exactly), and never sooner than the last case already running
ends. A larger case would fit no better, so a Mac that cannot fit the smallest takes nothing;
a worker turned down waits while others are busy, in case one hands a case back, and otherwise
stops.

So usually this Mac takes the large cases and slower Macs only those they will not hold the
sweep up with. In a sweep of equal cases one mini takes a case when there are at least five, and
with six cases each of up to three minis takes one; in a grid sweep they take the coarse ones. A
Mac found faster than this one, as the mini was while this Mac was busy with other work, takes
the large cases instead, and this Mac the small ones. With one other Mac the rule is the one used
before there could be several. Every choice depends only on the queue, how far each case has got,
and the ratios, so the same events give the same plan; which Mac connects first can still change
who gets which case. Results are kept in the sweep's order, whichever Mac finishes first.

**When things go wrong.** A Mac that cannot be reached is left out, and the sweep's outcome says
why. If a Mac fails a case (out of memory, say) or its connection drops mid-case, the case goes
back to the queue, for this Mac or another worker, that Mac takes no more, and the outcome says
so. Cancelling the sweep cancels every worker's case, and if this Mac stops or a connection
drops, that worker's input closes and it stops its case and exits.

**Measured.** Six charge masses, 50 to 200 kg, in the street canyon on the medium grid, from the
Mac Studio (M4 Max), with the CI mini (M4) over Thunderbolt. With one other Mac, measured before
there could be several while the Studio was otherwise idle: 22.1 s alone and 18.5 s shared, the
mini running one case. On 9 October 2026 the Studio was busy with other work (load averages of 7
to 37), so a case took 21 to 27 s there against 15 s on the mini. Three interleaved rounds took:

| | Round 1 | Round 2 | Round 3 | Median | Cases elsewhere |
|---|---|---|---|---|---|
| Studio alone | 90.9 s | 127.0 s | 119.1 s | 119.1 s | none |
| With the mini | 62.8 s | 59.4 s | 72.7 s | 62.8 s | 2, 4 and 4 on the mini |
| With the mini and a stand-in | 59.8 s | 43.0 s | 63.2 s | 59.8 s | 2 to 4 on the mini, 1 on the stand-in |

The stand-in second worker is `--local-workers 1`, a worker process on the Studio sharing its
GPU, since a second Mac was not at hand; it adds little because it shares the GPU it would
relieve, and a real second Mac would do better. Found faster, the mini took the large cases and
most of the sweep, and the sweep took about half as long. All 54 results were identical to the
last bit, wherever they ran. The load makes single timings vary by half or more, so the medians
are the figures to go by.

`BombCAD sweep` runs the same without a window:

```bash
swift run -c release BombCAD sweep Example.bombcad --masses 50,100,200 --worker mini.local --worker studio.local --out Example-swept.bombcad
```

with `--worker` once for each Mac (`--remote` is the same), `--grids coarse,medium` instead of
`--masses`, `--prefix` for the results' names and `--ratio` for the starting estimate of how much
slower the other Macs are. `--local-workers 1` adds a `BombCAD worker` process on this Mac, sharing
its GPU, to try the scheduling without another Mac. It prints each result with the device that ran
it, and the outcome with each Mac that stopped or could not start.

Limits: until a Mac has run a tenth of a case, its speed is the starting estimate, so the first
cases can go to a Mac slower than estimated (`--ratio` helps when that is known); the structure's
work is not counted in a case's cost; a shared Mac's other work, such as CI on the mini, slows its
cases, which only shifts what the scheduler gives it once measured; a worker that hands a case back
takes no more in that sweep; and a sweep's end waits for any Mac still connecting, which on the
first connection for a build includes copying it.

## Measurements and interpretation

For a multi-body run, the overall structural trace is the largest displacement across
intact bodies. Individual histories are retained by object ID and name, shown in current
readouts and included as separate CSV series. Aggregate failure counts sum the bodies'
element counts; maximum displacement and damage take the maximum. A conservative
inter-object interaction stop prevents a completed capture, because inter-object contact
is outside the supported model.

Pressure snapshots retain every recorded solver gauge sample, converted to kPa relative to the
run's ambient pressure. Chart reduction retains the low and high value of each bucket, but CSV
export and stored data use the full history. The pressure readout reports the largest positive
overpressure; negative phases remain visible in the trace.

Gauges match by name, position and occurrence when the same name/position is duplicated. A
moved or renamed gauge does not silently compare with a different measurement location. Missing
matches are reported and their traces omitted. Times remain seconds since detonation in storage,
displayed/exported as milliseconds; comparison does not align peaks or remove propagation delay.

Structural histories sample the largest displacement of intact elements every 1 ms of simulated
time, with initial and final points. They are independent of the display's wall-clock update
schedule. Peaks are **recorded peaks**, not a guarantee that faster motion between samples was
resolved. Failure fraction and maximum damage are final-run readouts. Debris displacement is
excluded, as in the existing structural chart. Different structures can be overlaid, but the
largest intact displacement can refer to different physical locations in each structure.

Only completed, stable runs can be kept. The captured numerical settings come from the loaded
solver, with its target duration recorded at completion. Changing the stop target after completion
does not rewrite the historical target. An input edit awaiting rebuild cannot capture old fields
under new settings. Resetting or reopening creates a fresh solver; saved results do not resume it.

## Inputs and provenance

Each run retains its complete Scenario, numerical settings, elapsed time, step count, capture
date, app version, solver revision, Metal device name and operating-system version. A SHA-256
fingerprint covers the canonical encoded scenario and numerical settings, excluding camera,
playback speed, result name and measurements. The view marks historical inputs that differ from
the current editor and warns when selected runs use different solver revisions. Its input
disclosure shows charge, grid options, materials, supports and reinforcement counts.

`SavedSimulationRun.solverVersion` is the explicit numerical contract (`blast-solver-1` initially).
The horizontal support-connection extension advances it to `blast-solver-2`. Advance it when solver defaults, equations or numerical interpretation change. Development
executables without bundle metadata report app version `development`; the revision is not a
Git commit or binary hash. Device/OS metadata supports interpretation rather than a promise of
bit-for-bit reproducibility across builds or hardware.

## Headless runs

`BombCAD run` runs a saved project without a window, for scripts, CI and other Macs:

```bash
swift run -c release BombCAD run Example.bombcad --out Example-run.bombcad --csv run.csv
```

It drives the same simulation model as the app and its sweeps, and gives the same answer to
the last bit as the same case swept in the app, with or without a structure. The app sizes its
batches of steps to the GPU's speed, but the solver takes every decision that changes a step
(how many structural substeps to encode, which caps the air's step; when to freeze the air;
when contact joins after a failure) at checkpoints every 64 steps, which no batch runs past, and
it clips a step to a time limit only at the start of a batch. Three runs of the concrete box on
the medium grid each took 2,116 steps, with a front-wall peak of 1,093.1 kPa. (A run played back
at a set speed stops at moments the wall clock sets, so it does not repeat; sweeps and `BombCAD
run` go flat out.) The command prints a summary: steps, simulated and wall time, the Metal
device, each gauge's peak and the structure's largest deflection.

| Option | Effect |
|---|---|
| `--name <name>` | The saved run's name; by default the first free of "Headless run", "Headless run 2", … |
| `--out <new.bombcad>` | Writes a copy of the project, inputs unchanged, with the run added to its saved runs |
| `--csv <file>` | Writes the gauge and deflection histories, as Export CSV does |
| `--resolution coarse\|medium\|fine` | Runs on another air grid, resampling attached imports as a grid sweep case does |
| `--mass <kg>` | Changes the primary charge, as a mass sweep case does |
| `--duration <s>` | Changes the simulated duration |
| `--usd <scene.usda>` | Writes the scene and the structure's surface over time for rendering elsewhere; see [Exporting a run for rendering](usd-export.md) |
| `--vdb <folder>` | Writes the air as OpenVDB volumes, a file a frame, into a new folder; see [Exporting a run for rendering](usd-export.md#the-air) |
| `--fragments <spec.json>` | Flies a cased charge's fragments and tracers through the blast, one way, a frame at a time; see [Fragments](fragments.md) |
| `--thermal <spec.json>` | Reckons the fireball's thermal radiation on the ground and the scene's faces, a frame at a time; `--thermal-results` writes it as JSON; see [Thermal radiation](thermal-radiation.md) |
| `--cloud <spec.json>` | Hands the hot gas left at the end over to a model of the fireball's rise and cloud, followed for minutes; `--cloud-results` writes it as JSON, `--sounding <file.csv>` gives it a measured atmosphere, and `BombCAD cloud <results.json>` follows it again without the blast; see [The fireball's rise and cloud](fireball-rise.md) |
| `--consumer local\|<ssh host>` | Where the fragments fly: this Mac's CPU (the default) or another Mac |
| `--fragment-results <file>` | Writes the fragments' impacts as JSON |
| `--ground-shock <spec.json>` | Estimates the ground's shaking under chosen points from the overpressure on the ground, a frame at a time; `--ground-results` writes it as JSON; see [Ground shock](ground-shock.md) |
| `--frame-interval <ms>` | Milliseconds of simulated time between frames of `--usd`, `--vdb`, `--fragments`, `--thermal` and `--ground-shock`, 1 by default |

The input project is never modified, and neither `--out` nor `--csv` overwrites an existing
file. With `--out`, the project must have room for another run (16 at most). A legacy layout
JSON can be run too; it gets the default settings of a new project. The exit status is 0 on
success, 1 if the run fails (an unstable solution, an air grid too large for the GPU, a bad
project) and 2 for a usage error. The same command works inside a built app, as
`BombCAD.app/Contents/MacOS/BombCAD run …`.

## Project storage

```text
Example.bombcad/
  results/runs.json                  # dev.bombcad.runs, encodingVersion 1, ordered run UUIDs
  results/runs/<run-id>.json          # dev.bombcad.run, encodingVersion 1
  assets/<source-id>.mesh.json        # Shared with the live scene and other historical runs
```

A result record contains metadata, numerical settings, full measurements and the versioned
scene payload. Historical imported geometry references manifest assets using the same codec
as the live scene; no external OBJ/STL path is needed. The retained metadata scene and referenced
scene must agree. Loading checks source integrity, input fingerprints, gauge ownership, finite
values, ordered timestamps and supported payload versions before opening the project.

Keep at most 16 runs and 500,000 combined gauge/structure samples per run. The existing container
limits also apply: 64 MiB per file and 256 MiB total. Capture validates the proposed project
before appending a run, so an oversized result cannot make the document unsavable. Removing runs
removes their indexed result files; unrelated optional files remain. Source assets are retained
under the existing undo/preservation policy. Normal saves without captured runs create no result
index, and JSON layout export continues to omit this project-level result collection.

## Verification

```sh
swift test --filter 'HeadlessRun|SweepSchedule|SweepWorker|Fragment|SavedRunTests|CompletedRunCaptureTests|ParameterSweepPlanTests|ParameterSweepExecutionTests|ProjectSessionTests|ProjectDocumentTests|Thermal'
```

Tests cover actual Metal runs, explicit change tracking, stable historical inputs, fixed-time
structural sampling, reset/reopen, moved packages with imported history, shared source assets,
removal, invalid data, chart reduction and CSV quoting. Native checks cover two grids, overlays,
peak differences, rename, remove/restore, CSV export and save/reopen at time zero. Additional checks
cover complete-input undo, sequential cases, cancellation, source-aware grid planning and document
replacement. Native checks cover restoring a run and undoing it, mass/grid sweeps, partial cancellation
and the preserved baseline after completion and saving.

## Pressure measurements and grid sensitivity

Saved-run comparisons derive measurements from every recorded pressure sample, using linear interpolation between samples. No archive format change is required; existing saved runs support these measurements.

- Positive impulse integrates only positive overpressure over the entire recorded window, including later positive lobes. Signed impulse integrates positive and negative pressure. Both use Pa·s (equivalent to kPa·ms).
- Arrival is the first upward crossing of a common, editable absolute overpressure threshold (default 0.1 kPa). The threshold must be finite and greater than zero.
- Positive-phase duration runs from that threshold crossing to the first subsequent zero crossing. This threshold-dependent duration excludes the initial rise below the threshold.
- A trace starting above the threshold has unresolved arrival and duration. A detected pulse without a recorded zero crossing has incomplete duration. Impulses cover only the recorded window and can therefore underestimate longer events.
- Reference differences use the same threshold and matching gauge identity. Missing arrival or duration does not produce a fabricated difference.

The Grid sensitivity disclosure sorts selected runs from coarse to fine and shows successive changes in peak, positive impulse, arrival and phase duration. Comparability requires distinct resolutions and identical physical inputs, numerical settings other than air-grid resolution, target duration and solver version. Resampled imported geometry is deliberately excluded because its changing geometry confounds an air-grid-only study. These changes describe sensitivity; they do not assert mathematical convergence or estimate an order of accuracy.
