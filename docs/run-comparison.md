# Saved runs and comparison

Complete a stable simulation, then choose **Keep Run…** beside the chart. Give the result a
unique name. **Compare** opens a view of retained runs, with up to four pressure or deflection
traces overlaid. Choose a reference run to see absolute peak differences. Runs can be renamed
(press Return in the name field), exported to CSV, removed and restored with **Undo last removal**.

Keeping a run is explicit. Advancing, pausing or resetting the simulation does not automatically
add result data or mark a project changed. Keeping, renaming and removing results do; native
project saving and autosave include those choices. Changing inputs or selecting another preset
keeps earlier named runs. Opening a different project restores that project's run collection.

## Measurements and interpretation

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
Advance it when solver defaults, equations or numerical interpretation change. Development
executables without bundle metadata report app version `development`; the revision is not a
Git commit or binary hash. Device/OS metadata supports interpretation rather than a promise of
bit-for-bit reproducibility across builds or hardware.

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
swift test --filter 'SavedRunTests|CompletedRunCaptureTests|ProjectSessionTests|ProjectDocumentTests'
```

Tests cover actual Metal runs, explicit change tracking, stable historical inputs, fixed-time
structural sampling, reset/reopen, moved packages with imported history, shared source assets,
removal, invalid data, chart reduction and CSV quoting. Native checks cover two grids, overlays,
peak differences, rename, remove/restore, CSV export and save/reopen at time zero.
