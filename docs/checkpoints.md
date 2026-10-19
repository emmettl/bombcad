# Checkpoints: a run saved part way and carried on

A run's state can be saved at a step and taken back by a solver built afresh from the same scene
and settings. The run then carries on exactly as it would have without stopping: the same to the
bit. That makes mid-run snapshots, what-ifs and ensembles from a shared start possible, and lets
a crashed run continue rather than start again from zero. It is the second tier of scrubbable
timelines, where any moment can be run again in full detail from the nearest checkpoint (the
first tier, display frames, is described with the app's timeline).

**Stage 1: the air, its refinement and its clocks. Stage 2: structures, envelopes' recorders and
venting, exposure planes, deflagrations and congestion.** Stage 3 is to add the app's "Save state
here" and "Continue from saved state".

```bash
blastbench snapshot --preset street --dx 0.25 --time 0.03 --checkpoint-at 0.01 --checkpoint-out street-10ms
blastbench snapshot --preset street --dx 0.25 --time 0.03 --resume street-10ms --out street-30ms.png
blastbench snapshot --preset street --dx 0.25 --from street-10ms --out street-10ms.png
```

`--checkpoint-at T` saves at the first 64-step boundary at or after T s. `--resume` carries on
from a checkpoint, and `--from` draws one as it was saved, with no physics. The fragments, ground
points and fireball fed alongside a run are not saved, so they are not allowed with these
options.

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

In the app's project package, a kept run's checkpoints are to live beside its timeline's frames,
under `runs/<run id>/checkpoints/step-000128/`, with one manifest and one size budget shared
with the frames. When the budget runs short, every other checkpoint is thinned out, keeping the
first and the last.

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
`/Volumes/StudioData/bombcad/checkpoints` for the benchmarks; `checkpointBytes` gives the raw
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
