# Performance

The question the project set out to answer: how close to real time can blast on structures be
simulated on a current Mac? All figures here were measured on an Apple M4 Max (32-core GPU,
36 GB) with `blastbench` and `scenebench`, in release builds. The same build has been measured
up to 10% slower in some sessions than in others, with nothing else running, presumably from the
machine's power or thermal state, and much more when other work shares the GPU. The headline
figures are now taken with `make perf` and kept as a series ([Tracking it](#tracking-it)).

## Short answer

Measured on 23 October 2026 with `make perf` at a9536ead: each scenario on today's recommended
settings (afterburning, hot air and far-field faces; the charge from the mapped start; the
fireball's gas losing the heat it radiates; structures settled under their own weight first), the
lower of two rounds. Each row is the latest figure taken in a quiet window, from one of two runs
(the Run column): 03:10–03:54 and 05:32–06:03.

<!-- perf:headline -->
| What is simulated | Slower than real time | Wall | GPU | Simulated | Steps | Size | Peak memory | Load | Run |
|---|---|---|---|---|---|---|---|---|---|
| Air blast, 1 M cells (0.5 m street) | 2.4× | 0.40 s | 0.15 s | 0.17 s | 815 | 1.0 M cells | 0.32 GB | 10.2 | 2026-10-23 05:32 |
| Air blast, 8.4 M cells (0.25 m street) | 31× | 5.2 s | 4.9 s | 0.17 s | 1,700 | 8.4 M cells | 0.95 GB | 11.0 | 2026-10-23 05:32 |
| Air blast, 67 M cells (0.125 m street) | 496×‡ | 84.3 s | 81.0 s | 0.17 s | 3,703 | 67.1 M cells | 6.0 GB | 10.2 | 2026-10-23 05:33 |
| Air blast, 0.25 m refined by 2 (the peaks of 0.125 m) | 91×‡ | 15.4 s | 14.7 s | 0.17 s | 1,871 | 8.4 M cells | 5.6 GB | 4.2 | 2026-10-23 05:34 |
| 225k-element concrete building, alone | 91×‡ | 3.1 s | 3.1 s | 0.034 s | 4,000 | 224,768 elements | 0.43 GB | 3.9 | 2026-10-23 05:34 |
| The same, contact running | 105×‡ | 3.6 s | 3.7 s | 0.034 s | 4,000 | 224,768 elements | 0.46 GB | 4.2 | 2026-10-23 05:34 |
| That building coupled to 1 M air cells | 118×‡ | 11.3 s | 10.8 s | 0.096 s | 908 | 1.0 M cells, 224,768 elements | 0.85 GB | 4.1 | 2026-10-23 05:34 |
| 160k-element three-storey building, coupled (0.25 m) | 70×‡ | 10.9 s | 10.7 s | 0.15 s | 1,415 | 3.2 M cells, 160,182 elements | 0.92 GB | 4.2 | 2026-10-23 05:34 |
| 23k-element frame collapsing, 3 s | 17× | 50.0 s | 49.2 s | 3.0 s | 9,493 | 1.3 M cells, 23,004 elements | 0.76 GB | 4.4 | 2026-10-23 05:35 |
| Twelve-storey office, first 0.5 s | 487× | 244 s | 144 s | 0.50 s | 2,613 | 1.5 M cells, 236,868 elements | 2.0 GB | 5.3 | 2026-10-23 05:39 |
| Beirut, the whole district on 4 m cells, 8 s | 28× | 228 s | 221 s | 8.0 s | 4,696 | 125.0 M cells, 738,387 components | 21.1 GB | 4.8 | 2026-10-23 05:47 |
| Beirut, the end-of-run damage judgement (the 4 m run's loads) | – | 49.8 s | – | – | – | 14,165 buildings, 738,387 components | – | 4.8 | 2026-10-23 05:47 |
| Beirut, the near box (1.32 km radius) refined to 2 m, 3 s | 14× | 42.3 s | 23.7 s | 3.0 s | 1,865 | 34.8 M cells, 162,086 components | 11.8 GB | 11.5 | 2026-10-23 05:48 |
| Beirut, the end-of-run damage judgement (the near box's loads) | – | 6.4 s | – | – | – | 3,012 buildings, 162,086 components | – | 11.5 | 2026-10-23 05:48 |
| Beirut, a drag preview frame (damage) | – | 0.62 s | – | – | – | 14,169 buildings, 724,512 components | – | 7.2 | 2026-10-23 03:31 |
| Beirut quick estimate, the full look | – | 58.8 s | – | – | – | 14,169 buildings, 724,512 components | 13.0 GB | 7.2 | 2026-10-23 03:31 |
| Beirut, a drag preview frame (damage), learned field model | – | 0.73 s | – | – | – | 14,169 buildings, 724,512 components | – | 11.3 | 2026-10-23 03:52 |
| Beirut quick estimate, the full look, learned field model | – | 61.7 s | 0.88 s | – | – | 14,169 buildings, 724,512 components | 16.1 GB | 11.3 | 2026-10-23 03:52 |
| Beirut, close calls refined: the first 8 buildings | 13× | 23.3 s | 14.7 s | 1.7 s | – | 12.0 M cells, 8 buildings | 4.4 GB | 27.8 | 2026-10-23 05:53 |
<!-- /perf:headline -->

The two runs, and the conditions as they were:

- **03:10–03:54.** The first quiet window by the rule the runner then used: no other `gpu-slot`
  job from 03:10 to the end (as `gpu-slot`'s job log confirms), load 1.6 to 3.3 at the GPU runs'
  starts, swap steady at 7.3 GB. But an iOS Simulator left booted by another session used a third
  of the GPU throughout, outside `gpu-slot`, and most GPU runs came out about 15% slower (12% to
  25%) than in the second run; the near box and the close calls did not, and the office was faster. Only the work on the CPU (the quick estimate and its preview) is taken from it.
  The runner's check now samples every process's GPU time too.
- **05:32–06:03,** once the simulator was shut down: no other job and no other GPU user for the
  first round (load 3.9 to 5.3, 10 to 11 for the first three air runs straight after the build,
  which the runner now waits out). From 05:53 others' district runs started, and the second round
  (and the first round's quick estimate, at load 24 to 49) ran beside them; it was stopped at
  06:03 after the coupled runs, so the frame, the office and Beirut have one round only.
- † Run beside another job, or (for GPU work) beside another process using the GPU. ‡ The two
  rounds differed by more than 5%: here the second round was the loaded one. In the first run the
  coupled runs' first round also settled each structure under its own weight (31.2 s, 21.0 s and
  276 s against 12.9 s, 12.6 s and 212 s), which the settle cache then held, as in the app.
- Rows without a simulated time are work on the CPU.

Against the figures this table showed before, measured on 3 to 17 October:

| What is simulated | 3–17 October | 23 October |
|---|---|---|
| Air blast, 1 million cells (0.5 m street) | 1× (0.3 s) | 2.4× (0.40 s) |
| Air blast, 8.4 million cells (0.25 m) | 19× (3.2 s) | 31× (5.2 s) |
| Air blast, 67 million cells (0.125 m) | 268× (46 s) | 496× (84 s) |
| 0.25 m refined by 2 (the peaks of 0.125 m) | 67× (11.5 s) | 91× (15.4 s) |
| The 225,000-element building, alone | 54× | 91× |
| The same, contact running | 98× | 105× |
| That building coupled to 1 million air cells | 70× (6.7 s) | 118× (11.3 s) |
| The 160,000-element three-storey building, coupled | 60× (9.3 s) | 70× (10.9 s) |
| The 23,000-element frame collapsing, 3 s | 11× (34 s) | 17× (50 s) |
| The twelve-storey office | 1,100× over 3 s | 487× over its first 0.5 s |
| Beirut on 4 m cells, 8 s | 25–28 min on the mini | 228 s |

**What changed since then**, from runs beside tonight's (interleaved rounds, agreeing within 2%):

- **The recommended air** is most of the air's change. On 0.25 m cells today's build took 3.6 s
  on the ideal gas with faces that copy (the old table's air), 6.0 s on afterburning hot air with
  far-field faces, and 6.1 s with the mapped start and the cooling besides (all three with the
  simulator running): 1.7 times, from a dearer cell-update (2,330 million cells a second against
  3,510) and 11% more steps in the hotter gas. The mapped start and the cooling cost under 2%.
- **The structure's own cost rose by half between 3 and 8 October, and has held since.** The
  table's 1,906 steps a second was measured on 3 October, before the concrete model gained
  compaction, cracks that turn with the stress, residual openings, inclined bars, bars that slip
  and the rest of that week. Built and run tonight side by side, the build of 3 October
  (1eb47fa2) gave 1,870 steps a second, that of 8 October (170cc1c8) 1,266 and today's 1,248.
  Builds in between put the steps at compaction (1c7720bc, about 10%) and at several commits on
  4–5 October and 8 October (about 15% and 10%; the Studio was too busy by then to pin them). So
  it is the features, not a regression, and since 8 October the structure has lost 1.5%.
- **Command buffers of 1 s** instead of the 75 ms aimed at since 12 October changed nothing, on
  the structure or the air: the timed command buffers cost nothing measurable.
- **Settling under self-weight** (17 October) takes about 18 s for the concrete building and 8 s
  for the three-storey one when the settle cache does not hold the structure; the table shows the
  cached runs. On top of that the coupled runs pay the recommended air and the structure's cost.
- **The frame's air is frozen after 0.28 s** where it was 0.80 s, so its collapse is mostly the
  structure alone, and it takes about the structure's own slowdown longer.
- **The office** was timed over 3 s, of which 1.8 s were the structure alone after the air froze;
  its first 0.5 s, fully coupled, are now the measure, and are not scaled up to 3 s. It varied
  more than the rest: 212 s with the simulator running and 244 s without, both with the settled
  structure cached, the GPU busy for only 59% of the second.
- **Beirut's district** had been timed on the mini only; on the Studio its 8 s take 228 s, and the
  whole process 435 s with reading the height grid, placing 14,165 buildings and building
  the solver.

"Real time" for a blast is not a useful target in itself: the event lasts a fraction of a
second, and the app plays it back at 100× slow motion by default. The practical meaning of these
figures is that a blast on a street scene computes in seconds, a damaged building in about ten
seconds, a collapse in under a minute, and a city district in a few minutes, with its quick
estimate in one and a preview frame of it, as the charge is dragged, in under a second.

## Tracking it

```bash
make perf              # waits for a quiet window, runs the list twice, appends to the history
make perf-compare      # each scenario against its previous entry; more than 10% slower is flagged
python3 Scripts/perf/compare.py --doc docs/performance.md   # redraws this page's two perf tables
```

`make perf` (`Scripts/perf/run-standard.py`) runs a fixed list of scenarios on the recommended
settings with this checkout's release binaries, built when the runs start and pinned to their
commit by `BOMBCAD_SOURCE_REVISION`. First it waits, checking every 10 minutes for up to five hours
(`--wait-from`, `--wait-until`; `--now` skips the wait), for a quiet window: no other holder of a
`gpu-slot`, no other process using more than 5% of the GPU, a load average under 8 and swap not
growing. If none comes it runs anyway (`--require-quiet` stops it instead) and records the
conditions. Every run is in `gpu-slot --mem` with its declared size. Each scenario runs twice, the
rounds interleaved; the lower wall time is kept and both are recorded. It writes `results.csv`,
`results.json` and each run's log to a folder on StudioData, and appends one line per scenario to
[`Benchmarks/perf/history.jsonl`](../Benchmarks/perf/history.jsonl): the commit, the date, the
machine (model, GPU cores, memory, macOS), the load and swap at the start, other GPU users, the
scenario's id and a hash of its settings, the wall and GPU time, the factor, the steps, the size
and the peak memory. `--collect <folder>` rebuilds the results and the history lines from a run's
folder. The table at the top takes each scenario's latest entry run in a quiet window, or its
latest if none was; `make perf-compare` sets each latest entry against the one before.

Run it on the Studio in a quiet window, not on the mini: weekly, and after anything that touches
the solver's speed (a kernel, the stepping, the refinement, the coupling, the quick estimate). The
scenario ids are stable, so that the series lines up: a changed scenario gets a new id rather than
a new meaning under an old one, and `compare.py` compares only entries whose settings hash and
machine match.

What the columns mean:

- **Wall** is the bench's own timed span, as everywhere on this page: the solve, without reading
  the scene, building the solver or writing an image. For the drag preview it is the median of the
  frames after the first, and for the close calls the time until the refined run has judged all
  eight buildings. The process's whole wall time is recorded beside it.
- **Slower than real time** is that wall time over the simulated time.
- **GPU** is the process's GPU time, all of it (setting up, settling, warming up and the timed
  span), from `ioreg`'s `accumulatedGPUTime` for its `AGXDeviceUserClient`s, read while it runs
  and once more as it exits (`Scripts/perf/linger.c` holds the process open for 1.5 s). With the GPU
  to itself, most runs were credited with 94% to 100% of their wall time (Beirut: 221 s of 228,
  its step buffers spanning 226 s); the office and the refined near box with 56% to 59%, which
  leaves the GPU idle for part of their span, and the 0.4 s street with 38%. Beside another process on the GPU it is credited with
  less, as the GPU interleaves the other's work into its command buffers' span: 42% to 77% beside
  the simulator (Beirut: 113 s of 262, the buffers spanning 260 s). A low share is so a sign of a
  shared GPU.
- **Peak memory** is `/usr/bin/time -l`'s peak memory footprint, which counts the Metal buffers.
- **Load** is the one-minute load average as the run started; the quick estimate's own threads
  raise it for the runs after it.

Each scenario's wall time, run by run:

<!-- perf:trend -->
| Scenario, wall time | 2026-10-23 03:12 (a9536ead) | 2026-10-23 05:32 (a9536ead) |
|---|---|---|
| `air-1m` | 0.50 s† | 0.40 s |
| `air-8m` | 6.1 s† | 5.2 s |
| `air-67m` | 97.5 s† | 84.3 s‡ |
| `air-refined-0.25x2` | 17.9 s† | 15.4 s‡ |
| `structure-alone` | 3.5 s† | 3.1 s‡ |
| `structure-contact` | 4.1 s† | 3.6 s‡ |
| `coupled-box-1m` | 12.9 s†‡ | 11.3 s‡ |
| `coupled-storeys` | 12.6 s†‡ | 10.9 s‡ |
| `collapse-frame` | 58.1 s† | 50.0 s |
| `office-0.5s` | 212 s†‡ | 244 s |
| `beirut-4m` | 262 s† | 228 s |
| `beirut-4m-judgement` | 40.5 s | 49.8 s |
| `beirut-near-2m` | 42.0 s† | 42.3 s |
| `beirut-near-2m-judgement` | 5.1 s‡ | 6.4 s |
| `beirut-quick-frame` | 0.62 s | 0.63 s† |
| `beirut-quick-look` | 58.8 s | 84.6 s† |
| `beirut-quick-field-frame` | 0.73 s | 0.77 s† |
| `beirut-quick-field-look` | 61.7 s | 75.0 s† |
| `beirut-close-calls-8` | 23.5 s† | 23.3 s |
<!-- /perf:trend -->

## Air solver

```bash
swift run -c release blastbench throughput
```

Street-canyon scenario: 64 × 64 × 32 m, 100 kg TNT equivalent, 170 ms simulated.

| Cell size | Cells  | GPU memory | Steps/s | Steps | Air swept | Whole event | Slower than real time | Sweeping all of it |
|-----------|--------|------------|---------|-------|-----------|-------------|-----------------------|--------------------|
| 0.5 m     | 1.0 M  | 0.06 GB    | 2,890   | 727   | 59%       | 0.3 s       | 1×                    | 2×                 |
| 0.25 m    | 8.4 M  | 0.48 GB    | 475     | 1,526 | 50%       | 3.2 s       | 19×                   | 30×                |
| 0.125 m   | 67 M   | 3.8 GB     | 67      | 3,055 | 42%       | 46 s        | 268×                  | 465× (est.)        |

That table is the ideal gas with faces that copy, as measured on 8 October 2026. On the
recommended air (`blastbench throughput --mapped --radiate`, the mapped start and the cooling as
the app's runs have them), on 23 October 2026 with `make perf` (see the
[short answer](#short-answer)):

| Cell size | Cells | Solver memory | Peak memory | Steps/s | Steps | Air swept | Whole event | Slower than real time |
|---|---|---|---|---|---|---|---|---|
| 0.5 m | 1.0 M | 0.08 GB | 0.32 GB | 2,040 | 815 | 62% | 0.40 s | 2.4× |
| 0.25 m | 8.4 M | 0.61 GB | 0.95 GB | 327 | 1,700 | 53% | 5.2 s | 31× |
| 0.125 m | 67 M | 4.9 GB | 6.0 GB | 44 | 3,703 | 47% | 84.3 s | 496× |

The 0.125 m run is now timed whole (`--full`) rather than estimated from a sample.

- **Still air is skipped.** The grid is cut into tiles of 8 × 8 × 8 cells, and a tile is swept
  only from the step before the blast can first reach it (see the
  [air-blast model](air-blast-model.md#skipping-still-air)). Over the street event 42% to 59%
  of the tiles are swept on average, and the event computes 1.5 to 1.7 times faster. The answer
  is the same to the last bit; `--no-skip` sweeps everything. (The 0.5 m run used to show 64%:
  the idle steps encoded past the end of the event were counted as sweeping tiles, and no
  longer are.)
- Throughput is about **2.1 to 2.6 billion cell-updates per second** when every cell is
  swept, each update being three directional sweeps; counting the skipped cells as updated,
  it is 3.0 to 4.5 billion. Earlier measurements gave 2.8 billion, and 3.2 to 4.8: the table
  was 6 to 9% faster when still-air skipping went in, and has come down with the features
  added since (see below).
- Halving the cell size costs 16 times as much: eight times the cells and twice the steps.
- Memory is 57 bytes per cell: two copies of the state, peak pressure, impulse, the solid mask
  and the visualisation volume.
- The time step is about a third of what still air would allow, because the hot gas left by
  the fireball has a high sound speed for the whole event.
- **Afterburning and hot air**, the recommended air since 15 October 2026, cost 1.3 to 1.85 times
  as much, from more work per cell, a shorter step in the hotter gas, and more of the air
  reached (below, "What the recommended air costs").
- Without `--full`, the finest figure is extrapolated from a timed sample of 192 steps of full
  sweeps, scaled by the swept fraction of the 0.25 m run (an estimate of 39 s, against 46 s
  measured).
- **The kernels are compiled for the gas in use.** Thermally perfect and dissociating air
  share the air's kernels with the ideal gas; compiled to handle all three, the kernels that
  sweep every cell ran the ideal gas 8 to 9% slower than before those models existed. The
  sweeps (coarse and fine) and the tile list are now compiled for the configured gas alone,
  which wins that back. The rest of the slowdown since, about 6%, came in small steps with
  later features.

### What the recommended air costs

Since 15 October 2026 runs start from `SolverConfiguration.recommended`: afterburning, hot air
and far-field faces. A run takes 1.3 to 1.85 times as long as on the ideal gas with copying
faces, the least when refined, and holds 73 bytes a cell instead of 57. Measured on 16 October
2026 with `blastbench profile` (by stage, each air against the others) and `blastbench aircost`
(a cell's update under each air, the street at 0.5 m with every cell swept, the airs stepped in
turn a few steps at a time; the minimum of 40 rounds, in a quiet spell where the minimum,
quartile and median agreed within 1%):

| Air | ns a cell-update | Against the ideal gas |
|---|---|---|
| Ideal gas, copying faces | 0.144 | 1.00 |
| Hot air alone | 0.199 | 1.38 |
| Afterburning with the ideal gas | 0.168 | 1.17 |
| Recommended | 0.215 | 1.50 |

- **Hot air's equation of state was most of a cell's extra cost.** With its vibration term made
  free (a throwaway build), hot air cost 1.04 times the ideal gas and the recommended air 1.20.
  Each update found a temperature from an energy six times (the five cells of its stencil and
  its own new state), each by two Newton steps and a third evaluation for the ratio of specific
  heats, and the energies of its two faces' four states: 21 evaluations, of two exponentials
  each.
- **Afterburning's fuel and oxygen** cost 1.17 a cell-update (16 bytes a cell more read and
  written each sweep, and the burn), and are the whole of the memory's growth: their two
  buffers, 8 bytes each.
- **The rest is more work**: on the street, 25% more cell-updates than the ideal gas's run (16%
  more steps, as the burning fireball is hotter and its sound faster, and 9% more cells swept a
  step); on open ground 3% more. Far-field faces cost nothing measurable.

Done: the temperature now comes from one Newton step from a rational first guess within 10⁻⁴
(Solver.metal, `airTemperatureAndHeat`), whose own evaluation gives the ratio of specific heats,
so each primitive state takes one evaluation instead of three. A cell-update on hot air costs
1.24 times the ideal gas's instead of 1.38, and on the recommended air 1.37 instead of 1.50
(the same quiet spell). Whole runs on the recommended air (`profile`, the old build and the new
in turn, in three quiet spells) take 1.05 to 1.08 times less on open ground and the street,
1.02 to 1.06 times less refined once there, and 1.04 to 1.07 times less close in refined once
(close in unrefined is too short to time). Results move in the last bits only: no peak, impulse or arrival
of `validate` (0.25 m, and 0.5 m refined once and twice) or `closeair` changed in the figures
printed, and the digests of the recommended air change.

Tried and dropped:

- **A table of the vibration term** (40 kB every 4 K, or 3 kB every 50 K with cubic
  interpolation), read from constant memory: 1.55 and 1.86 times the ideal gas, slower than the
  exponentials, as the threads of a group read scattered entries.
- **Each cell's state worked out once a sweep** and shared through the threadgroup's memory with
  the stencils that read it: bit-identical, but 1.07 to 1.29 times slower, as 18 kB a tile of
  shared memory leaves too few threads to hide the memory's latency.

Not done, by the user's choice on 16 October 2026: storing the fuel and oxygen in 16 bits would
save 8 bytes a cell (73 to 65, 11% of the air's memory) and about half of their 17% a
cell-update, but they would no longer be conserved exactly (rounding of about 10⁻⁵ of a mass
fraction a step). To revisit only if city-scale grids reach the memory's ceiling.

## Refinement

```bash
swift run -c release blastbench throughput --refine 2
```

Refined by 2 near the shock (see the [air-blast model](air-blast-model.md#refining-near-the-shock)),
a grid gives about the peaks of one twice as fine. Against that finer grid, in one session,
whole events:

| Event | Refined by 2 | Uniform, twice as fine | Faster |
|---|---|---|---|
| Street, 0.5 m cells | 1.2 s | 3.3 s (0.25 m) | 2.8× |
| Street, 0.25 m cells | 11.5 s | 46.5 s (0.125 m) | 4.0× |
| Open ground, 0.5 m cells | 1.6 s | 5.5 s (0.25 m) | 3.4× |
| Open ground, 0.25 m cells | 16.0 s | 97.6 s (0.125 m) | 6.1× |

On the recommended air (23 October 2026, `make perf`, margin 1), the street on 0.25 m cells
refined by 2 takes 15.4 s against 84.3 s on 0.125 m cells, 5.5 times faster, in 1,871 steps; 2,733 blocks are refined on average and at most 9,328,
and the solver reports 1.59 GB, against a peak footprint for the process of 5.6 GB.

On 0.25 m cells about 4,000 to 5,000 blocks of 4 × 4 × 4 cells are refined on average, 3 to 4%
of the grid, and memory is 1.55 GB (1 GB of it the pool of patches) against 3.8 GB on 0.125 m
cells. A fine cell's update, with its ghost cells, costs about 1.6 times a coarse one; the rest
of the refinement's work (saving the coarse cells around each patch, refluxing, averaging back
and placing the patches) is under a tenth of it. The gain grows as the blast spreads, since the
refined shell grows as the square of its radius and the air behind it as the cube.
`blastbench validate` gains less (13 s against 21 s on 0.5 m cells, 104 s against about 290 s on
0.25 m; with afterburning and hot air, 18 s against 28 s and 146 s against 419 s), as its blast does not spread far. With a deformable structure the gain is smaller
again, since the air around it is disturbed throughout: 100 ms of the cantilever wall at 200 kg
takes 7.2 s on 0.25 m cells refined against 11.0 s on 0.125 m cells, and of the concrete
building at 500 kg, 17.4 s against 22.4 s (149 mm of deflection against 148 mm). The fine cells' own outline (their mask, the structure
counted into them, and the wall fluxes at a patch's face) costs about a tenth. The first version, with larger blocks, was slower than
the finer grid; the [air-blast model](air-blast-model.md#refining-near-the-shock) has the story.

```bash
swift run -c release blastbench throughput --refine 2 --refine-levels 2 --dx 0.5
```

In two levels by 2, 0.5 m cells give about the peaks of 0.125 m cells. Whole events, in one
session, with the default 1 GB of patches and, in brackets, with 4 GB, which the patches never
fill:

| Event | Two levels by 2, 0.5 m | One level by 4, 0.5 m | One level by 2, 0.25 m | Uniform, 0.125 m |
|---|---|---|---|---|
| Street | 8.8 s (9.1 s) | 11.3 s (13.1 s) | 11.3 s | 46.3 s |
| Open ground | 8.1 s (10.5 s) | 9.9 s (14.2 s) | 16.0 s | 96.2 s |

So two levels are 5 to 12 times faster than the uniform grid they imitate, and 1.2 to 1.4 times
faster than one level by 4, which gives the same peaks (see
[Validation](validation.md#with-refinement)): their finest patches lie over blocks of 1 m rather
than 2 m, so the shell of 0.125 m cells around a shock is about half as thick, and around it the
first level's cells are 0.25 m across, an eighth as many in a given volume. They take less memory
too: at most about 5,300 patches of
the first level and 17,300 of the second, 1.4 GB, against 5,500 patches of 16³ cells, 2.0 GB, by
4. With 1 GB both fill it near the charge, and the part of the shock left out stays at the coarser
level; the peaks and impulses compared are with 1 GB. `blastbench validate` takes 80 s in two
levels, against 111 s by 4, 104 s on 0.25 m cells by 2 and 302 s on 0.125 m cells unrefined.

**What would not make it faster.** On `blastbench validate` the patches take about four fifths
of a refined run (104 s on 0.25 m cells refined by 2, against 21 s for the same grid
unrefined). Three ways to cut that were weighed:

- **A second level** (0.5 m cells refined twice by 2) puts the finest patches over the same 1 m
  blocks as 0.25 m cells refined by 2 do, so it could save only the coarse grid's work away from
  the shock: about a fifth, it was reckoned. Built since (above), it gives the same peaks and
  impulses 1.3 times faster on the street and on `blastbench validate`, and 2 times in the open,
  where the 0.25 m grid's pool is full and its coarse grid, eight times the cells, is swept
  throughout; and 1.2 to 1.4 times faster than one level by 4.
- **Smaller blocks** (2 × 2 × 2 cells): over the open-ground event on 0.25 m cells they would
  cut the refined cells by about a quarter but add half again to the ghost cells filled at the
  patches' faces, about 5% in all. Not built.
- **Flagging by the jump against the overpressure** instead of against the pressure, so that a
  weak shock and a strong one are refined alike: no faster (13.7 to 19 s against 13.4 s on
  0.5 m cells refined by 2), since the shell is not thick for want of a sharper test.

The cost is set by the area of the shock, which is largest where it is weakest. A higher
`refinementThreshold` (`--refine-threshold`) releases the weak far field: at 0.2 instead of
0.1 the same run takes 6.7 s instead of 13.4, with every peak and impulse the same except at
the farthest range, 27.8 m (6 m/kg^(1/3)), where the incident and reflected peaks fall from 80%
and 79% of Kingery–Bulmash to 70%. So for blasts that matter close in, a threshold of 0.2 halves
the cost.

### Where a refined run's GPU time goes

```bash
swift run -c release blastbench profile --preset open --refine 2 --refine-levels 2
```

`blastbench profile` runs a whole event with each of the air's stages in a compute encoder of its
own and sums their GPU time (the sums leave out the gaps between encoders), counts how closely the
patches fit the jumps the threshold flags, and times an empty dispatch; `--closein` takes
`closeair`'s burst at Z = 0.5. On a quiet Studio (October 2026), 0.5 m cells (40 mm close in),
refined by 2, the GPU time against the same grid unrefined, and its shares:

| Run | Against unrefined | Fine sweeps | Ghost fills | Coarse sweeps | Halo, reflux, restrict | Regridding |
|---|---|---|---|---|---|---|
| Open ground, one level | 5.4× | 52% | 15% | 19% | 9% | 4% |
| Open ground, afterburning | – | 49% | 18% | 20% | 9% | 4% |
| Street, one level | 5.3× | 45% | 18% | 19% | 11% | 5% |
| Close in, one level | 17× | 55% | 20% | 7% | 12% | 6% |
| Open ground, two levels | 30× | 56% | 21% | 4% | 16% | 3% |
| Street, two levels | 41× | 54% | 23% | 3% | 17% | 3% |
| Close in, two levels | 165× | 58% | 22% | 1% | 16% | 3% |

With the deformable wall on 0.25 m cells, the structure takes 34% of a run refined by 2 and the
fine cells' outline and the debris' trade with them (remask and sync) 7% more. Afterburning makes
a fine cell's update 13% dearer and its ghosts 30%.

- **Per cell, a fine update costs about twice a coarse one**: a coarse cell 0.16 to 0.22 ns a
  sweep, a fine cell 0.22 to 0.30 ns, and its share of the ghost fills 0.08 to 0.12 ns more.
  The ghosts, two cells either side of a patch along each sweep, half again as many cells as
  the patch, are re-filled before every sweep; those over unrefined air are each interpolated
  afresh from seven coarse cells at two times.
- **Half the patches are margin.** Of the refined blocks, 44% to 67% hold a pair of cells
  whose pressures differ by more than the threshold; the rest are there because they lie within
  the margin (two coarse cells, then) of one, or, for the first of two levels, around the second.
  Only 12% to 30% of the refined cells lie in such a pair: a shock smeared over two or three
  cells cuts through blocks four cells across.
- **Launching is cheap**: an empty dispatch takes 2.2 µs of GPU time, about 30 dispatches a step
  with one level and 75 with two, so 1% to 3% of a step, and 8% close in with one level.
- **Close in, the patches cover most of the domain** (70% of its blocks), so they hardly pay:
  uniform 20 mm cells take 0.31 s against 0.46 s for 40 mm cells refined by 2, and uniform
  10 mm cells 4.3 s against 4.5 s refined twice. Over `closeair`'s four distances, whose
  domains grow with the distance, 40 mm cells refined twice take 28 s against 48 s on uniform
  10 mm cells.

What might be done, with the speed-up each might give a refined run, from these shares:

| | Change | Estimate | Risk |
|---|---|---|---|
| 1 | A margin of one coarse cell instead of two | 1.15 to 1.3 | The shock nearer the coarse ghosts; peaks to be re-checked |
| 2 | Cheaper ghosts: neighbouring patches read in the sweep, the coarse interpolation once per coarse cell and substep | 1.08 to 1.12 | Low |
| 3 | A uniform finer grid where the patches would cover most of the domain | Up to 1.5 close in | None to the answers |
| 4 | Two levels: halo of the ring only, refluxing in one dispatch | 1.05 to 1.08 | Low |
| 5 | Each level only the substeps its own waves need (now the advisor's, below) | 1.15 and 1.3 on open ground with one and two levels; 1.0 on the street; 0.93 close in | Measured; none to the answers |
| 6 | A fine sweep specialised for cells away from the patch's faces | 1.05 to 1.1 | Low |
| 7 | Longer coarse steps where the fastest wave is in a patch | Under 1.03 | |

The fifth was built then and left unmerged, as on the ideal gas it gained only on open ground:
there the fastest wave is usually in the fireball's hot middle, which is smooth and so left
coarse, and the patches took 1.2 of their 2 substeps a step; on the street, among the
buildings, 1.9; and close in, where the patches hold the fastest wave, all of them. On the
recommended air (16 October 2026) the street's patches take 1.39 of 2, and in three quiet
spells (`throughput`, wall time, rounds agreeing within 1%) refined runs took 1.19 times less on
open ground with one level and 1.31 to 1.33 with two, and 1.07 to 1.08 on the street; the
peaks of `validate` moved up by 1 to 2.5% (towards Kingery–Bulmash), impulses under 1%, and
`closeair` not at all. It is now `SolverConfiguration.refinementOwnSteps` (`--refine-own-steps`),
which the advisor turns on ("Choosing settings", below). Detailed profiling makes it look
slower, as each stage's encoder of its own weighs on its extra dispatches: time it with
`throughput`.

Since, on 15 October 2026:

- **The first is the default** (`SolverConfiguration.refinementMargin` 1): it refines 15% to 23%
  fewer blocks, and runs take 1.18 to 1.33 times less on open ground and the street refined once,
  1.14 to 1.17 on the street refined twice and 1.02 on open ground refined twice, whose second
  level's pool is full either way (`throughput`, two interleaved rounds). Against a margin of two,
  no peak or impulse of `validate` (refined once and twice) or `closeair` (0.04 m refined twice,
  0.02 m once) moved by more than 1.3%, against reference scatters of 6.4% to 8%.
- **The third is the advisor's** (below, "Uniform when the patches cover most"): where a level's
  patches would hold more than a quarter of the domain, it weighs the grid of that level's cells
  instead: 1.37 times faster 2 m across. From two levels it stops at 0.02 m refined once where
  uniform 0.01 m cells would take 2.1 to 2.5 times as long, and goes to them only 1.5 m across.
- **The second did not pay**, and is on the branch `claude/cheaper-ghosts`, not merged. Its
  results are bit-identical (`digest`, refined by 2 and 4, once and twice), but the work moved
  rather than shrank: the ghost kernel got cheaper on open ground, while the fine sweeps, which
  now rebuild a ghost over unrefined air from its coarse cell's basis (96 bytes) and look up a
  neighbouring patch on every read, where a MUSCL stencil reads each ghost two or three times,
  got 5% to 25% dearer. Close in it was 1.1 to 1.2 times slower, on open ground no faster
  (five interleaved rounds each). As first built, with the bases worked out in a dispatch of
  their own before each sweep, it was 1.1 to 1.4 times slower than before.

**The fill among many blocks** (20 October 2026). A new patch's fill asked every rigid block
whether it held each fine cell, and asked again for the cell above: some thousands of blocks for
each of the patch's 512 cells over Beirut. Refined everywhere, the GPU's width hid it; refining a
[corridor](refinement-steering.md), whose two or three new patches a step leave it nearly idle,
the fill took 0.65 of the run's 2.5 GPU s. Each block of the level now lists the boxes overlapping
it, widened by two of its cells (`AirRefinement.setBoxes`), and the fill asks only those. Whether a
point lies in any box is the same answer, so runs are bit-identical
(`RefinementLevelsTests.fineOutlineOfManyBlocks`). On Beirut's 1 km box (8 m refined once to 4 m
under the ceiling, a quiet Studio, step buffers' GPU time) the corridor takes 2.0 s against 2.5 to
2.7, and refining everywhere 7.8 s against 8.6 to 8.9; the coarse cells alone take 1.0 s. What is
left of the corridor's cost per block (sweeps 2 times, ghosts 3 times the everywhere run's) is
dispatches too small to fill the GPU and the corridor's longer edge against coarse cells.

## Structural solver

```bash
swift run -c release blastbench structure
```

```bash
swift run -c release blastbench structure --contact
```

The single-storey concrete building: 224,768 elements of 62.5 mm, time step 9.1 µs.

| Mode                          | Steps/s | Element-updates/s | Slower than real time |
|-------------------------------|---------|-------------------|-----------------------|
| Before anything has failed    | 1,906   | 428 million       | 58×                   |
| With contact running          | 1,400   | 315 million       | 79×                   |
| Linear elastic, for comparison (`--elastic`) | 2,236 | 503 million | 49×             |

On 23 October 2026 (`make perf`, time step 8.6 µs, 0.17 GB) the first two rows were 1,281 and
1,105 steps per second (288 and 248 million element-updates per second, 91× and 105× slower than
real time). The table's figures date from 3 October, before that week's additions to the
concrete model, which together made a step about 1.5 times dearer: built and run side by side
tonight, the build of 3 October gave 1,870 steps per second, that of 8 October 1,266 and today's
1,248 (see the [short answer](#short-answer)).

The first two rows were 2,061 and 1,123 steps per second in earlier measurements; the first
has drifted down by about 8% with the features added since (and with the machine's thermal
state), and the second has gained from leaving buried nodes out of contact (below).

- The explicit time step is set by the element size and the speed of sound in concrete, and it
  is what makes structures expensive: 110,000 steps per simulated second at this resolution.
- **Threadgroup size mattered more than anything in the kernel.** The structural kernels were
  first launched in groups of the largest size the GPU allows, 1,024 threads. The element
  kernel needs many registers, so few such groups fit on a GPU core at once. Groups of 32 to
  512 threads run 50% faster (310 to 476 million element-updates per second; with contact,
  225 to 305 million), and 32, one SIMD group, is the fastest. Filling the contact grid
  deterministically (a clearing pass, then an atomic-minimum chain) later cost about 4% of
  that. The air solver, which is
  limited by memory bandwidth, is indifferent to its group size.
- **The concrete law is not the bottleneck.** The same mesh with a linear elastic material
  runs only 17% faster. Most of the time goes on reading and writing element and node data,
  and on hourglass control, which every material needs.
- **Contact is.** Switched on, it took 45% of the time. Nodes with all eight elements around
  them intact cannot meet a node of another piece without a surface node meeting it first, so
  the node pass marks them buried and contact leaves them out of its table and its search.
  That raised throughput with contact from 253 to 315 million element-updates per second, and
  the coupled runs of the three-storey building and the infilled frame gave the same results
  to the last digit.
- **Pairs that cannot touch are skipped** (October 2026). `blastbench contact-profile` times
  each case with contact off, with its table filled but no forces found, and in full. On the
  mini, quiet, contact took 20–23% of a structure's time: the table 4–10%, the pairs 13–16%
  (the solid building intact and with its front wall thrown out to break up, the shell
  building, and two terraced houses touching). Nodes that are not lattice neighbours begin two
  elements apart, so a node that has moved less than 0.45 of an element now looks only in the
  cells that hold a node that has moved further (see the
  [structural model](structural-model.md#contact)). Timed alternately with the old code on a
  loaded mini, three rounds each, the pairs took 30% less time in the solid building (1.39
  against 2.00 s over 1,500 steps) and 22% less with its wall breaking up; whole runs were 4%
  faster in the solid building, 11% in the shell building, 3% with the wall breaking up and
  4% for the terraced houses. The results are identical to the last bit in the intact
  buildings, the terraced houses and `blastbench digest`. With the wall breaking up they first
  differ between steps 500 and 550, by at most 0.6 µm on 8,719 nodes (a median of 9 units in
  the last place), as the compiler's fast arithmetic arranges the force sums differently, and
  the break-up then amplifies that (4,647 elements broken by step 1,500 against 4,698). A build
  that marks every node as moved, and so skips nothing, gives the same bits as the one that
  skips. Filling the table is now the larger part; folding its clearing pass into the previous
  substep's node pass would save a dispatch and a read of every node. Rooms and car parks of
  rigid objects spend under 1% of their time on contact: their cost is coupling to the air.
- Skipping the eigenvalue problem that finds diagonal cracks, for elements strained below
  cracking, was tried and made no measurable difference. Since 23 October it is skipped where a
  bound says no principal strain can reach the onset, which gains 3% ([below](#structure-step-cost)).
- Reading each element's material from a table (for structures of several materials) cost
  12%; compiling a specialised kernel for structures of one material recovers about half.
- The residual crack opening and the cyclic steel law cost about 8%. The cyclic law's history
  is read only for bars that have yielded; reading it for every bar cost twice as much.
- **Memory goes with the elements, not the lattice.** Element data (state, forces,
  reinforcement and its histories) is stored once per element, about 400 bytes with
  reinforcement, and node data once per node of an element, 32 bytes; the lattice itself
  costs 5 bytes per cell (a flag and the cell's element number) and 4 per node (the node's
  number); and contacts use a table that wraps space periodically, sized to about four
  entries per node at 40 bytes each (a header, a mark of movement and eight slots). The concrete building,
  225,000 elements and 283,000 nodes in a 1.4-million-cell lattice, takes 152 MB (about 156 MB with the marks of movement). Storing nodes for the whole lattice took 179 MB,
  and storing everything per lattice cell with a dense contact grid around the structure took
  640 MB. The coupled run takes 0.21 GB in all at 0.25 m air cells, against 0.70 GB at first.
  Reaching a node through its number costs nothing measurable, and the results are identical
  to the last bit, since the nodes keep their lattice order.
- The wrapped contact table cost 10% of contact throughput against a dense grid (253 against
  282 million element-updates per second, before buried nodes were left out), because cells a
  period apart share entries. A scrambling hash with the same memory cost 38%, because it put
  neighbouring cells far apart in memory.
- **Shrinking the contact table does not pay.** It is the largest part of the structure's
  memory after the elements, 45 MB of the concrete building's 147 MB. Sized to 4, 2 and 1
  entries per node instead of 8, it takes 126, 116 and 110 MB, but contact throughput falls
  by 5%, 10% and 16% (286, 271, 257 and 241 million element-updates per second in one
  session), because more cells share each entry and every extra candidate costs a node read
  before it is rejected. The results were identical to the last digit at every size, so no
  entry overflowed. Entries then held four nodes; on 25 mm elements they overflowed, with
  disastrous results (see the [structural model](structural-model.md#limitations)), so they
  now hold eight, and the table has four entries per node to keep its memory: contact
  throughput fell by about 6% (108 to 111 against 117 million element-updates per second,
  measured back to back).


### Structure step cost

Measured on 23 October 2026 (`blastbench structure`, the 225,000-element building alone, two
rounds each, interleaved, each in `gpu-slot`; no other process used more than 5% of the GPU, the
two rounds within 0.5% of each other). The builds kept from the first `make perf` runs
(`/Volumes/StudioData/bombcad/perf/bisect/`), in the order they reached main, and today's:

| Build | Steps/s | Change | What it added |
|---|---|---|---|
| 1eb47fa2 (3 Oct) | 1,938 | | |
| c74041b2 | 1,977 | +2% | shells, debris exchange, afterburning |
| 1c7720bc | 1,782 | −10% | compaction (Holmquist-Johnson-Cook) |
| da16258e | 1,741 | −2% | crack axes that turn |
| 9e693181 | 1,723 | −1% | residual crack opening |
| 5f920ba4 | 1,554 | −10% | the second crack (6030a01c) |
| 5c3d6105 | 1,473 | −5% | eight contact slots, inclined bars, the steel-aware step |
| 239a67ee | 1,433 | −3% | masonry joints, bare bars, the Model Code's tension law, sliding cracks |
| d5e57117 | 1,395 | −3% | |
| c2dcf7f2 | 1,296 | −7% | bars strained at the rate of their debonded length |
| 170cc1c8 (8 Oct) | 1,294 | | |
| 8da9b98d (23 Oct) | 1,220 | −6% | everything since |

Where today's step goes, from builds whose shaders were edited to leave things out (results not
kept; the run's elements are all far from cracking under gravity alone):

- The element pass is 85% of the step, the node pass 12% (nodes alone run 10,500 steps a
  second, and are bound by memory). Not writing the element state back saves 15% of the
  element pass, not writing the forces 2%: the pass is not bound by memory.
- **Most of the loss is code that does not run.** Compiling out every path that this run never
  takes (finding principal strains, crack axes, the second crack, interlock and dowels on open
  cracks, dilatancy, compaction's pressure, the search for bars bridging a crack, the cyclic bar
  law, the faces' loads, bond slip, fragments) gives 1,830 steps a second, 44% more, back to
  3 October's speed. Skipping the same paths with a branch that is never taken gains nothing:
  their presence, which the compiler pays for over the whole kernel, is the cost, not their
  work. Alone, the faces' loads cost 9% (when nothing loads them), the bars' rate and rupture
  over their debonded length 12% (live in this run), the second crack 4%, open-crack shear 3%,
  the bridging search 3%; together more than the sum.
- Padding the element state to 200, 208 or 224 bytes, to align it, changes nothing; nor do the
  rate factors' powers. Reading the corners again after the material law, instead of keeping
  them, is 9% slower.

What was done, each bit-identical by `blastbench digest`'s six sets and by
`ElementKernelSpeedTests` (a reinforced column pushed to failure, both kernels; and a million
random matrices against the bound):

| Change | Steps/s (alone) |
|---|---|
| 8da9b98d | 1,227 |
| No principal strains where a Gershgorin bound keeps them below the onset | 1,266 (+3%) |
| An element kernel without the faces' loads for substeps with none (function constant 40) | 1,370 (+12%) |

The second helps a body alone, a body under a prescribed velocity, and every structure settling
under its own weight before a coupled run; a coupled run's substeps load faces and keep the
general kernel. (These are `blastbench structure` runs interleaved with the base's in the morning,
with no other process on the GPU; `make perf` waited from 11:50 to 12:45 for a quiet window and
found none, the desktop app alone holding a third of the GPU, so the tracked series takes them at
its next night run.)

Tried and not landed (23 October; patches in `/Volumes/StudioData/bombcad/perf/structure-speed/B/`):

- **The element pass in two.** A light kernel, with the paths only cracked, framed, compacted or
  yielded concrete takes compiled out, ran the pristine elements and listed the rest for the
  general kernel, in a second, indirect dispatch. With all ten such paths out it ran 15% faster
  coupled and 10% alone, but it did not give the same bits: without the crack axes' turning, open
  cracks' shear or the cyclic bar law, the compiler's fast arithmetic rounded the paths both
  kernels share differently (the pushed column differed from the second substep). With only the
  seven paths whose removal left the bits alone (the principal strains, dilatancy, pressed
  interlock, the second crack, the turn back to the lattice, compaction's pressure, the bridging
  search), the light kernel was 1% faster, and the two extra dispatches made the whole 7% slower.
- **Compiling the element kernel for the air's gas** in coupled substeps, as the air's kernels are
  (`airModelConstant`): it moved the coupled wall's digest in every set.
- `noinline` on the concrete law, and the bars' loop kept rolled: each moved the pushed column's
  results.
- Reading the corners again after the material law, rather than keeping them: 9% slower.

What is left, and needs a decision rather than more of this: most of the 44% is open only to a
change that moves results at the rounding level, as the light kernel with every rare path out
does (the post-failure spread is of the size `--rounding` already shows,
[fast math](#fast-math-and-the-build)). It would land with `make ship ARGS=--full`. The bars'
rate and rupture over their debonded length cost 12% by their presence, but skipping their loops
at run time saves nothing, so gathering their neighbours once rather than twice would not help.

## Coupled runs

```bash
swift run -c release blastbench throughput --preset box --full
```

The same building in 32 × 32 × 16 m of air, 100 kg at 8 m, 96 ms simulated.

| Air cell size | Air cells | Whole event | Slower than real time |
|---------------|-----------|-------------|-----------------------|
| 0.5 m         | 0.1 M     | 6.2 s       | 65×                   |
| 0.25 m        | 1.0 M     | 6.7 s       | 70×                   |
| 0.125 m       | 8.4 M     | 13 s        | 141×                  |

On 23 October 2026 (`make perf`, the recommended air with `--mapped --radiate`), on 0.25 m
cells: 11.3 s, 118× slower than real time, in 908 steps, 0.85 GB at the peak, with the settled
structure taken from the settle cache. Settling the structure under its own weight first, which
the cache then holds for later runs, added 18 s (31.2 s against 12.9 s, in the earlier run that
night).

The structure sets the pace: refining the air from 0.5 m to 0.25 m costs almost nothing extra.
Each air step is followed by 5 to 15 structural substeps. Only the substeps the air's recent
step suggests are encoded (a quarter more, plus one), and the air step is capped on the GPU to
what they cover; encoding enough for still air, as before, left about two-thirds of them idle
while the hot gas kept the air's step short, and cost 10%. The count is set every 64 steps,
from the step before, and batches end at those checkpoints, so that it (and so the air's step)
depends only on the step count: a run repeats exactly however the app happens to batch it.

**With shells.** The same building meshed with [shell elements](shell-model.md) of 250 mm
(3,724 elements; `--shells 0.25`), measured in one session in which another program was also
using the GPU, so all the figures in this table are a little high:

| Air cell size | Shells, 0.25 m | Solid elements, 62.5 mm |
|---------------|----------------|-------------------------|
| 0.5 m         | 2×             | 74×                     |
| 0.25 m        | 7×             | 81×                     |
| 0.125 m       | 83×            | 157×                    |

**Mixed** (`--solid-near 8.2`): the front wall, facing the charge, as solid elements and the rest
as shells, tied together (see the [shell model](shell-model.md#shells-and-solids-together)):
24× slower than real time on 0.25 m cells, against 79× all solid, and 92× on 0.125 m cells.

Skipping still air helps the shell building little: its 32 m domain is mostly within a few
metres of the structure, where the air is always swept, and the charge stands close to it. On
0.125 m cells, 76% of the air is swept over the event and the run is 11% faster (70× slower
than real time, against 79×, in a later session).

With shells the air sets the pace instead: on 0.5 m cells the building runs at a couple of
times slower than real time, and on 0.125 m cells the air alone takes most of the time. The
shells' time step (34 µs for 250 mm concrete elements, against 9 µs) means a few substeps per
air step instead of 5 to 15, and there are 60 times fewer elements. GPU memory falls from 0.21
to 0.07 GB on 0.25 m cells. On its own (`blastbench structure --preset box --shells`), the shell
building runs at 1.2 times slower than real time.

## A three-storey building

```bash
swift run -c release blastbench throughput --preset storeys --full
```

A three-storey concrete frame, three bays by two of 6 m, with 250 mm slabs and 375 mm columns,
clad in 250 mm masonry with a window in every panel of its long faces: 160,182 elements of
125 mm in two materials, 100 kg at 8 m in front, 155 ms simulated.

| Air cell size | Air cells | GPU memory | Whole event | Slower than real time |
|---------------|-----------|------------|-------------|-----------------------|
| 0.5 m         | 0.4 M     | 0.15 GB    | 7.1 s       | 46×                   |
| 0.25 m        | 3.2 M     | 0.31 GB    | 9.3 s       | 60×                   |
| 0.125 m       | 25 M      | 1.6 GB     | 38 s        | 246×                  |

On 23 October 2026 (`make perf`, the recommended air), on 0.25 m cells: 10.9 s, 70× slower than
real time, in 1,415 steps, 0.38 GB in the solver and 0.92 GB at the peak, the settled structure
from the cache; settling it first added 8 s in the earlier run that night.

With the element data stored per element rather than per lattice cell, a building of this size
takes a third of a gigabyte; most of the 36 GB is still free.

**With shells and beams** (21,292 shells and 528 beams of 250 mm; `--shells`), in the same
session as the shell building above, against the solid elements rerun alongside:

| Air cell size | Shells and beams | Solid elements, 125 mm |
|---------------|------------------|------------------------|
| 0.5 m         | 17×              | 38×                    |
| 0.25 m        | 31×              | 52×                    |
| 0.125 m       | 231× (est.)      |                        |

The gain is smaller than for the single-storey building: the solid elements here are already
125 mm, and a shell does 32 layer points of work against a solid element's one. On its own the
structure runs at 6.6 times slower than real time.

## Collapse

```bash
swift run -c release blastbench snapshot --preset frame --time 3 --no-wave --out frame.png
```

The two-storey frame (23,004 elements of 125 mm, 1.3 million air cells of 0.25 m, 2,000 kg):
3 s simulated in 34 s, in which the columns nearest the charge break and both floors come
down. The
air was frozen after 0.80 s, when five acoustic crossing times had passed; from then on only
the structure is advanced. Larger elements help twice over: fewer of them, and a time step
twice as long. (The preset's charge was 250 kg until bars were made to hold cracked sections
together, then 1,000 kg until cracks turned with the stress; the frame now stands at both.)

On 23 October 2026 (`make perf`, with `--mapped --radiate`) the 3 s took 50.0 s (17× slower
than real time) in 9,493 steps, 0.76 GB at the peak. The
air now goes quiet and is frozen after 0.28 s instead of 0.80 s, so most of it is the structure
alone; 85 elements fail and the floors come down 4.8 m, as before.

Taller buildings, meshed as shells and beams of 0.25 m on 0.5 m air
(`blastbench snapshot --preset tall --dx 0.5 --time 4`, and `--preset tower`):

| Layout | Elements | Air | 4 s simulated in |
|---|---|---|---|
| Eight-storey frame, 28 m, 4,000 kg | 31,344 | 0.7 million cells | 84 s (21× slower than real time) |
| Twelve-storey tower with a core, 42 m, 4,000 kg | 94,532 | 1.0 million cells | 226 s (56×) |
| [Twelve-storey office](office-tower.md), steel and glass, 45.6 m, 1,000 kg (`--preset office --time 3`) | 236,868 | 1.5 million cells | 3 s in 3,296 s (1,100×) |

The air is frozen after 1.2 to 1.3 s; the rest is the structure alone, falling. The office costs
about 14 times the tower per second simulated: it has 2.4 times the elements, and a time step a
third as long, since its steel and curtain-wall frame carry waves faster.

The office's first 0.5 s, fully coupled to the air (`--preset office --dx 0.5 --time 0.5`,
23 October 2026, `make perf`): 244 s, 487× slower than real time, in 2,613 steps, 2.0 GB at the
peak, the settled structure from the cache, the GPU busy for 59% of it; 212 s in the earlier run
that night, beside the simulator, and 276 s settling the structure first. By then 28,204 of its 236,868 elements have failed (none of its 16,080 beam
elements), and 101 of the 480 steel connections have fractured. The rate is not scaled to the whole
3 s: after the air freezes the structure runs alone at another rate.

**A large-panel block of flats** ([its page](large-panel-flats.md); `blastbench panelblock`), solid
elements of 87.5 mm, two through each wall and floor, 670,560 of them with 92 joints between
parts (18,400 node pairs), contact on from the start, in a session shared with other GPU work:

| Run | Air | Simulated | Wall time |
|---|---|---|---|
| Under its own weight, damped, no air | none | 0.5 s | 280 s (560× slower than real time) |
| 500 kg in the street | 1.2 million cells of 0.25 m, frozen at 0.75 s | 4 s | 5,348 s (1,340×), its settling under its own weight first included |
| Gas in a corner flat (windows at 3 kPa) | 6.4 million cells of 0.125 m, never frozen | 1.5 s | 2,590 s (1,730×) |
| Gas in a corner flat (windows at 25 kPa, the preset) | 6.4 million cells of 0.125 m, never frozen | 4 s | 4,995 s (1,250×) |
The structure dominates: its time step is set by the 87.5 mm elements, about four times shorter than
the frame's, and it has 30 times the frame's elements. The gas needs 0.125 m cells, its young flame
being too slow on coarser ones, and a deflagration keeps the air awake and unrefined throughout.

## Districts

```bash
scenebench district-compare <Beirut's inputs> --dx 4 --height 320 --radius 2500 --mass 500000 --until 8 \
    --window 0.5 --ground saturated --observers Rigby2020_ESM1_radius_time.csv --out district
scenebench district-compare <Beirut's inputs> --dx 4 --height 320 --radius 1320 --mass 500000 --until 3 \
    --window 0.5 --ground saturated --refine 2 --ceiling auto --refine-memory 14 --out near
scenebench drag-time <Beirut's inputs> --dx 4 --height 320 --radius 2500 --loads loads-500000 --mass 500000 \
    --moves "" --drag 0,5,10,15,20,30,40,60,80,100 --parts damage --preview-draws 20 [--weights field.bcfw]
scenebench threshold-refine <Beirut's inputs> --dx 4 --height 320 --mass 500000 --buildings 8
```

[Beirut, 4 August 2020](beirut-2020.md), 0.5 kt, the inputs of its recipe, on 23 October 2026
with `make perf`: the runs from the second run that night (05:32–05:54, the GPU to themselves; one
round), the quick estimate and its preview from the first (03:31–03:51, beside a simulator that
used only the GPU; two rounds, within 1%):

| What | Wall time | Simulated | Steps | Size | Peak memory |
|---|---|---|---|---|---|
| The whole district on 4 m cells | 228 s (28× slower than real time) | 8 s | 4,696 | 125 M cells, 738,387 components | 21.1 GB |
| Its end-of-run damage judgement, as the app makes it, on the CPU | 49.8 s (40.5 s in the first run) | | | 14,165 buildings | |
| The near box (2.6 km across) refined to 2 m under a 46 m ceiling | 42.3 s (14×) | 3 s | 1,865 | 34.8 M cells and up to 5,460 refined blocks, 162,086 components | 11.8 GB |
| Its damage judgement | 6.4 s (5.1 s) | | | 3,012 buildings | |
| The quick estimate's full look, when a dragged charge is let go | 58.8 s | | | 14,169 buildings, 724,512 components | 13.0 GB |
| The same with the learned field model | 61.7 s, its peaks 0.11 s | | | | 16.1 GB |
| A drag preview frame (the damage), the median of the frames after the first | 0.62 s (the first 0.95 s) | | | | |
| The same with the learned field model | 0.73 s (the first 1.35 s) | | | | |
| Close calls refined: the nearest 8 of 1,057 close calls among 1,554 buildings | 23.3 s to the last answer, 16.0 s to the first | 1.742 s | | 12.0 M cells, 1,552 m across | 4.4 GB |

- **The district runs on the Studio in under four minutes**, against 25 to 28 on the CI mini
  ([Beirut](beirut-2020.md#cost)); the process takes 435 s in all, reading the height grid,
  placing the buildings and building the solver besides. Its step buffers spanned 226 s on the
  GPU, and the process was credited with 221 s of GPU time. Beside the simulator it took 262 s.
- **The judgement at the end of a run is a fifth of the run's time** on the district: 40 to 50 s
  on the CPU for 738,387 components, timed in `district-compare` around
  `EnvelopeDamageAssessment.assess` as the app calls it. It is the next thing to make faster on
  districts.
- **The learned field model** adds 3 s to the full look (5%) and 0.11 s to a preview frame (18%),
  and 3 GB of memory.
- **The close calls**: the quick estimate of the 1 km box's 1,554 buildings took 18 to 21 s, the
  refined run's first building was judged 16 s in and all eight by 23.3 s, against 22 s in
  [October's first measurement](surrogate-first-look.md#close-calls-refined-by-the-solver-21-october-2026).
- The judgements, the quick estimate and its preview run on the CPU (the field model's network
  apart), and their threads raise the load average to 10 to 13 while they run; they are the rows
  most moved by others' work on the CPU (the second run's full look took 85 s at a load of 49).

## The slab benchmark

With shells (`blastbench slab --shells 2,1`), 80 ms of the validation slab takes 0.4 s and 0.9 s
on 2 and 1 in elements, both with the converged answer.

`blastbench slab` runs 80 ms of the validation slab in 9 s with eight elements through the
thickness (68,608 elements of 12.7 mm, time step 1.7 µs) and in under a second with four. With
sixteen (553,000 elements) it takes about two minutes. Cracks that turn with the stress cost
about 1% against cracks on the lattice planes (since retired). Nonlocal crushing, when it
was an option, added about 3 s to the eight-layer time.

## Display

One frame takes 1 to 5 ms at 1400 × 875, depending on how much of the view the blast wave
fills, and frames share the GPU's queue with the solver's batches: at 60 frames a second that is
up to a third of the GPU, and more in a larger window or on a GPU that other work is using. So
while a run goes as fast as possible, the view times its frames and draws as often as a tenth of
the GPU allows, from 10 to 60 frames a second; paced playback draws at 60, and between runs
the view draws only on change (below). On a GPU
shared with other runs and tests, a fragments-on street canyon run (medium grid, 170 ms) took
53–55 s at 60 frames a second, 11–12 s with the limit, and 19–20 s headless, which also ends a
step at each millisecond's frame (1,856 steps against 1,527). The app aims for about 10 ms of
GPU work per batch of steps to keep the view fluid.

**The main thread.** Between batches the main thread takes in the batch's results and commits
the next, and the GPU waits whenever the rest of its work takes longer than a batch. A run's time,
step count and rates are shown at most 60 times a second, by small views of their own: when they
were set after every batch and read by the whole sidebar, SwiftUI took about 9 ms a batch, now
under 3 ms. The gauge chart is drawn again at most ten times a second, at about 9 ms each. A run
also tells macOS it is work the user is waiting for: in one trace of a window behind another app
on a busy Mac, 95% of the main thread's samples were on the efficiency cores, where each batch's
round trip and each chart took several times as long.

**Idle substeps.** The structural substeps for each air step are encoded before the GPU has
chosen the air's time step, so some return without work. In the three-storey building's first
150 ms, 13,504 substeps were encoded and about 8,900 needed. Inflating the surplus showed each
idle substep costs about 58 µs, so the idle ones take about 0.27 s of 8.5 s, or 3%. Encoding
fewer (a 10% or no margin over the last step, instead of 25%) saved 1% to 2%, within the
noise between runs, and changed the collapse, since the air steps fall differently. Indirect
dispatch, which would let the GPU skip them, needs bounds checks in every structural kernel
and a kernel to write the dispatch sizes, for at most those 3%; it has not been done.

**Between runs** the view draws only when something it shows changes: the camera, the display
settings, the selection, a new scene, or a run's time. It used to draw 60 frames a second
regardless, ray-marching the domain at every pixel each time, so an idle window took GPU time
from runs, sweeps and tests elsewhere on the Mac. With a street canyon open and nothing running,
on an M4 Max shared with other sessions' tests, the window took 16% of a GPU's time and 5% of a
core at 1440 × 920; it now takes none (the process's GPU time from `ioreg`'s
`accumulatedGPUTime`, over 30 s). During a run the view still draws on its timer, within the
budget above.

## Choosing settings

The advisor finds, for a scene and a target, the cheapest settings of the air that meet it, or the
best fidelity a budget buys: in the Run tab beside the Grid and Domain sections, and as
`BombCAD run <project> --advise peak:20%` (or `impulse:15%`, `deflection:30%`, `time:10m`), which
prints the advice and does not run. It weighs cells scaled to the charge (0.4, 0.2, 0.1, 0.05 and
0.025 m/kg^(1/3)) and the presets, unrefined or refined once or twice by 2 at thresholds of 0.1,
0.02 and 0.005, with and without afterburning; a scene with blocks or structures keeps to cells of
0.5 m or finer. It says which it did (the cheapest that meets the target, the nearest if none
does, or the best within the time) and what it could not meet, and the app applies the choice
with a click.

**Fidelity** is the standing's: each candidate's expected error is read from the error bands the
[standing](standing.md) would give that run, the worst over the gauges of the farther end of each
band from 1 (gauges without a band, such as those shielded from the charge, are named and left
out), and the structure's deflection band. So the advisor and the standing cannot disagree: both
read `ValidationTables`, the validation record's tables and the
[large scenes'](large-scenes.md#against-kingerybulmash-to-40-mkg13). Where nothing compared covers
a candidate (cells finer than any grid compared count as the finest compared), it has no band.

**Cost** is `RunCost`'s estimate for an unloaded M4 Max:

- steps from the hot gas's time step (about a third of still air's, 0.31 with afterburning);
- coarse cell-updates swept from when the blast reaches each part of the domain (Kingery–Bulmash's
  arrival, sampled over the domain), at 1.8 billion a second (the swept share it predicts, 27% for
  the 500 t burst, was 35% in the run);
- refined updates over a shell 18 cells thick about the shock while it is stronger than the
  threshold's reach (`ValidationTables.refinementReach`, 2 × threshold × ambient), no more at a time
  than the pool of refined blocks holds (a third of it for the first level and two thirds for the
  second), each fine update 1.6 times a coarse one; close in, the air within 0.8 m/kg^(1/3) of
  the charge refined from the shock's arrival to 6 ms/kg^(1/3) after the burst (below);
- 1.2 ms a step more with two levels of refinement (a step of its own costs nothing measurable);
- with adaptive substeps, the refined updates times the share of substeps a level is expected to
  take (`RunCost.ownStepsShare`): all of them while the patches hold the fireball close in, until
  6 ms/kg^(1/3) after the burst, and 0.6 of them after; within 0.05 of the shares measured on
  open ground, the street and the close-in burst 1.5 to 6 m across. The advisor turns them on
  for its refined settings where that share is under 0.8 (1.6 of 2 substeps;
  `RunAdvisor.ownStepsShare`), which is the open and the street but not close in, and the Run
  tab's "Adaptive substeps" can turn them off;
- the structure's element-updates at 300 million a second;
- 57 bytes a cell (73 with afterburning), plus the pools the refined levels are expected to grow
  to (`RunCost.poolShares`). A setting fits if both fit in what this Mac lets the air take. Where a
  target needs more, the advice says so, and names the sweep worker that would hold it (see
  [large scenes](large-scenes.md#the-refined-pools-memory)).

`blastbench advise --calibrate --time` sets it against runs timed on a quiet Mac (load under 2,
nothing else on the GPU; two rounds that agreed within 5%), the street and open ground of this
page and the large scenes' 500 t bursts alike: every one comes within 0.62 to 1.40 times the
estimate (uniform, refined once and twice, with and without afterburning; the pool's cap is what
brings the two-level runs in). The street reads low because more of its air is skipped than the
model's arrival times allow, behind its blocks. The large scenes' runs first recorded, on a Mac
loaded with other work, had taken 4 to 7 times as long.
Every finished `BombCAD run` records its wall time against its estimate in
`~/Library/Caches/BombCAD/run-costs.json`, and the advisor shows, beside the unloaded estimate,
what the median of this Mac's recent runs makes of it.

Limitations: only peaks, impulse and deflection are weighed; the cost of a structure is rough
(elements from its solids' volumes, a critical step of the element's size over 7,000 m/s); the
refined shell's thickness is one figure for every scene, and the close-in hold was fitted to one
burst, 0.5 m/kg^(1/3) above rigid ground; and wall times on a shared Mac vary by a factor of four
whatever the model says.

### Uniform when the patches cover most

Close in, the shock, the fireball and the reflections behind them fill most of the domain, the
patches stay where they are, and a level of refinement costs more than the grid of its cells
everywhere: its cells are each about twice a coarse cell's work with their ghosts, and every step
it fills halos, refluxes, restricts and regrids. So where a level's patches would hold more than
a quarter of the domain on average over the run (`RunAdvisor.uniformShare`), the advisor weighs
the grid of that level's cells in its place (refined once more if there were two levels, and so on
while the share stays as high), which has the same cells at the shock and finer ones elsewhere.
When the settings as they are fall in that case, it says so, in the Run tab and in `--advise`.

The threshold is where the two cost the same, measured on `blastbench profile --closein --width`,
1 kg 0.5 m above rigid ground in a domain the given width across and as high, run until the blast
has crossed it (1.5 m across, for `closeair`'s 5.5 ms), on 15 October 2026 (GPU time in the
stages, two rounds agreeing within 3%, the Mac shared with other work, so as ratios):

| Width | Patches' share | Uniform 0.02 m | 0.04 m refined once | 0.02 m refined once | 0.04 m refined twice | Uniform 0.01 m |
|---|---|---|---|---|---|---|
| 1.5 m | 0.63 | | | 11.4 s | 12.7 s | 10.9 s |
| 2 m | 0.31 | 2.6 s | 3.6 s | 14.2 s | 16.6 s | 30.4 s |
| 2.5 m | 0.25 | 4.8 s | 5.0 s | 23.3 s | 23.8 s | 58.6 s |
| 3 m | 0.19 | 7.8 s | 6.3 s | | | |
| 3.5 m | 0.15 | 12.8 s | 8.0 s | | | |

The share is of the domain's blocks refined once from 0.04 m, on average over the run. One level
and the grid of its cells cost the same at a share of 0.25; the per-cell costs alone would put it
near 0.47, but the uniform grid sweeps only the air the blast has reached, and the refined run's
halos, refluxing, restriction and regridding take 13% to 18% of its time besides. A level of
finer cells holds less: refined once from 0.02 m, 0.31, 0.16 and 0.11 of the domain at 1.5, 2
and 2.5 m, as the second level does from 0.04 m, since the smooth air behind the shock differs
less from one small cell to the next. So with two levels from 0.04 m, the rule gives uniform
0.01 m cells at 1.5 m and 0.02 m refined once at 2 m, the cheapest of the three in each.

For the share, `RunCost` holds the air within 0.8 m/kg^(1/3) of a charge refined from the
shock's arrival until 6 ms/kg^(1/3) after the burst, for a level of 0.04 m/kg^(1/3) cells, and
within a range that falls as the square root of the cells' size for finer ones (0.57 for 0.02;
coarser cells are held at 0.8, as the open ground's refined runs show nothing more). Fitted to the
shares above and at 4 and 6 m (0.117 and 0.056), it gives 0.72, 0.30, 0.22, 0.17, 0.15, 0.13 and
0.09 at 1.5 to 6 m, 0.37, 0.15 and 0.10 refined once from 0.02 m, and 0.37, 0.14 and 0.06 for
the second level at 1.5, 2 and 3 m (0.32, 0.16 and 0.10 measured); the shell alone gave two fifths
of the share at 1.5 m. The open ground and the street are unchanged.

## Fast math and the build

The kernels are compiled as one library with Metal's default, fast math. Environment switches
build them another way for measuring (`BuildProbe` in StructureTypes.swift; unset, nothing
changes): `BOMBCAD_KERNEL_MATH=relaxed` or `safe`, `BOMBCAD_KERNEL_CONTRACT=off` (Metal's
`fp contract` pragma: no fused multiply-adds), and edits that change no arithmetic,
`BOMBCAD_STATE_PADDING=n` (unused floats in the element state, at its end or with
`BOMBCAD_STATE_PADDING_AT=middle` after `compaction`) and `BOMBCAD_KERNEL_PERTURB=branch,kernel`
(a test in the element kernel that never passes; an unused kernel calling its helpers). Every
variant compiles and specialises its function constants as before.

**Edits that change no arithmetic move nothing.** Each of those edits left `blastbench digest`,
the quick Hupfauf (SN142, SN131), Janney and Chiquito P7 cases and the three Keys walls bit for
bit as the plain build (14 October 2026). An unused field in the middle of the element state
moves every later field, as `compactionStart` did, and still changed nothing.

**A different rounding moves results after failure,** as it would on another GPU or compiler.
Before failure the variants agree to about 1%; after it, see
[validation](validation.md#convergence-on-todays-defaults). Relaxed math changes no air result;
safe math changes the air's too.

**Cost,** against fast math, as the median of three interleaved rounds in a shared GPU slot
(the Mac's load 3–10, so steps per second were about a third of the figures above):

| Build | Structure alone | With contact | Three-storey building, coupled (0.5 / 0.25 / 0.125 m) |
|-------|-----------------|--------------|-------------------------------------------------------|
| Relaxed math | 1.00× the speed | 1.02× | 0.99 / 1.03 / 1.10× the time |
| Contraction off | 0.93× | 0.98× | 1.01 / 1.01 / 1.04× |
| Safe math | 0.82× | 0.86× | 1.19 / 1.24 / 1.40× |

The switches apply to the whole library, air included: on 0.125 m cells, where the air is most
of the work, safe math costs 1.4 times, so the air's kernels slow at least as much as the
structure's.

Fast math stays the default. A run chooses relaxed math or no fused multiply-adds as a
`KernelRounding` (`blastbench --rounding unfused`; `BombCAD ensemble --rounding-ensemble` and
`Scripts/concrete-matrix.py --rounding-ensemble` run all three) to see how far a result after
failure moves with the rounding; [validation](validation.md#the-models-spread-from-uncertain-inputs)
says how.

## Other Macs

Measured on the CI Mac mini (M4, 10-core GPU, 120 GB/s, 24 GB) on 7 and 8 October 2026, against
the M4 Max figures above (32-core GPU, 546 GB/s): 3.2 times the cores, 4.5 times the bandwidth.
The mini also runs other CI and an app on its desktop, so its figures are the best of several
runs; they agreed to within a few per cent overnight and when its runner was idle.

| Benchmark | M4 Max | M4 | Ratio |
|---|---|---|---|
| Air, every cell swept (`throughput --no-skip`), cell-updates per second | 2.8 billion | 0.57–0.64 billion | 4.4–4.9 |
| Air, street at 0.5 m, still air skipped, steps/s | 3,060 | 843–878 | 3.5 |
| Air, street at 0.25 m, still air skipped, steps/s | 524 | 140–144 | 3.7 |
| Structure alone (`structure`), steps/s | 1,227 | 378–381 | 3.2 |
| Concrete building coupled to the air, app's run loop (`BombCAD run`, medium grid) | 57–64 s | 110 s | 1.8 |

- **The air solver is limited by memory bandwidth.** With every cell swept, its rate per cell is
  steady at every size on both machines, and the ratio between them is the ratio of their
  bandwidths. Skipping still air leaves less work in each step, and the ratio falls towards the
  cores'.
- **The structural solver is limited by the GPU's cores** (or by something that scales with
  them, such as the chains of small kernels in each substep): its ratio is exactly the ratio of
  cores.
- **A coupled run in the app gains much less** than either, since part of its time is spent
  outside the GPU: the run loop waits for each batch and samples the structure every millisecond.
- The finest street grid (0.125 m) is quoted by `blastbench throughput` from a sample of full
  sweeps; on the mini that sample, 8 steps/s, is a full-sweep rate, so compare it with the first
  row, not with the 71 steps/s measured over the whole event above.

From these, a Mac with an **M5 Max, 40-core GPU** (614 GB/s) would be expected to run the air
about 1.1 times as fast as the M4 Max on large grids (the bandwidth ratio), up to 1.25 times on
small ones, and the structure about 1.25 times as fast (the ratio of cores), more if the M5's
cores are individually faster for this work, which is not known. Coupled runs in the app would
gain less. Its larger memory (up to 128 GB) matters more: it holds a street grid at 0.0625 m
(about 31 GB) that 36 GB cannot.

## Where the time goes, and what would help

| Cost                                              | Possible remedy                                        |
|---------------------------------------------------|--------------------------------------------------------|
| Structural time step tied to the smallest element | Shell and beam elements (done: 2–35× faster coupled); mass scaling |
| Air solved everywhere at one resolution           | Adaptive refinement                                    |
| Air solved before the blast reaches it            | Done: still air is skipped, 1.6–1.7× faster on the street scene |
| Air solved long after it matters                  | Already frozen once quiet; could be frozen region by region |
| Idle substep dispatches in coupled runs           | Now sized every 64 steps; worth about 3%, too little for indirect dispatch (below) |
| Concrete law costlier than the von Mises material | Profile it; the power functions in the rate and compression laws are the next suspects |
| A district's end-of-run damage judgement, 40 to 50 s on the CPU after a 228 s run (23 October 2026) | Profile it |

Shells and the skipping of still air are done. Adaptive refinement is the one left that would
change what is feasible.

Spreading one run over several Macs' GPUs is weighed in [Distributed computing](distributed-computing.md):
it would pay only on identical machines with fast links and large grids, and a bigger single GPU
or independent runs on other Macs come first.
