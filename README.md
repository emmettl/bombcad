# BombCAD

An interactive blast simulator for simple building layouts, written to answer one question:
how close to real time can a physically based simulation of blast on structures run on a
current Mac?

It has two solvers, both on the GPU:

- an **air-blast solver** that propagates the blast wave around obstacles and records peak
  overpressure and impulse on every surface;
- a **structural solver** for reinforced concrete, brick, concrete block, steel and glass that cracks,
  crushes, yields its reinforcement and breaks under those pressures. Broken pieces collide,
  fall and come to rest, and the air flows through the gaps they leave. Structures are meshed with solid elements, or
  with much faster shell elements for walls and slabs and beam elements for columns, or with
  both in one body, tied where they meet.

It is a study of the numerics and the performance, not a design tool.

![Blast wave in a street canyon 45 ms after detonation](docs/street-canyon-45ms.png)

![A three-storey concrete frame clad in masonry, 150 ms after a charge in front of it](docs/three-storey.png)

![A two-storey frame's glass façade breaking up 100 ms after 20 kg in the street](docs/glass-facade.png)

## Running it

Requires macOS 15 or later, Swift 6.4 and a Metal GPU.

```bash
swift run -c release BombCAD
```

```bash
make app
```

The second command builds `dist/BombCAD.app`, which can be launched from Finder.
[Releasing](docs/releasing.md) describes signed, notarized builds for other Macs.

In the view: drag or two-finger scroll to orbit, shift-drag or right-drag to pan, pinch or mouse
wheel to zoom. Space runs and pauses, ⌘R resets.

The sidebar has two tabs. **Run** picks a built-in layout, the grid, the charge and the display.
The layouts are open ground, a single building, a street canyon and a courtyard (rigid blocks);
a cantilever wall, a single-storey building, the same building behind a blast wall, a two-storey
frame (bare, infilled with masonry, or glazed with glass panes), a three-storey clad building, an
open-sided car park with a charge inside, an underpass, a column close to a charge, a
two-storey house of concrete blockwork meshed with shells, and the internal-explosion test
(deformable). The close-in column wants the fine grid: on coarser air it
is less than a cell or two across. The sidebar shows a structure's deflection now and the
largest it has reached.
**Edit layout** adds, moves, resizes and removes rigid blocks, deformable walls, openings and
pressure gauges, sets each wall's material and reinforcement, and has undo (⌘Z). The toolbar opens and saves layouts as JSON and lets you move
the charge, or the selected gauge, by clicking the ground. Gauge and deflection histories export
as CSV from beside the chart.

```bash
swift test
```

```bash
swift run -c release blastbench throughput
```

```bash
swift run -c release blastbench slab --sensitivity
```

`blastbench` also has `structure`, `validate`, `gas`, `chamber` and `snapshot` commands; see
[Performance](docs/performance.md) and [Validation](docs/validation.md).

## Headline results

Measured on an Apple M4 Max (32-core GPU, 36 GB).

| Case                                                        | Speed                        |
|-------------------------------------------------------------|------------------------------|
| Air blast, street scene, 8.4 million cells of 0.25 m        | 17× slower than real time    |
| Concrete building, 225,000 elements, coupled to the air     | 70× slower                   |
| The same building as 3,700 shell elements                   | 7× slower (2× on 0.5 m air)  |
| Three-storey building as shells and beams                   | 31× slower (17× on 0.5 m air) |
| The building with its front wall solid, the rest shells     | 24× slower                   |
| Three-storey frame with masonry cladding, 160,000 elements  | 60× slower                   |
| Two-storey frame collapsing over 3 s                        | 11× slower                   |

Three comparisons with the outside world, all in the [validation notes](docs/validation.md):

- **Blast loads.** On air cells of 0.25 m or finer, the impulse on a rigid wall is within 6% of
  the Kingery–Bulmash curves beyond 1.5 m/kg^(1/3), and within 5% everywhere checked on
  0.125 m cells. Peak pressures are under-resolved, more so close to the charge; refining the
  air near the shock gives the peaks of a grid twice as fine at a sixth to a third of its cost.
  The incident impulse is 13–22% low by default, or within 6% with afterburning and hot air
  switched on, which also bring the gas pressure in a closed room within 8% of the US design
  manual's.
- **Structural response.** Against a published blast test of a reinforced-concrete slab, the
  model predicts peak deflections of 101, 101 and 108 mm with 4, 8 and 16 elements through the
  thickness, where 108 mm was measured, with no material constant fitted to the test; with 32
  elements (4.4 million) it is 105 mm, so the peak has converged. The rebound
  after it is twice the measured one, and the result is sensitive to the load and to how the
  supports are modelled. Shell elements converge to 124 mm in about a second, with a rebound
  close to the measured one.
- **Internal explosion.** In a full-scale reinforced concrete chamber loaded by 200 kg of TNT,
  the peak pressures on the walls are 0.9 to 1.6 times those measured. With the structure as
  built, so far as the paper says, the roof is about twice as stiff as the paper's own model
  and springs back to 7 mm where 95 mm was measured; its joints stay whole where the test's
  were cut through. The test exposed missing mechanisms in the concrete model, errors in it,
  in contact and in the time step, and an error in the test's own set-up, all now dealt with.

Collapse and debris have not been compared with anything.

## Documentation

| Document                                    | Contents                                                        |
|---------------------------------------------|-----------------------------------------------------------------|
| [Air-blast model](docs/air-blast-model.md)  | Equations, numerical scheme, charge model, boundaries           |
| [Structural model](docs/structural-model.md) | Elements, time stepping, contact, coupling to the air           |
| [Concrete model](docs/concrete-model.md)    | Cracking, crushing, shear, reinforcement, strain-rate effects   |
| [Shell model](docs/shell-model.md)          | Shells for walls and slabs, beams for columns                   |
| [Validation](docs/validation.md)            | The slab test, empirical blast curves, verification tests       |
| [Performance](docs/performance.md)          | Benchmarks and where the time goes                              |
| [Roadmap](docs/roadmap.md)                  | Known limitations in order of importance, and planned work      |
| [Data wanted](docs/data-wanted.md)          | Sources that need fetching by hand, and what each would add     |
| [Releasing](docs/releasing.md)              | Signed, notarized builds                                        |

Each model document lists its sources, its limitations and the work that would address them.

## Code layout

| Target        | Contents                                                             |
|---------------|----------------------------------------------------------------------|
| `BlastCore`   | Air and structural solvers, materials, scenarios, benchmark data     |
| `BlastRender` | Scene renderer, orbit camera, offscreen snapshots                    |
| `BombCAD`     | SwiftUI app with the layout editor                                   |
| `blastbench`  | Command-line throughput, validation and snapshot tool                |
