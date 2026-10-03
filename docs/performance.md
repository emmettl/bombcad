# Performance

The question the project set out to answer: how close to real time can blast on structures be
simulated on a current Mac? All figures here were measured on an Apple M4 Max (32-core GPU,
36 GB) with `blastbench`, in release builds. The same build has been measured up to 10% slower
in some sessions than in others, with nothing else running, presumably from the machine's
power or thermal state; figures here are from cool runs.

## Short answer

| What is simulated                                   | Slower than real time |
|-----------------------------------------------------|-----------------------|
| Air blast, 1 million cells (0.5 m in a street scene) | 2×                    |
| Air blast, 8.4 million cells (0.25 m)               | 27×                   |
| Air blast, 67 million cells (0.125 m)               | about 430×            |
| A 225,000-element concrete building, alone          | 54×                   |
| The same, once pieces are colliding                 | 98×                   |
| That building coupled to 1 million air cells        | 70×                   |
| A 23,000-element frame collapsing                   | 9×                    |
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

| Cell size | Cells  | GPU memory | Steps/s | Steps | Whole event  | Slower than real time |
|-----------|--------|------------|---------|-------|--------------|-----------------------|
| 0.5 m     | 1.0 M  | 0.06 GB    | 2,300   | 727   | 0.3 s        | 2×                    |
| 0.25 m    | 8.4 M  | 0.48 GB    | 340     | 1,526 | 4.5 s        | 27×                   |
| 0.125 m   | 67 M   | 3.8 GB     | 42      | 3,052 | 72 s (est.)  | 430×                  |

- Throughput is about **2.8 billion cell-updates per second** at every size, each update being
  three directional sweeps.
- Halving the cell size costs 16 times as much: eight times the cells and twice the steps.
- Memory is 57 bytes per cell: two copies of the state, peak pressure, impulse, the solid mask
  and the visualisation volume.
- The time step is about a third of what still air would allow, because the hot gas left by
  the fireball has a high sound speed for the whole event.
- The finest figure is extrapolated from a timed sample of 192 steps.

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
  reinforcement and its histories) is stored once per element, about 380 bytes with
  reinforcement, and node data once per node of an element, 32 bytes; the lattice itself
  costs 5 bytes per cell (a flag and the cell's element number) and 4 per node (the node's
  number); and contacts use a table that wraps space periodically, sized to about eight
  entries per node at 20 bytes each. The concrete building, 225,000 elements and 283,000 nodes
  in a 1.4-million-cell lattice, takes 147 MB. Storing nodes for the whole lattice took 179 MB,
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
  entry overflowed. The table stays at about eight entries per node.

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
Each air step is followed by 5 to 15 structural substeps. Only the substeps the last batch's
air step suggests are encoded (a quarter more, plus one), and the air step is capped on the
GPU to what they cover; encoding enough for still air, as before, left about two-thirds of them
idle while the hot gas kept the air's step short, and cost 10%.

**With shells.** The same building meshed with [shell elements](shell-model.md) of 250 mm
(3,724 elements; `--shells 0.25`), measured in one session in which another program was also
using the GPU, so all the figures in this table are a little high:

| Air cell size | Shells, 0.25 m | Solid elements, 62.5 mm |
|---------------|----------------|-------------------------|
| 0.5 m         | 2×             | 74×                     |
| 0.25 m        | 7×             | 81×                     |
| 0.125 m       | 83×            | 157×                    |

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

The two-storey frame (23,004 elements of 125 mm, 1.3 million air cells of 0.25 m, 250 kg):
3 s simulated in 26 s. The air was frozen after 0.79 s, when five acoustic crossing times had
passed; from then on only the structure is advanced. Larger elements help twice over: fewer of
them, and a time step twice as long.

## The slab benchmark

With shells (`blastbench slab --shells 2,1`), 80 ms of the validation slab takes 0.4 s and 0.9 s
on 2 and 1 in elements, both with the converged answer.

`blastbench slab` runs 80 ms of the validation slab in 7 s with eight elements through the
thickness (68,608 elements of 12.7 mm, time step 1.7 µs) and in under a second with four. With
sixteen (553,000 elements) it takes under two minutes. Nonlocal crushing, when switched on,
adds about 3 s to the eight-layer time: each element past its peak strain averages a
neighbourhood of up to nine points along each axis.

## Display

One frame takes 1 to 5 ms at 1400 × 875, depending on how much of the view the blast wave
fills, so the display never limits the simulation. The app aims for about 10 ms of GPU work per
batch of steps to keep the view fluid.

**Idle substeps.** The structural substeps for each air step are encoded before the GPU has
chosen the air's time step, so some return without work. In the three-storey building's first
150 ms, 13,504 substeps were encoded and about 8,900 needed. Inflating the surplus showed each
idle substep costs about 58 µs, so the idle ones take about 0.27 s of 8.5 s, or 3%. Encoding
fewer (a 10% or no margin over the last step, instead of 25%) saved 1% to 2%, within the
noise between runs, and changed the collapse, since the air steps fall differently. Indirect
dispatch, which would let the GPU skip them, needs bounds checks in every structural kernel
and a kernel to write the dispatch sizes, for at most those 3%; it has not been done.

## Where the time goes, and what would help

| Cost                                              | Possible remedy                                        |
|---------------------------------------------------|--------------------------------------------------------|
| Structural time step tied to the smallest element | Shell and beam elements (done: 2–35× faster coupled); mass scaling |
| Air solved everywhere at one resolution           | Adaptive refinement; a moving window that follows the shock |
| Air solved long after it matters                  | Already frozen once quiet; could be frozen region by region |
| Idle substep dispatches in coupled runs           | Now sized from the last batch; worth about 3%, too little for indirect dispatch (below) |
| Concrete law costlier than the von Mises material | Profile it; the power functions in the rate and compression laws are the next suspects |

None of these has been done. The first two are the ones that would change what is feasible.
