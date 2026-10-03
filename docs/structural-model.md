# Structural model

The structural solver deforms and breaks one body, the "structure", under the pressures of the
air solver or under a prescribed pressure history. It lives in
`Sources/BlastCore/StructureSolver.swift` and `Sources/BlastCore/Shaders/Structure.metal`.
The material laws have their own document: [Concrete model](concrete-model.md).

## Mesh

The structure is the union of axis-aligned boxes (walls, slabs, columns) minus other boxes
(openings), filled with cubic elements on a regular lattice. An element exists wherever a
lattice cell's centre lies inside the body. The built-in layouts use elements of 62.5 mm, or
125 mm for the two-storey frame.

Because the mesh is a lattice, there is no connectivity table: an element finds its eight nodes
from its lattice position. Nodes on the ground plane are clamped when the structure has a fixed
base.

**Materials.** Each box can have its own material, up to eight in one structure; where boxes
overlap, the later one's wins. Pieces that touch share nodes, so they are bonded: masonry
infill is built into its concrete frame. The materials' properties sit in a small table in the
GPU's constant memory, and each element carries a one-byte index into it. Node masses come from
each element's own density, and the time step from the stiffest material. Reinforcement is
ignored in elements whose material has no steel, so a wall's mats do not run on through a
masonry panel that overlaps it, and crushing is averaged only over elements of the same
material. The "Frame with masonry infill" layout uses this: 250 mm brick panels in the front
of a concrete frame.

## Elements

| Aspect            | Choice                                                                        |
|-------------------|-------------------------------------------------------------------------------|
| Element           | Eight-node hexahedron, one-point quadrature (uniform strain)                  |
| Mass              | Lumped: an eighth of each element's mass at each of its nodes                 |
| Kinematics        | Total strain from nodal displacements (concrete); updated Lagrangian with the Jaumann stress rate (von Mises) |
| Hourglass control | Flanagan–Belytschko stiffness form, scaled to the element's bending stiffness |
| Bulk viscosity    | Linear (0.06) and quadratic (1.5), in compression only                        |

**Precision.** Nodes store their displacement from the lattice position, not their absolute
position, and concrete strain is computed from displacements alone. Small deflections therefore
keep full single-precision resolution however far the structure is from the origin.

**Hourglass control.** A one-point element cannot sense the four bending-like "hourglass"
modes, so a stabilising force is added for each. Here its stiffness is E h / 48 per unit modal
amplitude, the value at which a cube resists pure bending exactly as the continuum would. With
that choice a wall n elements thick has the correct bending stiffness for any n, instead of
needing many layers. The hourglass forces are capped at the element's bending capacity times
h² / 8, so they yield along with the material. For concrete that capacity is the larger of
the remaining tensile strength plus the steel, and s (1 − s / f) for an element squeezed at
mean stress s with strength f: how far a block under axial load can shift its force towards
one face, so nothing when it is unloaded or fully crushed and most at half strength.

The compressive term keeps cracked, squeezed concrete from distorting freely. Without it, two
of the validation slab's sensitivity cases (wider crack spacing, and bearings that hold the
slab down) collapsed through elements near the top surface distorting until removed. Its
cost is some extra bending strength where a compression zone is thinner than an element: a
reinforced beam carries 11–14% more than section analysis, against 8% without it. Counting
the full compressive stress instead was tried first; it made bending a few per cent stronger
still and was replaced.

## Time stepping

Central differences (explicit). The stable step is half the time a compression wave takes to
cross an element: 9 µs for 62.5 mm concrete elements. Each step is two kernels: one over the
elements (strain, stress, nodal forces) and one over the nodes (acceleration, velocity,
displacement). Both run over lists of the elements and nodes that exist, not the whole lattice.

Supports and loading:

- a node can be held still along any of x, y, z, or given a prescribed velocity;
- a node can rest on a support that pushes it up but does not hold it down, so a member can
  rotate onto the edge of a bearing and lift off it;
- gravity acts on every node;
- nodes cannot pass below the ground plane, and lose horizontal speed while on it;
- for running without the air, a pressure history can be applied to one outer face.

## Failure and removal

An element stops carrying stress and is removed ("eroded") when its material says it has
failed, or when it is crushed to a quarter of its volume. Its mass stays with its nodes, which
carry on as loose debris, pushed by the air (below). The app draws removed elements as small dark lumps at the middle of
their nodes. Removal matters for two things only: letting pieces separate, and opening the air's
solid mask. It is deliberately late (see the concrete model), because a cracked element still
resists compression and removing it too early destroys load paths.

