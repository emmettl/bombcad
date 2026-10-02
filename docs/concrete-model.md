# Concrete and reinforcement model

This is the material law used for reinforced concrete, plain concrete and masonry. It is
evaluated once per element per time step in `structureElements` in
`Sources/BlastCore/Shaders/Structure.metal`; its parameters are in `StructureMaterial` in
`Sources/BlastCore/StructureTypes.swift`.

A second, much simpler material (von Mises plasticity with a failure strain) is kept for
verification problems with exact answers. It is not described here.

## Overview

The model works on **total strain**: at each step it takes the element's Green–Lagrange strain,
computed from nodal displacements, and returns a stress. The only memory is a handful of history
values per element. There is no incremental plasticity for the concrete, which makes the model
robust and exactly reversible in the elastic range.

| Ingredient                  | Treatment                                                                 |
|-----------------------------|---------------------------------------------------------------------------|
| Cracking                    | Smeared over the three lattice planes, each with its own history          |
| Tension after cracking      | Exponential softening, scaled by fracture energy                          |
| Compression                 | Parabola to peak, linear softening to a 20% residual; permanent strain on unloading |
| Confinement                 | Strength and ductility rise with lateral compression                      |
| Shear across cracks         | Aggregate interlock, weakening with crack width                           |
| Reinforcement               | Smeared bars along the lattice axes, multi-linear hardening, rupture      |
| Strain rate                 | Published dynamic increase laws for concrete and steel                    |
| Removal                     | By crack width, when no intact bar crosses the crack; or by crushing      |

## Strain measure

The displacement gradient H at the element centre gives the Green–Lagrange strain
E = ½(H + Hᵀ + HᵀH), expressed in the lattice axes. Stress is computed in those axes as a second
Piola–Kirchhoff stress S and pushed forward to the Cauchy stress σ = F S Fᵀ / J. Large rigid
rotations therefore produce no spurious stress, which matters once walls topple.

Poisson coupling is handled through **equivalent uniaxial strains**: for each axis,

ε̃ᵢ = [(1 − 2ν′) Eᵢᵢ + ν′ tr E] / [(1 + ν′)(1 − 2ν′)]

so that σᵢ = E_c ε̃ᵢ reproduces isotropic elasticity while everything is linear. The effective
Poisson's ratio ν′ fades from ν to zero as the worst crack opens, because the strain of an open
crack is not elastic strain and must not put the directions alongside it into tension.

## Cracking

Each lattice plane keeps the largest tensile equivalent strain it has seen, κ. Cracks that are
not aligned with the lattice (diagonal cracks from shear) are detected from the principal
strains: when a principal strain exceeds the cracking strain, it is added to the histories of
the planes it cuts, in proportion to the squared direction cosines. Cracking across one
direction therefore leaves the tensile strength of the others intact.

Tension follows

- σ = E_c ε̃ up to the cracking strain ε₀ = f_t / E_c;
- σ = f_t exp(−(κ − ε₀) / ε_s) beyond it;
- unloading and reloading along the secant to the origin, so a crack closes at zero strain and
  full compressive stiffness returns.

The softening strain ε_s is set so that the energy dissipated per unit area of crack equals the
fracture energy G_f whatever the element size (crack band theory):

ε_s = G_f / (ℓ f_t) − ε₀ / 2

For plain concrete, which forms a single crack, the band width ℓ is the element size. In
reinforced concrete the bars force a crack every so often, so ℓ is the larger of the element
size and a typical crack spacing (100 mm by default). Without this, a fine mesh in reinforced
concrete dissipates one crack's energy in every row of elements, which is far too much.

## Compression and confinement

Compression follows, for a compressive strain ε with peak strain ε_c and strength f_c,

- σ = f_c [1 − (1 − ε/ε_c)ⁿ] up to the peak, with n = E_c ε_c / f_c so the initial stiffness is
  E_c. Unconfined, ε_c = 2 f_c / E_c and n = 2, which is the familiar parabola;
