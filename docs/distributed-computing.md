# Distributed computing

Whether one simulation could be spread over several Macs' GPUs, and when that would be worth
it. Written in October 2026, prompted by the CI Mac mini sitting next to the development Mac
Studio on a Thunderbolt cable. It began as an analysis, its figures estimates from the measured
single-GPU speeds in [Performance](performance.md) and the machines' published specifications;
what has since been built, and measured, is said where it comes up.

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
- **Feeding several models alongside the blast, on several machines,** was limited first by
  this Mac, not the network: cutting out each model's share of the air took the CPU about 5 ms
  a frame while the GPU waited. Cut out on the GPU, it now takes under a millisecond. See
  [Several consumers on several machines](#several-consumers-on-several-machines).
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
| Thermal radiation (flash exposure) | One way, fireball to surfaces; needs the fireball's size and temperature each frame, and the scene | Yes, the best candidate: small exchanges, concurrent with the blast, and what each surface sees is a job for the GPU's ray-tracing hardware ([Ray tracing](ray-tracing.md)). Now on a CPU, this Mac's or, from the app, another's, a few numbers a frame: [Thermal radiation](thermal-radiation.md) |
| Material heating and fire | Driven by the radiation; the blast's wind disturbs it only weakly | Yes: after the event |
| Ground shock away from the charge | One way: the air's pressure on the ground drives the soil | Yes: driven by recorded ground pressures. Built as an illustrative estimate, fed the ground's air each frame: see [Ground shock](ground-shock.md) |
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

## Several consumers on several machines

The case the table above points to: one blast feeding several separable models at once, each on
the machine that suits it, such as fragments on one Mac and thermal radiation on another. This is
a plan, measured where it starts; built so far are the first four steps below, but for
placing models by cost automatically.

**What there is.** A headless run feeds three consumers each frame: the fireball's size and
temperature to [thermal radiation](thermal-radiation.md), on a queue of its own on this Mac; the
bottom layer of cells to [ground shock](ground-shock.md), inline on this Mac; and a block of air
around the [fragments](fragments.md), on this Mac or on one other Mac through a worker. The
worker's protocol (version 2 when this was planned: JSON messages with raw binary payloads, over
the standard input and output of an SSH connection) already carried several sessions over one
connection, told apart by their identifiers, and its flow control is deterministic: the run waits only when a consumer falls
more than four frames behind, and the air it sends depends on reports already in, so a result is
the same wherever the consumer runs. But its sessions, reports and results were the fragments'
own, and a run has one remote consumer at most.

**Measured.** The street canyon on the medium grid, 0.17 s in 171 frames, from the Mac Studio,
with the CI mini as the other Mac, in October 2026 (two rounds of each arrangement; the Studio
was busy with other work, so its wall times are not compared, only the shares within a run):

| Each frame | Time | Size |
|---|---|---|
| Cutting out the fragments' block of air | 1.6 to 3.9 ms | 9.5 MB |
| Working out the fireball for thermal radiation | 3.2 to 5.1 ms | a few numbers |
| Cutting out the ground's layer | about 0.1 ms | 0.19 MB |
| Sending the fragments' air to the mini | 0.5 to 1.0 ms | |

All three together took 8 to 17% of each run, every frame with the GPU waiting, since a frame's
air is read between batches. The fireball is the dearest although it sends only a few numbers: it
is a pass over every cell on the CPU. The network is not the limit: the fragments' air went at 90
to 220 MB/s, against 0.9 GB/s measured through SSH over the Thunderbolt cable (1 GB in 1.1 s,
AES-GCM), and the run waited at most 0.27 s for the consumer. Taking frames at all also cost
about 5% more steps (1608 against 1527), each step ending on a frame's time.

**What it means.** Moving a consumer to another machine moves its own work, but not the cost of
feeding it, which stays on this Mac and grows with every consumer added. So the first work is on
this side.

**The plan, in order.**

