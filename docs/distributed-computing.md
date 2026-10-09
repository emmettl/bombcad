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
- **Separate models on separate machines** (the air on one, a fragment model on another,
  exchanging a little each frame) scale better than a split grid, but at most twice as fast,
  only when the models cost about the same; with this pair of machines the Studio's own CPU is
  the better second worker. See [Separate models](#separate-models-on-separate-machines).
  Most of the effects in the [long-term vision](long-term-vision.md) separate this way; three
  pairings do not. See [The long-term vision's effects](#the-long-term-visions-effects).
- **Before that, other routes win:** a bigger single GPU, faster single-GPU algorithms, and
  farming out independent runs (sweeps, grid studies, uncertainty), which scales perfectly at any
  size. [`BombCAD run`](run-comparison.md#headless-runs) is the building block for the last.

## The hardware at hand

| Machine | GPU | Memory bandwidth | Memory | Thunderbolt |
|---|---|---|---|---|
| Mac Studio (development) | M4 Max, 32-core | 546 GB/s | 36 GB | 5 |
| Mac mini (CI, `scrimply-ci-tb`) | M4, 10-core | 120 GB/s | 24 GB | 4 |

Measured, the M4 Max runs the air 4.4 to 4.9 times as fast as the mini when every cell is swept
(their bandwidth ratio) and the structure 3.2 times as fast (their ratio of cores); see
[Performance](performance.md#other-macs).

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

## Separate models on separate machines

Instead of cutting one model's grid, each machine could run a different model, exchanging a
little at each frame: the air on one, say, and a model of fragments flying ballistically on
another. This was weighed in October 2026; nothing is built.

**How it would work.** At each exchange, every simulated millisecond for instance, the air's
machine sends what the fragments need: the pressure, density and air velocity where each
fragment is. If the fragments act back on the air, their forces or blockage come back.

**Why it scales better than a split grid.**

- **Little data.** Ten thousand fragments at a few numbers each is a few hundred kilobytes an
  exchange, against megabytes of boundary cells every step.
- **Infrequent exchanges.** One a frame, not three a step. On the medium street grid a
  simulated millisecond is about six air steps and some 12 ms of the M4 Max's time, so a 0.1 to
  0.2 ms round trip over Thunderbolt IP is about 1%.
- **But send samples, not fields.** The whole medium grid's air is about 170 MB, more than 50 ms
  over this link: the air's machine should sample where the fragments are, or send only the
  region around them.

**The limit.** Two models side by side take as long as the slower of them instead of their sum,
so the most they can gain is a factor of two, when they cost the same.

- Fragments are usually cheap: thousands of particles with drag, gravity and ground impacts are
  little next to millions of air cells, so moving them saves almost nothing.
- They become expensive with contact between fragments or with the structure, break-up, or
  millions of pieces; then the gain approaches two.
- The mini is 3.2 to 4.5 times slower than the M4 Max ([Performance](performance.md#other-macs)):
  it should take the cheaper model, and the split pays only if that model runs there in less
  time than the air takes on the Studio.

**The direction of the coupling decides most.**

- **One way**, the air pushing the fragments but not the reverse, is the usual approximation
  when fragments fill little of the air. Nothing waits on the fragment model, which can trail
  behind, or run after the simulation from saved frames, as the
  [volume export](usd-export.md#the-air) writes them: no coupling at run time, on any machine.
- **Both ways**, each model must use the other's state from the previous exchange for the two to
  overlap. That is standard, and stable when the fragments are much denser than air, as concrete
  is; a millisecond is short beside a heavy fragment's response to the air.

**Built, as a trial.** A cased charge's fragments, flown one way through blocks of the air
streamed each frame, on this Mac or on the mini: see [Fragments](fragments.md). Over Thunderbolt,
1.6 GB of air went to the mini at about 200 MB/s without the run waiting for it, the result was
the same to the last bit, and, as expected, the fragments are too cheap for moving them to gain
anything: one CPU core keeps up with a few thousand.

**Better first.** The Studio's CPU is mostly idle while its GPU runs the air, and its cores could
step tens of thousands of ballistic fragments a millisecond without any network. A second queue
on the same GPU would help little: the air solver already uses nearly all its bandwidth.

**Air and structure split this way**, the coupling BombCAD already has, gain less:

- The structure is about three quarters of a coupled building run, so overlapping the two gains
  at most about 1.33 times, on two equal machines.
- They exchange every air step, not every millisecond, so latency counts again, and the loads
  and the structure's motion lag a step.
- On the mini, 3.2 times slower for the structure, the structure would hold everything up.

## The long-term vision's effects

Which of the effects in the [long-term vision](long-term-vision.md) could run apart from the
blast in this way, judged by the same tests: which way the coupling runs, how often, and how much
must pass. Most separate, because they happen on different time scales: prompt radiation in
microseconds, the thermal flash over milliseconds to seconds, the blast in milliseconds, collapse
over seconds, the fireball's rise over seconds to minutes, fire over minutes to hours, fallout
over hours to days. Effects that overlap in time and act on each other must run together; those
that only follow from the blast can trail it, or come after it, elsewhere. Of these models only
the blast, the structures, the thermal radiation and the fireball's rise exist.

| Effect | Coupling to the blast | Separable? |
|---|---|---|
| Structural response in a detailed study | Both ways, every air step | No: at most about 1.33 times (above). One GPU. |
| Fragments and debris | Mostly one way: the air pushes them; failed elements hand them over | Yes: alongside, on another machine or the CPU, or afterwards from saved frames |
| Simplified buildings across a wide area, as obstacles | Both ways: they shield and redirect the blast | No: they belong in the air's solve. Deriving them from detailed studies is independent runs, which scale perfectly. |
| Damage to those buildings | In effect one way, if most collapse comes after the main blast has passed (an assumption to state) | Yes: each driven by its recorded loads, as independent jobs |
| The early fireball (expansion, afterburning) | It is the hot gas in the air model | No: the same solver |
| The fireball's rise and cloud | Handed over once the blast has left | Yes, in sequence, from the air model's final state. Now a hand-over of a few numbers at the end of a run, followed for minutes in milliseconds: [The fireball's rise and cloud](fireball-rise.md) |
| Thermal radiation (flash exposure) | One way, fireball to surfaces; needs the fireball's size and temperature each frame, and the scene | Yes, the best candidate: small exchanges, concurrent with the blast, and what each surface sees is a job for the GPU's ray-tracing hardware ([Ray tracing](ray-tracing.md)). Now on this Mac's CPU, a few numbers a frame: [Thermal radiation](thermal-radiation.md) |
| Material heating and fire | Driven by the radiation; the blast's wind disturbs it only weakly | Yes: after the event |
| Ground shock away from the charge | One way: the air's pressure on the ground drives the soil | Yes: driven by recorded ground pressures |
| The crater and ground shock near the charge | Both ways, in the first milliseconds: the ground loads and vents the blast, and throws soil into it | No near the charge; yes for thrown soil once airborne, ballistic like fragments, unless its dust loading of the air matters |
| Prompt radiation | None with the flow; depends on the geometry and the air's density | Yes, entirely: before, alongside or independently |
| Fallout and plumes | One way, from the risen cloud and the weather | Yes, in sequence, after the rise |

So only three pairings need one solver on one GPU: the blast with detailed structures, with the
crater near the charge, and with the early fireball. These are where faster single machines
matter. Thermal radiation, fragments, thrown soil and distant ground shock are concurrent and
one-way, suited to a second machine or the CPU, with small exchanges each frame. The fireball's
rise, fire and fallout are a chain of hand-overs after the blast: they speed up a set of
scenarios, not one run. Wide-area studies are better placed than they look: deriving simplified
buildings and assessing each building's damage are independent runs, and only the air's solve
over the whole area must be one computation, the case where splitting a single grid eventually
pays ([When it pays](#when-it-pays)).

**Adding machines.** More hardware, a second and stronger mini or another Studio, can take on
the separable models, but a run cannot finish sooner than its inseparable core: with X the time
of the blast and whatever must share its solver, and Y that of everything separable, one machine
takes X + Y and enough machines approach X, a gain of at most (X + Y) / X. Today Y is nothing.
As expensive effects arrive (thermal radiation over a city, every building's damage, fire), extra
machines absorb them and keep a run near the blast's own time: they let the scope grow without
the run slowing, rather than making any one model faster.

- Models alongside the blast take a machine each, or several where they divide (thermal
  radiation by patches of surface, fragments by groups); the slowest share sets the pace.
- Independent jobs, each building's damage or deriving simplified buildings, scale almost in
  proportion to the machines, like sweeps.
- Hand-overs in sequence (the fireball's rise, fire, fallout) do not shorten one scenario; they
  raise the throughput of several, as a production line does.
- Work goes by cost: a stronger machine takes the heaviest separable model, the present mini
  (3.2 to 4.5 times slower) the lightest or the independent jobs.
- The blast's machine sends every consumer its share each frame: samples, kilobytes to megabytes,
  are fine; whole fields to many consumers would fill its link.
- One larger machine does some of this already, on its CPU or spare GPU, so extra machines pay
  once one machine is full; the inseparable core stays on one GPU, where a faster machine is
  the only help, until its grid outgrows it.

## Better first

- **A bigger single GPU.** An M3 Ultra (80-core GPU, 819 GB/s, up to 512 GB) would run about
  1.5 times as fast as the M4 Max with no communication at all, and could hold a 0.0625 m street
  grid (about 31 GB).
- **Single-GPU algorithms.** Letting refined patches take shorter steps than the coarse grid
  (subcycling), and cheaper contact, which takes 45% of a structure's time once on
  ([Performance](performance.md#structural-solver)).
- **Independent runs.** A sweep's cases, a grid-sensitivity study or an uncertainty ensemble are
  separate runs: only the project goes out and the result comes back, so the link does not
  matter and the scaling is perfect. Built in October 2026 for sweeps: see
  [Sharing a sweep with another Mac](run-comparison.md#sharing-a-sweep-with-another-mac). Six
  equal cases took 18.5 s on the Studio and the mini together against 22.1 s on the Studio
  alone, the mini running one, with identical results.

## Sources

- Apple, [Mac mini technical specifications](https://www.apple.com/uk/mac-mini/specs/): M4
  120 GB/s and Thunderbolt 4; M4 Pro 273 GB/s and Thunderbolt 5.
- J. Geerling, [1.5 TB of VRAM on Mac Studio: RDMA over Thunderbolt 5](https://jeffgeerling.com/blog/2025/15-tb-vram-on-mac-studio-rdma-over-thunderbolt-5)
  (2025): RDMA in macOS 26.2, its Thunderbolt 5 requirement, and measured latency.
- [Performance](performance.md): the single-GPU speeds, memory per cell and structural costs used
  above.
