# BombCAD

An interactive blast simulator for simple building layouts, written to answer one question:
how close to real time can a physically based simulation of blast on structures run on a
current Mac?

It has two solvers, both on the GPU:

- an **air-blast solver** (finite volume, compressible Euler) that propagates the blast wave
  around obstacles and records peak overpressure and impulse on every surface;
- a **structural solver** (explicit finite elements) for reinforced concrete and masonry that
  cracks, crushes, yields its reinforcement and breaks under the pressures the air solver
  delivers. Broken pieces collide, fall and come to rest, and the air flows through the gaps
  they leave.

It is a study of the numerics and the performance, not a design tool: see
[Limitations](#limitations).

![Blast wave in a street canyon 45 ms after detonation](docs/street-canyon-45ms.png)

![A two-storey concrete frame three seconds after a large charge beside it](docs/frame-collapse.png)

## Running it

Requires macOS 15 or later, Swift 6.4 and a Metal GPU.

```bash
swift run -c release BombCAD
```

```bash
./Scripts/make-app.sh
```

The second command builds `build/BombCAD.app`, which can be launched from Finder.

In the view: drag or two-finger scroll to orbit, shift-drag or right-drag to pan, pinch or mouse
wheel to zoom. Space runs and pauses, ⌘R resets.

The sidebar has two tabs. **Run** picks a built-in layout, the grid, the charge and the display.
**Edit layout** adds, moves, resizes and removes rigid blocks, deformable walls and openings, and
lets you move the charge by clicking the ground. Layouts can be saved and opened as JSON files
from the toolbar.

```bash
swift test
```

```bash
swift run -c release blastbench throughput
```

```bash
swift run -c release blastbench throughput --preset box --full
```

```bash
swift run -c release blastbench structure
```

```bash
swift run -c release blastbench validate
```

```bash
swift run -c release blastbench slab --sensitivity
```

```bash
swift run -c release blastbench snapshot --preset frame --time 3 --no-wave --out frame.png
```

## How fast is it?

All figures are measured on an Apple M4 Max (32-core GPU, 36 GB).

**Air blast only** (`blastbench throughput`): the street-canyon scenario, a 64 × 64 × 32 m volume,
100 kg TNT equivalent, simulated for 170 ms.

| Cell size | Cells  | GPU memory | Steps/s | Whole event | Slower than real time |
|-----------|--------|------------|---------|-------------|-----------------------|
| 0.5 m     | 1.0 M  | 0.06 GB    | 2,300   | 0.3 s       | 2×                    |
| 0.25 m    | 8.4 M  | 0.48 GB    | 340     | 4.5 s       | 27×                   |
| 0.125 m   | 67 M   | 3.8 GB     | 42      | 72 s (est.) | 430×                  |

The air solver advances about 2.8 billion cells per second regardless of grid size.

**Structure only** (`blastbench structure`): the single-storey concrete building, 225,000
hexahedral elements of 62.5 mm, runs 1,750 steps per second (390 million element-updates per
second). Its stable time step is 9 µs, so on its own it is 63× slower than real time. Once
something has failed and contact switches on (`--contact`), that becomes 1,200 steps per second,
or 91× slower than real time.

**Coupled** (`blastbench throughput --preset box --full`): the same building in a 32 × 32 × 16 m
volume of air, 100 kg at 8 m, simulated for 96 ms.

| Air cell size | Air cells | Whole event | Slower than real time |
|---------------|-----------|-------------|-----------------------|
| 0.5 m         | 0.1 M     | 8 s         | 86×                   |
| 0.25 m        | 1.0 M     | 9 s         | 93×                   |
| 0.125 m       | 8.4 M     | 16 s        | 162×                  |

Here the structure, not the air, sets the pace.

**Collapse.** A collapse lasts seconds rather than milliseconds. Once the blast has left, the air
is frozen and only the structure is advanced. The two-storey frame above (23,000 elements of
125 mm) takes 29 s to simulate for 3 s, which is 10× slower than real time; the air was frozen
after 0.8 s.

Rendering a frame takes 1 to 5 ms, so the display is never the bottleneck. The app deliberately
plays back in slow motion (100× by default), because the blast itself lasts a fraction of a second.

## How accurate is it?

### Against a real test

`blastbench slab` runs the structural solver against a published experiment: the normal-strength
slab of the 2013 Blast Blind Simulation Contest (University of Missouri–Kansas City with ACI
Committees 447 and 370), tested in the Blast Loading Simulator of the US Army Engineer Research
and Development Center. The slab is 64 × 33.75 × 4 in of 5,400 psi concrete with nine No. 3 bars,
simply supported over 52 in, and was loaded by a measured pressure history peaking at 50 psi with
an impulse of 1,020 psi·ms. The specimen, material curves, load and measured response are taken
from Kewaisy, Khalil and ElFouly, *Advanced Modeling of Blast Response of Reinforced Concrete
Walls with and without FRP Retrofit*, ACI Spring Convention 2018.

| Mesh                         | Peak mid-span deflection | At    | Residual |
|------------------------------|--------------------------|-------|----------|
| **Measured**                 | **108 mm**               | 30 ms | 91 mm    |
| 8 elements through thickness | 108 mm (100%)            | 27 ms | 76 mm    |
| 4 elements through thickness | 113 mm (105%)            | 28 ms | 93 mm    |

No material constant was fitted to the test: concrete properties come from standard correlations
with its strength, the bars follow their published stress-strain curve, and strength rises with
strain rate by published laws. Agreement this close is partly luck, and the result is sensitive:

- Changing the load by 5% changes the peak by about 14% (94 mm and 124 mm).
- With static strengths, or with the fixed design factors of UFC 3-340-02 in place of the
  strain-rate laws, the model predicts that the slab collapses. The test load is well above the
  slab's static capacity, so its survival depends on rate strengthening.
- Halving the fracture energy, lowering the tensile strength by 20%, or changing the aggregate
  size moves the peak by 1% or less. Halving the assumed crack spacing gives 103 mm.
- Doubling the assumed crack spacing to 200 mm (more than the slab's thickness) tips the model
  into a shear failure that the test did not show.

An earlier version of the model, with a simpler crack law, matched the peak for the wrong reason
(far too much energy absorbed by cracking on a fine mesh) and collapsed once that was corrected.
The pressure record was read off the published plot by hand and scaled to the stated impulse.
This is one test of one slab under a uniform load; it says nothing about walls loaded by the air
solver, close-in charges or collapse.

### Against theory

Both solvers are verified against problems with known answers (`swift test`, 51 tests).

Air:

- Sod's shock tube, with both Riemann solvers and along each axis
- a normal shock reflecting off a rigid wall (Rankine–Hugoniot reflected pressure within 2%)
- the Sedov–Taylor point blast (shock radius within 4% on a diagonal and along an axis)
- exact conservation of mass and energy in a closed box containing an obstacle
- mirror symmetry of a centred burst

Structure:

- an elastic stress wave in a bar: speed √(E/ρ) and stress ρcv within 5%
- a cantilever under its own weight: tip deflection and first natural period within 5%
- a spinning body: energy within 1% and angular momentum within 0.5% over a quarter turn
- two blocks colliding head-on, and one block coming to rest on another

Concrete and reinforcement:

- cracking at the tensile strength, releasing the fracture energy within 5% on two mesh sizes
- crushing at the compressive strength along the intended curve, softening to a residual
- a cracked element recovering its compressive stiffness when the crack closes
- reinforcement carrying a cracked element to yield, hardening, then rupturing
- shear across a crack matching the aggregate-interlock law within 5% at two crack widths
- tensile strength rising with strain rate by the published law within 6%
- a reinforced beam reaching the moment capacity of section analysis within 10%

Coupling:

- a block immersed in pressurised air settles into hydrostatic stress within 3%
- a free wall closing a shock tube gains the impulse the air delivers to it within 1%
- a hole knocked in a wall opens the air's solid mask and lets the blast through
- the air's solid mask travels with a wall that is pushed along the tube

### Blast loads against an empirical curve

`blastbench validate` compares a 100 kg surface burst on rigid ground with the Kinney–Graham
empirical free-air curves for 200 kg (the ground acts as a mirror):

| Range | Peak overpressure, 0.25 m grid | 0.125 m grid | Positive impulse (any grid) |
|-------|--------------------------------|--------------|-----------------------------|
| 10 m  | 61% of reference               | 68%          | 84%                         |
| 15 m  | 66%                            | 74%          | 83%                         |
| 20 m  | 72%                            | 81%          | 83%                         |
| 25 m  | 77%                            | 86%          | 84%                         |

Peak overpressure reads low because a captured shock is smeared over two or three cells, and it
improves as the grid is refined. Impulse, which governs the response of most structures, is
already grid-independent at 0.5 m; its constant 16% shortfall comes from the source model, not the
resolution. Published empirical curves themselves differ by around 30% in this range.

### Consistency across air grids

The 3 m reinforced cantilever wall, 6 m from the charge, behaves the same way as the air grid is
refined:

| Charge | Air cells 0.5 m           | 0.25 m             | 0.125 m            |
|--------|---------------------------|--------------------|--------------------|
| 50 kg  | 16 mm deflection at 0.1 s | 28 mm              | 36 mm              |
| 200 kg | sheared off at its base   | sheared off        | sheared off        |

![A cantilever wall toppling after a charge sheared it off at its base](docs/wall-toppling.png)

## How it works

**Air**

- 3D compressible Euler equations, ideal gas with γ = 1.4, uniform Cartesian grid.
- Dimensionally split MUSCL–Hancock finite volumes with a minmod-family limiter and an HLLC
  Riemann solver, second order away from shocks. One Metal compute kernel per sweep.
- Blocks and structures are voxelised; walls and the ground use mirrored ghost states, which keeps
  the scheme exactly conservative.
- The charge is a "bursting balloon": its TNT-equivalent energy (4.184 MJ/kg) and mass are
  deposited in a small sphere of hot gas.
- The CFL limit is computed on the GPU, so many steps are queued per command buffer and the CPU
  never waits on a read-back between steps.
- Once the air is within 2 kPa of ambient everywhere, or five acoustic crossing times have
  passed, the air is frozen and only the structure carries on.

**Structure**

- Eight-node hexahedral elements on a regular lattice, one-point quadrature, lumped mass,
  central-difference time integration.
- Hourglass control scaled to the element's physical bending stiffness, so a wall a few elements
  thick bends correctly; the hourglass forces are capped at the element's bending capacity.
- Contact: every node acts as a sphere one element across. Nodes are binned into a grid each
  substep and repel strangers with a damped penalty spring plus Coulomb friction. Nodes also
  land on the ground plane. Contact only runs once something has failed.

**Concrete and reinforcement**

- The model works on total strain, with cracks smeared over the three lattice planes. Each
  plane keeps its own history, so cracking across one direction leaves the others intact;
  diagonal cracks from shear are found from the principal strains and shared between the planes
  they cut.
- Across a plane, tension softens exponentially and compression follows a parabola and then
  softens to a residual. Both are scaled so that the energy to open a crack or crush a band is
  the material's whatever the mesh; in reinforced concrete the crack energy is spread over a
  typical crack spacing rather than one element.
- Shear across a cracked plane is carried by aggregate interlock, which weakens as the crack
  widens (Vecchio and Collins' modified compression field theory).
- Reinforcement is smeared into the elements it passes through and follows a multi-linear
  stress-strain curve up to rupture.
- Strength rises with strain rate: CEB-FIP 1990 for concrete in compression, Malvar and Ross
  for concrete in tension, Malvar and Crawford for reinforcement.
- An element is removed when a crack across it is 5 mm wide and no intact bar crosses that
  crack, or when it is crushed far beyond its residual strength.
- Concrete properties default to standard correlations with compressive strength (ACI 318 for
  stiffness, Eurocode 2 for tensile strength, fib Model Code 2010 for fracture energy).
- A simpler von Mises material remains for verification problems.

**Coupling** runs both ways.

- Air to structure: after each air step, the structure takes however many substeps its own
  stability limit requires, with every exposed element face loaded by the air pressure beside
  it, on the deformed geometry.
- Structure to air: intact elements are then counted into the air cells they currently occupy.
  A cell is solid when it is at least a third full, so the solid mask follows a wall as it moves
  and opens where it breaks. Cells that open are refilled from their neighbours.

**Rendering** uses two passes. The first ray-traces the ground and rigid blocks, coloured from the
peak-pressure and impulse fields, and rasterises the structure's deformed mesh straight from the
solver's buffers. The second ray-marches a shock indicator through the air.

| Target        | Contents                                                             |
|---------------|----------------------------------------------------------------------|
| `BlastCore`   | Air and structural solvers, materials, scenarios, benchmark data     |
| `BlastRender` | Scene renderer, orbit camera, offscreen snapshots                    |
| `BombCAD`     | SwiftUI app with the layout editor                                   |
| `blastbench`  | Command-line throughput, validation and snapshot tool                |

## Limitations

- The concrete model has been compared with one test. It has no confinement strengthening, so
  concrete under very high pressure close to a charge crushes too easily, and cracks can only
  form on the lattice planes.
- Sections with no steel through their thickness rely on aggregate interlock alone for shear.
  The slab benchmark shows how sensitive that can be.
- Reinforcement is perfectly bonded and smeared: there is no bond slip, dowel action or bar
  buckling, and bars are placed by the element, not individually.
- In the editor, reinforcement is assigned automatically from each piece's proportions.
- The structure moves the air's solid cells but does not push the air: a moving wall imparts no
  velocity to the gas, and gas in a cell that becomes solid is simply removed, so mass and energy
  of the air are not exactly conserved once the structure moves.
- Contact is approximate. Pieces that were joined overlap by up to one element before they
  touch, contact surfaces are bumpy at the element scale, and debris that travels more than a
  few metres from the structure leaves the contact grid and the air's mask. Collapse sequences
  are chaotic: two runs of the same case differ in detail.
- The rigid buildings in the other scenarios never respond at all.
- The ideal-gas balloon source ignores detonation chemistry and afterburn, and is poor very close
  to the charge (within a few charge diameters or a few cells).
- Open boundaries use simple extrapolation, which reflects a small part of an outgoing wave.
- Geometry is limited to axis-aligned blocks, walls, slabs and columns on flat ground.

Results are plausible and, in the one case checked, close to a measurement, but they are not
validated for engineering decisions.
