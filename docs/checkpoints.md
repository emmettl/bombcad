# Checkpoints: a run saved part way and carried on

A run's state can be saved at a step and taken back by a solver built afresh from the same scene
and settings. The run then carries on exactly as it would have without stopping: the same to the
bit. That makes mid-run snapshots, what-ifs and ensembles from a shared start possible, and lets
a crashed run continue rather than start again from zero. It is the second tier of scrubbable
timelines, where any moment can be run again in full detail from the nearest checkpoint (the
first tier, display frames, is described with the app's timeline).

**Stage 1: the air, its refinement and its clocks. Stage 2: structures, envelopes' recorders and
venting, exposure planes, deflagrations and congestion. Stage 3: the app** saves a recorded run's
state every eighth of the way and at Simulation ▸ Save State Here, and continues a replayed run
from the state saved at the time shown or just before ([using the
app](using-the-app.md#continuing-a-run-from-a-saved-state)). Two follow-ups were measured and
stopped on 20 October 2026: [app tests from saved
states](#app-tests-from-saved-states-measured-and-stopped-20-october-2026), whose time is not in
the physics, and [ensembles from a shared
prefix](#ensembles-from-a-shared-prefix-designed-and-stopped-20-october-2026), whose proof is not
simple and whose saving is small.

```bash
blastbench snapshot --preset street --dx 0.25 --time 0.03 --checkpoint-at 0.01 --checkpoint-out street-10ms
blastbench snapshot --preset street --dx 0.25 --time 0.03 --resume street-10ms --out street-30ms.png
blastbench snapshot --preset street --dx 0.25 --from street-10ms --out street-10ms.png
```

`--checkpoint-at T` saves at the first 64-step boundary at or after T s. `--resume` carries on
from a checkpoint, and `--from` draws one as it was saved, with no physics. The fragments, ground
points and fireball fed alongside a run are not saved, so they are not allowed with these
options.

## Retaking a doc image from a checkpoint

A picture on these pages whose run takes an hour or more (the office on fin plates at 3 s, the
large-panel street charge at 1.5 and 4 s) is to keep a checkpoint shortly before its time, under
`$BOMBCAD_DATA/checkpoints/<image>/`, with a README giving the command and the
commit that wrote it. Its run is not repeated for that alone: the checkpoint is saved the next
time the scene is rerun for a reason of its own (a change to the physics, a release's pictures).
From then on, after a change that only alters how things are drawn (colours, the camera, what
is shown), the picture is drawn again from there in minutes:

```bash
blastbench snapshot --preset office --dx 0.5 --time 3 --frames 0.5,1,2 --checkpoint-at 2.9 --checkpoint-out office-fin-2900ms --out office-tower-fin-3s.png
blastbench snapshot --preset office --dx 0.5 --time 3 --resume office-fin-2900ms --out office-tower-fin-3s.png
blastbench panelblock --case street --frames 1.5,4 --checkpoint-out street
blastbench panelblock --case street --frames 1.5,4 --resume street/street-4000ms
```

`panelblock --checkpoint-out` saves one shortly before each frame (from `--checkpoint-lead`
s before it, 0.1 by default), in `<case>-<ms>ms`; `--resume` draws the frames after it again.
The resumed run must be given the same options as the run that saved, and the same frames
after the checkpoint (each frame's time clips the step before it). Its picture is then the
same to the byte.

- A change to the physics, the settings or the scene makes the checkpoint refuse: the run, and
  its checkpoint, are then made afresh (and the page's numbers checked).
- A checkpoint is read only by a build whose parts keep the same versions.
- Choose the checkpoint's time well before the picture's. Once the air sleeps, its steps are
  long, and 64 of them can take 50 ms or more.
- A run in which a delayed charge has fired is refused, and `--fragments`, `--ground-shock`
  and `--thermal` cannot be combined with checkpoints.

## What is saved

Each part of the solver lists "the state I own" (`SolverCheckpointing`): its buffers' byte
ranges and its scalars, with a version that changes whenever what it saves changes. A part added
to the solver must either join the list or appear in the refusals (`checkpointUnsupported`), so
it can never be silently left out.

- **The air:** both copies of the cells (a tile never swept holds the same in each), the fuel
  and oxygen with afterburning, the solid and rigid masks, the peaks and impulse, the fastest
  wave carried from batch to batch, which tiles are awake, the terrain's cut cells' carried
  differences and capped slivers. Also the clocks (the time, the step, the GPU's clock ticks),
  which copy of the cells is current, whether the air sleeps, the structure's last step, the
  still air, the gravity's ground state, the pools' bookkeeping, the energy radiated and the
  gauges' histories.
- **Each refinement level:** its pool's size and tables (block to patch, patch to block, the
  free stack, the counters, the patches listed for the next step and their dispatches, the
  pinned and seen marks), its fine cells in both copies, their species, masks, occupancy, wall
  speeds and impulse, and with cut terrain the fine cut cells and their differences. A second
  level's cells lie in its parent's buffers after the parent's own, and each level saves its own
  slice. The halo, the ghosts, the flux sums and the requests are rewritten every step before
  they are read, so they are not saved.
- **The radiative cooling:** the time since it last took its loss. It takes it every 4 steps,
  so a 64-step boundary is always a step it takes it on.
- **Each structure** (solids, shells, or both): its time, its step override, the step it failed
  at, its settled displacements and work sums, and every buffer it shares with the CPU (nodes,
  elements, layers and fibres, beams, damage, contact pairs, footings, bars, rubble, the terrain
  it rests on). The air's side of the coupling is saved with the air: the walls' speeds, the
  coupling tiles, the occupancy, the interaction and envelope buffers, the debris exchange and
  the structure's cut cells. A structure's buffers are found by reflection: the solver's own and
  those of its named sub-systems (`checkpointSubsystems`), so a buffer added to one is saved
  without being listed.
- **Envelopes:** the components' recorders (peaks, bins, histories, clocks; the still pressure,
  held on the GPU only, through a blit), the exposure, the venting's panes, walls and rooms, and
  an exposure plane.
- **A deflagration:** its buffers, its vents' opening times and the unburnt fuel it started with;
  **congestion:** its buffers and its current state.

A run is taken back into a solver built from the same scene and settings, which rebuilds
everything derived from them (pipelines, the terrain's geometry, gravity's tables, the mapped
start's records). Its pools are grown to the sizes they had when saved, and the saved state is
written over its own. The header's fingerprints of the scene and of the settings must match, and
so must the grid. A checkpoint from another scene, other settings or another grid is refused.

A checkpoint is taken only at a 64-step boundary (`BlastSolver.checkpointInterval`) and between
batches: there, every decision that depends on the coupling is made from the state alone.

## The format

A folder holding `checkpoint.json` and one file a part. The header gives:
- the format;
- the parts, with their versions and pieces;
- what it covers (`air`, `clocks`, `refinement`, `radiativeCooling`, `structures`, `envelopes`,
  `venting`, `exposurePlane`, `deflagration`), and whether that is the
  whole run's state;
- the fingerprints of the scene and the settings;
- the grid, the step and the time;
- the pools' sizes;
- the bytes before and after compression, and the seconds it took to write.

Each part's file holds its bytes LZFSE-compressed in chunks of 16 MB, on the CPU's cores. A
chunk compression does not shrink is stored as it is.

In the app, a run's checkpoints lie beside its timeline's frames, in
`checkpoints/step-000128/` of its recording, listed in its `run.json` (`RunTimelineManifest`,
entries of kind `checkpoint`, `pinned` for those saved by hand), and Keep Run keeps them in the
project package under `runs/<run id>/`. The manifest's budget is the frames' space and the
checkpoints' (Settings ▸ Replay) together. When the checkpoints pass theirs, every other one is
thinned out, keeping the first, the last and those saved by hand; a new one that still does not
fit is removed and the run saves no more by itself. `RunTimelineTests` runs a wall on the coarse grid for 0.2 s, saves by hand
when paused at 30%, replays, continues from the state at or before 70% and runs on: it ends with
the same digest as the run straight through.

## Checked

`blastbench checkpoint-check` runs each of the digest's air-only scenes straight through.
Separately, it runs them to a step, saves, builds a new solver, takes the state back and runs
on. It compares the two by a digest of the cells, peaks, impulse, clocks and every refined
level's fine cells block by block (`stateDigest`; which pool slot holds a block depends on the
GPU's atomics, so it does not count). On the CI mini, every one of the 24 runs below ended the
same to the bit:

- the open ground, the street and the street with afterburning (1 million cells);
- each on the default air, on the recommended air (the mapped start, afterburning, hot air and
  radiative cooling), refined once, refined twice, refined twice over a ridge on cut cells,
  refined once over a hill with gravity, and refined once over a slope saved at step 256 of 320;
- the open ground on 10 and 50 million cells.

What a checkpoint takes, early in a run (128–320 steps), on the mini:

| Cells | Settings | Raw | Stored | Save | Take back |
|---|---|---|---|---|---|
| 1 M | default air | 52 MB | 2–5 MB | 0.2 s | 0.01 s |
| 1 M | recommended | 69–70 MB | 3–48 MB | 0.2–0.3 s | 0.01–0.05 s |
| 1 M | refined once | 119–710 MB | 18–137 MB | 0.5–1.7 s | 0.04–0.35 s |
| 1 M | refined twice | 319–740 MB | 84–369 MB | 1.3–2.2 s | 0.2–0.25 s |
| 10 M | recommended | 664 MB | 74 MB | 1.1 s | 0.08 s |
| 50 M | recommended | 3.4 GB | 78 MB | 4.1 s | 0.6 s |

The raw size is about 66 bytes a coarse cell: two copies of the cells, two of the species, the
peaks, impulse and masks. Still air compresses to almost nothing, so the stored size follows how
much of the domain the blast has reached, and the refinement's pools. Saved by default to
`$BOMBCAD_DATA/checkpoints` for the benchmarks; `checkpointBytes` gives the raw
size beforehand.

Stage 2, on the Studio, also to the bit: the blast wall in solids and in shells, on the default
and the recommended air, saved at step 128 of 192 and 512 of 640, and refined; the street's
buildings with recorders, venting and an exposure plane on both airs; the gas-filled room's
deflagration; the open ground with an exposure plane (`blastbench checkpoint-check --case wall`,
`--street-envelopes`, `--envelopes`, `--exposure-plane`, `--preset gasroom`).

Through `blastbench snapshot`, on the street at 0.25 m:
- A run saved at 10 ms (at step 256, 14.3 ms; 554 MB raw, 18 MB stored, 1 s) and resumed
  draws the same image at 30 ms as the run straight through, byte for byte.
- The run that saved draws it too.

`SolverCheckpointTests` checks a refined-twice run on a slope saved at step 64 and carried on to
128, a struck wall in shells and a glazed building with its recorders and venting carried on the
same way, the refusals (a step off the boundary, another scene, other settings, a batch in
flight), and the compression's round trip.

## App tests from saved states (measured and stopped, 20 October 2026)

**The idea.** A test fixture would make a checkpoint once per test run, in a temporary folder and
never committed, since a checkpoint is read only by a build with the same part versions. App
tests that need only a run's late state would continue from it rather than run the whole
simulation (emmettl/bombcad-work#3).

**Standing: measured, not built.** The time is not in the physics. A fixture made once per test
run also costs the prefix it saves, unless two tests share it, and none of the slow ones do.

The app's suite took 365 s on the Studio with its suites in parallel. The tests that run a scene
to its end, each alone (debug build, `swift test --no-parallel`):

| Test | Alone | Where the time goes |
|---|---|---|
| New District's near and far field | 70–78 s, now 2–4 s | The run to 0.8 s takes about 3 s. The envelope damage judged at its end took 55–67 s, in the debug build's SDOF integration (`EnvelopeDamageAssessment.assess`); now under 1.2 s (below). |
| A scenario with a structure runs coupled | 13.7 s | Its own scene (500 kg on the blast wall); the rebuilds after it count too |
| Results export a row per sample | 7.1 s | Its own scene (the blast wall's default charge), and its every-step rows need the whole run |
| The others that run to the end | 0.1–2 s | Small scenes on the coarse grid |

Some other tests are slow, but they cannot start late:
- the thermal radiation, 20 s, compares a whole run with and without;
- meshing a structure in shells and back, 18 s, and the gauges' editing, 17 s, are rebuilds, not
  runs.

Several tests in parallel took minutes, but from sharing the Mac, not from their own runs.

**The SDOF integration made cheap (20–21 October 2026).** `SDOFSystem.integrate` now does the same
arithmetic in the same order, without generic code the debug build leaves unspecialised. First, the
tables are walked by index and `max`, `min` and `abs` have concrete stand-ins (a99c4117). Then:
- the backbone is read once, not on each step (each read retained and released it);
- each table's search starts at the last step's segment, not its first point: a pane's tables have
  75–89 points;
- the steps loop without a range iterator, and `ultimateResistance` runs without `map` and `max`.

Measured on 6,282 distinct SDOF inputs captured from the near/far test and the 25 envelope and glass
suites, replayed alone through the old and new code: 28.5 s to 6.9 s in a debug build, 1.07 s to
0.61 s at `-O`. Every response is the same to the byte, in both builds. In the package's debug
tests, under the same load: the near/far test 7.4–9.1 s to 1.9–4.3 s, and its end-of-run judgement
5.2–6.4 s to 0.66–1.2 s. The 25 suites went from 21.3 s to 0.9–1.4 s.

In release the judgement was a real wait at a district's end. On Beirut's saved run, the app's
`assess` of 465,671 façade loads (10,961 buildings) took 63–81 s and now takes 28–30 s, every
building judged the same.

The plan's examples cannot use a checkpoint:
- **FragmentOverlay's last frame:** fragments are fed alongside the run from its start and are
  not saved, so a run with them refuses to save or continue.
- **The replay of a kept run** (`RunTimelineTests`): it checks the recording from its first frame,
  and a continued run records only from where it continued.
- **Envelope damage at the end:** the judgement, not the run, is the cost.

A checkpoint fixture pays when several slow tests need the same late state. Then each one past the
first saves its run.

## Ensembles from a shared prefix (designed and stopped, 20 October 2026)

**The idea.** Many members of an ensemble differ only in a strength: a concrete's tension, a
steel's yield, a glass's flaw constant. Until the run reaches the point where that strength
decides anything (the shock arriving at the structure, the first crack), every member computes
the same thing. Run that prefix once, save it, and branch each member from the checkpoint
(emmettl/bombcad-work#3).

**Standing: stopped at the design.** The proof that a branch is safe is not simple for the
members that exist, and they would save almost nothing. Nothing was built.

### What a branching restore needs

Today a restore refuses any checkpoint whose scene or settings fingerprint differs
(`restoreCheckpoint(from:scene:)`). A branch needs a restore that takes a checkpoint saved from
scene A into a solver built from scene B, where B differs from A only in listed fields. It must
also prove that the saved state is, to the bit, the state B's own run would have reached. Three
parts:

1. **A fingerprint over everything but the varied fields.** The header keeps A's full
   fingerprint, the fingerprint with the varied fields blanked, and their values in A. B is
   accepted only if its blanked fingerprint is A's, and only for fields on an allow-list that
   says how each may be proved unread.
2. **The state taken back without the varied fields.** A structure's buffers are saved by
   reflection, so any buffer built from a material (per-element parameters, a precomputed table)
   would come back as A's and overwrite B's. Each such buffer must be known and left out, or
   rebuilt after the restore. Today nothing marks them.
3. **The proof that the prefix did not depend on the fields.** This is the hard part. The
   candidate proofs are below.

### The candidate proofs

- **"Not yet read" per field.** A field that no kernel or CPU step has read yet cannot have
  affected the state. This is false for every strength in the structural cases, from step 0:
  - `ValidationEnsemble.perturbed` scales Young's modulus with the compressive strength, so `fc`
    changes the stiffness, the wave speed and the step itself;
  - the hourglass control caps its force at a capacity that includes `0.02 ft` and the uncracked
    tension envelope (`Structure.metal`, the hourglass capacity), read every step in every
    concrete element;
  - the crack softening is packed from `ft` and the fracture energy into each material's GPU
    parameters at load (`StructureSolver.parameters(for:)`), and the self-weight settle runs
    every one of these kernels before the blast.
- **"Not yet decisive" per field.** A field that is read only in a comparison that has not yet
  gone the other way cannot have changed a bit. Suppose the base run uses each varied field's
  weakest value and no comparison has crossed. Then by induction over steps every stronger member
  takes the same branches and computes the same bits. That needs, for every site that reads the
  field:
  - an audit that the site is a pure threshold, with no smooth use below it;
  - a recorded running maximum of the compared quantity (the largest principal stress over `ft`,
    the hourglass force over its capacity, the bar stress over `fy`) in the kernels, saved with
    the state.

  The concrete model reads `ft` at cracking, in the tension envelope, in the hourglass capacity,
  in the crack softening and in the mortar joints' strength. Several options change how it reads
  it (cracked stiffness, cracked hex, tension stiffening). A site missed in the audit, or added
  later without its monitor, gives a silently wrong member. A bit-identical test on a few scenes
  cannot rule that out for others. This is the "cannot be proved safe" case the plan's stop rule
  names.
- **A digest of the would-be state.** Run B's prefix too and compare `stateDigest`s. This is the
  right test of an implementation, but as a proof it costs the prefix it was meant to save.

### What sharing would save

- **The ensembles' sampled members** vary every input together: charge, stand-off and `fc` with
  the tension. None of their prefixes are shared.
- **The calibration's design** (`--design`) varies the concrete's tension alone, but on cases with
  no air: Janney's and OA1's beams, Saatci's and Peterson's impacts, and the contest slab. Their
  loads act from the first step (a ramp, a weight at the beam's face, a pressure record from 0 ms).
  So they have no prefix before the strength is read, and only a short one before the first crack.
- **The coupled cases** (Wu's S8, Chiquito's S1) would share the flight of the shock to the slab.
  For Wu's S8 that flight is about 0.2 ms of a 100 ms run. The slab's response, which depends on
  every strength, is the run.
  - Measured on the Studio with `blastbench twoface --wu S8 --roomy --time T`, the slab already
    moving by 0.3 ms: 3 s of computing to 0.3 ms and 58 s to 5 ms, after the settle.
  - The ensemble reckons the whole member at about 1,000 s, so the shared prefix is about 0.3% of
    it.

### Where it would pay, and be simple

The one case that looks both simple and worth having is glass on a district. Before the shock
reaches a pane, the venting's pane is at rest: its deflection and its accumulated fatigue are
exactly zero, and the strength enters only as `stress / strength` with a zero stress
(`SolverVenting.metal`). A checkpoint whose panes are all still exactly at rest would then be the
same for any glass strength. That condition can be read from the saved state (each pane's
deflection, speed and fatigue all zero), with no new monitor. It still has to be confirmed that
still air loads a pane with exactly zero, and that nothing else reads the strength. On a district
the shock's flight to the far façades is a large share of the run. No ensemble varies glass strength
in a coupled run today: the glass cases take measured loads, and the district's glass chances come
from the surrogate. So this is left for when one does, with the would-be state's digest as its test.

## Limitations

- **Refused:** a batch in flight; a run in which a delayed charge has fired (charges still to
  fire are laid out again from the scene, so a checkpoint before the first fires is fine); the
  experimental rigid boxes.
- **The same build.** A checkpoint is read by the build that wrote it, or one whose parts keep
  the same versions. It is not an archive format.
- **The time limits a resumed run is advanced with must be those of the run it carries on.** A
  batch's first step is clipped to the time limit, so a different sequence of limits makes a
  different (equally valid) run.
- A pool that runs out of room before it grows makes the run depend on the GPU's timing, with or
  without a checkpoint (`refinementPoolGrewLate`).

## Sources

The method is the solver's own. LZFSE is Apple's (the Compression framework).