- linear softening from f_c to 0.2 f_c over a strain range set by a crushing energy G_c
  (250 G_f by default) in the same mesh-independent way as tension;
- on unloading from a strain ε_un, the stress falls in a straight line to zero at a permanent
  strain ε_p given by Karsan and Jirsa's rule, ε_p / ε_c = 0.145 (ε_un / ε_c)² + 0.13 (ε_un / ε_c),
  never more steeply than elastic unloading. Below ε_p the concrete carries nothing, and
  reloading retraces the line. Each lattice axis keeps its own compressive history.

**Confinement.** Concrete squeezed from the sides is stronger. Each axis's strength is
multiplied by K = 1 + 4.1 σ_lat / f_c, where σ_lat is the smaller of the compressive stresses
the other two axes can supply, estimated elastically and capped at the unconfined strength
(so K ≤ 5.1). The strain at peak and the softening range grow by 1 + 5(K − 1), so confined
concrete is far more ductile. K follows its target through a running average over 50 time
steps: applied instantly, the coupling between axes is several times stiffer than the elastic
solid and breaks the explicit time-step limit.

## Shear across cracks

Before cracking, shear is elastic. Across a cracked plane the shear stiffness drops to a quarter
and the shear stress is capped by aggregate interlock, the capacity of rough crack faces to
transmit shear, from the modified compression field theory:

v = 0.18 √f_c / (0.31 + 24 w / (a + 16))    (MPa, mm)

where a is the largest aggregate size (16 mm by default) and w is the crack width, taken as the
crack strain times the band width ℓ. A hairline crack carries about 0.58 √f_c, close to the
tensile strength; a 1 mm crack carries about 30% of that.

This term was added after a model without it failed. With no shear transfer across cracks, a
flexurally cracked slab with no steel through its thickness cannot pass shear between its
tension and compression zones; the zones slide apart and the member splits along its length.
The validation slab collapsed that way until interlock was included.

## Reinforcement

Bars are smeared: each element carries a steel ratio (bar area per unit area of concrete) along
each lattice axis. A reinforcement layer given to the model is shared between the elements it
overlaps in proportion to the overlap, so a mat of bars lying on an element boundary is split
between the two layers either side.

A bar's strain is the stretch of the lattice direction it lies along, so bars rotate with the
element. Its stress follows an elastic–plastic law with a multi-linear hardening curve of up to
eight points: either a straight line from yield to ultimate followed by a plateau, or a measured
curve. The bar ruptures, permanently, when its plastic strain passes the last point.

The default steel has a 500 MPa yield, 575 MPa ultimate at 7.5% strain and rupture at 12%.

## Strain-rate effects

Blast loads strain materials at 0.1 to 100 per second, and both concrete and steel are stronger
at those rates. With `rateDependent` set, strengths are multiplied by a dynamic increase factor
that depends on a running average (50 steps) of the element's effective strain rate ε̇:

| Material and mode    | Factor                                                      | Source                    |
|----------------------|-------------------------------------------------------------|---------------------------|
| Concrete compression | (ε̇ / 30×10⁻⁶)^(1.026 α), α = 1 / (5 + 9 f_c / 10 MPa), below 30 /s; cube-root law above | CEB-FIP Model Code 1990 |
| Concrete tension     | (ε̇ / 10⁻⁶)^δ, δ = 1 / (1 + 8 f_c / 10 MPa), below 1 /s; cube-root law above | Malvar and Ross, 1998 |
| Steel yield          | (ε̇ / 10⁻⁴)^α, α = 0.074 − 0.040 f_y / 414 MPa             | Malvar and Crawford, 1998 |
| Steel ultimate       | (ε̇ / 10⁻⁴)^α, α = 0.019 − 0.009 f_y / 414 MPa             | Malvar and Crawford, 1998 |

The factor raises strength without changing stiffness. Two details matter:

- The **tensile factor is frozen when an element first cracks**. Once a crack forms, strain
  gathers in it at a rate that depends on the element size and says nothing about the material.
- The **steel factor moves from its yield value to its ultimate value** as the bar hardens.