1. **Cut the air out on the GPU.** (Done.) Kernels at the end of each batch, in
   `Extract.metal`, cut out the fragments' block of air and the fireball's sums row by row
   (added up on the CPU in double precision in a fixed order, so the same from run to run), but
   write only in the batch whose last step lands on its time limit, as a frame's does. A
   headless run says before each batch what the coming frame will want
   (`BlastSolver.frameRequest`, set from `SimulationModel.prepareBatch`), and `airSlice` and
   `fireball` return the GPU's result when it is for that moment, region and temperature, and
   read the state as before otherwise (the frame at time zero, the app, blastbench). The slice
   matches the CPU's to a unit in the last place of its half floats, nearly all of it exactly,
   and asking changes nothing in the blast. Measured as above, three rounds of each, the old
   build and the new alternating:

   | Each frame, all three consumers on this Mac | Before | After |
   |---|---|---|
   | The fireball | 2.8 to 3.0 ms | 0.03 to 0.05 ms |
   | The fragments' block of air (now a copy out of a shared buffer) | 1.7 to 2.5 ms | 0.4 to 0.8 ms |
   | All the run's work between batches | 4.7 to 5.6 ms | 0.5 to 1.0 ms |

   About an eighth of what it was, within the aim. With the fragments on the mini, sending them
   still takes 0.5 to 1.0 ms a frame on the thread that drives the GPU, which step 3 moves off
   it. The ground's layer (about 0.1 ms) is still cut out on the CPU. The Studio was busy with
   other work again (load averages of 7 to 62), so whole runs are not compared.
2. **One kind of consumer session** (protocol version 3). (Done.) A session names its kind
   (fragments, thermal radiation or ground shock) and what that needs to start; each frame's
   input travels as a header saying what it is, its samples as the payload; and the result comes
   back as one encoded outcome. The models are held the same way here and on a worker
   (`ConsumerEngine`), so each gives the same result to the last bit here, with all three
   sharing one worker, or spread over two, as the tests check. On a worker each session runs on
   a queue of its own, so several share a connection side by side. The worker is always a copy
   of the same build, so the protocol needs no compatibility with older versions. A frame's
   samples for another Mac are now copied out on the connection's writing queue, not the
   thread that drives the GPU: sending to the mini went from 0.6 to 1.0 ms a frame to about
   0.015 ms (three rounds, the old build and the new alternating), leaving 0.4 ms a frame for
   the run with the fragments there. Runs still send only the fragments to other Macs this way
   until step 3. Thermal radiation also has sessions of its own on a worker, built alongside,
   which send every receiver back after each frame for the app to draw; folding them into these,
   with that live view as an option of the kind, came with step 3.