![A single-storey building after a large charge: damage in amber and red, failed elements as rubble](deformable-building.png)

## Contact

Once anything has failed, every node on a surface acts as a sphere one element across. A node
with all eight elements around it intact is buried and left out: nothing can reach it without
first meeting the surface nodes in front of it.

1. Each substep, nodes are binned into element-sized cells of all space, which map into a
   table that wraps periodically (its period is the structure's extent rounded up to a power of
   two, shortened if need be to keep it near eight entries per node). An entry holds up to four
   nodes, the lowest-numbered that arrive, whatever the thread timing; entries are tagged with
   the substep's number, and only those touched are cleared.
2. Each node looks in the 27 cells around it, ignoring nodes from other cells that share an
   entry, and repels any node closer than one element with a
   penalty spring, a damper (30% of critical) and Coulomb friction (coefficient 0.5).
3. The spring stiffness is a tenth of the stiffest spring the time step allows, based on the
   lighter of the two nodes, so contact never limits the time step.

Nodes that began as lattice neighbours never repel each other. While they share an intact
element it holds them apart; once it has failed they may already be closer than a sphere's
width, and a spring switched on in that state would create energy. The price is that two pieces
that were joined can overlap by up to one element before they touch.

## Coupling to the air

**Air to structure.** After each air step the structure takes as many substeps as its stability
limit needs to cover the same interval (typically 5 to 15). Every element face that borders the
air, or a failed element, is loaded by the overpressure of the air cell just outside it. The
face's current position, normal and area are used, so loads follow the deformed shape.

**Structure to air.** After those substeps, intact elements are counted into the air cells
they currently occupy. A cell within a few metres of the structure is solid when it is rigid
scenery or at least a third full of elements. The solid mask therefore travels with a wall that
is pushed along, and opens where a wall breaks, letting the blast through. A cell that opens is
filled with the average of its fluid neighbours.

**Debris.** A node with no intact element left around it is loose debris, and the air loads it
directly, since it no longer belongs to any face. It stands for a lump of the structure's main
material of its own mass, so of volume *V* = mass / density, and feels

- the air's pressure gradient across that volume, −∇*p* *V*, from central differences of the
  air cells around it (one-sided beside a solid cell), and
- drag on a cube of the same volume in the wind relative to it, ½ ρ *C*<sub>d</sub> *V*<sup>2/3</sup>
  |*u* − *v*| (*u* − *v*), with *C*<sub>d</sub> = 1.

The first throws debris along with the blast front; the second carries it in the flow that
follows. The air does not feel the reaction, so it loses no momentum to the debris it pushes;
with debris of a few tonnes against the much larger mass of air a blast sets moving, this is a
small error. `StructureSolver.debrisDrag` switches the loading off. A masonry panel shattered
by a charge is now thrown into the building rather than left hanging in place.

