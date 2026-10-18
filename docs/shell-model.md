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
through a shell's thickness. In the app, the structure section has an **Elements** picker. IFC
buildings import as shells and beams too (`IFCStructure`; see [structures from
IFC](structural-editing.md#structures-from-ifc)).

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
6. A shell whose centre lies in an opening is left out, unless its plate lies whole within that
   opening. A window's glass is such a plate, a pane set in a wall's opening. It is moved onto
   the wall's midsurface and made to fill the opening to its reveal, so that it shares the
   wall's nodes round the opening, and it keeps its own thickness and material. Its edges are
   then held as the wall holds them, rigidly; a real pane sits in a frame, more loosely. Where
   two plates in the same plane overlap, the later one's element wins.
7. Each reinforcement region that crosses a plate becomes a layer of bars at its own depth, with
   bar area per unit width along each of the plate's axes, up to four layers per element. In a
   column, a region filling the section (a column's smeared steel) becomes four corner bars at
   40 mm cover, and one filling part of it (a mat near one face) a bar group at its middle, up to
   eight groups; the ratios across the column count as ties.
8. **The base.** Nodes on the ground are clamped, position and rotation, when the structure has
   a fixed base, unless it has a base connection that can open, slide and fail: then it acts at
   nine points through a wall's thickness and nine by nine over a column's section, which turn
   with the node, so the base can rock on its toe (see
   [base connections](structural-model.md#base-connections)).

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
across the quad, and each layer's state is 40 bytes (20 before each crack's residual opening, 28 before its slips
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
  interlock, and by the dowel action of the intact bars that cross it, 1.65 ρ √(f<sub>c</sub>
  f<sub>y</sub>) for a ratio ρ of bars across the crack (Rasmussen), as in the solid elements;
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
yield stress, as lateral pressure. Shear across a cracked fibre is carried by interlock and by
the dowel action of the bars along the beam.

As in the solid elements, what interlock and dowels cannot hold, a crack in a layer or fibre
slides by for good, and a crack that has slid keeps half its slip open (`crackSlip`,
`crackDilatancy`; see [Shear across cracks](concrete-model.md#shear-across-cracks)), each layer
storing its three slips. On the slab benchmark and on Saatci's beams as beam elements the
difference is under a millimetre; the eight-storey frame at 500 kg sways 0.3 m where it swayed
0.6 m, and the layouts' other outcomes are unchanged.

The solid elements' bars also resist sliding by kinking: their tension, leaning along the
slide, given as a term of its own. Shells and beams need none. A shell that slides across a
crack tilts (or, in its plane, shears) as a whole, so its bar layers' tension already turns
with it; adding the term as well counted it twice, and after a slab punched its bars hung it
back up to more than it had carried before punching. The bars' rupture by kinking is kept:
dowel action ends, and the element is removed, once a crack has slid by the slip limit below.

**Punching.** Where a slab meets a column, the ring of slab elements touching the column's
footprint punches as one. Each step the mean shear through their thickness, averaged around
the ring, is compared with the connection's punching strength from Eurocode 2 (EN 1992-1-1,
6.4.4): v = 0.18 k (100 ρ f<sub>c</sub>)<sup>1/3</sup> MPa, at least 0.035 k<sup>1.5</sup>
f<sub>c</sub><sup>1/2</sup>, with k = 1 + √(200 / d) (d in mm) at most 2, on the control
perimeter u<sub>1</sub> = 2 (c<sub>1</sub> + c<sub>2</sub>) + 4π d two effective depths from
the column's face. The ring carries the same force through a perimeter through its elements'
centres, 2 (c<sub>1</sub> + c<sub>2</sub>) + 4 s for elements of side s, and the whole
thickness t, so it punches at a mean shear of v u<sub>1</sub> d / (u t), raised with strain rate
as the tensile strength is. The tension face is taken as the top, towards which a slab hogs
over its column; d is to its outermost bars and ρ the geometric mean of its bars each way, at
most 2%. Once punched, the ring's elements lose the concrete's share of their shear through
the thickness, and their top bars, pushed up against their cover, rip out and carry nothing;
the bottom bars, running on over the column, hold the slab by dowel action and by hanging it
as the ring tilts, until they have slid by the slip limit and the ring is removed. A punched
ring is drawn at 90% damage. 0.18 is Eurocode 2's characteristic coefficient, so the strength
is a little below the mean of tests.

**Shear across a section.** A shell or a beam is a member's whole depth in one element, and
its layers or fibres alone cannot fail in diagonal tension: built from beams, a beam without
stirrups that broke in shear at 332 kN (Vecchio and Shim's OA1; see
[Validation](validation.md#a-beam-failing-in-shear)) carried 470 kN, its bending strength, and
nothing failed. So each beam, across each side of its section, checks its shear against the
section's strength by the simplified modified compression field theory (Bentz, Vecchio and
Collins, 2006; the general method of CSA A23.3); shells can do the same across each of their
axes, but by default do not (below).

- V = (β √f<sub>c</sub> f<sub>a</sub> + ρ<sub>v</sub> f<sub>y</sub> cot θ) b d<sub>v</sub>, with
  β = 0.4 / (1 + 1500 ε<sub>x</sub>) and θ = 29° + 7000 ε<sub>x</sub>, √f<sub>c</sub> in MPa at
  most 8, the concrete's part raised with strain rate as its tensile strength is.
- Without the minimum of stirrups (ρ<sub>v</sub> f<sub>y</sub> ≥ 0.06 √f<sub>c</sub>) β is also
  multiplied by 1300 / (1000 + s<sub>ze</sub>), s<sub>ze</sub> = 35 d<sub>v</sub> / (15 +
  a<sub>g</sub>) mm, at least 0.85 d<sub>v</sub>: larger members are weaker in shear for their
  size. d<sub>v</sub> = max(0.9 d, 0.72 h), d to the outermost bars; beams' stirrups are their ties.
- ε<sub>x</sub>, the longitudinal strain at mid-depth, is the method's own, from the section's
  forces: (|M| / d<sub>v</sub> + |V| + N / 2) / (2 E<sub>s</sub> A<sub>s</sub>), A<sub>s</sub> the
  bars on the tension side (all of them where that side has none), between −0.0002 and 0.003.
  The element's own strain at mid-depth was tried first: where a crack gathers into one
  element, at a hinge, it is many times the average over a crack spacing that the method is
  built on, and a strip that yielded in bending at once lost its shear strength.
- f<sub>a</sub> = 3.5 − 2.5 M / (V d), between 1 and 2.5, the shear-span factor of earlier
  editions of ACI 318 (quoted from memory): within about an effective depth of a support or a
  point load the load arches straight to it and no diagonal crack forms.
- The shear compared is the section's, averaged over four times the time a shear wave takes to
  cross its depth, so that a passing stress wave does not count as a diagonal crack; pushed
  suddenly at 0.12 m/s, a strip in bending carries a passing shear of 0.6 MPa, near its whole
  strength. Without the average, the beam above failed on momentary spikes.
- Slab elements within two effective depths of a column's face are left to punching.

Once a section's shear passes its strength, it has failed that way for good: its concrete
carries no shear across it, a beam's stirrups their part, ρ<sub>v</sub> f<sub>y</sub> cot θ
(θ for a strain of 0.001), and nothing else, and it is removed once it has slid by the slip
limit. The dowel action and interlock of the layers and fibres apply only until then. A failed
section is drawn at 90% damage. On OA1, built from beams of 100 and 50 mm, the check gives 328
and 343 kN (99% and 103%), and the load falls away within 3 mm as the test's did, at about
6 mm of deflection against 9 mm measured.

**Not in shells by default.** `StructureModel.shellSectionShear` turns the check on in shells.
A 1 m strip of shells with OA1's bars per metre then fails at 298 and 319 kN (90% and 96%).
But under the contest slab's blast load the check broke the slab's sections at 6 ms, two
effective depths in from its supports, where hinges form first as a suddenly loaded slab
responds and carry about 3 MPa of shear, against about 1.5 MPa by the method even raised for
strain rate; the slab survived the test, and the solid elements carry it. The method is a
static one. Until it is checked against a member that failed in shear under a blast, shells
keep their layers' interlock and dowel action alone.

**Not under impacts.** On Saatci's beams struck by a falling weight (see
[Validation](validation.md#beams-struck-by-a-falling-weight)), the check failed the beams
beside the impact within half a millisecond under every drop, beams with stirrups and light
drops included, which in the tests left only cracks. Without it, beams come within a few per
cent of the heavy drops' peaks. Averaging over longer either breaks the beams with stirrups
too or spares the one without; a check of each section's strength cannot tell which beam the
stirrups save. `ShellSolver.disableSectionShear()` turns it off.

**Bars** follow the cyclic steel law and strain-rate factors of the solid elements. In shells
they rupture when their plastic strain, averaged along the bars over the debonded length (from
the elements beside them in the previous step), passes the rupture strain; judged at a single
element, the bars of the validation slab ruptured early, as they once did in the solid elements.

**Von Mises** (steel and the elastic material) uses the plane-stress return of Simo and Taylor
in shells and uniaxial plasticity in beams, on the Green-Lagrange strain, with elastic shear.

**Steel's strain rate** (since 18 October 2026, `StructureMaterial.rateLaw`, `SteelRateLaw`):
- **The law.** Structural steel's yield and hardening rise with its strain rate by Cowper and
  Symonds's 1 + (ε̇ / D)^(1/q).
- **From the tensile test's rate.** The factor is taken over its value at a tensile test's
  2.5 × 10⁻⁴ /s (EN ISO 6892-1), the rate the yield is measured at, and never below 1. So a
  member loaded slowly keeps its yield.
- **The rate is the plastic strain rate,** the fibre's or layer's own, averaged over the
  strain-rate window and read from the step before, as LS-DYNA's viscoplastic option takes it.
  Driven by the total strain rate, a beam held sideways at 0.9 of its capacity crept to 268 mm. Its small
  vibrations raised and lowered the yield, and each fall let the fibres already at yield flow a
  little more. On the plastic rate the yield returns to static once flow stops, and the beam holds
  as it does without the law (95 mm against 88).
- **Checked on a stocky strut** (`BucklingTests`). Squashed at 10⁻³ /s it carries 1.00 of f_y A
  (the law gives 1.03). At 0.3 /s it carries 1.23 (the law gives 1.26, read with the lag of the
  average).
- **The constants by grade.** A stronger steel's yield rises less.

  | Yield | D, q | Source | Factor at 10⁻³, 0.3 and 1 /s |
  |---|---|---|---|
  | To 300 MPa (mild steel, S235, S275) | 40.4 /s, 5 | N. Jones, *Structural Impact*, 1989, Table 8.1 | 1.04, 1.26, 1.35 |
  | To 400 MPa (S355, A992) | 68.8 /s, 5.8 | Fitted to Murray, Rowell and Thornton's A992, 372 MPa (ERDC, IESS 2018, Table 4), within 2% at 0.002–2 /s | 1.03, 1.24, 1.33 |
  | Above (S420, S460, A572 grade 50) | 94.4 /s, 4.0 | Fitted to their A572 grade 50, 424 MPa (Table 3), within 2% | 1.02, 1.19, 1.27 |

  Murray et al.'s steels, tested for UFC 3-340-02's coming steel chapter, rose 1.17–1.25 at
  0.2 /s. That is within UFC's design range of rates (0.02–0.3 /s), and in line with the design factors
  of about 1.2–1.3 quoted from it for structural steel in bending (its table not checked here). Steels stronger than they tested (quenched and
  tempered) take the last row, likely too much still.
- **The grade is read first.** A section's equivalent rectangle (`SteelSection.equivalent`), a
  profiled sheet's skin and ribs, and an imported flanged member are scaled after their steel's
  grade is read, from the steel's own yield.
- **Cold-formed sheet** (S280GD–S350GD) takes the constants of its yield, which were measured on
  hot-rolled steel.
- **Where it applies.** Beams and shells of von Mises steel that carries a law (structural steel
  does). A material without one, the closed-form studies' and a user's own, keeps its yield at
  any rate.
- **Not here.** The bars in concrete keep the CEB's law of the concrete model, and steel solid
  elements have none.

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

## Timber

Timber is a material for shells and beams only (`MaterialModel.timber`, `TimberProperties`);
solid elements refuse it. Each shell layer is ContinuumKit's timber, copied into the kernel in
single precision:
- **Elastic part:** `OrthotropicPlaneStress`, stiff along the grain and soft across it.
- **Failure:** `TimberFailure`, contributed to ContinuumKit for this and released in alpha.26
  (docs/extraction/TIMBER_FAILURE.md there). One element driven past breaking along the grain,
  across it and in shear follows the released law within 3% of each strength (`TimberTests`).

**Grain.** It runs along a global axis (`grainAxis`), turned by `grainRotation` about each
shell's normal. In a shell normal to that axis, it runs along the shell's first axis.

**Beams.** A beam's grain runs along the beam, and each of its 4 × 4 fibres follows `TimberFailure`
on that one axis:
- **Along the grain:** elastic at E₀, crushing plastically at f_c,0, and breaking in tension.
- **Across:** shear at G, splitting by f_v.
- **The faces:** the outermost fibres sit at 0.86 of the half-depth, so a fibre breaks at 0.86 of
  the strength, when the section's face would reach it in bending.

**Layers (cross-laminated timber).**
- **Lamellae:** up to eight, each a share of the thickness, each along the grain or across it
  (crossed).
- **Integration through the thickness:** three Gauss–Lobatto points in each lamella (three to
  five through one), which is exact for their elastic bending. One rule over the whole thickness
  would not be, since the stiffness jumps from lamella to lamella. Lobatto's points include the
  faces, where timber breaks in bending; with Gauss–Legendre's, a panel broke 12% late.
- **Shear through the thickness:** the section's shear force is its shear stiffness times the
  shells' transverse shear strain. In each direction that stiffness is the shear analogy's, as EN
  1995-1-1:2025 takes for CLT: a² / (t₁/2G₁ + Σ tᵢ/Gᵢ + tₙ/2Gₙ). Here a is the distance between
  the outer lamellae's centres, G is along the grain, and G_R (rolling shear) is across it. One
  lamella takes 5/6 of G.
- **Spreading the shear:** it is spread through the thickness as equilibrium spreads it in
  bending (Jourawski, S(z)/EI with each lamella's modulus that way). Each layer takes its share as
  the strain that carries it at its own damage.
- **Damage:** the analogy takes each lamella at its damaged modulus, so a lamella broken in
  rolling shear takes the section's shear stiffness with it, as the shear must pass through it.
- **Why not each layer's own strain:** with every layer at the shells' one shear strain, a 3-ply
  panel's crossed lamella carried a tenth of its rolling shear, and its stiffness was five times
  the analogy's.

**Breaking.** Three brittle modes are judged on the undamaged stress, after Sandhaas and van de
Kuilen's Hashin-type criteria (HERON 58, 2013):

| Mode | When | Softens |
|---|---|---|
| Fibre | σ_L reaches its strength in tension | σ_L in tension |
| Splitting | (σ_T/f_t,90)² + (τ_LT² + τ_LZ²)/f_v² reaches 1, σ_T counted in tension only | σ_T in tension, and the in-plane and through-thickness shears along the grain |
| Rolling shear | τ_TZ reaches f_r | τ_TZ |

- **Softening:** each mode softens linearly over its fracture energy, except the fibres, which
  break at once by default (`fibreEnergy` 0). The University of Ottawa's glulam beams and CLT
  panels did so, at finger joints and defects, and Lacroix recommends a brittle resistance curve
  for glulam. With clear wood's 60 kJ/m² the panels carried 12–25% more than measured.
- **Bands:** the in-plane modes are smeared over the element (√(ab)), rolling shear over its
  lamella. A band too long for its energy breaks at once.
- **Compression:** crushing is perfectly plastic at f_c,0 and f_c,90. Damage never softens
  compression, since a crack closes.
- **Removal:** an element is removed when every layer is torn across one of its axes. That means
  fibres broken where the grain runs that way and split where it runs across, so a CLT panel
  goes when its lamellae have broken both ways through.

**In the app:**
- **Materials:** Softwood C24, Glulam GL24h, and CLT of five C24 lamellae, with the grain along x,
  are among the editor's materials. "Material properties" sets their grain, lamellae, moduli,
  strengths and dynamic increase factor.
- **Meshing:** a piece of timber is meshed as shells and beams whatever its "Elements" choice,
  as profiled sheeting is.
- **Sample:** the "Terraced houses, brick and timber" sample is a 1930s row of three with timber
  floors and roof (below).

**Grades** (`TimberProperties.strengthClass`, `crossLaminatedPanel`, `StructureMaterial.timber(_:)`):

| Grade | E₀ / E₉₀ / G (GPa) | f_m / f_c,0 / f_t,90 / f_c,90 / f_v / f_r (MPa, mean, before the factor) | Density (kg/m³) | Dynamic increase factor |
|---|---|---|---|---|
| C16 | 8.0 / 0.27 / 0.50 | 24.7 / 24.0 / 0.70 / 2.6 / 4.9 / 1.5 | 370 | 1.4 |
| C24 | 11.0 / 0.37 / 0.69 | 37.1 / 29.7 / 0.70 / 3.0 / 6.2 / 1.5 | 420 | 1.4 |
| C30 | 12.0 / 0.40 / 0.75 | 46.4 / 33.9 / 0.70 / 3.2 / 6.2 / 1.5 | 460 | 1.4 |
| GL24h | 11.5 / 0.30 / 0.65 | 31.0 / 29.4 / 0.88 / 3.0 / 4.5 / 1.3 | 420 | 1.14 |
| GL28h | 12.6 / 0.30 / 0.65 | 36.2 / 34.3 / 0.88 / 3.0 / 4.5 / 1.3 | 460 | 1.14 |
| CLT of C24 lamellae | as C24 | as C24 | 420 | 1.28 |

The fibres break at the mean bending strength f_m, because members under a blast bend, and in
bending timber breaks at its rupture modulus. That is about 1.6 times its strength in pure
tension (JCSS: E[R_t,0] = 0.6 E[R_m]), so a member in pure tension, such as a tie, is that
much too strong.

Where the numbers come from:
- **Moduli:** the classes' means (EN 338:2016, EN 14080:2013). Rolling shear is a tenth of
  shear (PRG 320-2019 Annex X3; the Glulam-Bulletin).
- **Strengths:** the classes' characteristic values, raised to their means with the JCSS
  Probabilistic Model Code's distributions and coefficients of variation (Part 3.5, 2006):
  - bending 0.25, or 0.15 for glulam;
  - compression along 0.8 times that, shear and rolling shear the same;
  - tension across, Weibull at 0.25;
  - compression across, normal at 0.1.
  - Rolling shear's characteristic value is 1.0 MPa.
- **Fracture energies:** spruce's (Sandhaas and van de Kuilen): 0.5 kJ/m² splitting, 1.2 sliding
  along the grain, 0.6 rolling. Along the grain the fibres break at once (above).
- **Dynamic increase factors:** on the strengths only, none on stiffness, as the University of
  Ottawa's shock-tube tests found:
  - 1.28 on CLT panels' resistance (Poulin et al., J. Struct. Eng. 144(2), 2018);
  - 1.14 on glulam beams' bending strength without finger joints in their outer laminations
    (Lacroix's thesis, 2017);
  - 1.4 on solid timber (CSA S850-12, provisional; Jacques et al. 2014 found 1.41 on studs'
    rupture modulus).

### The terraced houses

`ScenarioPreset.terracedHouses` (`terracedRow` for other charges): a row of three two-storey
houses as built in the UK from the 1930s, 5 m wide and 8.5 m deep with 2.6 m storeys, under
25 kg in the street 10 m in front.
- **Walls:** cavity walls of two 102.5 mm brick leaves 50 mm apart, at the front, back and
  gables, the leaves bonded round the corners, with one-brick party walls.
- **Wall ties** (`cavityWallTies`), smeared over each cavity wall as a [joint between
  parts](structural-model.md#base-connections), the inner leaf's nodes tied to the outer's:
  - 2.47 ties per m², one per 900 mm across and 450 mm up (PD 6697, Approved Document A; LABC
    Warranty's *Wall tie replacement in existing buildings*, 2020, for ties of the 1930s);
  - each pulls out at 1.18 kN and buckles at 0.55 kN, the means of as-built ties in Messali and
    Ravenshorst's database of connections (TU Delft, 2019, Table 12);
  - 0.3 kN/mm, held to 10 mm and gone at 50 mm, the shape of Arslan et al.'s pull-out tests
    (*Construction and Building Materials* 266, 2021);
  - no shear (Skroumpelou et al., 2018, measured 0.1–0.2 kN at 20 mm);
  - once buckled, the leaves close the cavity freely and then bear on each other with friction
    0.6 (`Anchorage.closingGap`).
- **Floors and roof:** timber joists, 47 × 200 mm C24 at 400 mm under 22 mm boards. The 125 mm
  mesh cannot hold the joists, so each floor is smeared into a 98 mm timber plate with the
  joists' bending stiffness, mass and bending capacity per metre, spanning between the party
  walls and gables. The pitched roof is a flat roof of the same make at the eaves, since boxes
  square to the axes cannot pitch.
- **Joists' seats** (`joistPocket`): each plate stops 25 mm short of the walls. At the party walls
  and gables its edge rests in a pocket 100 mm deep, unstrapped as before the 1980s (LABC: older
  walls get no restraint from the floors). The joist bears on the brick, can lift off it, and is
  held along its length by friction alone until it has slid out of the pocket. TU Delft's tests
  of joists in pockets (Messali and Ravenshorst, 2019, Tables 1 and 2) found 0.5–0.7 kN to pull a
  joist out, as friction 0.6–0.95 (here 0.7) and 0.02–0.06 MPa of initial shear strength (here
  0.04, lost over 2 mm) on the joists' bearing. The brickwork above the pocket does not hold the
  joist down. The front and back walls get no restraint from the floors.
- **Roof covering** (`RoofCovering`): plain clay tiles, 73.2 kg/m² as laid (Keymer's), or
  concrete interlocking tiles (50 kg/m², Marley) or Welsh slate (about 25 kg/m²). It is a layer
  25 mm thick over the whole row, resting on the roof and the walls' tops by its weight and
  friction 0.5 (`roofCoveringSeat`). The nails that BS 5534 puts in every fourth or fifth course
  of plain tiles and in every slate are left out, since no measured pull-out was found, so
  suction greater than its weight lifts it. It holds together weakly (10 kPa of tension), so once
  lifted it breaks up into pieces about an element across and is thrown as debris. It sits 60 mm
  above the roof, more than its battens, so that the mesh keeps its nodes apart from the walls'.
- **Openings:** windows front and back on each floor, and a front door, open (no glass).
- **Sources:** the University of the West of England's Construction Web ("Evolution of building
  elements": 1930s cavity walls of brick both ways, 200 × 50 mm joists at 300–400 mm, cut roofs
  on the party walls) and the English Housing Survey's *Floor space in English homes* (2018).
  The storey height is assumed. Pre-1919 terraces, a third of them, have solid one-brick walls
  instead.

At rest the floors' seats carry the floors' weight within 3%, the covering rests on the roof
and walls with its weight, and the ties carry nothing (`TerracedHousesTests`).
`blastbench house` runs the row under any charge and grades each house by the wartime damage
categories (`TerracedRowDamage`); its comparison with bombed houses is in
[validation](validation.md#terraced-houses-against-wartime-bomb-damage).

## Laminated glass

`StructureMaterial.laminatedGlass(_:a:b:)` meshes a laminated pane a × b as one shell, with the
laws and data the envelope's pane uses ([building envelopes](building-envelopes.md#laminated-glass),
`LaminatedGlass`, `Interlayer`):

- **Before it cracks:** monolithic glass, its stiffness scaled so that the shell deflects as the
  plies' Wölfel–Bennison deflection thickness does over the shorter span, its tensile strength so
  that it cracks when the more stressed ply would (the stress thickness), its mass the plies' and
  the interlayer's. The plies crack at the stress a load rising over 1 ms breaks them at, by
  E1300's flaw model and glass's static fatigue (`GlassStrength`, Brown's integral of a ramp,
  σ₆₀ (60 (n + 1) / t)^(1/n)), from E1300's median 60 s strength for the pane's area.
- **Fragmenting:** once a crack opens through a layer anywhere in a pane (its crack strain past
  0.2%), the whole pane is in fragments, which keep their mass and carry nothing: Hooper's
  post-crack model (thesis, Imperial College London, 2011, §7.2.2) takes the cracks to spread at
  once across the pane and the glass's modulus to nothing. A pane is a solid; the mark passes from
  the elements' pass to the next through the nodes' pass, so it does not depend on the order the
  threads run in. Left to bear on one another in compression, the fragments' stiff bands gathered
  the interlayer's stretch between them and it tore through.
- **The interlayer:** an isotropic membrane at the midsurface, in plane stress by von Mises
  (Poisson's ratio 0.45), hardening along Hooper's Johnson–Cook fit to cracked laminate (Table
  7.3), σ = (6.72 + 10.6 ε_p^0.303)(1 + 0.248 ln ε̇) MPa on 0.55 GPa, at the envelope's 10 s⁻¹
  (`Interlayer.crackedLaminateCurve`), scaled to other interlayers by their plateau stresses. It
  tears where its total strain passes the failure strain (`Interlayer.failureStrain`), and only its
  tearing removes an element. As two sets of bars, one each way, it was a net with no shear,
  which sheared at the corners; held at a flat plateau, as the envelope's membrane is, its
  stretch gathered into a band. The hardening spreads it.
- **The frame:** `LaminatedShellTest` holds a pane on pinned edges, as Osnes et al.'s clamps did,
  or in structural silicone: edge springs (`SpringSupport`) of the laminate's `edgeCapacity` per
  metre either way, reached at 20 mm (Hooper's 20 mm bites peaked at 15–22 mm, §6.3) and tearing to
  nothing over 5 mm more; `releasesOnPull` lets the edge come away once either has torn.

Judged on Osnes et al.'s 15 shock-tube panes and Hooper's 8 bonded panes beside the envelope's
single degree of freedom ([validation](validation.md#laminated-glass), `blastbench laminated`,
`LaminatedShellTests`). The transport hub's shed roof can be laminated
([transport hub](transport-hub.md)).

## Coupling to the air

**Loads.** At each of its four points, a shell is loaded by the difference between the air's
overpressure on its two sides, sampled half its thickness and half an air cell out from its
midsurface (or further out if that cell is solid), along its current normal; where the air is
[refined](air-blast-model.md#refining-near-the-shock), half a fine cell out, in the fine cells. A
beam is loaded the same way on its four sides.

**Shielded faces.** Two members' shells closer than an air cell, parallel and one over the other
(the leaves of a cavity wall, a roof under its covering, layers laid face to face), leave no air
between them that the grid resolves, so the first fluid cell beyond the inner face of either lies
beyond the other: each would take the whole difference across the pair, and the pair twice the
load. A face that another member's intact element faces across less than an air cell
(`ShellMesh.shields`, found once from the mesh, the gap measured as they move) sees the air shut
between them instead, as a closed volume compressed or expanded adiabatically from its gap at
rest g₀: p₀ ((g₀ / g)^γ − 1), with g no less than a tenth of g₀; faces touching at rest see
ambient air. A 1930s cavity is closed at its reveals, so its air leaks out only slowly; the leak
is left out. Once the other element is removed or has moved more than a cell away, the face sees
the air beyond again. Without this the [terraced houses'](#the-terraced-houses) cavity walls took
the blast twice; with the cavity at ambient instead, the rooms' pressure, once they had filled
through the windows, pushed every inner leaf out with nothing behind it. Of the presets and the
profiled sheeting's harnesses (Langdon, ADBLAST), only the terraced houses have such faces (a
scan of their meshes, 18 October 2026); imported IFC walls whose layers lie face to face
(`tiesTouching`) have them too, and each layer now takes its own side instead of the whole
difference. The large-panel flats and the Keys and Alsubaei walls are solid elements and are not
affected. No recorded validation result outside the terraced houses has such faces.

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
| One shell cracked through its thickness and slid across the crack, with and without 1% of bars | The bars add 2.00 MPa, against 2.02 MPa from Rasmussen's dowel formula |
| 2.4 m square slab, 200 mm thick, on a 300 mm column, under rising pressure, on 100 and 75 mm elements | Punches at 547 and 535 kN, against 575 kN from Eurocode 2, with nothing removed before; the bottom bars then hang it up to about the same load again by some 50 mm of drop, before rupturing, and the ring comes away |
| Block of solid elements thrown at a shell plate | Bounces off; momentum conserved within 10⁻⁶; passes through without contact |
| The block dropped onto a shell slab | Comes to rest on it |
| Free shell wall closing a shock tube | Gains the air's impulse within 2% |
| Intact shell wall across the tube | Far side hears only the flexing wall |
| Hole in it | Mask opens; blast passes through |

## Validation

**Steel members.** Nassr's W150 and W200 beams and columns, blasted in the open, are the steel
beams' first measured comparison: 0.59–1.23 of the measured deflection for the beams and
0.35–1.68 for the columns. They are within a quarter on the shots near elastic and the
curtain shot, and over-read about the weak axis, where the steel's missing strain-rate law
shows ([steel members](validation.md#steel-beams-and-columns-in-the-open)). With that comparison
`SteelSection.equivalent` came to scale the steel's hardening with its yield (it had kept the
section's hardening against a scaled stiffness and yield, 2.5 times too steep for a W150).

The contest slab of the [validation notes](validation.md) with shells, through
`blastbench slab --shells 2,1,0.5`:

| Shell size | Peak | At | End of record | RMS difference | Run time |
|---|---|---|---|---|---|
| 2 in (51 mm) | 136 mm (126%) | 30 ms | 114 mm (125%) | 17.3 mm | 0.4 s |
| 1 in (25 mm) | 135 mm (125%) | 30 ms | 113 mm (124%) | 17.0 mm | 0.9 s |
| 2 in, bars under Malvar and Crawford's rate law | 124 mm (115%) | 29 ms | 96 mm (105%) | 10.3 mm | |
| Measured | 108 mm | 30 ms | 91 mm | | |
| Solid elements, 16 through (Malvar and Crawford's law; 121 mm, 112%, under the CEB's) | 108 mm (100%) | 27 ms | 80 mm (88%) | 9.8 mm | minutes |

Since the bars' strain-rate law became the CEB's (see the
[concrete model](concrete-model.md#strain-rate-effects)), which tension tests of bars support,
the shells go a quarter too far, where the solid elements go 5–15% too far: under Malvar and
Crawford's steeper law the shells peaked at 124 mm. Under that law, with 4, 8, 16 and 32 layers
the peak was 121, 124, 124 and 124 mm, so the shells' answer has converged, and it was 18%
above the solid elements' converged 105 mm. Part of the gap is known:
on the reinforced strip the solid elements are 5–8% stronger than the shells, because of the
hourglass forces of squeezed elements. With the fixed design factors of UFC 3-340-02 the shells
peak at 154 mm (solids 121 mm); with static strengths the shells fail (the solids reach
143 mm). The shells rebound about as
little as the specimen did, where the solid elements rebound twice as far.

**The presets, against the solid elements.** These were run with Malvar and Ross's tensile
strain-rate law, the default before the fib Model Code 2010's (see the
[concrete model](concrete-model.md#strain-rate-effects)), and have not been repeated.

| Case | Shells and beams | Solid elements |
|---|---|---|
| Concrete building, 100 kg, by 100 ms | 7 mm, nothing removed | 16 mm, nothing removed |
| Concrete building, 500 kg, by 100 ms | Front wall shears through (54 elements) and is pushed in 663 mm | Front wall cracks along its base and is pushed in 165 mm, nothing removed |
| Three-storey building, 100 kg, by 150 ms | Ground-floor panels near the charge broken through, 1,264 elements removed | 320 removed |
| Two-storey frame, 250 kg, over 3 s | Blasted column destroyed; both floors sag towards it, then collapse fully with the columns by 3 s | Stands: 8 mm, nothing removed |

The two tall layouts are meshed with shells and beams only, since solid elements would be far
too many. Run for 4 s on 0.5 m air, with dowel action, punching and the beams' sectional shear
check (which, with their 0.5% of ties as stirrups, barely binds in these columns), with the
Model Code's tensile strain-rate law:

| Layout | 500 kg | 1,000 kg | 2,000 kg | 4,000 kg (the layouts' charge) |
|---|---|---|---|---|
| Eight-storey frame (28 m; 3 × 2 bays of 6 m, flat slabs on 450 mm columns) | Sways 0.3 m and stands; 6 elements removed | The first floor punches off its columns and drops; the rest stands | The same | Every floor punches off its columns and pancakes; the columns are left standing bare |
| Twelve-storey tower (42 m; 20 m square, a 6 m core of 300 mm walls, twelve perimeter columns) | Loses its front column; the core and floors bridge it | The lowest floor drops at the front; the rest stands | The same | The floors punch off their columns and pancake; the core breaks and goes over; the columns are left standing bare |

Under Malvar and Ross's law the frame at 4,000 kg lost only its two lowest floors, and at
500 kg swayed 0.9 m; the tower at 1,000 kg only sagged. The outcome is chaotic: before the
beams' sectional check, the frame came down entirely at 4,000 kg under that law too.

Before dowel action and punching, the eight-storey frame stood at 250 kg and fell at 500 kg,
and the tower fell at 500 kg: the blasted columns, as beams, sheared through, and slabs slid
off their columns by the general slip rule. With the bars' dowel action the columns survive
what broke them, and a collapse now starts with punching. Dowel action is Rasmussen's
strength for a bar with plenty of concrete around it; a column's bars, 40 mm from its face,
would split their cover first, so the columns are probably too strong in shear now (see
limitation 4), and so are the solid elements'.

None of these has been compared with a test. The solid elements' column was measured after
their bars were made to resist sliding across cracks and to hold cracked sections together
(see the [concrete model](concrete-model.md#shear-across-cracks)), and with cracks that turn
with the stress until they open (see [Cracking](concrete-model.md#cracking)); before the
first, the solid building's front wall was pushed in 675 mm at 500 kg and part of the frame's
first floor fell at 250 kg, and with cracks on the lattice planes the front wall was pushed in
225 mm and the three-storey building lost 1,505 elements. Until shells and beams were given
the bars' dowel action and slab–column joints a punching check, the shell frame fell at
250 kg, where the solid elements stood at 1,000 kg; now it stands at 250 kg too (below).

## Buckling

Can the beams buckle? A transport hub's roof hangs on slender steel. So since 17 October 2026 a
straight steel strut has been shortened slowly to check (`BucklingStudy`, `blastbench buckling`,
`BucklingTests`). Its far end is held, and the end pushed in is a prescribed node, which keeps its
spin, so that end cannot turn. A small sideways nudge in the shape of its first mode starts it
bending.

**Elastic, slowly** (50 mm square, E = 210 GPa):

| Strut | Its ends | Carried once buckled | Theory |
|---|---|---|---|
| 3 m, 60 beams | Pinned and clamped | 2.04 P_E | 2.046 P_E |
| 3 m, 60 beams | Both clamped | 3.99 P_E | 4 P_E |
| 1.5 m, 15 beams (the test) | Pinned and clamped | 2.06 P_E | 2.046 P_E |
| 1.5 m, 15 beams (the test) | Both clamped | 4.05 P_E | 4 P_E |

Shortened at a finite speed, the strut goes past its critical load before it bows out. The peak
was 2.26–2.74 P_E pinned and clamped at 0.5–2 mm/s on 3 m. Once it has bowed, the load it carries
settles to its critical load, whatever the damping (2 or 20 s⁻¹). One beam across the section
buckles it correctly. The beams' large rotations, from quaternion directors, carry it into the
post-buckled shape: 60–90 mm sideways.

These checks against closed forms run on perfectly straight members
(`memberImperfections = false`), as the closed forms assume.

**Inelastic, perfectly straight** (S355, clamped at both ends, elastic–perfectly plastic):

| Slenderness λ̄ | Peak | min(N_cr, N_pl) | Eurocode 3, curve a |
|---|---|---|---|
| 0.5 (1.1 m) | 886 kN | 887.5 kN, squash | 0.92 N_pl, 818 kN |
| 1.0 (2.2 m) | 886 kN | 884 kN | 0.67 N_pl, 591 kN |
| 1.5 (3.3 m) | 442 kN | 394 kN, Euler | 0.37 N_pl, 330 kN |
| 2.0 (4.4 m) | 276 kN | 222 kN, Euler | 0.22 N_pl, 198 kN |

A stocky strut squashes at f_y A. A slender one buckles at its Euler load, or 12–24% past it at
this speed of shortening. Near λ̄ = 1, where buckling and yield meet, the beams carry the perfect
strut's load: 1.5 times Eurocode 3's design resistance. The design resistance allows for the
member's crookedness and for the residual stresses of rolling. Straight members model neither.

**Bowed, by default** (since 17 October 2026, `MemberImperfection`). Every steel member is now
bowed as Eurocode 3 takes members to be:
- Its line of beams is cut at its joints: the nodes it shares with another member, a shell or a
  tie, and its ends.
- Each length of four or more beams between joints gets a half sine across its weaker side.
- The amplitude is EN 1993-1-1 §5.3.2(11)'s for an imperfection in the buckling mode,
  e₀ = α (λ̄ − 0.2) W_pl / A (γ_M1 = 1). Here λ̄ is the length's as a pinned strut, and α is the
  member's buckling curve's (`StructureModel.bucklingCurve`, b by default, or each member's own).
- The beams' kernel adds each end's offset and turn to its node's motion and takes away the strain
  the bow alone would carry. So a bowed member starts unstressed, its axial force bends it through
  the bow, and the bow turns with it.
- The nodes stay on the straight line for the air, contact and drawing, a few millimetres off.
- Members of an elastic stand-in (yield above 2 GPa), concrete and timber stay straight.

Pinned S355 struts 50 mm square, loaded by a head mass under gravity raised slowly (load control:
the largest force the foot carries is the resistance, χ N_pl; `blastbench buckling
--curve-slenderness`). The beams' χ over Eurocode 3's:

| λ̄ | Curve a | Curve b | Curve c | Table 5.1's elastic bow, b | Its plastic bow, b |
|---|---|---|---|---|---|
| 0.2 | 1.00 | 1.00 | 1.00 | 0.96 | 0.94 |
| 0.5 | 1.01 | 1.02 | 1.02 | 0.95 | 0.91 |
| 0.8 | 1.00 | 1.00 | 1.00 | 0.93 | 0.87 |
| 1.0 | 0.98 | 0.98 | 0.99 | 0.92 | 0.86 |
| 1.5 | 0.98 | 0.98 | 0.97 | 0.94 | 0.88 |
| 2.0 | 1.01 | 0.99 | 0.98 | 0.96 | 0.92 |

**Results.**
- **The default bow is within 3% of every curve.** Twice the elements and twice the loading time
  move χ by under 1%.
- **Table 5.1's fixed bows (L/300 to L/150) read 2–18% low on these solid struts.** They were
  sized for I-sections, whose W / A is larger beside their radius of gyration; §5.3.2(11)'s
  amplitude follows the section.
- **Residual stresses are not added.** The equivalent bow stands for them, as the code intends,
  and with it the curves are met.
- **A member clamped at its joints** is bowed as if pinned, a larger bow than its shorter
  buckling length needs: the safe side.
- **The hub's members.** Its hollow chords and posts take curve a, its UC columns c and its
  purlins b.

**Dynamic.** A strut struck at its end buckles behind the compression front. There the force is
F₀ = E A v / c, and the bowing grows fastest at Lindberg's preferred wavelength,
λ = 2π √(2 E I / F₀), short of the Euler buckle. Gladden et al. measured λ ∝ v^(−1/2) in rods
struck by projectiles. On a 20 mm square strut struck at 25–200 m/s:

| Struck at | F₀ | Lindberg's λ | The beams' (8 random starts) | Ratio |
|---|---|---|---|---|
| 25 m/s | 406 kN | 0.738 m | 0.797 m | 1.08 |
| 50 m/s | 812 kN | 0.522 m | 0.579 m | 1.11 |
| 100 m/s | 1,624 kN | 0.369 m | 0.443 m | 1.20 |
| 200 m/s | 3,248 kN | 0.261 m | 0.269 m | 1.03 |

The wavelength is measured as the peak of the sideways speed's spectrum over the compressed
length, after five e-folds of the fastest growth, summed over eight random starts. One start
alone scatters by ±20%. It scales as v^(−0.52), against Gladden et al.'s measured and Lindberg's
v^(−1/2). The beams buckle about the right wavelength under a sudden load, 3–20% long.

No test of a steel column buckling under blast with its measured response has been compared.
Nassr et al.'s columns under blast with axial load (McMaster, 2012) were loaded to a quarter of
their capacity, short of buckling.

## Steel connections

Where steel members meet, they share a node unless the model says how they are connected. A
shared node is a rigid joint that never breaks: only the members' own fibres can fail. Real
connections turn, and they fracture. Since 18 October 2026, `StructureModel.steelConnection`
names a connection (`SteelConnection`).

**Where the hinges go.** Each steel beam that stops at another member gets its own end node,
held to the joint's node by a hinge (`ShellMesh.Hinge`). "Stops at" means the joint is held by a
column, by a member running on through it, or by a shell. The column, or the through member,
keeps the joint's node.

**How a hinge acts** (the `shellHinges` kernel, run before the nodes move):
- **Stiffness.** Half that of a beam element of the same length: rotation 2EI/h about each cross
  axis, axial and shear 0.5EA/h, torsion G(I₂+I₃)/h.
  - It can't be stiffer. The beam's end node carries only its share of one element's mass, so a
    stiffer hinge would need a shorter step.
  - It is rigid by EN 1993-1-8's measure (§5.2.2.5, S_j ≥ 25EI/L) for a beam over 12.5 elements
    long.
- **Plastic moment.** It turns plastically past a fraction of the beam's plastic moment, so the
  beam's plastic hinge forms in the connection.
- **Strength along the beam.** Where the connection is weaker than the beam, it yields along the
  beam as well, pulled or pushed.
- **Fracture.** It lets the beam go entirely (moment, shear and pull) once its bending turn
  about the cross axes, elastic and plastic together, reaches the fracture rotation. The tested
  connections fractured in the same way.

**The connections**, each from tests under a column's removal:

| Connection | Moment / M_p | Fracture turn | Along the beam | Source |
|---|---|---|---|---|
| Welded flange, bolted web (WUF-B) | 0.95 | 0.081 rad | as the beam | Sadek et al., NIST TN 1669 (2010) |
| Reduced beam section (RBS) | 0.8 | 0.14 rad | as the beam | NIST TN 1669; AISC 358 sizes the cut |
| Single-plate shear (fin plate) | 0.05 | 0.089 rad | 0.13 of the squash load | Weigand and Berman (2016), 13 tests |

How the shear tab's figures were derived:
- **Fracture turn:** the median of Weigand and Berman's thirteen tests (0.067–0.110 rad).
- **Moment:** three A325 bolts' shear strength (130 kN each), about the middle bolt at 76 mm
  pitch, over W18×35's M_p.
- **Strength along the beam:** the three-bolt tests' median pull (435 kN), over the equivalent
  rectangle's squash load for W18×35 (4M_p/d = 3,350 kN).
- **Shear:** left unlimited. The tests held 32–60 kN once their pull had grown, but under gravity
  the tab carries its beam.

**The column-removal assemblies** (`ColumnRemovalTest`, `blastbench removal`): two spans pushed
down at the middle column's stub at 0.1 m/s.

| Assembly | Joints | Peak load | Failed at | Measured |
|---|---|---|---|---|
| WUF-B, W21×73 on W18×119, 6.10 m spans | rigid | 1,559 kN | none by 1.1 m | 890 kN, 495 mm |
| | hinged | 1,032 kN | 629 mm (1.27) | |
| RBS, W24×94 on W24×131, 6.10 m spans | rigid | 2,545 kN | none by 1.1 m | 1,780 kN, 851 mm |
| | hinged | 1,905 kN | 895 mm (1.05) | |
| SPS, W18×35 on W14×90, 9.1 m spans | rigid | 569 kN | none by 1.4 m | about 157 kN, 892 mm |
| | hinged | 181 kN | 941 mm (1.05) | |

The load is read every 5 ms and judged on its mean over 10 mm of drop, because it rings with the
stub's mass. Weigand and Berman loaded one connection as the two-span system would load it, so
their stub load is derived: 2(T sin θ + V cos θ), from the eight three-bolt tests' medians (a
pull of 431 kN, 40 kN shear at the column face, 0.0905 rad).

- **Rigid joints** never fail by the test's drop: the beams' fibres alone carry the catenary.
- **Hinged, they fail late,** 5–27% past the test's drop. The hinge turns less than the chord
  rotation the tests quote, because the beams bend too.
- **The loads read high:** 1.07–1.16 of measured at their peaks.
- **This is a check, not a validation.** The fracture turns come from these same tests, so they
  are calibration.

**Not compared:** connections at blast rates.
- **Culache's** high-rate moment connections (Southampton, 2017) could not be fetched.
- **Dinu et al.'s** end-plate connections under column loss (Timișoara) are on a server that
  refuses connections.
- **EN 1993-1-8's component method** is not used: none of its springs is built.

**In the presets:**
- **The hub** has welded flanges, and none of its 46 fractures under its 100 kg
  ([transport hub](transport-hub.md)).
- **The office** has fin plates. Its front ground-storey columns, which no beam now holds from
  turning, are lost to the 1 t at the kerb, and 334 of its 480 fin plates fracture by 1 s as the
  floors above them drop ([office](office-tower.md#on-fin-plates)). With rigid joints it stood.

## Limitations

1. **Midsurface geometry.** Members end on each other's midsurfaces and centrelines, so where
   they meet the overlap is counted in both (a little extra mass), a column can move by up to
   half an element onto cladding flush with it, and the drawing shows small steps.
2. **Thin walls are at least one air cell thick.** A 150 mm wall on 250 mm cells blocks 250 mm
   of air, as the solid elements' mask does.
3. **Plane stress.** There is no stress through a shell's thickness: no confinement, no spall or
   scabbing, no punching through the thickness. Close to a charge, where those matter, the
   solid elements are the better model.
4. **Shear across a section follows a design method** in beams, the simplified modified
   compression field theory, compared with one static test (within 3%). Shells do not use it by
   default, since under a blast it broke the slab test's shells where the slab held, so a wall
   or slab built from shells can still be too strong in diagonal tension; in-plane shear of a
   wall is not checked this way at all. **Direct shear is a simple slip rule**, with a
   bar-kinking limit that has not been compared with a test. **Punching follows Eurocode 2's strength**, checked on the average shear around
   a column head, with no allowance for an eccentric load (an edge or corner column, or a
   blast from one side) and the tension face taken as the top. What holds a slab after it has
   punched, its bottom bars, recovers about the punching load by 50 mm of drop in the one
   check made, which may be high; no punching test, before or after punching, has been run.
   The column heads are rigid patches the size of the column.
5. **More flexible than measured** on the one test: 25% over the measured peak, against 5–15%
   for the solid elements.
6. **Debris is crude.** Contact spheres are as large as the elements, 250 mm by default, and the
   contact safeguards above are numerical, not physical. Loose shell nodes are pushed by the air
   as solid debris is, each standing for its share of the elements it belonged to; being larger,
   they slow the air in their cell more (a single loose 250 mm plate on 0.5 m cells gains 4% less
   than free-stream drag).
7. **Rotational inertia is scaled up**, which slightly slows rotation of short members.
8. **Damage reads higher on larger elements** for the same crack, since the removal strain is
   the removal width over the element size.
9. **Structures from IFC are only as square as their boxes.** Each wall, slab and member is
   one box square to the axes: inclined and curved elements stay rigid, a wall's layers become
   its one structural layer, flanged steel a rectangle of equal bending stiffness (about twice
   as stiff axially), and members that meet are tied rigidly. Parallel plates a little apart
   are moved onto one midsurface (by up to a quarter of an element), as the mesh's lines run
   through the whole building and two near ones leave slivers that shorten the time step; the
   mesh itself puts parallel plates within a fifth of an element of each other on the first's
   midsurface.

10. **Timber walls bending in their plane are too stiff.** Bilinear membranes lock in in-plane
    bending, and timber's E/G of 16 makes it worse. A deep glulam beam meshed as a wall, six
    elements deep, was 43% too stiff ([validation](validation.md#glulam-beams-in-a-shock-tube)).
    Members wider than half their depth mesh as beams and are not affected, nor is bending out of
    the plane (floors, roofs, CLT panels).
11. **Members are bowed, not modelled crooked.** Steel members carry Eurocode 3's equivalent
    bow, so they buckle at their design curves' resistance ([buckling](#buckling)). The bow
    stands for crookedness and rolling's residual stresses together; neither is modelled as
    measured. It assumes pinned ends between joints, the safe side for members clamped there. A
    beam bent about its strong axis with nothing holding it sideways between joints (a sheet's
    screws count as holding it) gets the same bow, about twice the one §5.3.4(3) gives for
    lateral-torsional buckling, so it buckles sideways sooner than it should: a lone 6 m Zed
    purlin collapses sideways under 0.9 of its in-plane capacity, where straight it holds.
    Sheeted purlins and rails stay straight, as the screws hold them at every rib line. That is
    right pushed in, where the screwed flange is the compressed one. Under uplift, from suction
    or the sheet's rebound, it is the unsafe side. The free flange is then in compression and
    the sheeting does not hold it: EN 1993-1-3 §10.1 takes it as a beam on an elastic foundation,
    and that usually governs a purlin. The equivalent rectangle has no flanges to tell apart, so
    a sheeted purlin is too strong under uplift.
    Flanged sections drawn as rectangles (`SteelSection.equivalent`) are stiffer about their
    minor axis than the section, a beam's well above it, so they buckle that way at a higher
    load than they should; their bow is sized for the rectangle.
12. **Connections are three tested types, at slow rates.** A hinge takes one connection's
    moment, fracture turn and pull for every beam in the model, scaled to each beam's plastic
    moment. Connections are not sized to their beams, and there is no component method. The
    fracture turns come from column-removal tests at about 0.1 m/s. A beam's fracture under
    blast, at strain rates a thousand times higher, has not been compared. A hinge fractures
    on its bending turn alone, not on the pull that grew with it in the tests. Its shear is
    unlimited, so a shear tab never fails in shear.

## Future work

- **Contact that knows the shells' thickness**, within the shells and between shells and solid
  elements.
- **Punching against a test**, before and after punching, and with an eccentric load.
- **A flanged section's minor axis as it is**, so that a bowed I-section buckles about its weak
  axis at its own load; and a test of imperfect struts under an impulsive axial load (Kenny's
  thesis, in [data wanted](data-wanted.md)).

## Sources

- F. Sadek, J. A. Main, H. S. Lew, S. D. Robert, V. P. Chiarito and S. El-Tawil, *An
  experimental and computational study of steel moment connections under a column removal
  scenario*, NIST Technical Note 1669, 2010 (open). The WUF-B and RBS assemblies and their
  fracture rotations.
- J. M. Weigand and J. W. Berman, "Steel gravity connections subjected to large rotations and
  axial loads", *Connections VIII*, Boston, 2016 (open, NIST pub 920903). Single-plate shear
  and bolted angle connections under a column's removal, Table 1.
- J. R. Gladden, N. Z. Handzy, A. Belmonte and E. Villermaux, "Dynamic buckling and
  fragmentation in brittle rods", *Physical Review Letters* 94, 035503, 2005 (arXiv
  cond-mat/0410642). The preferred wavelength of a rod struck at its end, and its v^(−1/2) scaling
  measured.
- H. E. Lindberg and A. L. Florence, *Dynamic Pulse Buckling*, Martinus Nijhoff, 1987. The
  preferred mode of a column under a suddenly applied load.
- EN 1993-1-1:2005, §6.3.1. Buckling curves for compression members (curve a, α = 0.21).
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
