# Structural model

The structural solver deforms and breaks one body, the "structure", under the pressures of the
air solver or under a prescribed pressure history. It lives in
`Sources/BlastCore/StructureSolver.swift` and `Sources/BlastCore/Shaders/Structure.metal`.
The material laws have their own document: [Concrete model](concrete-model.md). Walls and slabs
can instead be meshed with shell elements and columns with beams, many times faster: see
[Shell and beam model](shell-model.md). This document describes the solid elements.

## Mesh

The structure is the union of axis-aligned boxes (walls, slabs, columns) minus other boxes
(openings), filled with cubic elements on a regular lattice. An element exists wherever a
lattice cell's centre lies inside the body. The built-in layouts use elements of 62.5 mm, or
125 mm for the two-storey frame.

Because the mesh is a lattice, there is no connectivity table: an element finds its eight nodes
from its lattice position. Nodes on the ground plane are clamped when the structure has a fixed
base, or tied to the ground by a connection that can fail (see
[base connections](#base-connections)).

**Materials.** Each box can have its own material, up to eight in one structure; where boxes
overlap, the later one's wins. Pieces that touch share nodes, so they are bonded: masonry
infill is built into its concrete frame. The materials' properties sit in a small table in the
GPU's constant memory, and each element carries a one-byte index into it. Node masses come from
each element's own density, and the time step from the stiffest material. Reinforcement is
ignored in elements whose material has no steel, so a wall's mats do not run on through a
masonry panel that overlaps it, and crushing is averaged only over elements of the same
material. The "Frame with masonry infill" layout uses this: 250 mm brick panels in the front
of a concrete frame.

**Joints between materials.** With `StructureModel.interfaceBond` set (in the editor, "Joints
between materials can open"), the elements along a boundary between two materials, on the
weaker one's side, carry across it only the bond: by default 0.2 MPa in tension and 10 J/m² of
fracture energy, as of mortar on concrete. They are given a material of their own, a copy of
theirs with that strength and energy, so the crack-band scaling keeps the joint's energy right
whatever the element size, and shear across it is the concrete model's interlock. Infill then
comes away from its frame at the bond; pulled apart, a concrete element and a masonry one
separate at 0.2 MPa instead of masonry's 0.3. Joints within masonry, between its units, are
meshed where the elements are fine enough: see the
[concrete model](concrete-model.md#masonry-as-units-and-mortar-joints). The presets keep their pieces bonded; on the
infilled frame and the three-storey building the bond changes little, since their panels near
the charge break through anyway (1,969 against 1,936 elements removed; 350 against 387 mm).

**Steel and glass.** Besides reinforced concrete, plain concrete, masonry (solid, as brick) and
concrete block (hollow, as breeze block; see the
[concrete model](concrete-model.md#default-parameters)), the presets include structural steel (S355: von Mises, 355 MPa, failing at 20% strain) and annealed glass
(brittle: cracking at 45 MPa, with the fracture energy, 8 J/m², of its toughness, and gone
after half a millimetre), meant for panes meshed as shells (and drawn as see-through glass, turning milky as it cracks), alone or in a
[mixed body](shell-model.md#shells-and-solids-together). A 1 m square pane of 6 mm glass held
at its edges breaks under 1 kg at 3 m and survives 0.5 g.

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
cross an element: 9 µs for 62.5 mm concrete elements. The wave's speed counts the bars where
they are densest (the largest ratio along one lattice axis plus any inclined bars), which
shortens the step by a few per cent in reinforced concrete; counting the concrete alone, a
25 mm mesh whose inclined bars overlapped a mat's blew up. Each step is two kernels: one over the
elements (strain, stress, nodal forces) and one over the nodes (acceleration, velocity,
displacement). Both run over lists of the elements and nodes that exist, not the whole lattice.

Supports and loading:

- a node can be held still along any of x, y, z, or given a prescribed velocity;
- every node inside a support region (`StructureModel.supports`, a list of boxes) is held
  still, for structures cut off at a part treated as rigid, such as a massive end wall;
- a node can rest on a support that pushes it up but does not hold it down, so a member can
  rotate onto the edge of a bearing and lift off it;
- the nodes on the ground plane can be tied to it by a connection of finite stiffness and
  strength instead of clamped ([base connections](#base-connections));
- gravity acts on every node;
- nodes cannot pass below the ground plane, and lose horizontal speed while on it;
- for running without the air, a pressure history can be applied to one outer face.

## Base connections

A clamped base is an assumption: the joint between a wall and its footing, and the footing in
the ground, never give. `StructureModel.baseAnchorage` replaces the clamp with a connection
(`Anchorage`) that can deform, open, slide and fail. Each node on the ground plane is tied to
the ground over its share of the base (a quarter of each element face it touches) by:

- **across the joint**, a stiff bearing in compression, damped as contacts are (30% of
  critical), and in tension a spring up to the joint's tensile strength, then a plateau held to
  a given opening (yielding starter bars) and a linear fall to nothing, unloading towards the
  origin;
- **along the joint**, a spring that sticks up to the Mohr–Coulomb limit, cohesion plus friction
  times compression, then slides. Opening takes the cohesion away as it takes the tension, and
  sliding wears both away over a given slip.

Shells and beams have one node through a wall's thickness or a column's section, so there the
connection acts at points of the footprint instead: nine through the thickness at each node on
a wall's base, over half of each element edge it ends, and nine by nine over a column's
section, from face to face with the trapezoid rule's weights. Each point moves with its node's
rotation, so a wall can open at its heel while it bears at its toe, and the node takes the
points' moment as well as their force. (Points at the middles of nine strips put the toe 7/16
of the thickness out instead of at the face, and a shell wall resting on the ground rocked
42% further than the rigid estimate; from face to face it is within 9%, as solid elements are.)

Once nothing is left the node only rests on the ground: it bears on it, slides on it with
Coulomb friction, and lifts off and lands again anywhere on it. By default the springs are as
stiff as one more element of the body's material, E / h and G / h per unit area, which leaves
the time step unchanged; a stiffer connection shortens it to keep the base nodes stable.

Three connections are provided:

| Connection | Tension | Cohesion | Friction | Lost over |
|---|---|---|---|---|
| Resting on the ground | none | none | 0.6 | nothing to lose |
| Construction joint | 1 MPa | 1.3 MPa | 0.7 | 40 J/m² opening (80 µm); 1 mm of slip |
| Dowelled (starter bars, ratio ρ) | ρ f_y (at least 1 MPa) | 1.3 MPa + 0.7 ρ f_y | 0.7 | held to 20 mm, gone at 40 mm; 20 mm of slip |

The joint's cohesion and friction are those of a rough joint in Eurocode 2, EN 1992-1-1
§6.2.5 (c = 0.45 of a C30 concrete's mean tensile strength, μ = 0.7), its tensile strength and
fracture energy about half the concrete's own; the bars' clamping is §6.2.5's ρ f_y μ for bars
at right angles to the joint. The bars' plateau stands for yield over a debonded length, about
their uniform elongation over twenty diameters each side; it is a placeholder, not a fitted
value.

**Checks** (`AnchorageTests`, an elastic block so the body itself stays out of it): a resting
block bears its weight within 3%; a bonded block pulled up by a slowly rising body force holds
at 80% of the joint's strength and comes away at 130%; starter bars hold their yield force as
the joint opens and let go past twice the plateau; a resting block holds a push of 80% of the
friction and accelerates at (F − μW)/m within 10% at 130%, with the friction force averaging
μW within 10%; a construction joint holds 70% of its cohesion and friction and slides through
at 130%; and a tall block resting on the ground holds 70% of the push that tips it, while at
130% its heel rises as a rigid block rocking about its toe would, within 15%. The same wall
meshed with shells bears its weight within 3%, holds at 70%, rocks within 20% of the rigid
block at 130% (9% in fact), and stands on a construction joint; a column of beam elements
bears its weight and, set turning, rocks on one edge of its foot.

**A freestanding wall** (`AnchorageStudy`, `blastbench anchorage`). The deformable-wall
preset's wall, 3 m high and 250 mm thick with a 565 mm²/m mat near each face, as a 1 m strip
on 62.5 mm elements, loaded by a triangular pulse of the Kingery–Bulmash reflected pressure and
impulse for 50 kg of TNT, uniform over its face, with no air and no clearing, for 0.5 s:

| Distance (pulse) | Base | Peak sway | At 0.5 s | Base uplift | Slip | Ties lost |
|---|---|---|---|---|---|---|
| 6 m (1,950 kPa, 1.8 ms) | clamped | 183 mm | 114 mm | | | |
| | starter bars | 254 mm | 113 mm | 17 mm | 0.4 mm | 0% |
| | construction joint | over | over | | 169 mm | 100% |
| | resting | over | over | | 203 mm | |
| 10 m (434 kPa, 4.3 ms) | clamped | 64 mm | 28 mm | | | |
| | starter bars | 77 mm | 14 mm | 3.5 mm | 0.1 mm | 0% |
| | construction joint | over | over | | 34 mm | 100% |
| | resting | over | over | | 51 mm | |
| 15 m (156 kPa, 7.5 ms) | clamped | 28 mm | −9 mm | | | |
| | starter bars | 31 mm | 0 mm | 1.2 mm | 0.04 mm | 0% |
| | construction joint | over | over | | 8 mm | 100% |
| | resting | over | over | | 27 mm | |
| 25 m (58 kPa, 11.5 ms) | clamped | 11 mm | 5 mm | | | |
| | starter bars | 11 mm | −1 mm | 0.3 mm | 0 | 0% |
| | construction joint | 310 mm | rising | 26 mm | 1.3 mm | 80% |
| | resting | 327 mm | rising | 27 mm | 5 mm | |

"Over" is a wall rotating away from its base past 0.7 m of sway at 0.5 s; "rising" one still
rotating away. No element failed in any run; each takes about 2.5 s.

Meshed with shells of 125 mm (`blastbench anchorage --shells`, about 1.4 s a run) the wall
does the same on every base: peak sway 210, 69, 29 and 10 mm clamped, 248, 78, 33 and 12 mm
on starter bars, and over, or still going over, on a plain joint or resting, at 6, 10, 15 and
25 m.

Where the wall is cast on starter bars the clamped base is a fair stand-in at a distance: the
peak sway is within 10% of the clamped wall's at 15 and 25 m, 21% more at 10 m and 39% more at
6 m, where the bars yield and the heel lifts 17 mm, and the wall ends no further over. Without
bars it is not. A plain construction joint cracks through under every pulse here, even the
58 kPa one at 25 m that sways the clamped wall 11 mm, and the wall then rocks on its toe as if
it stood loose. Resting on the ground it rocks up at every distance; at 25 m it is given about
200 J per metre against the 92 J it takes to tip it, so it goes over. A wall that stands
clamped can therefore be thrown over if its base is not tied into its footing. This is a
comparison of support assumptions, not a validation: no measured wall is reproduced, the load
is idealised, and the footing itself is rigid.

**Not modelled.** The ground is rigid and flat: there is no footing, soil, embedment or
foundation rotation, only the joint at z = 0. The connection has no rate dependence and no
dilatancy, the bars' yield is a plateau of the joint as a whole rather than bars at the faces,
and opening and sliding interact only through the shared loss of strength. Support regions
(`supports`) still hold their nodes still.

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
   two, shortened if need be to keep it near four entries per node). An entry holds up to eight
   nodes, the lowest-numbered that arrive, whatever the thread timing; entries are tagged with
   the substep's number, and only those touched are cleared.
2. Each node looks in the 27 cells around it, ignoring nodes from other cells that share an
   entry, and repels any node closer than one element with a
   penalty spring, a damper (30% of critical) and Coulomb friction (coefficient 0.5).
3. The spring stiffness is a tenth of the stiffest spring the time step allows, based on the
   lighter of the two nodes, so contact never limits the time step.

Three safeguards keep contact from creating energy. A node that its own crowded entry dropped
takes no part that step, so two nodes either see each other or neither does and their forces are
equal and opposite; once two nodes separate faster than 1 m/s the spring between them pushes no
further; and contact changes a node's velocity by at most 2 m/s in one step. Without them, nodes
hidden from each other in crowded entries can meet already deeply overlapped, and the penalty
spring then flings them apart: the shell elements' debris was thrown at up to 1,000 m/s before
they were added (see the [shell model](shell-model.md#coupling-to-the-air)). The two-storey frame
behaves as before with them.

Nodes that began as lattice neighbours never repel each other. While they share an intact
element it holds them apart; once it has failed they may already be closer than a sphere's
width, and a spring switched on in that state would create energy. The price is that two pieces
that were joined can overlap by up to one element before they touch.

## Coupling to the air

**Air to structure.** After each air step the structure takes as many substeps as its stability
limit needs to cover the same interval (typically 5 to 15). Every element face that borders the
air, or a failed element, is loaded by the overpressure of the air cell just outside it, or,
where the air is [refined](air-blast-model.md#refining-near-the-shock), of the fine cell just
outside it. The face's current position, normal and area are used, so loads follow the deformed
shape.

**Structure to air.** After those substeps, intact elements are counted into the air cells
they currently occupy. A cell within a few metres of the structure is solid when it is rigid
scenery or at least a third full of elements. An element larger than an air cell is counted at
points no further apart than an air cell; counted at its centre alone, a wall of 0.1 m elements
on 0.05 m air cells was left porous, every other cell open, and the blast went through it. The
solid mask therefore travels with a wall that
is pushed along, and opens where a wall breaks, letting the blast through. A cell that opens is
filled with the average of its fluid neighbours.

**Debris.** A node with no intact element left around it is loose debris, and the air loads it
directly, since it no longer belongs to any face. It stands for a lump of volume *V*, an eighth
of each element the body started with around it, whatever those were made of, and feels

- the air's pressure gradient across that volume, −∇*p* *V*, from central differences of the
  air cells around it (one-sided beside a solid cell), and
- drag on a cube of the same volume in the wind relative to it, ½ ρ *C*<sub>d</sub> *V*<sup>2/3</sup>
  |*u* − *v*| (*u* − *v*), with *C*<sub>d</sub> = 1.

The first throws debris along with the blast front; the second carries it in the flow that
follows. A masonry panel shattered by a charge is thrown into the building rather than left
hanging in place. `StructureSolver.debrisDrag` switches the loading off.

The air feels the reaction. Each node adds what it takes, the momentum −**F** Δt and the work
−**F**·**v** Δt, into its air cell, and after the substeps the air is given the sums (the work
that drag dissipates stays in the air as heat). The sums are kept as 64-bit fixed-point
integers (two 32-bit atomic words, with the carry passed by hand), so that they are exact, give
the same answer whatever order the nodes arrive in, and cannot overflow beside a charge.
Momentum is then conserved between air and debris: in a steady wind, the air loses what the
debris gains to within 1%. (32-bit sums either overflowed beside a charge, with the sign of the
change wrapping round, or, made coarser to prevent that, rounded away the small pushes on
single nodes and lost 5% of the momentum.)

Three guards keep the exchange from wrecking the air where it is extreme. A cell of gas
thinner than a hundredth of ambient density (a crack just opened beside a chamber at
megapascals) loads no debris. A cell is given at most 1,000 m/s of velocity change in one air
step, the exchange being scaled down past that, so momentum is not conserved there. And debris
may not take a cell below 1% of ambient pressure: the drag and the pressure gradient, held for
a whole air step, could otherwise leave negative internal energy, which the air solver's own
floors never see because the exchange comes after its sweeps. Without them, the internal
explosion test (see [Validation](validation.md#an-internal-explosion-in-a-reinforced-concrete-chamber))
blew up: a cell inside a cracking wall reached 10¹¹ m/s. Rubble still packed where its wall stood therefore slows the gas through it, and
the pressure that builds up in front of it pushes it on, much as it would push the wall.

Drag is computed from the air as it stands at the start of an air step, and held for the
whole step. Where debris is packed densely into a cell, that could take more than the air's
relative momentum and reverse the flow (a test with fine debris filling a cell in a 300 m/s
wind reversed the air to −170 m/s). So before the substeps a short pass adds up the frontal
area of the loose debris in each air cell, and each node's drag is scaled by 1 / (1 + ½ |*u* −
*v*| *A*<sub>cell</sub> Δ*t* / *V*<sub>cell</sub>): the implicit (backward Euler) form of the
cell's air relaxing towards its debris. With it the same test slows the air to 116 m/s in its
first step and never reverses it. Sparse debris is barely affected.

Debris is loaded only within the region around the structure where the air's mask is
followed, since only there can the reaction be given back, and not at all while the air is
frozen.

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

1. **One structure, bonded throughout unless joints are asked for.** A layout has a single
   deformable body, of up to eight materials (joints between them take some of those). Joints
   between materials are an element thick and open at the bond's strength, and masonry's own
   mortar joints are meshed on fine enough elements, but there are no bearings that can
   separate and no joints between other pieces of the same material. Rigid blocks never
   respond.
2. **Debris is pushed crudely.** Loose nodes feel the air's pressure gradient and a drag with a
   fixed coefficient, as cubes of their share of the elements around them. The air feels
   the reaction, so packed rubble slows the gas through it, but only through drag spread over
   a whole air cell: rubble is never solid to the air, and a cell's air sees all its debris as
   moving together. A node still attached to one intact element is not loose and is loaded
   only through that element's faces. Debris more than a few metres from the structure, or
   moving after the air has been frozen, is not loaded at all.
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
   eight lowest-numbered. The table wraps space periodically, so debris anywhere still collides,
   but cells a period apart share an entry and its eight slots. Entries used to hold four: on
   25 mm elements debris packed more nodes than that into a cell, and the nodes left out sank
   into the others and were pushed back out when they reappeared, feeding energy to the debris
   until it tore half a million elements off the chamber test's walls and roof in 8 ms. With
   eight (or sixteen) nothing of the kind happens. Debris more than a few metres
   from the structure leaves the air's mask.
5. **Collapse is chaotic, though repeatable.** A run is repeated exactly, to the last bit, on
   the same machine, however its steps are batched (everything that changes what a step
   encodes is decided at checkpoints 64 steps apart), but a collapse amplifies small
   differences, so a slightly different input (a charge a centimetre away, a time limit at a
   different moment, a change to the model) gives a different pattern of debris. The two-storey frame shows it: across this project's versions
   its upper floor has sometimes stayed up at 3 s and sometimes fallen, as changes to the
   concrete model that barely alter its first second tipped the collapse one way or the
   other; since bars resist sliding across cracks it stands at its old 250 kg charge, and
   since cracks turn with the stress until they open it stands at 1,000 kg too (90 mm; 98 mm
   with a second crack), so the preset now uses 2,000 kg, at which it falls. The twelve-storey
   layout, meshed with shells and beams, falls at 4,000 kg, its floors punching off their
   columns; the eight-storey frame has come down at that charge in one version of the model
   and lost only its two lowest floors in the next (see the
   [shell model](shell-model.md#validation)). No outcome has been compared with anything.

   Repeatability took three fixes for races between GPU threads. An element failing in a pass
   was seen by some of its neighbours in that pass and not others; a failing element is now
   marked first and committed in the node pass that follows. The nodes in a contact grid cell
   were stored, and their forces summed, in the order threads arrived; each cell is now
   emptied in one pass and filled in the next with an atomic-minimum chain that keeps its four
   lowest-numbered nodes in ascending order, whatever the timing. That also decides which
   nodes a crowded cell drops.
6. **Uniform element size.** A large building at fine resolution needs many elements, and the
   time step is set by the smallest (here, every) element. Walls, slabs and columns can be
   meshed with [shells and beams](shell-model.md) instead.
7. **Lattice-aligned geometry only.** No inclined walls, curved shells or circular columns.
8. **No structural damping** beyond the material's own dissipation, so elastic ringing persists
   longer than in a real structure.

## Future work

- **Cut cells**, in which the solid's surface cuts through air cells, so that walls are placed
  more precisely than a cell and their thickness does not flicker. This was planned as a
  conservation fix, but measurement showed the gas is already conserved within 0.3% (see
  limitation 3), so it is now a matter of geometric accuracy, and a large change to the air
  solver for it.
- **Joints within a material**: bearings that separate, and pieces of the same material that
  are not bonded. (Masonry's mortar joints are done, on solid elements fine enough to show
  them.)
- **Glass that fragments realistically**: its strength depends on the duration of the load and
  on surface flaws, and its pieces are sharp and small.
- **Proper contact surfaces**: node-to-face contact with a consistent gap, which removes the
  one-element overlap and the bumpiness.
- **Coarser solid elements away from the damage**, or solids near a charge with
  [shells and beams](shell-model.md) elsewhere.

## Sources

- CEN, EN 1992-1-1:2004, *Eurocode 2: Design of concrete structures — Part 1-1*, §6.2.5, shear
  at the interface between concretes cast at different times. The construction joint's
  cohesion and friction, and the clamping of bars across it.
- D. P. Flanagan and T. Belytschko, "A uniform strain hexahedron and quadrilateral with
  orthogonal hourglass control", *International Journal for Numerical Methods in Engineering*
  17, 1981. The element and its hourglass control.
- T. Belytschko, W. K. Liu, B. Moran and K. Elkhodary, *Nonlinear Finite Elements for Continua
  and Structures*, 2nd ed., Wiley, 2014. Explicit time integration, objective stress rates,
  bulk viscosity, penalty contact and element erosion.
- J. O. Hallquist, *LS-DYNA Theory Manual*, Livermore Software Technology Corporation. The
  conventional choices for explicit structural codes, which this solver follows in outline.