Alternatively, fixed factors can be set (`concreteRateFactor`, `steelRateFactor`), such as the
design values of UFC 3-340-02 (1.19 and 1.17 for bending in the far range).

## Removal

An element is removed when

- a crack across one of its planes has opened by 5 mm (3 mm for masonry) and no intact bar
  crosses that plane; or
- a compressive strain passes the end of softening by a further softening range; or
- its volume has fallen to a quarter.

Tension-softened concrete carries no tension long before a 5 mm opening. The late removal is
deliberate: a cracked element still resists compression and interlock shear, and removing it
early destroys load paths that exist in reality.

## Default parameters

`StructureMaterial.concrete(compressiveStrength:)` derives the other properties from the
compressive strength f_c (in MPa):

| Property           | Formula                    | Source                |
|--------------------|----------------------------|-----------------------|
| Young's modulus    | 4700 √f_c MPa              | ACI 318               |
| Tensile strength   | 0.3 f_c^(2/3) MPa          | Eurocode 2 (mean)     |
| Fracture energy    | 73 f_c^0.18 N/m            | fib Model Code 2010   |
| Crushing energy    | 250 × fracture energy      | Common practice       |
| Poisson's ratio    | 0.2                        |                       |
| Density            | 2400 kg/m³                 |                       |

Built-in materials:

| Material            | f_c    | Reinforcement used | Strain-rate laws | Notes                                 |
|---------------------|--------|--------------------|------------------|---------------------------------------|
| Reinforced concrete | 30 MPa | Yes                | Yes              |                                       |
| Plain concrete      | 30 MPa | No                 | Yes              | Same concrete, bars ignored           |
| Masonry             | 8 MPa  | No                 | No               | E = 6 GPa, f_t = 0.3 MPa, G_f = 20 N/m |

In the built-in layouts, walls and slabs have 12 mm bars at 200 mm centres both ways in each
face (565 mm²/m, centred 40 mm below the surface); the frame's slabs have 754 mm²/m and its
columns 2% longitudinal steel with 0.4% ties. In the editor, reinforcement is assigned
automatically from each piece's proportions.

## How the model got here

The model was built in steps, each tested against the slab benchmark in
[Validation](validation.md). The dead ends are recorded because they show which ingredients
matter.

1. **Von Mises plasticity with one yield stress.** No distinction between tension and
   compression, no reinforcement. Useful only for showing that the solver worked.
2. **Rotating-crack model, straight-line steel hardening, fixed rate factors.** Predicted
   134 mm against 108 mm measured (24% over).
3. **Measured steel curve and strain-rate laws added.** Predicted 88 mm, but the result
   depended on the mesh, because every row of elements was dissipating a full crack's energy.
4. **Tension softening regularised by crack spacing.** The slab collapsed: with tension
   stiffening no longer exaggerated, the lack of any shear transfer across cracks was exposed
   and the slab split along its length.
5. **Cracks fixed to lattice planes, with aggregate-interlock shear.** Predicted 108 mm on a
   fine mesh and 113 mm on a coarse one, with no element failures.
6. **Confinement added.** No change to the slab result, as expected for a member in bending.
7. **Permanent compressive strain added.** The peak is unchanged. The rebound after it improved
   slightly (root-mean-square difference from the measured history down from 7.9 mm to 6.8 mm
   on the fine mesh), but the model still rings more than the specimen did.

Step 3's agreement was therefore an artefact, and step 5's rests on the shear mechanism that
step 4 showed to be missing.

## Limitations

1. **Validated against one test**, a one-way slab in bending under a uniform load.
2. **Cracks form only on lattice planes.** A diagonal crack is represented by damage shared
   between two planes, not as an inclined plane with its own opening and sliding. Shear
   failures are the least trustworthy predictions the model makes.
3. **Members with no steel through their thickness** rely on interlock alone for shear. The
   slab benchmark is close enough to a shear failure that its result is sensitive to the
   assumed crack spacing.
