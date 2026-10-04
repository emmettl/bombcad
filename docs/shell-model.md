# Shell and beam model

Walls and slabs can be meshed with shell elements, and columns with beam elements, instead of
solid ones. A wall 250 mm thick needs four solid elements of 62.5 mm through its thickness and
sixteen per metre each way; as shells it needs sixteen elements of 250 mm per square metre, about
64 times fewer, with a time step about four times longer. Coupled to the air on cells of 0.25 or
0.5 m, the concrete building runs 10 to 35 times faster and the three-storey building about twice
as fast; on finer cells the air takes most of the time (see [Performance](performance.md)).

The code is `Sources/BlastCore/ShellMesh.swift`, `ShellSolver.swift` and
`Shaders/Shell.metal`. Choose them with `StructureModel.elementKind = .shell`; `elementSize` is
then the elements' size along the members, and `shellLayers` (8 by default) the number of layers
through a shell's thickness. In the app, the structure section has an **Elements** picker.

## Mesh

Every solid must be a wall or slab (its thinnest side no more than half of each of the others),
which becomes shells, or a column (at least twice as long as it is wide), which becomes beams.
Anything else, a block as long as it is wide, cannot be meshed this way.

1. Each wall or slab becomes a plate on its midsurface, and each column a line on its
   centreline, of the solid's thickness or section and material.
2. A member that ends inside, or against, another moves its end onto the other's midsurface or
   centreline: a wall standing under a slab ends at the slab's midsurface, two walls at a corner
   end on each other's, a column ends at the midsurface of the slab it carries, and a panel
   between columns ends on their centrelines.
3. All members share one grid. Along each axis its lines are the plates' midsurfaces, then the
   columns' centrelines (a centreline within half an element of a midsurface moves onto it, so
   that cladding flush with a column is joined to it), then the columns' faces and ends, the
   plates' edges and the edges of openings. A line closer than half an element to one already
   kept is dropped, so no element is much smaller than the rest. The gaps between lines are then
   split evenly into elements no larger than `elementSize`.
4. Members that meet therefore share the nodes where they meet, so the joint is rigid, as
   monolithic concrete is.
5. **Column heads.** Where a column meets a slab, the slab's nodes within the column's footprint
   are tied rigidly to the column's node: they move with it, and it takes their forces (with the
   moments of those forces about it) and their mass. The column then bears on the slab over its
   whole section. Through a single node, the slabs of the two-storey frame were torn off every
   column by the blast.
6. A shell whose centre lies in an opening is left out. Where two plates in the same plane
   overlap, the later one's element wins.
7. Each reinforcement region that crosses a plate becomes a layer of bars at its own depth, with
   bar area per unit width along each of the plate's axes, up to four layers per element. In a
   column, a region filling the section (a column's smeared steel) becomes four corner bars at
   40 mm cover, and one filling part of it (a mat near one face) a bar group at its middle, up to
   eight groups; the ratios across the column count as ties.

## Elements

**Shells.**

| Aspect | Choice |
|---|---|
| Element | Four-node quadrilateral, flat in its reference state, a degenerated solid with a director (fibre) at each node |
| Nodes | Displacement and rotation (a unit quaternion); the director is the rotated reference normal |
| Strain | Total Green-Lagrange strain in the element's reference axes, which are lattice axes, built from displacements alone so that small strains keep their precision far from the origin |
| Membrane and bending | 2 × 2 points in the plane, each with Gauss-Legendre layers through the thickness, in plane stress |
| Transverse shear | Assumed strains of MITC4, tied at the middles of the edges, shear factor 5/6 |
| Hourglass control | None needed |

A point at height ζ (from -1 to 1) through the thickness t lies at
x = Σ N<sub>a</sub> (x<sub>a</sub> + ζ t/2 d<sub>a</sub>), where d<sub>a</sub> is the director
at node a. The in-plane strains at each layer follow from the derivatives of that position along
the element's two axes; the transverse shear strains from the products of those derivatives
with the director, at the four tying points of MITC4, interpolated across the element. The
forces on the nodes and on the directors are the derivatives of the strain energy; a force on a
director becomes a moment about its node.

The layers are at Gauss-Legendre points, which integrate elastic bending exactly. Equal layers
with a point at each centre, tried first, made every plate 1/n² too flexible (6% with four
layers).

**Beams** are the line counterpart: a degenerated solid whose section is carried by two
directors at each node (the rotated reference axes of the section), with one point along the
beam, which neither locks in shear nor has spurious modes, and 4 × 4 Gauss fibres across the
section, each with the uniaxial law along the beam and shear across it.

**Both.** Masses are lumped. Rotational inertia is scaled up to (t² + A) / 12 per unit mass for
a shell of area A, and (L² + w² + d²) / 12 for a beam, so that rotation never limits the time
step, which is half the time a compression wave takes to cross the shortest element side or beam.
On the GPU a shell's four in-plane points run in four adjacent threads, whose forces are summed
across the quad, and each layer's state is 28 bytes (20 before each crack's residual opening
was stored). Together with less work in the material
laws, that took the three-storey building's structure, run on its own, from 9.6 to 6.6 times
slower than real time, and the single-storey building's from 2.5 to 1.2 times.

