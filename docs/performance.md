# Performance

The question the project set out to answer: how close to real time can blast on structures be
simulated on a current Mac? All figures here were measured on an Apple M4 Max (32-core GPU,
36 GB) with `blastbench`, in release builds.

## Short answer

| What is simulated                                   | Slower than real time |
|-----------------------------------------------------|-----------------------|
| Air blast, 1 million cells (0.5 m in a street scene) | 2×                    |
| Air blast, 8.4 million cells (0.25 m)               | 27×                   |
| Air blast, 67 million cells (0.125 m)               | about 430×            |
| A 225,000-element concrete building, alone          | 52×                   |
| The same, once pieces are colliding                 | 81×                   |
| That building coupled to 1 million air cells        | 75×                   |
| A 23,000-element frame collapsing                   | 7×                    |

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
| Before anything has failed    | 2,116   | 476 million       | 52×                   |
| With contact running          | 1,356   | 305 million       | 81×                   |

- The explicit time step is set by the element size and the speed of sound in concrete, and it
  is what makes structures expensive: 110,000 steps per simulated second at this resolution.
- **Threadgroup size mattered more than anything in the kernel.** The structural kernels were
  first launched in groups of the largest size the GPU allows, 1,024 threads. The element
  kernel needs many registers, so few such groups fit on a GPU core at once. Groups of 32 to
  512 threads run 50% faster (310 to 476 million element-updates per second; with contact,
  225 to 305 million), and 32, one SIMD group, is the fastest. The air solver, which is
  limited by memory bandwidth, is indifferent to its group size.
- Skipping the eigenvalue problem that finds diagonal cracks, for elements strained below
  cracking, was tried and made no measurable difference.
- The residual crack opening and the cyclic steel law cost about 8%. The cyclic law's history
  is read only for bars that have yielded; reading it for every bar cost twice as much.
- Memory is about 240 bytes per lattice cell, whether or not it holds an element (340 with
  reinforcement, for the bars' cyclic history), plus the
  contact grid at 20 bytes per cell of the surrounding space.

## Coupled runs

```bash
swift run -c release blastbench throughput --preset box --full
```

The same building in 32 × 32 × 16 m of air, 100 kg at 8 m, 96 ms simulated.

| Air cell size | Air cells | Whole event | Slower than real time |
|---------------|-----------|-------------|-----------------------|
| 0.5 m         | 0.1 M     | 6.6 s       | 69×                   |
| 0.25 m        | 1.0 M     | 7.2 s       | 75×                   |
| 0.125 m       | 8.4 M     | 14 s        | 146×                  |

The structure sets the pace: refining the air from 0.5 m to 0.25 m costs almost nothing extra.
Each air step is followed by 5 to 15 structural substeps.

## Collapse

```bash
swift run -c release blastbench snapshot --preset frame --time 3 --no-wave --out frame.png
```

The two-storey frame (23,004 elements of 125 mm, 1.3 million air cells of 0.25 m, 250 kg):
3 s simulated in 22 s. The air was frozen after 0.79 s, when five acoustic crossing times had
passed; from then on only the structure is advanced. Larger elements help twice over: fewer of
them, and a time step twice as long.

## The slab benchmark

`blastbench slab` runs 80 ms of the validation slab in 7 s with eight elements through the
thickness (68,608 elements of 12.7 mm, time step 1.7 µs) and in under a second with four. With
sixteen (553,000 elements) it takes about four minutes.

## Display

One frame takes 1 to 5 ms at 1400 × 875, depending on how much of the view the blast wave
fills, so the display never limits the simulation. The app aims for about 10 ms of GPU work per
batch of steps to keep the view fluid.

## Where the time goes, and what would help

| Cost                                              | Possible remedy                                        |
|---------------------------------------------------|--------------------------------------------------------|
| Structural time step tied to the smallest element | Shell or beam elements for thin members; mass scaling; coarser elements away from damage |
| Air solved everywhere at one resolution           | Adaptive refinement; a moving window that follows the shock |
| Air solved long after it matters                  | Already frozen once quiet; could be frozen region by region |
| Idle substep dispatches in coupled runs           | Decide the substep count on the GPU with indirect dispatch |
| Concrete law costlier than the von Mises material | Profile it; the power functions in the rate and compression laws are the next suspects |
| Dense storage of a sparse structural lattice      | Compact storage indexed by element list                 |

None of these has been done. The first two are the ones that would change what is feasible.