4. **Too little damping after the peak.** Cracks close exactly at zero strain and bars unload
   elastically, so small cycles of unloading and reloading dissipate nothing. The slab test
   shows this: the model recovers about 20 mm after its peak and rings by 8 mm either way,
   where the specimen recovered about 13 mm and settled. Friction on crack faces and bond slip,
   which damp a real member, are not modelled.
5. **Confinement is capped** at about five times the unconfined strength, and there is no
   compaction of the pores. Concrete under the very high pressures close to a charge is beyond
   the model's range.
6. **Reinforcement is perfectly bonded and smeared.** There is no bond slip, dowel action, bar
   buckling or lap failure, and bars are placed by the element, not individually.
7. **No spalling model as such.** Tensile failure under a reflected stress wave is captured
   only as far as the tension law and removal rule happen to capture it.
8. **Crack spacing and aggregate size are inputs**, not predictions.
9. **Masonry is treated as weak concrete**, with no joints, bond pattern or units.

## Future work

- **More validation**: a slab with steel in both faces, a wall loaded by the air solver rather
  than a prescribed pressure, a member that failed in shear, and a close-in test with spall.
  Candidates include the high-strength slabs of the same contest (Thiagarajan et al., 2015) and
  the University of Ottawa shock-tube programmes, most of which load each specimen several
  times and so need care.
- **Inclined cracks**: a fixed-crack formulation that stores crack orientation, with interlock
  and dilatancy on the actual crack plane.
- **Hysteresis in cracked concrete**: friction on closing cracks and bond slip, to damp the
  rebound.
- **Compaction** of the pores under very high pressure, for concrete close to a charge.
- **Bond slip** between bars and concrete, which governs crack spacing instead of assuming it.
- **Discrete bars** as truss elements for heavily reinforced joints and for dowel action.
- **Masonry with joints.**

## Sources

- Z. P. Bažant and B. H. Oh, "Crack band theory for fracture of concrete", *Materials and
  Structures* 16, 1983. Scaling tension softening by fracture energy and band width.
- F. J. Vecchio and M. P. Collins, "The modified compression-field theory for reinforced
  concrete elements subjected to shear", *ACI Journal* 83(2), 1986. The aggregate-interlock
  limit on crack shear, after J. C. Walraven, "Fundamental analysis of aggregate interlock",
  *Journal of the Structural Division, ASCE* 107, 1981.
- F. E. Richart, A. Brandtzaeg and R. L. Brown, *A Study of the Failure of Concrete under
  Combined Compressive Stresses*, University of Illinois Engineering Experiment Station
  Bulletin 185, 1928. The confinement coefficient 4.1.
- I. D. Karsan and J. O. Jirsa, "Behavior of concrete under compressive loadings", *Journal of
  the Structural Division, ASCE* 95(ST12), 1969. Permanent strain on unloading. The formula was
  written from memory and has not been checked against a copy.
- J. B. Mander, M. J. N. Priestley and R. Park, "Theoretical stress-strain model for confined
  concrete", *Journal of Structural Engineering* 114(8), 1988. Strain at peak under confinement.
- L. J. Malvar and C. A. Ross, "Review of strain rate effects for concrete in tension",
  *ACI Materials Journal* 95(6), 1998.
- L. J. Malvar and J. E. Crawford, "Dynamic increase factors for steel reinforcing bars",
  28th DoD Explosives Safety Seminar, 1998.
- Comité Euro-International du Béton, *CEB-FIP Model Code 1990*, Thomas Telford, 1993.
  Compressive rate law.
- fib, *fib Model Code for Concrete Structures 2010*, Ernst & Sohn, 2013. Fracture energy.
- EN 1992-1-1, *Eurocode 2: Design of concrete structures*. Mean tensile strength.
- ACI Committee 318, *Building Code Requirements for Structural Concrete*. Elastic modulus.
- US Department of Defense, *Structures to Resist the Effects of Accidental Explosions*,
  UFC 3-340-02, 2008. Design dynamic increase factors.
- J. G. Rots, *Computational Modeling of Concrete Fracture*, PhD thesis, Delft University of
  Technology, 1988. Smeared fixed and rotating crack models, shear retention.