## Materials

The materials are those of the solid elements, in plane stress (shells) or along the beam
(beams).

**Concrete.** Each shell layer at each point follows the [concrete model](concrete-model.md)
with the stress through the thickness zero:

- the in-plane strains give equivalent uniaxial strains along the element's two axes, and
  cracks are smeared over the two planes normal to them, each with its own history;
- a diagonal crack in the plane is found from the principal values of the elastic stress over
  E, and a diagonal crack through the thickness from the principal tension of each axis's
  normal stress with the transverse shear across it;
- shear across a cracked plane, in the plane and through the thickness, is carried by aggregate
  interlock;
- there is no confinement, since a plate in plane stress is free through its thickness.

The planes are the element's own axes, as the solids' lattice planes were, and there is no
second crack. None is needed: the interlock across the planes fades as the cracking shared
into them opens, so tension that turns away from a crack does not lock. A layer cracked across
one axis and then pulled along the diagonal carries 0.64, 0.36 and 0.21 times the tensile
strength across it at 10, 30 and 60 times the cracking strain (0.16 at 30° and 60°), where a
solid element with fixed crack axes carried 0.6 however far it was pulled, and 0.35 with its
second crack (see [Cracking](concrete-model.md#cracking)). Beams' fibres share their cracking
the same way.

A beam's fibres crack across the beam, from their axial strain or the principal tension of axial
stress with shear, and are confined by the column's ties: half the tie ratio times the bars'
yield stress, as lateral pressure.

**Bars** follow the cyclic steel law and strain-rate factors of the solid elements. In shells
they rupture when their plastic strain, averaged along the bars over the debonded length (from
the elements beside them in the previous step), passes the rupture strain; judged at a single
element, the bars of the validation slab ruptured early, as they once did in the solid elements.

**Von Mises** (steel and the elastic material) uses the plane-stress return of Simo and Taylor
in shells and uniaxial plasticity in beams, on the Green-Lagrange strain, with elastic shear.

**Removal.** A shell is removed when, at any of its four points,

- every layer is cracked past the removal width across one axis and no intact bars cross that
  way;
- every layer is cracked across one axis and the element has slipped through its thickness, over
  its own length, by the slip limit (direct shear). The slip limit is the removal width where no
  intact bars cross the crack; where they do, it is the slip at which the bars, kinking across it
  over their debonded length (the crack spacing), reach their rupture strain:
  √(2 ε<sub>rupture</sub>) times the debonded length, about 50 mm for the presets' slabs;
- every layer is crushed or cracked past removal and no bars are left intact;
- every layer is cracked past the hard limit of the solid elements;
- its midsurface is crushed to a quarter of its area or turned inside out (it would otherwise
  outrun the time step); or
- for von Mises, any layer passes its failure strain.

A beam is removed by the same rules over all its fibres, or when shortened to half its length.

## Coupling to the air

**Loads.** At each of its four points, a shell is loaded by the difference between the air's
overpressure on its two sides, sampled half its thickness and half an air cell out from its
midsurface (or further out if that cell is solid), along its current normal; where the air is
[refined](air-blast-model.md#refining-near-the-shock), half a fine cell out, in the fine cells. A
beam is loaded the same way on its four sides.

**Mask.** Each intact shell and beam marks the air cells its volume occupies, at points no more
than half a cell apart. Any point makes its cell solid, and the cell moves with the mean
velocity of the points in it, so a wall pushed along drives the air ahead of it as solid walls
do. A member thinner than an air cell is one cell thick to the air.

**Contact.** As for the solid elements, once anything has failed every node is a sphere one
element across, found through a periodic table, and nodes that began within 1.5 elements of each
other never repel. Three safeguards, added for the shells and since given to the solid elements
too, keep it from creating energy:

- an entry of the table holds eight nodes (four for the solid elements' smaller cells), and a
  node its entry has dropped takes no part that step, so that two nodes either see each other or neither does and their forces are equal and
  opposite;
- once two nodes are separating faster than 1 m/s the spring between them pushes no further;
- contact changes a node's velocity by at most 2 m/s in one step.

Without them the two-storey frame's debris, piled on the ground, met already deeply overlapped
(hidden from each other in crowded entries) and the penalty springs released tens of
megajoules, throwing it at up to 1,000 m/s. With them, contact still stops pieces meeting at tens
of metres a second within a few steps, but never throws them.

## Shells and solids together

One body can mix the two: solid elements where the stress through a wall's thickness matters,
near a charge, and shells and beams elsewhere (`StructureModel.setElementKind(_:of:)`, or
`solidNear(_:within:shellSize:)` for the pieces within some distance of a point; in the app,
the Solid/Shell switch on each piece). `elementSize` is then the solid elements' size and
`shellElementSize` the shells'. The body is meshed as two (`MixedStructure`) and tied:

- **Where.** A shell node that lies in a solid element, where a shell's midsurface runs into a
  solid piece, is tied to the line of the solid's nodes that spans the shell's thickness there,
  along its normal.
- **How.** A rigid link: the shell node moves with the line's mean displacement and its
  rotation about the line's middle, and hands its force to the line in equal shares and its
  moment as forces across it (M × r / Σ|r|²), the duals of those, so the tie does no work. The
  twist about the shell's normal, which shells do not carry, drops out. The node's mass moves
  onto the line.
- **When.** Both parts take the shorter of their two time steps. Each substep runs the solid
  elements, then a whole shell substep in which the tied nodes report their loads instead of
  moving, then the solid nodes, which take them, and last the tied shell nodes, which follow.
- **The air.** Both parts are loaded by the air and both mark its mask; a shell's point counts
  as a whole cell's worth of solid elements, so the mask follows each part by its own rule.
- **Contact.** Once contact is on in either part (once anything in either has failed, by
  default), it is on in both, and the parts meet each other too. Each substep, after both have
  found their own contacts and before either moves, each solid surface node looks through the
  shell part's contact table for shell nodes, and each shell node through the solid part's
  table for solid nodes, within half the sum of their spheres' widths (0.16 m for 62.5 mm solid
  elements and 250 mm shells). The spring, damper, friction and safeguards are those within a
  part. Each pair is worked out the same way from both sides, from the substep's starting
  positions and velocities, so the forces are equal and opposite and the sums run in table
  order: runs repeat exactly. Shell nodes tied into the solid are left out, and so are pairs
  that began within 1.5 of the larger element, as within each part. The solid pass marks the
  shell nodes it finds within reach, and the shell pass, whose search over the solid's smaller
  cells is the wider, runs only for those.

A first tie, to the eight corners of the one solid element the shell node lies in, let the
moment in over a single element's height and was 10% soft; tied across the thickness, a
cantilever strip whose first quarter is solid elements and the rest shells sags within 1.3% of
beam theory, as the all-shell and all-solid strips do. A block of solid elements thrown at a
free shell plate bounces off it with the total momentum unchanged to one part in a million,
where without contact it passed through; dropped onto a shell slab held at its edges, it
comes to rest on it. At 2,000 kg the building with only its front wall solid throws that wall
into the room, and over 2 s the shell wall that falls in after it now comes to rest on its
debris, where before it fell through it (2,776 elements removed against 2,571); the run takes 19% longer (13% over the first 0.5 s), most of it
the shells' own contact, which the solid's failure now switches on.

| Single-storey building, 100 kg (`blastbench throughput --preset box --full`) | 0.25 m air cells |
|---|---|
| All solid elements of 62.5 mm | 79× slower than real time |
| Front wall solid elements, the rest shells of 250 mm (`--solid-near 8.2`) | 24× |
| All shells of 250 mm | 7× |

At 500 kg the building with only its front wall solid deflects 235 mm by 100 ms, against
165 mm all solid and 664 mm all shells: the front wall cracks along its base as the all-solid
one does (23 elements removed against none), and the shell side walls and roof, which hold it
less stiffly, bend more.

## Verification

| Check | Result |
|---|---|
| Building preset meshed | Walls and roof share nodes where they meet; windows left out; two bar layers per element |
| Frames meshed | Twelve columns of the three-storey building, sharing nodes with every slab they meet |
| Cantilever strip sagging under its own weight | Within 2% of beam theory |
| Its natural period | Within 3% of beam theory |
| Plate hanging from its top edge | Stretch within 2% of ρgL²/2E |
| Simply supported square plate under pressure | Within 3% of Navier's solution |
| Free plate spun through 90° | Length unchanged, kinetic energy within 0.1%: no spurious strain |
| Cantilever beam sagging under its own weight | Within 2% of beam theory with shear |
| Free beam spun through 90° about two axes (bending and twist) | Length unchanged, kinetic energy within 0.1% |
| Reinforced strip (shells) in three-point bending | 6–7% above section analysis on 50 and 25 mm elements, which agree within 0.6% (solid elements: 11–14%) |
| The same beam meshed with beams | 1–2% above section analysis on 50 and 25 mm elements |
| Two-storey frame under its own weight | Stands, sagging a few millimetres, nothing removed |
| Two plates thrown together | Turn back at one element apart; momentum conserved |
| Block of solid elements thrown at a shell plate | Bounces off; momentum conserved within 10⁻⁶; passes through without contact |
| The block dropped onto a shell slab | Comes to rest on it |
| Free shell wall closing a shock tube | Gains the air's impulse within 2% |
| Intact shell wall across the tube | Far side hears only the flexing wall |
| Hole in it | Mask opens; blast passes through |

## Validation

The contest slab of the [validation notes](validation.md) with shells, through
`blastbench slab --shells 2,1,0.5`:

| Shell size | Peak | At | End of record | RMS difference | Run time |
|---|---|---|---|---|---|
| 2 in (51 mm) | 124 mm (115%) | 29 ms | 96 mm (105%) | 10.3 mm | 0.4 s |
| 1 in (25 mm) | 124 mm (115%) | 29 ms | 97 mm (106%) | 10.2 mm | 0.9 s |
| 0.5 in (13 mm) | 123 mm (114%) | 28 ms | 94 mm (103%) | 9.7 mm | |
| Measured | 108 mm | 30 ms | 91 mm | | |
| Solid elements, 16 through | 108 mm (100%) | 27 ms | 80 mm (88%) | 9.8 mm | minutes |

With 4, 8, 16 and 32 layers the peak is 121, 124, 124 and 124 mm, so the shells' answer has
converged, and it is 18% above the solid elements' converged 105 mm. Part of the gap is known:
on the reinforced strip the solid elements are 5–8% stronger than the shells, because of the
hourglass forces of squeezed elements. With the fixed design factors of UFC 3-340-02 the shells
peak at 154 mm (solids 121 mm); with static strengths both fail. The shells rebound about as
little as the specimen did, where the solid elements rebound twice as far.

**The presets, against the solid elements.**

| Case | Shells and beams | Solid elements |
|---|---|---|
| Concrete building, 100 kg, by 100 ms | 7 mm, nothing removed | 16 mm, nothing removed |
| Concrete building, 500 kg, by 100 ms | Front wall shears through (54 elements) and is pushed in 663 mm | Front wall cracks along its base and is pushed in 165 mm, nothing removed |
| Three-storey building, 100 kg, by 150 ms | Ground-floor panels near the charge broken through, 1,264 elements removed | 320 removed |
| Two-storey frame, 250 kg, over 3 s | Blasted column destroyed; both floors sag towards it, then collapse fully with the columns by 3 s | Stands: 8 mm, nothing removed |

None of these has been compared with a test. The solid elements' column was measured after
their bars were made to resist sliding across cracks and to hold cracked sections together
(see the [concrete model](concrete-model.md#shear-across-cracks)), and with cracks that turn
with the stress until they open (see [Cracking](concrete-model.md#cracking)); before the
first, the solid building's front wall was pushed in 675 mm at 500 kg and part of the frame's
first floor fell at 250 kg, and with cracks on the lattice planes the front wall was pushed in
225 mm and the three-storey building lost 1,505 elements. The shells have no dowel action or kinking yet, so the two models now differ most
where a section cracks through and slides: the frame shows how far apart two reasonable
models of a collapse can end up.

## Limitations

1. **Midsurface geometry.** Members end on each other's midsurfaces and centrelines, so where
   they meet the overlap is counted in both (a little extra mass), a column can move by up to
   half an element onto cladding flush with it, and the drawing shows small steps.
2. **Thin walls are at least one air cell thick.** A 150 mm wall on 250 mm cells blocks 250 mm
   of air, as the solid elements' mask does.
3. **Plane stress.** There is no stress through a shell's thickness: no confinement, no spall or
   scabbing, no punching through the thickness. Close to a charge, where those matter, the
   solid elements are the better model.
4. **Direct shear and punching are a simple slip rule**, with a bar-kinking limit that has not
   been compared with a test. The column heads are rigid patches the size of the column.
5. **More flexible than measured** on the one test: 15% over the measured peak, against 4% for
   the solid elements.
6. **Debris is crude.** Contact spheres are as large as the elements, 250 mm by default, and the
   contact safeguards above are numerical, not physical. Loose shell nodes are pushed by the air
   as solid debris is, each standing for its share of the elements it belonged to; being larger,
   they slow the air in their cell more (a single loose 250 mm plate on 0.5 m cells gains 4% less
   than free-stream drag).
7. **Rotational inertia is scaled up**, which slightly slows rotation of short members.
8. **Damage reads higher on larger elements** for the same crack, since the removal strain is
   the removal width over the element size.

## Future work

- **Contact that knows the shells' thickness**, within the shells and between shells and solid
  elements.
- **A punching model** for slab–column joints in place of the slip rule.

## Sources

- S. Ahmad, B. M. Irons and O. C. Zienkiewicz, "Analysis of thick and thin shell structures by
  curved finite elements", *International Journal for Numerical Methods in Engineering* 2, 1970.
  The degenerated-solid shell.
- T. J. R. Hughes and W. K. Liu, "Nonlinear finite element analysis of shells: Part I.
  Three-dimensional shells", *Computer Methods in Applied Mechanics and Engineering* 26, 1981.
  Directors and finite rotations in explicit shells.
- E. N. Dvorkin and K.-J. Bathe, "A continuum mechanics based four-node shell element for
  general nonlinear analysis", *Engineering Computations* 1, 1984. The MITC4 assumed transverse
  shear strains.
- J. C. Simo and R. L. Taylor, "A return mapping algorithm for plane stress elastoplasticity",
  *International Journal for Numerical Methods in Engineering* 22, 1986.
- S. Timoshenko and S. Woinowsky-Krieger, *Theory of Plates and Shells*, 2nd ed., McGraw-Hill,
  1959. Navier's solution for the simply supported plate.
- T. Belytschko, W. K. Liu, B. Moran and K. Elkhodary, *Nonlinear Finite Elements for Continua
  and Structures*, 2nd ed., Wiley, 2014. Explicit shells and beams, rotational inertia scaling.
