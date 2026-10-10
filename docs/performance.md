# Performance

The question the project set out to answer: how close to real time can blast on structures be
simulated on a current Mac? All figures here were measured on an Apple M4 Max (32-core GPU,
36 GB) with `blastbench`, in release builds. The same build has been measured up to 10% slower
in some sessions than in others, with nothing else running, presumably from the machine's
power or thermal state; figures here are from cool runs.

## Short answer

| What is simulated                                   | Slower than real time |
|-----------------------------------------------------|-----------------------|
| Air blast, 1 million cells (0.5 m in a street scene) | 1×                    |
| Air blast, 8.4 million cells (0.25 m)               | 19×                   |
| Air blast, 67 million cells (0.125 m)               | 268×                  |
| Air blast on 0.25 m cells refined by 2 near the shock (the peaks of 0.125 m) | 67× |
| A 225,000-element concrete building, alone          | 54×                   |
| The same, once pieces are colliding                 | 98×                   |
| That building coupled to 1 million air cells        | 70×                   |
| A 23,000-element frame collapsing                   | 11×                   |
| A 160,000-element three-storey building, coupled    | 60×                   |

"Real time" for a blast is not a useful target in itself: the event lasts a fraction of a
second, and the app plays it back at 100× slow motion by default. The practical meaning of these
figures is that a blast on a street scene computes in seconds, a damaged building in under ten
seconds, and a collapse in about twenty.

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
- **Afterburning and hot air** (`--afterburn --air thermal`) cost about twice as much: the
  street event at 0.25 m takes 7.5 s instead of 3.5 s in one session, from more work per cell
  (the fuel and oxygen, and a temperature solved by two Newton steps for each pressure), a
  shorter step in the hotter gas, and more of the air reached. Hot air alone costs about a
  quarter.
- Without `--full`, the finest figure is extrapolated from a timed sample of 192 steps of full
  sweeps, scaled by the swept fraction of the 0.25 m run (an estimate of 39 s, against 46 s
  measured).
- **The kernels are compiled for the gas in use.** Thermally perfect and dissociating air
  share the air's kernels with the ideal gas; compiled to handle all three, the kernels that
  sweep every cell ran the ideal gas 8 to 9% slower than before those models existed. The
  sweeps (coarse and fine) and the tile list are now compiled for the configured gas alone,
  which wins that back. The rest of the slowdown since, about 6%, came in small steps with
  later features.

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
- Skipping the eigenvalue problem that finds diagonal cracks, for elements strained below
  cracking, was tried and made no measurable difference.
- Reading each element's material from a table (for structures of several materials) cost
  12%; compiling a specialised kernel for structures of one material recovers about half.
- The residual crack opening and the cyclic steel law cost about 8%. The cyclic law's history
  is read only for bars that have yielded; reading it for every bar cost twice as much.
- **Memory goes with the elements, not the lattice.** Element data (state, forces,
  reinforcement and its histories) is stored once per element, about 400 bytes with
  reinforcement, and node data once per node of an element, 32 bytes; the lattice itself
  costs 5 bytes per cell (a flag and the cell's element number) and 4 per node (the node's
  number); and contacts use a table that wraps space periodically, sized to about four
  entries per node at 36 bytes each (a header and eight slots). The concrete building,
  225,000 elements and 283,000 nodes in a 1.4-million-cell lattice, takes 152 MB. Storing nodes for the whole lattice took 179 MB,
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

Taller buildings, meshed as shells and beams of 0.25 m on 0.5 m air
(`blastbench snapshot --preset tall --dx 0.5 --time 4`, and `--preset tower`):

| Layout | Elements | Air | 4 s simulated in |
|---|---|---|---|
| Eight-storey frame, 28 m, 4,000 kg | 31,344 | 0.7 million cells | 84 s (21× slower than real time) |
| Twelve-storey tower with a core, 42 m, 4,000 kg | 94,532 | 1.0 million cells | 226 s (56×) |

The air is frozen after 1.2 to 1.3 s; the rest is the structure alone, falling.

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

Shells and the skipping of still air are done. Adaptive refinement is the one left that would
change what is feasible.

Spreading one run over several Macs' GPUs is weighed in [Distributed computing](distributed-computing.md):
it would pay only on identical machines with fast links and large grids, and a bigger single GPU
or independent runs on other Macs come first.
