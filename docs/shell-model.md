# Shell model

Walls and slabs can be meshed with shell elements instead of solid ones. A wall 250 mm thick
needs four solid elements of 62.5 mm through its thickness and sixteen per metre each way; as
shells it needs sixteen elements of 250 mm per square metre, about 64 times fewer, and a time step
about four times longer. Coupled to the air on cells of 0.25 or 0.5 m, the concrete building runs
8 to 16 times faster; on finer cells the air takes most of the time (see
[Performance](performance.md)).

The code is `Sources/BlastCore/ShellMesh.swift`, `ShellSolver.swift` and
`Shaders/Shell.metal`. Choose shells with `StructureModel.elementKind = .shell`; `elementSize` is
then the shells' size in the plane, and `shellLayers` (8 by default) the number of layers
through the thickness. In the app, the structure section has an **Elements** picker.

## Mesh

Every solid must be plate-like: its thinnest side no more than half of each of the others.
A column is not, and a layout with one cannot be meshed with shells (there are no beam
elements yet).

1. Each solid becomes a plate on its midsurface, of the solid's thickness and material.
2. An edge of a plate that lies inside, or on the face of, another plate it touches is moved to
   end on that plate's midsurface: a wall standing under a slab ends at the slab's midsurface,
   and two walls meeting at a corner end on each other's.
3. All plates share one grid. Along each axis its lines are the plates' midsurfaces, then their
   edges, then the edges of openings; a line closer than half an element to one already kept is
   dropped, so no element is much smaller than the rest. The gaps between lines are then split
   evenly into elements no larger than `elementSize`.
4. Plates that meet therefore share the nodes along the line where they meet, so the joint is
   rigid, as monolithic concrete is.
5. An element whose centre lies in an opening is left out. Where two plates in the same plane
   overlap, the later one's element wins.
6. Each reinforcement region that crosses a plate becomes a layer of bars at its own depth, with
   bar area per unit width along each of the plate's axes; up to four layers per element.

## Element

| Aspect | Choice |
|---|---|
| Element | Four-node quadrilateral, flat in its reference state, a degenerated solid with a director (fibre) at each node |
| Nodes | Displacement and rotation (a unit quaternion); the director is the rotated reference normal |
| Strain | Total Green-Lagrange strain in the element's reference axes, which are lattice axes, built from displacements alone so that small strains keep their precision far from the origin |
| Membrane and bending | 2 × 2 points in the plane, each with Gauss-Legendre layers through the thickness, in plane stress |
| Transverse shear | Assumed strains of MITC4, tied at the middles of the edges, shear factor 5/6 |
| Hourglass control | None needed |
| Mass | Lumped, a quarter of each element's mass at each node |
| Rotational inertia | Scaled up to (t² + A) / 12 per unit mass, A the element's area, so that rotation never limits the time step |
| Time step | Half the time a compression wave in the plane takes to cross the element's shorter side |

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

## Materials

The materials are those of the solid elements, in plane stress.

**Concrete.** Each layer at each point follows the [concrete model](concrete-model.md) with the
stress through the thickness zero:

- the in-plane strains give equivalent uniaxial strains along the element's two axes, and
  cracks are smeared over the two planes normal to them, each with its own history;
- a diagonal crack in the plane is found from the principal values of the elastic stress over
  E, and a diagonal crack through the thickness from the principal tension of each axis's
  normal stress with the transverse shear across it;
- shear across a cracked plane, in the plane and through the thickness, is carried by aggregate
  interlock;
- there is no confinement, since a plate in plane stress is free through its thickness.

**Bars** are layers of their own, at their depth, along both axes, with the cyclic steel law
and strain-rate factors of the solid elements. They rupture when their plastic strain,
averaged along the bars over the debonded length (from the elements beside them in the
previous step), passes the rupture strain. Judged at a single element, the bars of the
validation slab ruptured early, as they once did in the solid elements.

**Von Mises** (steel and the elastic material) uses the plane-stress return of Simo and Taylor
on the Green-Lagrange strain, with elastic transverse shear.

**Removal.** A shell is removed when, at any of its four points,

- every layer is cracked past the removal width across one axis and no intact bars cross that
  way;
- every layer is cracked across one axis and the element has slipped through its thickness by
  the removal width (direct shear); bars do not prevent this, since in-plane bars give a shell
  no dowel action;
- every layer is crushed or cracked past removal and no bars are left intact;
- every layer is cracked past the hard limit of the solid elements; or
- for von Mises, any layer passes its failure strain.

## Coupling to the air

**Loads.** At each of its four points, a shell is loaded by the difference between the air's
overpressure on its two sides, sampled half its thickness and half an air cell out from its
midsurface (or the next cell out if that one is solid), along its current normal.

