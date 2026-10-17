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
- **Over Wi-Fi,** independent runs and work on saved runs still pay; anything that exchanges
  every step does not. The most useful case is a thin client: the app on a laptop, the blast on
  a large GPU elsewhere. A headless prototype, `BombCAD watch`, showed every frame of the ground's
  paint over the house Wi-Fi with 20 to 30 ms of lag, at about 1% of the run's time. See
  [Slower links](#slower-links-wi-fi-and-the-like).
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
| Thermal radiation (flash exposure) | One way, fireball to surfaces; needs the fireball's size and temperature each frame, and the scene | Yes, the best candidate: small exchanges, concurrent with the blast, and what each surface sees is a job for the GPU's ray-tracing hardware ([Ray tracing](ray-tracing.md)). Now this Mac's or, from the app, another's, its cells marched on the GPU, a few megabytes a frame: [Thermal radiation](thermal-radiation.md) |
| Material heating and fire | Driven by the radiation; the blast's wind disturbs it only weakly | Yes: after the event |
| Ground shock away from the charge | One way: the air's pressure on the ground drives the soil | Yes: driven by recorded ground pressures. Built as an illustrative estimate or a layered soil column, fed the ground's air each frame: see [Ground shock](ground-shock.md) |
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
a plan, measured where it starts; built so far are the first four steps below.

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
   `Extract.metal`, cut out the fragments' block of air and the fireball's sums block by block
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
4. **Placement and failure.** (Done.)

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
   runs the blast, so where it ran changed nothing then.

   *Measured again with the march.* Since then the thermal radiation marches the fireball's
   luminous cells on the GPU, a ray per direction from each receiver ([Thermal
   radiation](thermal-radiation.md)), which is not cheap, and shares this Mac's GPU with the
   blast. Measured in October 2026 on two scenes, both 100 kg with afterburning and hot air,
   0.17 s in 171 frames: the street canyon on the fine grid (67 million cells, about 10,500
   receivers), and a city block of sixteen blocks 22 m square and 12 to 27 m tall in
   128 × 128 × 32 m on the medium grid (34 million cells, about 35,000 receivers). Rounds
   interleaved, medians; the Studio was shared throughout with other sessions' builds and an
   iOS Simulator's and other apps' GPU work (load averages 13 to 210), which stretched runs up
   to four times, so the times within a run say more than whole runs. The run now prints the
   GPU's time on the blast, and on the march where it runs here.

   | City block, thermal radiation only | Run | Blast's GPU time | March a frame | Of it this GPU's | Waited |
   |---|---|---|---|---|---|
   | No models | 20.9 s | 18.1 s | | | |
   | Here | 37.4 s | 30.4 s | 51 ms | 26 ms | 0 s |
   | On the mini, busy with tests | 43.9 s | 23.6 s | 188 ms | | 12.7 s |
   | Later, all slower: here | 87.4 s | 67.0 s | 123 ms | 51 ms | 0 s |
   | On the mini, quieter | 71.7 s | 60.9 s | 66 ms | | 0 s |

   On the city block the march is the dearest model by far: here it lengthened the run by
   about 80%, more than its own time on the GPU, since the blast's batches and the march's
   take turns on it. The fragments (2,000 and 500 tracers) took 1.5 to 1.7 ms a frame and the
   ground shock 0.02 ms, on the CPU, wherever they ran. On the mini the march took 54 to 66 ms
   a frame when it was quiet and 150 to 280 ms while its own tests ran; it kept up with the run
   in the first case and held it up by 5 to 22 s in the second. In the second set of rounds,
   every round, the run with the march on the mini was the quickest (57 to 84 s against 68 to
   114 s). On the street canyon's fine grid, frames of 1 to 4 s, the march took 90 to 330 ms a
   frame on either Mac and about 20 ms of this GPU, about 2% of the blast's, so where it ran
   was lost in the noise (a median of 297 s here against 494 s on the mini, both within
   167 to 712 s, and 485 s with no models).

   Feeding the march is a cost of its own that placing cannot move: its cells are packed on
   this Mac's CPU between batches, with the GPU waiting, 8.5 ms a frame on the city block and
   20 ms on the street's fine grid (1 to 7% of a run), wherever the march runs.

   *Placing by cost.* So the march is worth moving when another Mac keeps up with the run, and
   whether one does changes from minute to minute, as the mini's tests come and go. A model may
   now be placed `auto`, by cost: `BombCAD run --consumer auto --worker <host>` (or
   `thermal=auto` for one model; `--worker` once for each Mac it may use), and **Automatic** in
   each model's **Run on** picker in the app, among the Macs set for sweeps. Each model goes
   where the run is estimated to take least time a frame (`ConsumerPlacement`): the run takes
   as long as its slowest part, which is the blast plus every model here that shares its GPU,
   or any model, here or elsewhere, slower than that, models on the same Mac adding up. A model
   stays here unless moving it saves at least 3%. What each costs comes from two places:

   - **A probe**, just before the run (in the app, when the Macs connect): four fireballs like
     the run's largest, half a sphere at 2,000 K on the ground under the charge, sent to a
     session of the model on each Mac (`ConsumerProbe`). It catches each Mac's load at the
     time. Only the thermal radiation is probed: its march costs about the same each frame,
     while the fragments' and the ground's costs are small and follow the run.
   - **The last run of the same inputs.** Every run now records, in the user's caches
     (`ConsumerCostStore`, shared by the app and `BombCAD run`), the blast's own time a frame,
     less any waiting and any model here on its GPU, and each model's time a frame where it
     ran. A run's own time cannot be probed: the blast's frames grow from 25 ms to 150 to 290 ms
     on the city block as the blast spreads, so its first frames do not foretell the rest.

   Until a run of the same inputs has been measured, a model moves only to a Mac that is quicker
   at it than this one. Tried on the city block, rounds interleaved with the march here and on
   the mini: the first run, unmeasured, kept the march here; the next two put it on the mini,
   which kept up (the run waited 0 and 0.3 s). Every choice depends only on the costs, so the
   tests set them and check the plan, and check, with in-process workers, that a model placed by
   cost gives the same result as here.

5. **A direct data channel, only if measured to be needed.** A TCP connection over the
   Thunderbolt Bridge, opened with a one-time token passed over SSH, which keeps control and
   authentication. At 0.9 GB/s a connection, and with separate connections for separate Macs
   spreading the encryption across cores, nothing foreseen needs it.

**What it will not do.** Most consumers are cheap: one core keeps up with a few thousand
fragments, and the ground's shaking is lighter still. Moving them gains nothing until one is
expensive. The thermal radiation's march over a city block of receivers is the first that is
(above); fragments that collide, or many buildings' damage, would be others. What the plan buys is room for those without
the run slowing, within the bound in [Adding machines](#the-long-term-visions-effects).

## Slower links: Wi-Fi and the like

Everything above assumes the Thunderbolt cable. Weighed in October 2026 for a Mac on Wi-Fi, such
as a laptop on the same network; only the thin client ([below](#a-thin-client)) has been measured
over Wi-Fi. Typical figures, and this desk's:

| Link | Usable rate | Round trip |
|---|---|---|
| Thunderbolt Bridge, SSH (measured here) | about 0.9 GB/s | about 0.1 ms |
| 10 Gb Ethernet (built into the Studio) | about 1 GB/s | about 0.05 ms |
| Gigabit Ethernet | about 110 MB/s | about 0.2 ms |
| Wi-Fi 6, 6E or 7, good conditions | 30 to 150 MB/s | 2 to 10 ms, with spikes past 50 ms |
| The Studio to the mini, both on Wi-Fi 6E (measured, SSH) | 35 to 41 MB/s | 6 to 81 ms, 21 ms on average |

10 Gb Ethernet is nearly as good as the cable for all of this; Wi-Fi is not. A job crosses a slow
link well when two things hold: what it sends a frame, at the link's rate, takes well under the
frame's own computing, and nothing waits for a reply. Latency then does not matter, only
bandwidth, and only on average.

**What still works.**

- **Independent runs.** Sweeps and ensembles cross any link. A case sends its project and gets
  back its result, at most 256 MiB and usually far less, against tens of seconds or more of
  running; the worker's executable and resource bundles, about 22 MB, go once a build. This
  should scale over Wi-Fi as over the cable, though a Mac on Wi-Fi is likely to be a laptop,
  slower than the Studio, which the scheduler handles by giving it the smaller cases.
- **Models fed one way, if they can fall behind.** A consumer only reads the air, so frames
  can stream ahead of it and nothing waits on the round trip. At about 39 ms a frame on the
  street canyon, 50 MB/s carries about 2 MB a frame. The ground's 0.19 MB fits easily. The
  fragments' 9.5 MB block of air does not: about 30 s to send against a run of about 5 s. The
  run waits for a consumer more than four frames behind, so as built it would be held up.
  Sending the air only where the fragments are, or in half precision, or letting a consumer
  trail without holding the run (its frames are already kept in `ConsumerSpool`), would each
  fix it, results unchanged. It would gain nothing yet: these models are cheap
  ([Placement and failure](#several-consumers-on-several-machines)).
- **Work on saved runs.** [USD export](usd-export.md), fragments flown afterwards from saved
  frames, comparisons: files, so any link.

**What does not.** A split grid swaps faces up to three times a step and agrees the time step
every step; a Wi-Fi round trip is longer than a whole air step on the medium grid. The air and a
structure exchange every air step, and so do any models fed both ways. All of these stall on
Wi-Fi.

### A thin client

The other way round: the app on a laptop, on Wi-Fi, editing the scene and watching, while the
blast runs on the Studio's GPU. Of everything on a slow link this is the most useful to someone
using BombCAD: a large GPU in a room somewhere, worked from anywhere in the building.

**What existed.** The models fed alongside a run can each run on another Mac (**Run on**), and
sweeps can share their cases, but the blast itself always ran on the Mac showing it.

**Why it fits a slow link.** Watching is lossy where a consumer is not. A consumer needs every
frame; a viewer needs only the latest state, at whatever rate the link allows, and can drop the
rest. Runs are slower than real time, so the screen updates at the run's pace: tens of
milliseconds a frame on the street canyon, seconds on its fine grid.

**What would cross.**

- *Out:* the project once, then edits and playback commands: kilobytes.
- *Back, live:* what the screen draws, not the solver's state. The medium grid's air is about
  170 MB a frame, far too much; a slice or the paint on surfaces (peak pressure, impulse,
  fluence) is well under a megabyte. The structure's node positions are a few megabytes for the
  225,000-element building, too much every frame but fine sent as the latest, a few times a
  second. If the air must be seen as a volume, rendering it on the Studio and sending video
  (VideoToolbox, HEVC) is a few megabytes a second whatever the grid.
- *Back, after:* the run's result, once, for playback and comparison on the laptop, as a sweep
  case returns one now.

**Built, headless, as a prototype.** `BombCAD watch <project> --on <ssh host>` runs a project on
another Mac and watches it from this one (`HeadlessWatch.swift`; worker protocol 11 adds `watch`,
`view`, `viewAck` and `viewStats`). The worker is the sweeps' own, copied over SSH. At each
millisecond's frame it sends what a viewer draws:

- the ground's paint over the whole grid: overpressure now, the peak and the impulse so far, three
  half-precision values a column (pressures in kPa, held to half precision's ±65,504; a test
  caught peaks in pascals overflowing it);
- the structure's surface, the points and each face's damage every frame, the faces only when
  their number changes;
- with `--volume <stride>`, the overpressure in every stride-th cell of the air, cut out on the
  GPU at the end of the frame's batch, as the fragments' air is.

Frames are compressed (lz4 by default) on the writer's queue, off the thread driving the GPU. Flow
control is a window of acknowledgements: the worker builds a frame only while fewer than two
are unacknowledged, and always builds the last, so a slow link or a slow viewer skips frames and
the run never waits for it. The run comes back at the end and is checked against its inputs'
fingerprint, as a sweep case is. `--stdio` lets the watcher read a worker through its own
standard input and output: the Studio takes no SSH logins, so for the realistic direction the
Studio piped a worker on its own GPU into `BombCAD watch --stdio` on the mini, over SSH on Wi-Fi.

**Measured, 17 October 2026.** The street canyon (65,000 ground columns) and the city
block (34 million cells, 262,000 columns), 100 kg, 171 frames; Wi-Fi is the measured link above,
both Macs on it. The mini was shared with other sessions' checks (load averages up to 95), so its
whole-run times swung five-fold between identical runs and say nothing; the costs below are each
run's own, timed where they happen.

| Blast on | Watched over | Scene, frame | A frame sent | Shown | Update, median | Lag, median (95%) |
|---|---|---|---|---|---|---|
| Studio | Wi-Fi | street, ground | 169 kB | 170 of 171 | 114 ms | 18 ms (78 ms) |
| Studio | Wi-Fi | city, ground | 281 kB | all | 203 ms | 31 ms (112 ms) |
| Studio | Wi-Fi | city, ground + volume every 2nd cell | 1.7 MB | all | 200 ms | 113 ms (239 ms) |
| Studio | Thunderbolt | the same | 1.7 MB | all | 240 ms | 65 ms (91 ms) |
| mini | Wi-Fi | street, ground | 161 kB | all | 330 to 830 ms | 22 to 24 ms (101 to 106 ms) |
| mini | Thunderbolt | street, ground | 161 kB | all | 540 to 990 ms | 7.4 to 7.5 ms (9 ms) |
| mini | Wi-Fi | city, ground | 277 kB | all | 385 to 1,420 ms | 41 to 44 ms (109 to 123 ms) |
| mini | Thunderbolt | city, ground | 277 kB | all | 400 to 560 ms | 24 ms (26 to 30 ms) |
| mini | Wi-Fi | city, ground + the whole volume | 9.5 MB | 163 of 171 | 600 ms | 760 ms (1.3 s) |
| mini | Wi-Fi | three-storey building, surface | 2.9 MB | all | 1.9 s | 161 ms (254 ms) |
| mini | Thunderbolt | three-storey building, surface | 2.9 MB | all | 1.6 s | 75 ms (88 ms) |

Lag is from the frame's values being read on the worker to its acknowledgement arriving back,
the decoding on the watcher included. What it found:

- **The ground's paint is small for any link.** 160 to 280 kB a frame with lz4 (2.4 to 5.7
  times smaller than raw), 1.5 MB/s at the Studio's pace, a twentieth of what this Wi-Fi carries.
  Every frame crossed; the lag was about Wi-Fi's own round trip.
- **The run barely notices.** Reading a frame held the thread driving the GPU 0.8 ms (street) and
  2.5 ms (city) on the Studio, 1% of the run, once the ground's rows were read across the cores
  (16.6 ms a frame for the city block on the mini, on one core, before). Packing and compressing ran off that
  thread. The larger cost is stopping at exact frames, which a watched run does and an unwatched
  one does not: 4 to 5% more steps (1,856 against 1,781 on the street, 1,943 against 1,848 on the
  city). A viewer does not need exact frames; taking the state wherever a batch ends would remove
  this.
- **A structure's surface is the next weight.** 2.9 MB a frame for the three-storey building,
  compressing only 1.4 times (positions in full precision), 22 ms a frame to read. Fine at its
  pace over Wi-Fi; sending displacements from a reference sent once, in half precision, would cut
  it to under a third.
- **A whole volume is where Wi-Fi ends.** The city's overpressure in every cell is 68 MB a frame,
  9.5 MB with lz4: Wi-Fi carried 12.6 MB/s, eight frames were skipped, and the lag reached a
  second. The watcher was half the limit: decoding a frame took 230 to 290 ms on the mini.
  Reading it held the run 54 to 400 ms a frame, as the cut-out copies all five quantities of
  every cell to the CPU to keep one. Every second cell in each direction (8 times fewer) crossed
  at 7.4 MB/s, every frame, with 0.1 s of lag. For a volume, the GPU should cut out only the
  overpressure, in half precision, and the viewer should draw the field coarser than the solver
  holds it.

**Drawn here by the app's renderer.** The renderer draws from a `SceneViewState`, which a run
elsewhere can fill (`ViewSetup` once, a `ViewFrame` each frame, uploaded by `ViewUpload`, all in
BlastRender). `watch --scene <stride>` has the worker send those too (`SceneViewCodec`, binary,
compressed as the rest; protocol 12 adds `viewSetup`), and `--render <folder>` draws each frame
with `SceneRenderer` on this Mac and writes PNG images. The field goes at every stride-th cell
along each axis, cut down on the GPU (`coarsenField` in ViewField.metal): each coarse texel keeps
its block's largest peak, impulse and shock indicator and its overpressure of largest magnitude,
so a front one cell thick still shows. Measured the same day, the blast on the Studio, the mini
drawing it over Wi-Fi:

| Scene, field | A frame sent | Shown | Update, median | Lag, median | Held the run, a frame (first build) |
|---|---|---|---|---|---|
| city, every 4th cell | 1.2 MB | all | 216 ms | 102 ms | 22 ms |
| city, every 2nd cell | 7.2 MB | 169 of 171 | 213 ms | 245 ms | 29 ms |
| three-storey building, every 2nd cell | 7.6 MB | all | 459 ms | 323 ms | 33 ms |
| city, every cell | 34 MB | 55 of 171 | 489 ms | 778 ms | 117 ms |

- **Every 4th cell looks like the whole.** On the city block it is 64 times less field, and the
  picture drawn here keeps the same fronts in the same streets, slightly softer and wider; every
  2nd cell is hard to tell from the whole. The whole field saturates Wi-Fi (35 MB/s carried),
  and two frames in three are skipped.
- **Drawing here is cheap.** Uploading a frame into the view's buffers took 1 to 5 ms on the
  mini at every 2nd or 4th cell, and decoding it 1 to 7 ms; drawing a 1280 × 720 image and writing
  it as a PNG 50 to 70 ms.
- **The run paid for the field, at first.** 22 to 33 ms a frame held on the thread driving the
  GPU, 8 to 11% of the city run, against 2.5 ms for the ground's paint alone: the field was
  rebuilt and cut down in command buffers of their own, each waited for, and the structure's
  surface was read for the paint as well as its meshes for the view. Now the view field is a
  `FrameRequest` like the fragments' air: the visualisation and `extractViewField`
  (Extract.metal) run at the end of the batch that lands on the frame, and
  `BlastSolver.viewField(stride:)` takes what they wrote; the frame is encoded on the writer's
  queue; and with a scene view the paint leaves out the surface. Timed again, old and new
  builds alternating, the Studio loaded (load averages 13 to 113):

  | Held the run, a frame | Before | After |
  |---|---|---|
  | city, every 4th cell | 9.2 to 16.7 ms | 4.0 to 4.7 ms |
  | city, every 2nd cell | 16.1 to 38.6 ms | 9.6 to 10.8 ms |
  | three-storey building, every 2nd cell | 22.5 to 39.1 ms | 5.4 to 8.9 ms |

  What is left is mostly copying the field out of the GPU's buffer (34 MB a frame at every 2nd
  cell of the city block) and the ground's paint. The field cut out in the batch is the one
  worked out after it, bit for bit, and asking for it leaves the run the same.
- **The structure's mesh is the rest.** The three-storey building's frames compress only 1.6
  times, being displacements and rotations in full precision.

**What it means for the app.** A thin client is practical over ordinary Wi-Fi for everything
drawn on surfaces, live, at the run's own pace, for about 1% of the run, and for the air as a
volume at about every second cell, and for the scene as the app draws it at every 2nd to 4th
cell of the field. What is left is the app's side: a **Run on** for the blast, the viewport fed
from the frames that arrive rather than from a solver here, and edits and playback going the
other way.

## Macs nearby, without SSH

Everything above reaches the other Mac over SSH, which needs Remote Login and a key on the Mac
doing the work, and is started from the Mac sending it. For a laptop working a Studio that is the
wrong way round: the Studio here takes no SSH logins. Built in October 2026 (`NearbyWorkers.swift`,
`NearbyPairing.swift`), with Apple's Network framework; setting it up is in
[Macs nearby](run-comparison.md#macs-nearby-without-ssh).

**How it works.**

- **Sharing.** The Mac doing the work runs `NearbyServer` (the app's setting, or `BombCAD serve`),
  advertising two Bonjour services under its name: `_bombcad-pair._tcp` for pairing and
  `_bombcad._tcp` for sessions. Their TXT records give its identifier, BombCAD version, worker
  protocol and solver version and GPU, so the other Mac can list it, and grey it out if the
  versions cannot work together, before connecting.
- **Pairing, once.** Plain TCP. Each side makes a fresh X25519 key; the sending Mac commits to its
  public key and a nonce (their SHA-256) before seeing the other's, then reveals them, so a Mac in
  the middle cannot choose keys after seeing both. Both derive the same six-digit code from the
  shared secret and the whole exchange (HKDF). The sharing Mac's user allows it, seeing the code;
  the sending Mac's user confirms the sharing Mac shows the same; each side then proves it holds
  the key (HMAC over the exchange) before either keeps it. A Mac in the middle pairing with each
  side separately has a different secret with each, so the two codes differ but for one chance in
  a million. The key, 256 bits, is kept in the Keychain, or a file readable only by its owner.
- **Sessions.** TLS 1.2 with that key as a pre-shared key (`TLS_PSK_WITH_AES_128_GCM_SHA256`), the
  sharing Mac holding every paired Mac's key under its identifier and restarting the listener when
  one is added or forgotten. The first message asks for any gate (the same `RemoteGate` an SSH
  worker checks); the sharing Mac answers, then starts a `BombCAD worker` process and carries
  bytes between it and the connection. From there the messages are those of an SSH worker,
  unchanged, so every job type works as it does over SSH. A paired Mac is `nearby:<its name>`
  wherever an SSH host is taken; `RemoteSweepWorker.connect` sends those this way.
- **Links.** Bonjour reports every interface a Mac is seen on: the mini here on the Thunderbolt
  bridge, Wi-Fi and two link-local interfaces. Left to itself, the connection took a link-local
  one, at Wi-Fi's speed; so the link is chosen, fastest first: the bridge, wired Ethernet with an
  IPv4 address, Wi-Fi, then the rest (`BOMBCAD_NEARBY_LINK` forces one, for measuring).

**Measured, 17 October 2026,** the mini serving (`BombCAD serve` started over SSH, its pairings in
a file), the Studio sending; the mini shared with CI (load averages 82 to 130), so whole runs say
little. The city block with every 2nd cell of the air as a volume, 1.7 MB a frame, 171 frames:

| Link | Connecting | Lag, median (95%) |
|---|---|---|
| SSH, Thunderbolt | 0.5 to 4.4 s | 43 to 45 ms (54 to 84 ms) |
| Nearby, Thunderbolt | 0.1 s | 43 to 48 ms (67 to 131 ms) |
| SSH, Wi-Fi | 0.6 to 1.6 s | 107 to 128 ms (225 to 244 ms) |
| Nearby, Wi-Fi | 0.1 to 0.8 s | 255 to 261 ms (576 to 601 ms) |

- **Connecting** takes a tenth of a second instead of SSH's half a second to four: no login, no
  check of the copied build.
- **Over Thunderbolt** the two are alike in a run. Raw, 50 MB echoed both ways at once took
  0.12 s, about 0.8 GB/s each way, as fast as SSH's 0.6 to 0.9 GB/s; a small watched run (frames of
  10 kB) had 1.9 ms of lag.
- **Over Wi-Fi, the mini's sending is slow.** Timed alone, 100 MB from the mini to the Studio
  through Network.framework took 7 to 13 MB/s, with TLS or without, IPv4 or IPv6, any service
  class, ECN off or on, at any priority; from the Studio to the mini 44 MB/s; plain sockets from a
  process the mini's SSH started, 42 to 43 MB/s; Network.framework receiving on the Studio from a
  plain socket, 43 MB/s. So it is Network.framework sending on the mini, over Wi-Fi only. Its
  interfaces use the user-space network stack (`CHANNEL_IO`), whose work runs in the sending
  process: with the mini at loads near 100 that would starve it where the kernel's sockets are not,
  but it is not yet shown. **Open**: measure again in the mini's quiet window; if it holds, carry a
  session's bulk on a plain socket keyed by the pairing.
- **Not measured here:** the Studio as the sharing Mac, the thin client's own direction. The
  Studio's firewall is on and asks, for each new build started from a shell, whether it may accept
  connections, which wants someone at the Studio; the signed app asks once.

**Tests** pair two stores in one process over a pair of queues (codes agree; declined on either
side; a key revealed other than the one committed to; a Mac in the middle), and run a real
listener on this Mac with a sweep case to the same answer, refusing an unpaired Mac, a wrong key
and a busy gate. They find the listener at its port, not by Bonjour: a test process's Bonjour
answers never came (Local Network privacy, it seems), and waiting for them hung the suite.

## Better first

- **A bigger single GPU.** An M3 Ultra (80-core GPU, 819 GB/s, up to 512 GB) would run about
  1.5 times as fast as the M4 Max with no communication at all, and could hold a 0.0625 m street
  grid (about 31 GB).
- **Single-GPU algorithms.** Letting refined patches take shorter steps than the coarse grid
  (subcycling), and cheaper contact, which takes about a fifth of a structure's time once on
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
  Uncertainty ensembles of the validation cases share their runs the same way (`BombCAD
  ensemble`, a job of its own for the worker, protocol version 9, and 10 since a run carries
  the kernels' rounding; see
  [Validation](validation.md#the-models-spread-from-uncertain-inputs)): 153 runs of nine cases
  took 1 h 55 min on the Studio, a second worker on it and the mini, against 4.5 hours of runs,
  the mini taking 53. Each result is kept as it arrives, and a worker that does not answer
  gives its run back.

## Sources

- Apple, [Mac mini technical specifications](https://www.apple.com/uk/mac-mini/specs/): M4
  120 GB/s and Thunderbolt 4; M4 Pro 273 GB/s and Thunderbolt 5.
- J. Geerling, [1.5 TB of VRAM on Mac Studio: RDMA over Thunderbolt 5](https://jeffgeerling.com/blog/2025/15-tb-vram-on-mac-studio-rdma-over-thunderbolt-5)
  (2025): RDMA in macOS 26.2, its Thunderbolt 5 requirement, and measured latency.
- [Performance](performance.md): the single-GPU speeds, memory per cell and structural costs used
  above.
