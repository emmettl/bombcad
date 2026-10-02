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
needing many layers. The hourglass forces are capped at the element's bending capacity (its
remaining tensile strength times h² / 8), so they yield along with the material.

## Time stepping

Central differences (explicit). The stable step is half the time a compression wave takes to
cross an element: 9 µs for 62.5 mm concrete elements. Each step is two kernels: one over the
elements (strain, stress, nodal forces) and one over the nodes (acceleration, velocity,
displacement). Both run over lists of the elements and nodes that exist, not the whole lattice.

Supports and loading:

- a node can be held still along any of x, y, z, or given a prescribed velocity;
- gravity acts on every node;
- nodes cannot pass below the ground plane, and lose horizontal speed while on it;
- for running without the air, a pressure history can be applied to one outer face.

## Failure and removal

An element stops carrying stress and is removed ("eroded") when its material says it has
failed, or when it is crushed to a quarter of its volume. Its mass stays with its nodes, which
carry on as loose debris. The app draws removed elements as small dark lumps at the middle of
their nodes. Removal matters for two things only: letting pieces separate, and opening the air's
solid mask. It is deliberately late (see the concrete model), because a cracked element still
resists compression and removing it too early destroys load paths.

![A single-storey building after a large charge: damage in amber and red, failed elements as rubble](deformable-building.png)

## Contact

Once anything has failed, every node acts as a sphere one element across.

1. Each substep, nodes are binned into a grid of element-sized cells covering the structure
   and a few metres around it. A cell holds up to four nodes. Cells are tagged with the
   substep's number, so the grid never needs clearing.
2. Each node looks in the 27 cells around it and repels any node closer than one element with a
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

**Substep bookkeeping.** The air's time step is decided on the GPU, so the CPU cannot know how
many substeps each air step will need. It encodes the largest number that could be needed
(bounded by the time step of still air), and surplus substeps return immediately.

## Verification

See [Validation](validation.md). In brief: stress-wave speed, cantilever deflection and natural
period, rigid rotation, collisions and stacking are all checked against theory, and the coupling
is checked for impulse transfer, hydrostatic equilibrium, venting and a moving mask.

## Limitations

1. **One structure, one material.** A layout has a single deformable body made of one material.
   Rigid blocks never respond.
2. **Coupling moves the mask but not the air.** A moving wall imparts no velocity to the gas,
   and gas in a cell that becomes solid is removed. Once the structure moves, the air's mass and
   energy are no longer exactly conserved. The effect is small while walls move slowly compared
   with the blast, and wrong in principle for fast debris.
3. **Contact is approximate.** Surfaces are bumpy at the element scale, formerly joined pieces
   overlap by up to an element, a crowded grid cell silently drops nodes beyond four, and
   debris more than a few metres from the structure leaves the contact grid and the air's mask.
4. **Collapse is chaotic.** Two runs of the same collapse differ in detail, because of harmless
   races between GPU threads (in filling the contact grid, for example) that a collapse then
   amplifies.
5. **Uniform element size.** A large building at fine resolution needs many elements, and the
   time step is set by the smallest (here, every) element.
6. **Lattice-aligned geometry only.** No inclined walls, curved shells or circular columns.
7. **No structural damping** beyond the material's own dissipation, so elastic ringing persists
   longer than in a real structure.

## Future work

- **Momentum-conserving coupling**: a cut-cell or immersed-boundary treatment in which moving
  solid faces do work on the gas.
- **Several bodies and materials** in one layout, including steel sections and glazing.
- **Proper contact surfaces**: node-to-face contact with a consistent gap, which removes the
  one-element overlap and the bumpiness.
- **Coarser elements away from the damage**, or shell and beam elements for thin members, to
  make whole buildings affordable.
- **Reproducible collapse**, by making the contact grid's fill order deterministic.

## Sources

- D. P. Flanagan and T. Belytschko, "A uniform strain hexahedron and quadrilateral with
  orthogonal hourglass control", *International Journal for Numerical Methods in Engineering*
  17, 1981. The element and its hourglass control.
- T. Belytschko, W. K. Liu, B. Moran and K. Elkhodary, *Nonlinear Finite Elements for Continua
  and Structures*, 2nd ed., Wiley, 2014. Explicit time integration, objective stress rates,
  bulk viscosity, penalty contact and element erosion.
- J. O. Hallquist, *LS-DYNA Theory Manual*, Livermore Software Technology Corporation. The
  conventional choices for explicit structural codes, which this solver follows in outline.
