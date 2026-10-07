# Distributed computing

Whether one simulation could be spread over several Macs' GPUs, and when that would be worth
it. Written in October 2026, prompted by the CI Mac mini sitting next to the development Mac
Studio on a Thunderbolt cable. Nothing here is built: it is an analysis, and the figures in it
are estimates from the measured single-GPU speeds in [Performance](performance.md) and the
machines' published specifications, not measurements of a distributed solver.

## Short answer

- **Splitting one run across the Studio and the mini would not help.** The mini is too small a
  partner and its link too slow; at best it would match one GPU.
- **Splitting one run across identical, larger machines starts to pay** once each GPU holds
  roughly 10 to 20 million air cells and the link has microsecond latency (RDMA). Two M4 Max
  machines over Thunderbolt 5 might run the 0.125 m street event about 1.8 times as fast.
- **It is essential only for problems too big for one machine**, such as a city block at
  0.0625 m (about a terabyte of state). There it would scale almost perfectly.
- **Before that, other routes win:** a bigger single GPU, faster single-GPU algorithms, and
  farming out independent runs (sweeps, grid studies, uncertainty), which scales perfectly at any
  size. [`BombCAD run`](run-comparison.md#headless-runs) is the building block for the last.

## The hardware at hand

| Machine | GPU | Memory bandwidth | Memory | Thunderbolt |
|---|---|---|---|---|
| Mac Studio (development) | M4 Max, 32-core | 546 GB/s | 36 GB | 5 |
| Mac mini (CI, `scrimply-ci-tb`) | M4, 10-core | 120 GB/s | 24 GB | 4 |

The link between them runs at 40 Gb/s, the mini's Thunderbolt 4 limit (`system_profiler
SPThunderboltDataType` on both). Thunderbolt Bridge networking over it is ordinary IP: typically
2 to 3 GB/s in practice, with a round trip of the order of 100 µs. macOS 26.2 added RDMA over
Thunderbolt 5, which reports latencies under 10 µs and 80 Gb/s, but it needs Thunderbolt 5 at
both ends, so not with this mini (an M4 Pro mini has it).

## How it would work

**The air.** Cut the grid into boxes, one per GPU (domain decomposition). Each step, every GPU
updates its own box, then swaps the cells along its faces with its neighbours. The scheme reads
two cells either side, so each face sends a layer two cells deep: about 40 bytes per face cell
(five 4-byte conserved quantities, two layers), more with afterburning's fuel and oxygen. The
sweeps are directional, so a fresh swap is needed before each sweep that crosses a cut: up to
three per step. All GPUs must also agree on the time step, the smallest any of them allows,
which is a global reduction every step: one round trip across the cluster. (It could be hidden
by using the previous step's value with a safety margin.)

A step then takes about

> compute ÷ number of GPUs + swaps (bytes ÷ bandwidth) + messages × latency

and it pays only when the first term clearly outweighs the other two. The compute falls with
the volume of each box, the swaps with its surface, so bigger boxes scale better.

**The structure.** A structure could stay on one GPU, with the air around it split among the
others, exchanging only the pressures and velocities at the interface. That is simple, but the
structure is usually the larger cost (below), so it would soon limit the speed-up. Splitting the
mesh itself means swapping shared nodes every structural substep (many per air step) and, hard
part, handling contact, failed elements and debris that move between GPUs.

## When it pays

Two identical M4 Max-class machines, the street-canyon grid cut in half (one shared face), whole
air steps:

| Air grid | One GPU, per step | Swapped per step | Over Thunderbolt IP | Over Thunderbolt 5 RDMA |
|---|---|---|---|---|
| 1 M cells (0.5 m) | 0.33 ms | ~0.6 MB | slower than one GPU | about the same |
| 8.4 M (0.25 m) | 1.9 ms | ~2.6 MB | 1.0–1.2× | 1.5–1.6× |
| 67 M (0.125 m) | 14 ms | ~10 MB | ~1.4× | ~1.8× |

The per-step times are measured ([Performance](performance.md#air-solver)); the rest are
estimates. With the mini as the partner instead, it could take only about a fifth of the grid
(its share of the two machines' bandwidth), so the best case is about 1.2× before any
communication, and over IP the communication takes most of that.

The usual pattern holds:

- Below about 1 to 2 million cells per GPU, latency dominates, and adding a machine slows a run.
- From roughly 10 to 20 million cells per GPU, with RDMA-class links, two to eight GPUs scale
  usefully (strong scaling).
- Splitting never reduces the number of steps, which are sequential: each halving of the cells
  still doubles them.
- For problems that do not fit one machine, the boxes are huge and the swaps negligible, and
  scaling is near perfect (weak scaling). A 256 × 256 × 64 m city block at 0.0625 m is about
  17 billion cells and 1 TB: eight or more large-memory machines, each with about 2 billion
  cells and some 0.7 s of compute per step, against milliseconds of swapping. An event would
  take about an hour.

## What makes this solver harder than a textbook case

1. **Structures dominate coupled runs.** The 225,000-element building runs 54 times slower than
   real time alone and 70 times coupled to a million air cells: the structure is about three
   quarters of the time. Splitting only the air would gain at most about 1.3 times.
2. **The work is lopsided at first.** [Still air is skipped](air-blast-model.md#skipping-still-air)
   until the blast can reach it, so early on only the GPU holding the charge has work. Fixed
   boxes would be badly balanced; the cuts would have to pass through the charge, or the tiles
   be redistributed as the blast spreads. The [refinement](air-blast-model.md#refining-near-the-shock)
   patches move with the shock and would need the same.
3. **Repeatability.** The solver repeats to the last bit, using fixed-point sums. A split run
   would need every reduction done in a fixed order, independent of how the grid is cut, to keep
   that.

## Better first

- **A bigger single GPU.** An M3 Ultra (80-core GPU, 819 GB/s, up to 512 GB) would run about
  1.5 times as fast as the M4 Max with no communication at all, and could hold a 0.0625 m street
  grid (about 31 GB).
- **Single-GPU algorithms.** Letting refined patches take shorter steps than the coarse grid
  (subcycling), and cheaper contact, which takes 45% of a structure's time once on
  ([Performance](performance.md#structural-solver)).
- **Independent runs.** A sweep's cases, a grid-sensitivity study or an uncertainty ensemble are
  separate runs: only the project goes out and the result comes back, so the link does not
  matter and the scaling is perfect. On the Studio and the mini together a sweep would finish
  about a fifth sooner (the mini completes about one case in five), and more usefully the mini
  could take a long study overnight. This needs the app to send cases to another Mac running
  `BombCAD run` and read back the saved runs; not built.

## Sources

- Apple, [Mac mini technical specifications](https://www.apple.com/uk/mac-mini/specs/): M4
  120 GB/s and Thunderbolt 4; M4 Pro 273 GB/s and Thunderbolt 5.
- J. Geerling, [1.5 TB of VRAM on Mac Studio: RDMA over Thunderbolt 5](https://jeffgeerling.com/blog/2025/15-tb-vram-on-mac-studio-rdma-over-thunderbolt-5)
  (2025): RDMA in macOS 26.2, its Thunderbolt 5 requirement, and measured latency.
- [Performance](performance.md): the single-GPU speeds, memory per cell and structural costs used
  above.