**Moving walls.** The same pass sums the velocities of the elements in each solid cell (as
fixed-point integers, so that the GPU's atomic additions are exact and order-independent). The
air's sweep then mirrors the gas about the wall's velocity rather than about zero: the ghost
state behind a face moving at *w* along the sweep has velocity 2*w* − *u*. A wall advancing into
still air therefore drives the correct piston shock ahead of it and a rarefaction behind, and a
flexing wall radiates sound to the far side. Rigid scenery always has zero velocity. The option
`SolverConfiguration.movingWalls` switches this off, which restores the earlier behaviour of a
surface that is stationary wherever it currently is.

For the deformable-wall preset the difference is small: with 50, 200 and 500 kg charges the
peak deflection is 1% to 3% lower with moving walls, because the air ahead of the wall now
resists its motion. Air throughput is unchanged.

**Substep bookkeeping.** The air's time step is decided on the GPU, so the CPU cannot know how
many substeps each air step will need. It encodes the largest number that could be needed
(bounded by the time step of still air), and surplus substeps return immediately.

## Verification

See [Validation](validation.md). In brief: stress-wave speed, cantilever deflection and natural
period, rigid rotation, collisions and stacking are all checked against theory, and the coupling
is checked for impulse transfer, hydrostatic equilibrium, venting, a moving mask, a piston
shock, and the drag and pressure-gradient push on loose debris.

## Limitations

1. **One structure, bonded throughout.** A layout has a single deformable body, of up to eight
   materials, and pieces that touch are fully bonded. There are no interfaces: no mortar
   joints, no sliding of infill against its frame, no bearings that can separate. Rigid
   blocks never respond.
2. **Debris is pushed crudely, and does not push back.** Loose nodes feel the air's pressure
   gradient and a drag with a fixed coefficient, as cubes of the main material whatever they
   are made of, and the air feels no reaction. A node still attached to one intact element
   is not loose and is loaded only through that element's faces. Debris is never a solid
   to the air: gas passes through rubble as if it were not there.
3. **Walls are a staircase of whole cells.** A wall's surface in the air is placed to the
   nearest cell, and its thickness there can flicker by a cell as it moves (a 0.5 m wall on
   0.25 m cells covers two cells or three). The gas itself is conserved: the face flux of a
   moving wall adds the gas that its not-yet-covered cell would have squeezed out, and that gas
   is removed when the cell is covered. A wall driven 1.1 m through the grid conserves the
   gas's mass within 0.3% once the grid's volume is scaled to the true volume; the apparent
   change, about 1.7%, is one cell of staircase. The work the air does on the wall and the
   work the wall does on the air are computed separately and do not exactly balance. A solid
   cell's velocity is the mean of its elements, so a spinning fragment smaller than a cell looks
   to the air like one moving in a straight line.
4. **Contact is approximate.** Surfaces are bumpy at the element scale, formerly joined pieces
   overlap by up to an element, and a crowded entry of the contact table drops nodes beyond its
   four lowest-numbered. The table wraps space periodically, so debris anywhere still collides,
   but cells a period apart share an entry and its four slots. Debris more than a few metres
   from the structure leaves the air's mask.
5. **Collapse is chaotic, though repeatable.** A run is repeated exactly, to the last bit, on
   the same machine, but a collapse amplifies small differences, so a slightly different input
   (a charge a centimetre away, a different batching of steps, a change to the model) gives a
   different pattern of debris. The two-storey frame shows it: across this project's versions
   its upper floor has sometimes stayed up at 3 s and sometimes fallen, as changes to the
   concrete model that barely alter its first second tipped the collapse one way or the
   other. Neither outcome has been compared with anything.

   Repeatability took three fixes for races between GPU threads. An element failing in a pass
   was seen by some of its neighbours in that pass and not others; a failing element is now
   marked first and committed in the node pass that follows. The nodes in a contact grid cell
   were stored, and their forces summed, in the order threads arrived; each cell is now
   emptied in one pass and filled in the next with an atomic-minimum chain that keeps its four
   lowest-numbered nodes in ascending order, whatever the timing. That also decides which
   nodes a crowded cell drops.
6. **Uniform element size.** A large building at fine resolution needs many elements, and the
   time step is set by the smallest (here, every) element.
7. **Lattice-aligned geometry only.** No inclined walls, curved shells or circular columns.
8. **No structural damping** beyond the material's own dissipation, so elastic ringing persists
   longer than in a real structure.

## Future work

- **Cut cells**, in which the solid's surface cuts through air cells, so that walls are placed
  more precisely than a cell and their thickness does not flicker. This was planned as a
  conservation fix, but measurement showed the gas is already conserved within 0.3% (see
  limitation 3), so it is now a matter of geometric accuracy, and a large change to the air
  solver for it.
- **Several bodies and materials** in one layout, including steel sections and glazing.
- **Proper contact surfaces**: node-to-face contact with a consistent gap, which removes the
  one-element overlap and the bumpiness.
- **Coarser elements away from the damage**, or shell and beam elements for thin members, to
  make whole buildings affordable.

## Sources

- D. P. Flanagan and T. Belytschko, "A uniform strain hexahedron and quadrilateral with
  orthogonal hourglass control", *International Journal for Numerical Methods in Engineering*
  17, 1981. The element and its hourglass control.
- T. Belytschko, W. K. Liu, B. Moran and K. Elkhodary, *Nonlinear Finite Elements for Continua
  and Structures*, 2nd ed., Wiley, 2014. Explicit time integration, objective stress rates,
  bulk viscosity, penalty contact and element erosion.
- J. O. Hallquist, *LS-DYNA Theory Manual*, Livermore Software Technology Corporation. The
  conventional choices for explicit structural codes, which this solver follows in outline.