**Mask.** Each intact shell marks the air cells that its thickness occupies, at points no more
than half a cell apart over its midsurface and through its thickness. Any point makes its cell
solid, and the cell moves with the mean velocity of the points in it, so a wall pushed along
drives the air ahead of it as solid walls do. A shell thinner than an air cell is one cell
thick to the air.

**Contact.** As for the solid elements: once anything has failed, every node is a sphere one
element across, found through the same kind of periodic table, and nodes that began within 1.5
elements of each other never repel.

## Verification

| Check | Result |
|---|---|
| Building preset meshed | Walls and roof share nodes where they meet; windows left out; two bar layers per element |
| Cantilever strip sagging under its own weight | Within 2% of beam theory |
| Its natural period | Within 3% of beam theory |
| Plate hanging from its top edge | Stretch within 2% of ρgL²/2E |
| Simply supported square plate under pressure | Within 3% of Navier's solution |
| Free plate spun through 90° | Length unchanged, kinetic energy within 0.1%: no spurious strain |
| Reinforced strip in three-point bending | 6–7% above section analysis on 50 and 25 mm elements, which agree within 0.6% (solid elements: 11–14%) |
| Two plates thrown together | Turn back at one element apart; momentum conserved |
| Free shell wall closing a shock tube | Gains the air's impulse within 2% |
| Intact shell wall across the tube | Far side hears only the flexing wall |
| Hole in it | Mask opens; blast passes through |

## Validation

The contest slab of the [validation notes](validation.md) with shells, through
`blastbench slab --shells 2,1,0.5`:

| Shell size | Peak | At | End of record | RMS difference | Run time |
|---|---|---|---|---|---|
| 2 in (51 mm) | 124 mm (115%) | 29 ms | 96 mm (105%) | 10.2 mm | 0.8 s |
| 1 in (25 mm) | 124 mm (115%) | 29 ms | 97 mm (106%) | 10.2 mm | 1.7 s |
| 0.5 in (13 mm) | 123 mm (114%) | 28 ms | 94 mm (102%) | 9.6 mm | 5.5 s |
| Measured | 108 mm | 30 ms | 91 mm | | |
| Solid elements, 16 through | 112 mm (104%) | 27 ms | 90 mm (99%) | | minutes |

With 4, 8, 16 and 32 layers the peak is 121, 124, 124 and 124 mm, so the shells' answer has
converged, and it is 11% above the solid elements' converged 112 mm. Part of the gap is known:
on the reinforced strip the solid elements are 5–8% stronger than the shells, because of the
hourglass forces of squeezed elements. With the fixed design factors of UFC 3-340-02 the shells
peak at 154 mm (solids 130 mm); with static strengths both fail. The shells rebound about as
little as the specimen did, where the solid elements rebound twice as far.

At the concrete building preset with 100 kg the shells and solids deflect by 7–9 mm. With 500 kg
both fail: the solid front wall tears along its base and is pushed in 675 mm by 100 ms, the shell
wall shears off around its edges and is pushed in 906 mm.

## Limitations

1. **Walls and slabs only.** There are no beam elements, so frames, columns and the three-storey
   building cannot be meshed with shells.
2. **Midsurface geometry.** Members end on each other's midsurfaces, so where they meet the
   overlap is counted in both (a little extra mass) and the drawing shows small steps.
3. **Thin walls are at least one air cell thick.** A 150 mm wall on 250 mm cells blocks 250 mm
   of air, as the solid elements' mask does.
4. **Plane stress.** There is no stress through the thickness: no confinement, no spall or
   scabbing, no punching through the thickness. Close to a charge, where those matter, the
   solid elements are the better model.
5. **Direct shear is a simple rule.** Sliding by the removal width removes an element; the
   bars' dowel action is ignored, and the rule has not been compared with a test.
6. **More flexible than measured** on the one test: 15% over the measured peak, against 4% for
   the solid elements.
7. **Debris is crude.** Contact spheres are as large as the elements, 250 mm by default, and
   loose shell nodes are not pushed by the air (intact flying panels are).
8. **Rotational inertia is scaled up**, which slightly slows rotation of short members.

## Future work

- **Beam elements** for columns and beams, sharing the shells' nodes, so that whole frames can
  be meshed without solids.
- **Shells and solids together**: solid elements near the charge, where the stress through the
  thickness matters, and shells elsewhere.
- **Debris loading** for loose shell nodes, and contact that knows the shells' thickness.

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
  and Structures*, 2nd ed., Wiley, 2014. Explicit shells, rotational inertia scaling.