3. **Fan-out.** (Done.) One list of consumers replaces the run's three
   separate feeds (`HeadlessRun.Feed`); each runs here or on another Mac, placed with
   `--consumer fragments=<where>,thermal=<where>,ground=<where>` (`local` or an SSH host; a host
   alone still places the fragments), those on the same Mac sharing one connection to it. The
   run waits only for whichever falls more than four frames behind, and prints for each its
   frames, bytes, what a frame cost the run to feed, and how long the run waited for it. Each
   gives the same result wherever it runs, as the tests check with the fragments on one
   in-process worker and the other two sharing another. Measured on the street canyon, the
   Studio quieter this time (load averages about 7), two rounds of each:

   | Where | Fragments | Thermal radiation | Ground shock | Run | Waited |
   |---|---|---|---|---|---|
   | All here | 0.30 to 0.32 ms | 0.03 ms | 0.06 to 0.07 ms | 5.3 to 5.4 s | 0 s |
   | All on the mini | 0.23 ms | 0.03 to 0.05 ms | 0.06 to 0.07 ms | 5.7 to 5.8 s | 0.02 to 0.04 s |
   | Fragments on the mini | 0.24 to 0.27 ms | 0.04 to 0.05 ms | 0.07 to 0.08 ms | 5.7 to 5.8 s | 0.02 to 0.03 s |

   Each column but the last two is what a frame cost the run to feed that model. About 0.4 ms a
   frame in all, wherever they run, about 1% of the run; the fragments' air went at about
   310 MB/s. Placing models on the mini added about 0.4 s, its connection at the start, and
   saved nothing, as expected: these models are cheap. What the step buys is the means to
   place an expensive one.

   In the app, too, each of the three runs here or, by its own **Run on** (**Fly on** for
   fragments), on a Mac set for sweeps, those on the same Mac sharing one connection to it.
   A kind may be live: its model's state then comes back after each frame for the app to draw
   (the fragments' particles, the receivers' fluence, the ground points' estimates so far), sent
   before the frame's report, so that a model reported caught up has its last frame's state in.
   The thermal radiation's own sessions, built alongside for its live view, are folded into
   these.
4. **Placement and failure.** (Done, but for placing by cost, which waits on a model worth it.)

   *Failure.* A consumer whose Mac dropped stopped reporting, and since the run waits for one
   more than four frames behind, the run waited for ever. Now every model placed on another Mac
   keeps each frame sent in a file (`ConsumerSpool`, written on a queue of its own and unlinked
   as soon as it is open, so nothing is left behind however the process ends), and if that Mac
   fails it or the connection drops, a consumer here takes every frame kept from the start, then
   those that follow (`ResilientFrameConsumer`). Same model, same inputs: the result is the
   same as if the other Mac had finished, and the run waits while this one catches up. Tried on
   the mini, its worker killed 46 frames into the street canyon with all three models there,
   the run finished with every result the same as a run kept here throughout (but for the
   ground's feeding time), its lines saying so: "here after frame 46, that Mac having failed:
   The worker on scrimply-ci-tb stopped." That test found that a write to the dead connection
   ended BombCAD with SIGPIPE; it now ignores the signal. Keeping the fragments' frames writes
   about 1.6 GB to the temporary folder in the street canyon, off the thread that drives the GPU.

   *Choosing the Mac.* Each model has its own picker in the app, this Mac or any Mac set for
   sweeps, as `--consumer` places each in a headless run.

   *Cost.* A worker reports with each frame the seconds its model has spent so far (protocol
   version 6), and a headless run prints each model's own time a frame where it ran. In the
   street canyon, the Studio busy with other work and the mini not:

   | Model | Here | On the mini |
   |---|---|---|
   | Fragments (2,000 and 500 tracers) | 1.19 ms | 1.09 ms |
   | Thermal radiation (about 10,500 receivers) | 1.17 ms | 0.93 ms |
   | Ground shock (19 points) | 0.01 ms | 0.01 ms |

   against about 39 ms a frame for the run. Each takes a few per cent of one core while the GPU
   runs the blast, so where it runs changes nothing. The rule for placing by cost follows: a
   model is worth another Mac once its time a frame nears the run's, when the run would begin to
   wait for it (the time each run waited is printed too), and then the fastest Mac free, as
   sweeps measure them. Choosing so automatically waits for a model that costly; until then it
   could only ever choose this Mac.
5. **A direct data channel, only if measured to be needed.** A TCP connection over the
   Thunderbolt Bridge, opened with a one-time token passed over SSH, which keeps control and
   authentication. At 0.9 GB/s a connection, and with separate connections for separate Macs
   spreading the encryption across cores, nothing foreseen needs it.

**What it will not do.** Today's consumers are cheap: one core keeps up with a few thousand
fragments, and the fireball's radiation and the ground's shaking are lighter still. Moving them
gains nothing until one is expensive, such as thermal radiation over a city or by ray tracing,
fragments that collide, or many buildings' damage. What the plan buys is room for those without
the run slowing, within the bound in [Adding machines](#the-long-term-visions-effects).

## Better first

- **A bigger single GPU.** An M3 Ultra (80-core GPU, 819 GB/s, up to 512 GB) would run about
  1.5 times as fast as the M4 Max with no communication at all, and could hold a 0.0625 m street
  grid (about 31 GB).
- **Single-GPU algorithms.** Letting refined patches take shorter steps than the coarse grid
  (subcycling), and cheaper contact, which takes 45% of a structure's time once on
  ([Performance](performance.md#structural-solver)).
- **Independent runs.** A sweep's cases, a grid-sensitivity study or an uncertainty ensemble are
  separate runs: only the project goes out and the result comes back, so the link does not
  matter and the scaling is perfect. Built in October 2026 for sweeps, across any number of
  Macs, each given cases by its measured speed: see
  [Sharing a sweep with another Mac](run-comparison.md#sharing-a-sweep-with-another-mac). Six
  equal cases took 18.5 s on the Studio and the mini together against 22.1 s on the Studio
  alone, the mini running one, with identical results; with the Studio busy with other work,
  the mini was measured faster, ran four of the six, and halved the sweep (a median 63 s against
  119 s).

## Sources

- Apple, [Mac mini technical specifications](https://www.apple.com/uk/mac-mini/specs/): M4
  120 GB/s and Thunderbolt 4; M4 Pro 273 GB/s and Thunderbolt 5.
- J. Geerling, [1.5 TB of VRAM on Mac Studio: RDMA over Thunderbolt 5](https://jeffgeerling.com/blog/2025/15-tb-vram-on-mac-studio-rdma-over-thunderbolt-5)
  (2025): RDMA in macOS 26.2, its Thunderbolt 5 requirement, and measured latency.
- [Performance](performance.md): the single-GPU speeds, memory per cell and structural costs used
  above.
