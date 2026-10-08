# Validation

What has been checked, against what, and how far the results can be trusted. "Verification"
here means agreement with theory (is the model solved correctly?); "validation" means agreement
with measurements (is it the right model?).

All of it can be reproduced:

```bash
swift test
```

```bash
swift run -c release blastbench slab --sensitivity
```

```bash
swift run -c release blastbench beam
```

```bash
swift run -c release blastbench shear --layers 24,36
```

```bash
swift run -c release blastbench impact --layers 16
```

```bash
swift run -c release blastbench closein
```

```bash
swift run -c release blastbench closeair --dx 0.01
```

```bash
swift run -c release blastbench validate
```

```bash
swift run -c release blastbench chamber
```

## Summary

| Area                 | Evidence                                             | Confidence                         |
|----------------------|------------------------------------------------------|------------------------------------|
| Air solver numerics  | Exact solutions                                      | High                               |
| Blast loads          | Kingery–Bulmash curves from 0.75 to 6 m/kg^(1/3): impulse on a wall within 6% on 0.25 m cells beyond 1.5 m/kg^(1/3); refinement gives the next finer grid's peaks | Good for impulse on walls; peaks under-resolved; incident impulse 13–22% low without afterburning, within 4% with it (fitted) |
| Gas in a closed room | UFC 3-340-02: 48% to 114% of the design curve by default; 98% to 108% with afterburning and hot air; 90% of Cooper's closed vessel, burnt out | Good with afterburning and hot air, nothing fitted |
| Structural numerics  | Beam and wave theory                                 | High                               |
| Concrete material    | Its own curves; section analysis of a beam           | High that it does what is intended |
| Structural response  | One slab test: solid elements 104–112 mm (96–103%) on 4 to 16 elements through, shells 124 mm (115%); one beam bent to failure: peak moment 97–99%, failure at 38–52 mm against 42 mm; one beam without stirrups failing in shear: converges 11–12% strong, failing suddenly as the test did; seven drop-weight impacts on beams: with stirrups within 15% under light drops and −5% to +15% under heavy ones, the beam without stirrups broken by the heavy drop as in the test, and damaged by the light one it survived; nineteen on beams without stirrups at rising speeds: within 15% up to 3 m/s and 18% on average beyond on 16 elements, but further on 24, springing back too far, and decided by how the ends were held | Moderate for bending; low for shear: one test, and coarse meshes far too strong; moderate for impact, where the concrete's strain-rate law decides it |
| Close-in charges     | Reflected impulse within 8% of Kingery–Bulmash from 0.3 m/kg^(1/3) on fine enough cells; full-scale slabs under 2–15 kg at 0.5 and 1 m: gauges beside the slab 75–80% of those measured, the impulse under the charge 86–95% of Kingery–Bulmash's; the slab left a third as far down as measured, barely spalled, and the 0.5 m breach not converged with the mesh | Good for the load; low for close-in damage: the slab is too strong and spalls too little |
| Internal explosion   | One full-scale chamber test: peak wall pressures 0.9 to 1.6 times those measured; the roof is about twice as stiff as the paper's model and its edge is left 16 mm up against 95 mm | Low: the joints' inclined cracking decides it, and the crack models disagree |
| Collapse and debris  | Nothing                                              | None: plausible-looking only       |

## Structural response against a real test

### The test

The normal-strength slab of the 2013 Blast Blind Simulation Contest, organised by the University
of Missouri–Kansas City with ACI Committees 447 and 370 and tested in the Blast Loading
Simulator of the US Army Engineer Research and Development Center, Vicksburg. The simulator is
a large shock tube that applies a uniform, measured pressure history to one face of a specimen.

| Property        | Value                                                                          |
|-----------------|--------------------------------------------------------------------------------|
| Slab            | 64 × 33.75 × 4 in (1626 × 857 × 102 mm)                                        |
| Supports        | Simple, 52 in (1321 mm) apart                                                  |
| Concrete        | 5,400 psi (37 MPa)                                                             |
| Main bars       | Nine No. 3 (9.5 mm) at 4 in, 1 in from the unloaded face                       |
| Cross bars      | No. 3 at 12 in                                                                 |
| Steel           | Yield 72 ksi (496 MPa), 118 ksi (814 MPa) at 8% strain, rupture near 15%       |
| Load            | Peak 50 psi (345 kPa), impulse 1,020 psi·ms (7.0 kPa·s), over 80 ms            |
| Measured        | Peak mid-span deflection about 4.25 in (108 mm) at 30 ms; about 3.55 in (90 mm) at 70 ms |

**Source of the data.** T. H. Kewaisy, A. A. Khalil and A. ElFouly, *Advanced Modeling of Blast
Response of Reinforced Concrete Walls with and without FRP Retrofit*, ACI Spring Convention,
2018, which reproduces the contest's specimen drawing, material curves, pressure record and
measured displacement history. The test programme itself is reported in G. Thiagarajan,
A. V. Kadambi, S. Robert and C. F. Johnson, "Experimental and finite element analysis of doubly
reinforced concrete slabs subjected to blast loads", *International Journal of Impact
Engineering* 75, 2015.

**How the data were taken.** The pressure record, the steel curve and the displacement history
were read off the published plots by hand. The pressure record was then scaled so that its
impulse equals the stated 1,020 psi·ms; the scaling was under 1%, and the scaled peak is
49.9 psi against the stated 50.

### The model

The slab is meshed with cubic elements, eight (12.7 mm) or four (25.4 mm) through its
thickness. It is supported on two lines of nodes on the unloaded face (a pin and a roller), and
the recorded pressure is applied to the other face. Gravity is ignored, since the slab stood
vertically.

Nothing was fitted to the test. The concrete's stiffness, tensile strength and fracture energy
come from standard correlations with its compressive strength; the bars follow their published
curve; strengths rise with strain rate by published laws. Two inputs are assumptions: the crack
spacing (100 mm) and the aggregate size (16 mm).

### Results

| Case                             | Peak deflection | At    | At 70 ms | Elements failed |
|----------------------------------|-----------------|-------|----------|-----------------|
| **Measured**                     | **108 mm**      | 30 ms | 90 mm    |                 |
| Model, 16 elements through       | 112 mm (103%)   | 27 ms | 77 mm    | 0 of 552,960    |
| Model, 8 elements through        | 104 mm (97%)    | 26 ms | 64 mm    | 0 of 68,608     |
| Model, 4 elements through        | 104 mm (96%)    | 26 ms | 84 mm    | 0 of 8,704      |
| With Malvar and Ross's tensile law: 32 through | 105 mm (98%) | 26 ms | 74 mm | 32 of 4,423,680 |
| 16 through                       | 107 mm (99%)    | 26 ms | 67 mm    | 0 of 552,960    |
| 8 through                        | 101 mm (93%)    | 26 ms | 66 mm    | 0 of 68,608     |
| 4 through                        | 100 mm (93%)    | 26 ms | 79 mm    | 0 of 8,704      |

The tensile strain-rate law is the fib Model Code 2010's by default (see the
[concrete model](concrete-model.md#strain-rate-effects)); with it the peak is 96–103% on 4 to 16
elements. The tables below were made with Malvar and Ross's, the default until the drop-weight
impacts and close-in slabs below showed it too stiff; the 32-element run has not been repeated.

Mid-span deflection through the record, with Malvar and Ross's tensile law, in millimetres:

| Time  | Measured | 32 through | 16 through | 8 through | 4 through |
|-------|----------|------------|------------|-----------|-----------|
| 5 ms  | 9        | 10         | 10         | 9         | 9         |
| 10 ms | 35       | 37         | 37         | 36        | 35        |
| 15 ms | 66       | 68         | 69         | 68        | 66        |
| 20 ms | 88       | 93         | 95         | 91        | 90        |
| 25 ms | 103      | 105        | 107        | 101       | 100       |
| 30 ms | 108      | 102        | 105        | 97        | 97        |
| 35 ms | 107      | 91         | 93         | 84        | 86        |
| 40 ms | 98       | 81         | 81         | 75        | 81        |
| 45 ms | 95       | 78         | 77         | 74        | 86        |
| 50 ms | 98       | 83         | 80         | 80        | 90        |
| 55 ms | 98       | 91         | 88         | 86        | 88        |
| 60 ms | 96       | 92         | 93         | 84        | 80        |
| 65 ms | 92       | 84         | 90         | 76        | 77        |
| 70 ms | 90       | 74         | 80         | 67        | 80        |

The root-mean-square difference over the record is 10.1 mm for 32 elements through the
thickness, 9.8 mm for 16, 14.4 mm for 8 and 10.5 mm for 4. **The peak has converged at 105 to
107 mm**, at most 3% below the measurement: 100, 101, 107 and 105 mm from 4 to 32 elements
through. (The 32-element run predates steps 22 to 24 of the
[concrete model](concrete-model.md#how-the-model-got-here), the residual opening kept where a
crack opened, a second crack, and splitting cracks softened over one element, which moved the
others by a millimetre or two at most. The 16-element history in the table predates step 24,
which left its peak at 107 mm and its end at 67 mm.)
The rise to the peak is reproduced within a few millimetres on every mesh. After the peak every
mesh rebounds further than the specimen did (about 30 mm against 13 mm) and settles lower, about
75 mm on the finer meshes against 90 mm. The rebound is set by a hinge at mid-span: once its
crushed compression zone unloads, the section cracks through its depth and the two halves
swing back about the bars. The [concrete model](concrete-model.md#how-the-model-got-here)
gives the evidence.

**Finer still, and the crack model.** The 32-layer run (4.4 million elements of 3.2 mm,
36 minutes) loses 32 elements, cover below a wide flexural crack. A strip of the slab 25 mm
wide bends the same way at a thirtieth of the cost (`blastbench slab --strip 25 --layers
8,16,32`): 105, 113 and 112 mm. The strip cracks square to the lattice, and gives the same
whichever [crack model](concrete-model.md#cracking) is used; the full slab, whose cracks
incline towards its corners and supports, does not. With cracks on the lattice planes, which
mishandle inclined cracks, the full slab gave 101, 105, 112 and 112 mm from 4 to 32 elements
through, with histories within 7 to 10 mm and less rebound. The measurement lies between the
two models' converged peaks.

Getting there took one more change: bars now rupture when their plastic strain averaged over
a debonded length (the crack spacing) passes the rupture strain, not their strain in the one
element a crack runs through. Before that, the 32-layer slab's mid-span crack gathered into a
single column of 3.2 mm elements, whose bars ruptured at a 0.5 mm opening, and it collapsed.

Two errors had to be found before the fine mesh behaved: compressed concrete's sideways
swelling was counted as cracking, and the compressive strain-rate law lost 97% of the
strength above 30 per second. Before they were fixed the 16-layer slab sat on a knife edge
between 110 mm and collapse, decided by a 0.1% change in the load or by round-off. Earlier
figures reported here (108 mm on 8 elements, then 102 mm) came from versions with one or
both errors.

**With shells.** The same slab meshed with [shell elements](shell-model.md) peaks at 124 mm
(115%) on 2, 1 and 0.5 in elements and with 8 to 32 layers through the thickness, so the shells
have converged too, 18% above the solid elements. They rebound about as little as the specimen
did: 94–97 mm at the end of the record against 91 mm measured, with a root-mean-square
difference over the record of 10 mm. A run takes a second or two. The
[shell model](shell-model.md#validation) has the details.

For comparison, the source reports these peaks from other tools on the same slab and load:

| Tool                                                       | Peak            |
|------------------------------------------------------------|-----------------|
| Extreme Loading for Structures (applied element method)    | 107 mm (99%)    |
| RCBlast (single degree of freedom)                         | 117 mm (108%)   |
| SBEDS (single degree of freedom, flexure)                  | 239 mm (221%)   |

### Sensitivity

Eight elements through the thickness, strain-rate laws, one thing changed at a time:

| Change                                       | Peak            | Elements failed |
|----------------------------------------------|-----------------|-----------------|
| None                                         | 101 mm (94%)    | 0               |
| Load 5% lower                                | 88 mm (81%)     | 0               |
| Load 5% higher                               | 115 mm (107%)   | 0               |
| Aggregate 10 mm instead of 16 mm             | 101 mm (93%)    | 0               |
| Crack spacing 50 mm instead of 100 mm        | 98 mm (91%)     | 0               |
| Crack spacing 200 mm                         | 101 mm (94%)    | 0               |
| Fracture energy halved                       | 101 mm (94%)    | 0               |
| Tensile strength 20% lower                   | 103 mm (96%)    | 0               |
| Cracks close fully (no residual opening)     | 101 mm (94%)    | 0               |
| Residual crack opening 30% instead of 10%    | 101 mm (94%)    | 0               |
| Residual crack opening 50%                   | 101 mm (94%)    | 0               |
| Crushing spread over at least 50 mm          | 102 mm (94%)    | 0               |
| Crushing averaged over 48 mm (nonlocal)      | 101 mm (94%)    | 0               |
| Supports as 1 in bearings, held down         | 79 mm (73%)     | 0               |
| Supports as 1 in bearings, free to lift      | 87 mm (81%)     | 0               |
| 16 elements through the thickness            | 107 mm (99%)    | 0               |
| Fixed UFC 3-340-02 factors, no rate laws     | 121 mm (112%)   | 0               |
| Static strengths                             | 143 mm (133%)   | 0               |

Reading this table:

- **The rate treatment matters most.** The load is well above the slab's static capacity, so
  how much stronger steel and concrete are when loaded quickly sets the peak. With static
  strengths the model predicts 143 mm, a third more than was measured (it broke apart until
  splitting cracks were softened over one element; see step 24 of the
  [concrete model](concrete-model.md#how-the-model-got-here)). With the fixed design factors of
  UFC 3-340-02, which are deliberately conservative, it predicts 121 mm, 12% more than was
  measured: conservative, as intended. (Before bar
  rupture was judged over a debonded length, these factors gave a collapse.) The test is
  therefore a sharp check on the rate treatment, and a poor check on anything else.
- **A 5% change in load moves the peak by 13–14%.** The hand-read pressure record could
  easily be 5% out in its shape, though its impulse is pinned.
- **No material assumption tips the slab into failure any more.** Earlier versions sat near a
  shear failure, which one assumption or another (a lower load, smaller aggregate, a wider
  crack spacing, 5% more load) would trigger, never the same one twice. Those failures went
  when the hourglass control was fixed, which suggests they were the zigzag modes, not shear.
- **The concrete's tensile properties barely matter** here, as expected for a slab whose
  resistance comes from its bars.
- **The supports matter by 15–25%.** The default is a pin and a roller on single lines of
  nodes. Bearings one inch wide lower the peak to 79–87 mm. The source does not
  describe the rig; [Data wanted](data-wanted.md) lists it.

### What this does and does not show

It shows that the model reproduces the flexural response of a lightly reinforced one-way slab
under a uniform dynamic load, including the influence of strain rate, to within about 7% at
the peak on meshes of 4 to 32 elements through the thickness, converging at 3% below the
measurement. The rebound after the peak is too large on every mesh.

It does not show that the model predicts shear failure, breach, spalling, fragmentation or
collapse correctly; that walls loaded by the air solver respond correctly (the air solver's
loads have their own error, below); or that a second slab would agree as well. Agreement within
a few per cent on one test with this much sensitivity is partly luck.

The air solver's loads on a wall are close to the reference (next section), so a wall loaded by
the air solver starts from about the right impulse. The combination has still not been compared
with a test.

## A reinforced beam bent to failure

A second structural test, slow and in bending, chosen because it isolates what the slab
leaves mixed with strain rate: whether the concrete and its bars hold together as a beam
yields and deflects to failure.

### The test

One of the conventionally reinforced beams of J. R. Janney, E. Hognestad and D. McHenry,
"Ultimate flexural strength of prestressed and conventionally reinforced concrete beams",
*Journal of the American Concrete Institute* 52(1), 1956, as described and modelled by J. Xu
and Y. Lu, "Numerical modelling for reinforced concrete response to blast load: understanding
the demands on material models", ACI SP-306, 2016, whose figures supply the data used here.

| Property  | Value                                                                       |
|-----------|-----------------------------------------------------------------------------|
| Beam      | 6 × 12 in (152 × 305 mm), 120 in (3,048 mm) long                            |
| Supports  | Simple, 108 in (2,743 mm) apart                                             |
| Load      | Four-point bending: two loads at the third points, 36 in (914 mm) apart      |
| Concrete  | 5,250 psi (36.2 MPa)                                                        |
| Bars      | Three No. 5, 8.3 in (211 mm) below the top (1.87%); no stirrups              |
| Steel     | Yield 48.3 ksi (333 MPa), no hardening reported                             |
| Measured  | Yield near 37 kN m at 11 mm; 41.5 kN m when it failed in flexure at about 42 mm |

The beam has no stirrups, so shear and the bond of its bars are carried by the concrete
alone; Xu and Lu chose it because one widely used concrete model in LS-DYNA, run with its
default settings, has the concrete around the bars give way and the beam fail abruptly at
18 mm. The measured curve was read off their plot by hand.

### The model

`BeamBenchmark.swift`: solid elements 6, 12 or 24 through the depth (51, 25 and 12.7 mm), the
bars smeared through a band one element deep. The supports are a pin and a roller on lines
of nodes at the bottom; the loads are applied through plates 2 in wide on rollers, moved down
at 0.1 m/s, slow against the beam's 16 ms period, with light damping. The moment between the
loads is half the reactions times the shear span. Nothing is fitted: the concrete's other
properties come from the standard correlations, the steel is elastic–perfectly plastic as
reported, and strain rate is off. `blastbench beam` runs it.

### Results

| Case                        | Peak moment         | Fails at  | RMS from the measured curve | Elements removed |
|-----------------------------|---------------------|-----------|-----------------------------|------------------|
| **Measured**                | **41.5 kN m**       | **42 mm** |                             |                  |
| Section analysis, at yield  | 37.9 kN m           |           |                             |                  |
| 24 elements through         | 40.5 kN m (98%)     | holds to 60 mm | 1.3 kN m               | 32 of 69,120     |
| 12 elements through         | 41.0 kN m (99%)     | 57 mm     | 2.3 kN m                    | 30 of 8,640      |
| 12, plates at half the speed | 41.7 kN m (101%)   | holds to 60 mm | 2.3 kN m               | 0 of 8,640       |
| 6 elements through          | 48.5 kN m (117%)    | 45 mm     | 5.2 kN m                    | 18 of 1,080      |

"Fails at" is where the moment first falls below 85% of its peak; the RMS is taken every
millimetre up to 42 mm. (On 12 elements the reaction spikes to 48 kN m for an instant at 41 mm,
as elements go; `blastbench beam` reports that as the peak, and the failure there.)

Mid-span moment against central deflection, in kN m:

| Deflection | Measured | 12 through | 24 through |
|------------|----------|------------|------------|
| 2 mm       | 9.3      | 11.2       | 12.3       |
| 5 mm       | 19.0     | 22.5       | 18.6       |
| 10 mm      | 34.0     | 36.2       | 34.6       |
| 12 mm      | 37.1     | 39.1       | 38.3       |
| 20 mm      | 38.8     | 40.5       | 39.7       |
| 30 mm      | 40.3     | 40.2       | 39.8       |
| 40 mm      | 41.3     | 39.0       | 39.5       |
| 50 mm      | failed   | 40.3       | 39.0       |

The stiffness, yield and plateau are within a few per cent on 12 and 24 elements. The model
does not show the slight hardening of the test (its steel has none), and the failure
deflection, which depends on how the compression zone between the loads crushes, moves with
the mesh and the loading rate: 57 mm on 12 elements, and none by 60 mm on 24 or at half the
speed, against 42 mm measured (38 and 52 mm before crack widths were read over each crack's own
band, below). Six elements through the depth are 17% strong, as expected where the
compression zone (about 40 mm) is thinner than an element (see
[limitation 2](concrete-model.md#limitations)).

**What the test found.** On 24 elements the first version split the beam along its bars at
13 mm and lost a thousand elements: the cracks along the bars, which no bar crosses, were
softened over the 100 mm crack spacing as if bars held them, so each released several
elements' worth of fracture energy too little. They now soften over one element (step 24 of
the [concrete model](concrete-model.md#how-the-model-got-here)), and since step 26 their width,
which sets the shear they carry, is read over it too. This is the same weakness Xu
and Lu found in the LS-DYNA model, in the opposite direction: there the concrete around the
bars lost all its strength too soon; here it lost too little energy in doing so.

### What this does and does not show

It shows that a beam with no stirrups yields and carries its plastic moment through large
deflections in the model, with its concrete and bars holding together, on two meshes, with
nothing fitted. It does not test strain rate, shear failure (the beam failed in flexure), or
anything dynamic, and its failure deflection is not pinned down.

## A beam failing in shear

The third structural test, and the first in which the concrete, not the bars, gives way: a
beam without stirrups that fails suddenly in diagonal tension, the hardest common case for a
smeared-crack model.

### The test

Beam OA1 of F. J. Vecchio and W. Shim, "Experimental and analytical reexamination of classic
concrete beam tests", *Journal of Structural Engineering* 130(3), 2004, their repeat of
Bresler and Scordelis's beam of the same name (1963). The geometry, concrete strength and
measured load against deflection are taken from P. Bernardi, R. Cerioni, E. Michelini and
A. Sirico, "A non-linear procedure for the numerical analysis of crack development in beams
failing in shear", *Frattura ed Integrità Strutturale* 35, 2016, 98–107, which is open access.

| Property  | Value                                                                        |
|-----------|------------------------------------------------------------------------------|
| Beam      | 305 × 552 mm, 4,100 mm long                                                  |
| Supports  | Simple, 3,660 mm apart                                                       |
| Load      | A point load at mid-span                                                     |
| Concrete  | 22.6 MPa                                                                     |
| Bars      | Two M30 64 mm above the bottom, two M25 64 mm above them (2,400 mm²); no stirrups, no top bars |
| Measured  | Diagonal-tension failure at about 332 kN and 9.2 mm, the load falling to 250 kN within 0.2 mm |

The measured curve was read off the source's plot by hand. The bars' properties are not in it:
a 440 MPa yield (from a secondary summary) and 200 GPa are assumed, and matter little, since
the bars stay elastic to the measured failure load (about 315 MPa). The width of the bearing
and loading plates, also not given, is taken as 100 mm.

### The model

`ShearBeamBenchmark.swift`: solid elements 12, 24 or 36 through the depth, each row of bars
smeared through a band one element deep, bearings and a loading plate as lines of nodes a
plate's width along the beam, the plate pushed down at 50 mm/s with light damping. Nothing is
fitted. `blastbench shear` runs it; `--slice 92` models a 92 mm slice of the width, which bends
and cracks the same way, for fine meshes.

### Results

| Case                          | Peak            | At      | Then                                 |
|-------------------------------|-----------------|---------|--------------------------------------|
| **Measured**                  | **332 kN**      | 9.2 mm  | Falls to 250 kN within 0.2 mm         |
| 12 elements through           | 456 kN (137%)   | 10.4 mm | Falls to 120 kN by 11 mm             |
| 24 elements through           | 368 kN (111%)   | 8.8 mm  | Falls to 39 kN by 10 mm              |
| 36 elements through           | 372 kN (112%)   | 8.4 mm  | Falls                                |
| 92 mm slice, 24 / 36 through  | 383 / 354 kN    | 8.9 / 8.2 mm |                                 |

Load against mid-span deflection, in kN:

| Deflection | Measured | 12 through | 24 through |
|------------|----------|------------|------------|
| 1 mm       | 93       | 97         | 90         |
| 2 mm       | 118      | 158        | 136        |
| 4 mm       | 195      | 238        | 215        |
| 6 mm       | 259      | 315        | 287        |
| 8 mm       | 307      | 388        | 353        |
| 9 mm       | 330      | 417        | 319        |

On 24 and 36 elements the beam fails as the test did: suddenly, in shear, with the bars well
below yield (about 350 MPa at the peak), at a load converged about 11–12% above the
measurement and a little earlier. It is 10–15% stiffer than the test after cracking. On 12
elements (46 mm) the diagonal crack cannot form in a narrow enough band, and the beam carries
37% more, nearly to the bars' yield. Neither the crack model nor dowel action explains the
excess: cracks on the lattice planes give 526 kN on 12 elements and cracks fixed at first
cracking 464 kN, and with no dowel action at all the beam carries the same 457 kN, since no
bar but the bottom ones crosses the diagonal crack. The load rate does not matter either
(457 kN at half the speed).

**With shells and beams.** Built from beam elements, the beam carried 470 kN, its bending
strength, and did not fail. Beams now check each section's shear against the simplified
modified compression field theory (see the [shell model](shell-model.md#materials)): the
beam then fails suddenly at 328 and 343 kN with beams of 100 and 50 mm (99% and 103%). Shells
can do the same (298 and 319 kN for a 1 m strip with the same bars per metre), but by default
do not, since under the contest slab's blast the check broke the slab where it held.

### What this does and does not show

It shows that the model can predict a brittle shear failure of a beam without stirrups, at a
load 11–12% high on fine enough meshes, without anything fitted; and that on coarse meshes
(about a twelfth of the depth) it overestimates such a member's shear strength by a third or
more. Solid elements need about 24 through a member's depth to fail it in shear where 8 are
enough for bending. Beams, checked by sections, get within 3% at both sizes tried.
It is one test, statically loaded, of one beam; the strength at blast rates, and members
with stirrups, are not tested.

## Beams struck by a falling weight

The fourth structural test, and the first loaded by an impact: eight beams differing only in
their stirrups, each struck at mid-span by a weight falling 3.26 m. It tests the response
over milliseconds, where the beam's own inertia carries much of the load, and whether a beam
that needs its stirrups to survive breaks without them.

### The test

S. Saatci, *Behaviour and modelling of reinforced concrete structures subjected to impact
loads*, PhD thesis, University of Toronto, 2007, open access (published with F. J. Vecchio in
the *ACI Structural Journal* 106(5), 2009). Only the first impact on each beam is used: later
ones struck a beam already damaged.

| Property  | Value                                                                        |
|-----------|------------------------------------------------------------------------------|
| Beams     | 250 × 410 mm, 4,880 mm long                                                  |
| Supports  | 3,000 mm apart: rollers below, and hinges above held down by pre-tensioned bars, so the beam can rotate and slide but not lift |
| Bars      | Two No. 30 (700 mm² each) top and bottom, 38 mm cover; 464 MPa yield, 630 MPa ultimate |
| Stirrups  | Closed D-6 wire (38.7 mm², 605 MPa): none (SS0), at 300 mm (SS1), 200 mm (SS2) or 100 mm (SS3) |
| Concrete  | 44.7–50.1 MPa at the time of the tests; 10 mm aggregate                      |
| Impact    | 211 kg (a-series) or 600 kg (b-series) at 8.0 m/s, onto a 50 mm steel plate 300 mm square |

| Test   | Weight | Measured peak / residual | Largest reaction at a support | Observed                    |
|--------|--------|--------------------------|-------------------------------|-----------------------------|
| SS0a-1 | 211 kg | 9.3 / 1.6 mm             | 305 kN                        | Diagonal cracks up to 0.5 mm |
| SS1a-1 | 211 kg | 12.1 / 0.9 mm            | 356 kN                        |                             |
| SS2a-1 | 211 kg | 10.0 / 0.5 mm            | 327 kN                        |                             |
| SS0b-1 | 600 kg | Failed                   | 399 kN                        | A shear plug punched through under the plate |
| SS1b-1 | 600 kg | 39.5 / 17.7 mm           | 625 kN                        |                             |
| SS2b-1 | 600 kg | 37.9 / 18.5 mm           | 592 kN                        |                             |
| SS3b-1 | 600 kg | 35.3 / 17.7 mm           | 682 kN                        |                             |

The thesis gives everything the model needs except the bearing plates' length, taken as
100 mm. Its own static analyses put the beams' strengths at 120 kN (SS0, shear), 159 kN (SS1,
shear) and 178–184 kN (SS2, SS3, bending), as reactions: every impact loaded the beams to two
to four times their static strength.

### The model

`ImpactBenchmark.swift`: solid elements 12, 16 or 24 through the depth, the plate as steel
elements, each pair of bars smeared through a band one element deep and the stirrups smeared
through the beam. The weight is added to the plate's top nodes, which start down at the speed
that conserves momentum with them (7.5–7.7 m/s for 211 kg, depending on how much of the
plate they carry); it leaves the plate once the plate turns back up, as the real one bounced
off (until it did, the 300 kg of Ando's tests below pulled the concrete under the plate off on
the rebound). The bearings are 100 mm of the bottom face, which may lift off, and 100 mm of
the top face, which may fall away but not rise: hung from its bottom face by a two-way
restraint, the concrete under the supports tore away on the rebound. Gravity is on and the
strain-rate laws are used; nothing is fitted. The residual is the mean of the last 30 ms of a
200 ms record, during which the beam is still swinging by a few millimetres; the reaction is averaged over 0.5 ms, about what the load cells, read 2,400 times
a second, would see.

`blastbench impact` runs it; `--beams 0.1` meshes the beam with beam elements of that size
instead, the stirrups as their ties.

### Results

Peak / residual mid-span displacement in mm, and elements failed, with the default tensile
strain-rate law (the fib Model Code 2010's) and, for comparison, Malvar and Ross's:

| Test   | Measured     | 16 through        | 24 through          | 16, Malvar–Ross    | 24, Malvar–Ross    |
|--------|--------------|-------------------|---------------------|--------------------|--------------------|
| SS0a-1 | 9.3 / 1.6    | 16.8 / 2.2 (279)  | 19.7 / 6.4, split along its bars (1,935) | 10.2 / 0.7 | 9.3 / 0.5   |
| SS1a-1 | 12.1 / 0.9   | 13.1 / 1.2        | 13.6 / 2.5          | 9.7 / 0.4          | 9.5 / 0.4          |
| SS2a-1 | 10.0 / 0.5   | 12.1 / 1.1        | 12.3 / 1.3          | 9.5 / 0.4          | 9.4 / 0.4          |
| SS0b-1 | Failed       | Broken (1,963)    | Broken (5,010)      | Broken (1,215)     | Broken (3,231)     |
| SS1b-1 | 39.5 / 17.7  | 37.5 / 12.9       | 45.5 / 29.9         | 28.7 / 2.9         | 29.2 / 6.2         |
| SS2b-1 | 37.9 / 18.5  | 35.7 / 14.6       | 40.3 / 25.5         | 27.9 / 5.6         | 28.5 / 6.1         |
| SS3b-1 | 35.3 / 17.7  | 31.5 / 11.6       | 33.6 / 14.2         | 26.8 / 7.2         | 27.1 / 5.6         |

(Elements removed or left as bare bars in brackets. The Malvar–Ross columns predate cracks that
slide for good, the weight's bounce and crack widths read over each crack's own band, which
leave the peaks within a few per cent and raise the residuals.)

With the default law the beams with stirrups come within 15% of the measured peaks under the
light drops and within −5% to +15% under the heavy ones on 24 elements, and survive both; the
beam without stirrups is broken by the heavy drop along diagonal cracks running from the plate
towards the supports, as the test beam was. Their residuals are 14–30 mm on 24 elements against 18 mm measured (6–7 mm before cracks slid
for good and rode up on their aggregate; see the
[concrete model](concrete-model.md#shear-across-cracks)). The largest reactions at a support are 350–650 kN under the heavy drops the
beams survive, against 592–682 kN measured, and 400–450 kN under the light ones, against
305–356 kN.

Under the light drop the beam without stirrups comes through on 16 elements, 16.8 mm down at
its peak against 9.3 mm and left 2.2 mm down against 1.6, but with 279 elements removed under
the plate and where its diagonal cracks cross the bottom bars; on 24 it splits along its length
just above the bottom bars, though it is left only 6.4 mm down. The test beam survived with
diagonal cracks up to 0.5 mm. The peak comes within 5 ms, before any element goes; they go as
the beam swings after it. Until each crack's width was read over the length its own opening
is smeared over (see the [concrete model](concrete-model.md#cracking)), it broke on every mesh,
22.4 / 8.2 mm with 793 elements removed on 16 and 31.5 / 16.4 mm with 3,005 on 24: a split
along the bars, which no bar crosses and which gathers in one row of elements, was taken to be
as wide as its opening over the 100 mm crack spacing, four to six times too wide, and held by
that much less interlock. The beams with stirrups, whose stirrups cross such a split, did not
change.

**With bars that slip** (`--bond splitting`; see the
[concrete model](concrete-model.md#bars-that-slip-an-option)) the split goes. SS0a-1 survives
the light drop on both meshes with nothing removed, 12.0 / 2.5 mm on 16 elements and 11.0 /
1.7 mm on 24, and SS0b-1 still breaks under the heavy one (886 and 1,111 elements removed).
Perfectly bonded, the bars hand their changes of force to the row of concrete just above them,
which is where the beam splits. But slip stiffens the beams with stirrups: the light drops
11.0 and 10.6 mm (SS1a-1 and SS2a-1, against 12.1 and 10.0), the heavy ones 30–32 mm against
35–40, and left 9–11 mm down against 18, on 16 elements; and the reactions rise to 560–700 kN.
With the contest slab at 82% and OA1 at 142–147% with slip, it stays an option.

How much aggregate interlock strengthens with strain rate, which the model takes to be as much
as the tensile strength, remains open: with interlock doubled, about what Malvar and Ross's
factor gave it at these rates, SS0a-1 survived even before the crack widths were corrected.

**Beams without stirrups at increasing speeds.** T. Ando, N. Kishi, H. Mikami and K. G.
Matsuoka, "Weight falling impact tests on shear-failure type RC beams without stirrups",
*Structures under Shock and Impact VI*, WIT Press, 2000 (open access), with the fuller
Japanese paper, *Structural Engineering* 46A (2000) 1809–1818 (Muroran Institute of
Technology's repository), struck 27 beams of 150 × 250 mm without stirrups once each with
300 kg, at 1 m/s and then from 2 or 3 m/s up in steps of 1 m/s until they broke: two bottom
bars 40 mm up (2 D19 in series A, 2 D13 in B), spans of 1.0, 1.5 and 2.0 m (shear spans of
2.4, 3.6 and 4.8 depths), clamped top and bottom 200 mm in from each end in a jig the paper
describes as letting them turn and nothing else. The materials are as measured: 33 MPa concrete
of modulus 23.3 GPa, D19 bars yielding at 385 MPa and D13 at 400. `blastbench impact --ando`
runs the nineteen tests whose peak or residual displacement the papers give: the 1.5 m beams'
displacement histories, and the loops of load against displacement for the 1.0 m beams with
D19 bars and the 2.0 m beams with D13, whose ends give the peak and where they come back to no
load the residual, read to about 2 mm. Assumed: the weight's face as a 100 mm steel plate, the
clamps as 50 mm of each face held, 20 mm aggregate. The weight leaves the plate once the plate
turns back up, as a real one does; left on, it pulled the concrete under the plate off on the
rebound.

| Test | Speed | Measured (peak / residual) | 16 through | 24 through |
|------|-------|----------------------------|------------|------------|
| A24 | 1 m/s | 2 / 0 | 1.4 / −0.5 | 1.5 / −1.2 |
| A24 | 3 m/s | 11 / 8 | 11.7 / 7.1 (117) | 13.5 / 8.6 (446) |
| A24 | 4 m/s | 16 / 11 | 22.1 / 13.1 (412) | 21.2 / 16.4 (1,473) |
| A24 | 5 m/s | 29 / 25, broken | 28.5 / 16.6 (484) | 65.6 / 19.8 (3,547) |
| A24 | 6 m/s | 54 / 48, broken | 67.2 / 43.1 (1,269) | 127.6 / 79.0 (4,966) |
| A36 | 1 m/s | 1.5 / 0, flexural cracks only | 2.2 / −0.8 | 2.5 / −1.9 |
| A36 | 3 m/s | 13.5 / 9.5, a severe diagonal crack | 12.6 / 7.8 (33) | 13.6 / 7.3 (481) |
| A36 | 4 m/s | 28 / 24 | 23.7 / 11.0 (368) | 54.6 / 23.3 (2,479) |
| A36 | 5 m/s | 66 / 53, split into three | 49.5 / 31.1, broken (671) | 70.8 / 31.7, broken (2,657) |
| A48 | 4 m/s | – / 10.7, bent | 25.8 / 12.3 (401) | 48.7 / 23.1 (2,356) |
| B36 | 1 m/s | 2.7 / 0, flexural cracks only | 2.6 / −0.5 | 3.1 / −2.3 |
| B36 | 3 m/s | 16 / 11.4 | 14.6 / 3.7 | 15.5 / 1.0 |
| B36 | 4 m/s | 26 / 22.6, bent | 24.5 / 12.3 (11) | 27.5 / 11.3 (89) |
| B36 | 5 m/s | 105 / 88, broken by a diagonal crack | 50.1 / 31.3 (197) | 54.7 / 28.8 (621) |
| B48 | 1 m/s | 4 / 0 | 3.9 / −0.8 | 4.4 / −1.5 |
| B48 | 3 m/s | 21 / 19, bent | 18.1 / 8.7 (180) | 21.0 / 7.9 (458) |
| B48 | 4 m/s | 36 / 30 | 32.5 / 11.9 (16) | 36.6 / 8.4 (512) |
| B48 | 5 m/s | 55 / 47 | 60.2 / 35.4 (208) | 63.9 / 44.5 (1,416) |
| B48 | 6 m/s | 73 / 70 | 96.9 / 75.2 (321) | 305 / 297 (3,165) |

(Peak / residual mid-span displacement in mm; elements removed or left as bare bars in
brackets.) Up to 3 m/s the peaks are within 15% on 16 elements, with the diagonal cracking the
tests show. Faster, on 16 elements the peaks are within 18% of the tests' on average over the
fourteen from 3 m/s up, from 38% too far (A24 at 4 m/s) to half as far (B36 at 5 m/s, which
broke in the test); before each crack's width was read over its own band (see the
[concrete model](concrete-model.md#cracking)), they went 44% too far on average, the 2.0 m
beams two to three times. But the beams now spring back to about half the residual measured
(B36 at 4 m/s is left 12 mm down against 22.6, B48 at 4 m/s 12 against 30). On 24 elements
they go further, 58% too far on average (108% before), and some far further: A24 at 5 and
6 m/s, A36 at 4 m/s and B48 at 6 m/s two to four times. A36 breaks at 5 m/s as its test beam
did, cut through by removed elements beside the plate and at a support; B36, which its test
beam also broke at 5 m/s, bends but holds.

**Bars spread through the concrete about them** (`blastbench impact --spread`). Smeared, each
bar's steel sits in the one row of elements at its height, so the row that carries it, and the
row of plain concrete above that splits, thin as the mesh is refined. Spread instead from the
bar's nearest face to as far the other side (106 mm for Saatci's bars, 80 mm for Ando's, much
as Eurocode 2's effective tension area), the steel no longer depends on the mesh, and nor do
the beams: over the fourteen faster tests the peaks are 24% off on 16 elements and 25% on 24,
where they were 18% and 58%, and Saatci's beams with stirrups come within 3–8% on 24
elements. But the beams are too stiff: Ando's go 24% short on average (A24 at 6 m/s 28 mm
against 54), Saatci's heavy drops 13–18% short on 16 elements, and they spring back too far,
keeping a third of the deflection the tests kept (two thirds with the bars in one row, on 16
elements). SS0a-1 still loses 430–890 elements, now along the top of the spread steel. So the
one-row bars' agreement on 16 elements owes something to the split along the bars, which
softens a beam and holds its deflection; without it the beams spring back. Either way the
shear such a beam carries across its cracks, and what keeps a struck beam bent, are not yet
right, and the spread is not the default.

How the jig held the beams decides much of this. Held as pins at both ends (the paper's "turning
and nothing else"), the 1.0 m beams came within 15% at every speed and B36 broke at 5 m/s, but
the 2.0 m beams went twice as far; on steel plates turning freely about their centres, every
beam went two to five times too far. The paper's static tests carried more than a simply
supported beam would (68 kN against about 53 for B36), so the jig restrained the beams'
ends; how much, it does not say. Averaged over the fourteen peaks it reports, the clamps were
50% off and the pins 59% before crack widths were read over each crack's own band; the clamps
are now 18% off, and the pins and plates have not been run again. (Before the measured
material properties were used, the usual correlations made the model somewhat stiffer.)

**The tensile strain-rate law decides it.** Turning the laws off one at a time on SS2b-1 (16
through) shows that the concrete's tensile law is the one that matters. Under Malvar and Ross's
law (1998), which raises the tensile strength 2.7 times at the 7.3 per second the bars' gauges
recorded, the beams with stirrups are a quarter too stiff on every mesh, and the beam without
stirrups survives the light drop. The fib Model Code 2010's law, the same for every strength
and much milder above 1 per second (1.3 at 5 per second), brings the beams with stirrups within
the scatter, and is the default; Malvar and Ross's remains as `tensionRateLaw = .malvarRoss`.
Without any rate laws (16 through) the heavy drops peak at 35–43 mm and SS0a-1 breaks. The
factor, frozen as each element cracks, raises aggregate interlock across the crack with the
strength, and so the shear a beam without stirrups can carry; that is what Malvar and Ross's
steeper law buys SS0a-1. Three other changes made no difference: taking the tensile rate from
the largest principal stretching rather than the effective rate, keeping the fracture energy
fixed as the strength rises, and leaving interlock without the factor (which broke SS0a-1).
These comparisons were made before crack widths were read over each crack's own band.

**With beam elements.** Without the sectional shear check, beam elements give 12.7 mm for all
the light drops and about 38 mm for the heavy ones (36.7 / 17.2 mm for SS2b-1 with 50 mm
beams, against 37.9 / 18.5 mm), close to the measurements, but cannot tell the beam without
stirrups from the others: SS0b-1 survives. With the check, every beam fails within half a
millisecond under every drop: the impact's shear passes the beams beside the plate at two to
four times their static strength, and the check, averaged over 0.66 ms (four crossings of the
depth by a shear wave), takes it for a failure of the section. Averaging over four times as
long still broke all the heavy drops, the beams with stirrups too; ten times as long broke
none, SS0b-1 included. The static strengths of SS0 and SS1 differ by 30%, while the demand
is two to four times either: a check of each section's shear strength cannot tell which beam
the stirrups save, which is a matter of whether they hold a shear plug in.

### What this does and does not show

It shows that solid elements predict the response of beams with stirrups to an impact within
the scatter of the tests, light and heavy, with nothing fitted, once the tensile strength rises
with strain rate as the fib Model Code 2010 has it. It also shows that the result depends most
on that law, which is uncertain at these rates: under Malvar and Ross's steeper law the beams
were a quarter too stiff, and under the Model Code's the beam without stirrups is too weak in
shear, broken by a drop it survived. One beam geometry, one drop height, and only first
impacts.

Beam elements with the sectional shear check are not usable under impacts: the check is
static and breaks every beam. They are usable without it, for bending, where they come within
a few per cent of the heavy drops.

## Slabs under close-in charges

The fifth structural test, and the first in the open air with the air solver loading the
structure: full-scale slabs under charges hung 0.5 m and 1 m above them, where the concrete
spalls and is punched through.

### The test

M. Chiquito, L. M. López, R. Castedo, A. P. Santos and A. Pérez-Caldentey, "Full-scale field
tests on concrete slabs subjected to close-in blast loads", *Buildings* 13, 2068 (2023), with
the second campaign's damage on each face from S. Martínez-Almajano et al., *International
Journal of Computational Methods and Experimental Measurements* 9(3), 201–212 (2021). Both are
open access. Only the slabs without added protection are used.

| Property  | Value                                                                        |
|-----------|------------------------------------------------------------------------------|
| Slabs     | 4.40 × 1.46 × 0.15 m, C25/30 (25 MPa, 20 mm aggregate), 2,300 kg/m³          |
| Bars      | B500; first campaign (S) 12 mm at 150 mm both faces both ways; second (P) 10 mm at 300 mm towards the charge, 12 mm at 150 mm away from it; about 30 mm cover |
| Supports  | Laid across concrete blocks 0.9 m high, clamped by steel bars bolted through the slab 0.2 m from each end, 4.00 m apart |
| Charges   | PG2 (S) or dynamite (P), given as TNT equivalents, hung above the slab's centre |
| Gauges    | Flush in the tops of blocks beside the slab, level with its top face, 1 m and 2 m from its centre |

| Test  | Charge   | Height | Measured                                                       |
|-------|----------|--------|----------------------------------------------------------------|
| S1–S3 | 2 kg     | 1 m    | Minor cracks; 2.5 MPa at 1 m and 0.5 MPa at 2 m (text), peaks of 3.3–3.6 and 0.47–0.58 MPa (its Figure 9) |
| P1    | 1.74 kg  | 1 m    | Minor cracks; 2.01 MPa at 1 m                                   |
| P7    | 13.05 kg | 1 m    | Bent at mid-span, left 340 mm down; spalled 3.4% of the top face, 10.3% of the bottom |
| S4    | 15 kg    | 1 m    | Bent; 3% of the face damaged                                    |
| P2    | 13.05 kg | 0.5 m  | Punched through under the charge, the bars left across the hole; 510 mm down; spalled 8.2% and 18.6% |
| S5    | 15 kg    | 0.5 m  | Punched through; 7% damaged                                     |

Assumed: the bars rupture at 15% (B500 must stretch 7.5% at its peak stress and breaks well
after it; at 10% P2's mid-span bars broke on every mesh); the height is to the charge's centre
(the charges were spheres and rounded cubes);
the clamps are hinges that hold the slab down, and lengthwise at mid-depth, on the bolt lines,
its ends resting on the blocks behind them; the gauges' blocks are 0.55 m long, read off a
figure. The concrete's strength is the class's minimum, as the papers give it.

### The model

`CloseInSlabTest.swift`: air cells of 50 mm over the whole set-up (6.8 × 6.45 × 3 m, the
ground reflecting), the blocks rigid, the charge started from the one-dimensional solution
(see the [air-blast model](air-blast-model.md)), and the slab of solid elements 6, 8 or 12
through its thickness, its two mats smeared through bands, run for 300 ms with gravity. The
spalled area is the fraction of each face whose surface element has been removed or cracked
open past the width at which an unreinforced one would be. `blastbench closein` runs it.

### Results

**The load.** Kingery and Bulmash's curves are for a surface burst; for a burst in the air
they are used with the charge's mass divided by 1.8.

| Quantity, 2 kg at 1 m              | Reference                     | 50 mm cells | 25 mm cells |
|------------------------------------|-------------------------------|-------------|-------------|
| Gauge 1 m from the centre          | 2.5 MPa (text), 3.3–3.6 (figure) | 1.48 MPa | 1.98 MPa    |
| Gauge 2 m from the centre          | 0.5 MPa, 0.47–0.58            | 0.36 MPa    | 0.41 MPa    |
| In the open, as far as the 1 m gauge | 0.68 MPa (K–B)              | 0.48 MPa    | 0.58 MPa    |
| Impulse under the charge           | 961 Pa s (K–B, reflected)     | 819 Pa s    | 886 Pa s    |

Under the 13 kg charges the impulse under the charge is 78% of Kingery and Bulmash's on 50 mm
cells and 84–95% on 25 mm cells or 50 mm refined by 2 (3.7 kPa s against 4.4 at 1 m, 12.4
against 13.1 at 0.5 m), as [close in](#close-in) above. The slab's momentum after 5 ms, about
the impulse it received, is 8.4–8.7 kN s at 1 m and 10.9–11.4 kN s at 0.5 m, changing by under
5% between those grids: the load has converged. Afterburning changes it by under 3%. The gauges
read 75–80% of the text's values, as reflected peaks do on these cells.

**The slab.** Permanent mid-span deflection (mm), peak in brackets, read as the median across
the slab's width of its mid-depth nodes at mid-span, which a spall or crater under the charge
leaves out:

| Test  | Measured   | 6 through, 50 mm air | 8 through, 50 mm air | 6 through, 25 mm air refined by 2 |
|-------|------------|----------------------|----------------------|-----------------------------------|
| P1    | 0          | 3 (12)               |                      |                                   |
| S1–S3 | cracks     | 3 (14)               |                      |                                   |
| P7    | 340        | 100 (156)            | 79 (206)             | 128 (164)                         |
| S5    | punched through | 193 (252), whole | broken at mid-span, 789 (819) | 236 (283), spalled 3.5% under the charge, no hole |
| P2    | 510, punched through, hanging | 198 (250), whole | broken at mid-span, fell | 195 (278), spalled 1.9% under the charge, no hole |

(The 8-element and fine-air columns predate cracks that slide for good, which moved the 6-element
column by 7–17 mm.)

With Malvar and Ross's tensile law instead, P7 was left 51, 103 and 91 mm down on the three
grids, and P2 and S5 156–173 mm, spalling 1% of the far face on the fine air.

No light shot damages the slab, as in the tests. At 1 m the slab bends at mid-span, as the
test's did, but goes a third as far, and neither face spalls (the test's spalled 3.4% and
10.3%). At 0.5 m the model punches no hole under the charge on any mesh. On 8 elements through
the slab its mid-span hinge breaks, the bars ruptured, and it falls or nearly; on 6 it holds.
Only on air fine enough for the peak (110–119 MPa under the charge, against 124 MPa from the
curves) does a spall form: the reflected wave breaks a layer off the far face under the charge,
which flies off at about 28 m/s while the slab's middle slows to 9; but over 2–4% of the far
face, against 19%, and without a hole through. Under Malvar and Ross's tensile law the spall
had to overcome 17–21 MPa (its factor of 6.5–8 at 50–100 per second, frozen as each element
cracks), against the 10–15 MPa that spalling tests of such concrete find, from memory; and
until the fracture energy was made to grow more slowly than the strength (see the
[concrete model](concrete-model.md#strain-rate-effects)), the layer, held on by eight times the
static fracture energy, never flew at all. With the bars taken to rupture at 10%, P2's mid-span
hinge tore through on every mesh; and before bare bars (see the
[concrete model](concrete-model.md#removal)), concrete removed took its smeared bars with it,
so that a slab holed through would have fallen apart in any case.

**What moves P7** (6 through; permanent, peak):

| Change                                  | mm         |
|-----------------------------------------|------------|
| As above, with Malvar and Ross's tensile law (before the deflection was read at mid-depth) | 54 (140) |
| Without the strain-rate laws            | 120 (173)  |
| The ends free to slide lengthwise       | 92 (155)   |
| Both                                    | 128 (228)  |
| The charge 1.5 times heavier            | 147 (214)  |

A rigid-plastic estimate (two halves turning about the supports, a hinge of 54 kN m) with the
model's own impulse reaches about 260 mm, near the 228 mm the model gives without rate laws or
end restraint. With the load within about a tenth, the shortfall is the slab's: stiffened by
the rate laws and by arching against held ends, and springing back from its peak too far, here
as in the other slab and the chamber.

### What this does and does not show

It shows that the coupled model loads a slab close to a charge within about a tenth of the
empirical impulse and leaves it undamaged where the tests did. It does not reproduce close-in
damage: the slab is left a third as far down as the test's, spalls a fraction as much, is not
punched through under the charge, and, broken, falls where the test's hung on its bars. These
point at the breach under the charge, which needs the spall and the crushing above it to meet,
and at the slab's stiffness in bending; and they need the air fine enough to resolve the peak
under the charge. The supports' lengthwise restraint and the charges' shapes
are assumptions that matter.

## Blast loads against empirical references

`blastbench validate` puts a 100 kg charge on rigid ground and compares the air solver with two
references.

### Kingery–Bulmash, the design-practice standard

Kingery and Bulmash fitted polynomials to a large body of test data for a hemispherical surface
burst of TNT; they underlie ConWep and UFC 3-340-02. The curves used here are Swisdak's
simplified form of them (1994), which the test suite checks against five rows of Swisdak's own
table (within 1%) and against the three independent worked examples of the United Nations'
*International Ammunition Technical Guidelines*, IATG 01.80 (within 6%). The comparison runs
from 0.75 to 6 m/kg^(1/3), which for 100 kg is 3.5 m to 28 m.

Incident (side-on) wave over open ground:

| Range  | Z    | Reference peak | 0.5 m cells | 0.25 m cells | 0.125 m cells |
|--------|------|----------------|-------------|--------------|---------------|
| 3.5 m  | 0.75 | 2,411 kPa      | 59%         | 77%          | 97%           |
| 4.6 m  | 1    | 1,354 kPa      | 57%         | 77%          | 94%           |
| 7.0 m  | 1.5  | 551 kPa        | 66%         | 82%          | 94%           |
| 9.3 m  | 2    | 284 kPa        | 62%         | 76%          | 86%           |
| 13.9 m | 3    | 116 kPa        | 67%         | 80%          | 87%           |
| 18.6 m | 4    | 65 kPa         | 66%         | 79%          | 89%           |
| 23.2 m | 5    | 43 kPa         | 68%         | 81%          | 90%           |
| 27.8 m | 6    | 32 kPa         | 69%         | 80%          | 90%           |

| Range  | Reference impulse | 0.5 m cells | 0.25 m cells | 0.125 m cells |
|--------|-------------------|-------------|--------------|---------------|
| 3.5 m  | 890 Pa·s          | 116%        | 103%         | 106%          |
| 4.6 m  | 1,097 Pa·s        | 82%         | 80%          | 84%           |
| 7.0 m  | 824 Pa·s          | 81%         | 78%          | 78%           |
| 9.3 m  | 625 Pa·s          | 81%         | 80%          | 80%           |
| 13.9 m | 430 Pa·s          | 86%         | 86%          | 86%           |
| 18.6 m | 336 Pa·s          | 84%         | 86%          | 87%           |
| 23.2 m | 275 Pa·s          | 85%         | 86%          | 86%           |
| 27.8 m | 233 Pa·s          | 85%         | 85%          | 86%           |

| Range  | Reference arrival | 0.5 m cells | 0.25 m cells | 0.125 m cells |
|--------|-------------------|-------------|--------------|---------------|
| 3.5 m  | 1.3 ms            | 81%         | 94%          | 95%           |
| 4.6 m  | 2.2 ms            | 98%         | 92%          | 93%           |
| 7.0 m  | 4.6 ms            | 87%         | 90%          | 90%           |
| 9.3 m  | 7.9 ms            | 90%         | 94%          | 93%           |
| 13.9 m | 16.5 ms           | 92%         | 95%          | 96%           |
| 18.6 m | 26.9 ms           | 98%         | 97%          | 97%           |
| 23.2 m | 38.3 ms           | 97%         | 97%          | 98%           |
| 27.8 m | 50.2 ms           | 97%         | 98%          | 98%           |

On a rigid wall facing the charge (the far face of the domain is made reflecting, with the
charge at each stand-off in turn):

| Stand-off | Reference peak | 0.5 m cells | 0.25 m cells | 0.125 m cells |
|-----------|----------------|-------------|--------------|---------------|
| 3.5 m     | 16,763 kPa     | 20%         | 37%          | 67%           |
| 4.6 m     | 8,152 kPa      | 25%         | 44%          | 68%           |
| 7.0 m     | 2,511 kPa      | 35%         | 58%          | 83%           |
| 9.3 m     | 1,058 kPa      | 45%         | 65%          | 83%           |
| 13.9 m    | 331 kPa        | 57%         | 76%          | 88%           |
| 18.6 m    | 163 kPa        | 63%         | 80%          | 91%           |
| 23.2 m    | 101 kPa        | 68%         | 80%          | 92%           |
| 27.8 m    | 71 kPa         | 69%         | 82%          | 91%           |

| Stand-off | Reference impulse | 0.5 m cells | 0.25 m cells | 0.125 m cells |
|-----------|-------------------|-------------|--------------|---------------|
| 3.5 m     | 6,102 Pa·s        | 73%         | 84%          | 96%           |
| 4.6 m     | 4,107 Pa·s        | 77%         | 91%          | 102%          |
| 7.0 m     | 2,417 Pa·s        | 88%         | 97%          | 102%          |
| 9.3 m     | 1,689 Pa·s        | 95%         | 101%         | 105%          |
| 13.9 m    | 1,041 Pa·s        | 99%         | 102%         | 104%          |
| 18.6 m    | 748 Pa·s          | 94%         | 97%          | 98%           |
| 23.2 m    | 583 Pa·s          | 94%         | 94%          | 95%           |
| 27.8 m    | 477 Pa·s          | 93%         | 94%          | 94%           |

Reading these:

- **Reflected impulse, the load a wall actually feels, is within 6%** from 1.5 m/kg^(1/3)
  outwards on cells of 0.25 m or finer, and within 5% everywhere on 0.125 m cells. Closer in it
  needs finer cells: at 0.75 m/kg^(1/3) it is 84% on 0.25 m cells. This is the quantity that
  governs the response of most structures.
- **Peak pressures read low** because a captured shock is smeared over two or three cells. They
  improve steadily with resolution and are worst close in, where the reflected peak is a third
  low even on 0.125 m cells.
- **Incident impulse is 13% to 22% low** from 1 m/kg^(1/3) outwards, on every grid, so the
  shortfall is in the source model, not the resolution. The likeliest cause is the missing
  afterburning of the detonation products, which adds energy behind the shock (see the
  [air-blast model](air-blast-model.md#limitations)). It matters for objects the wave passes
  over, less for surfaces it strikes.
- **Arrival times are 2% to 10% early.**

`blastbench validate` prints these tables; `--z` chooses other scaled distances.

### With refinement

With the air [refined near the shock](air-blast-model.md#refining-near-the-shock) by 2
(`--refine 2`), each grid gives about the peaks and impulses of the uniform grid twice as fine:

| Range  | Incident peak: 0.5 m refined | 0.25 m | 0.25 m refined | 0.125 m | Reflected peak: 0.5 m refined | 0.25 m | 0.25 m refined | 0.125 m |
|--------|------|------|------|------|------|------|------|------|
| 3.5 m | 77% | 77% | 97% | 97% | 38% | 37% | 67% | 67% |
| 4.6 m | 77% | 77% | 93% | 94% | 43% | 44% | 68% | 68% |
| 7.0 m | 81% | 82% | 93% | 94% | 57% | 58% | 82% | 83% |
| 9.3 m | 76% | 76% | 86% | 86% | 65% | 65% | 83% | 83% |
| 13.9 m | 80% | 80% | 87% | 87% | 76% | 76% | 88% | 88% |
| 18.6 m | 79% | 79% | 89% | 89% | 80% | 80% | 91% | 91% |
| 23.2 m | 81% | 81% | 90% | 90% | 77% | 80% | 88% | 92% |
| 27.8 m | 80% | 80% | 90% | 90% | 79% | 82% | 88% | 91% |

| Stand-off | Reflected impulse: 0.5 m refined | 0.25 m | 0.25 m refined | 0.125 m |
|-----------|------|------|------|------|
| 3.5 m | 85% | 84% | 96% | 96% |
| 4.6 m | 91% | 91% | 103% | 102% |
| 7.0 m | 97% | 97% | 102% | 102% |
| 9.3 m | 101% | 101% | 104% | 105% |
| 13.9 m | 102% | 102% | 104% | 104% |
| 18.6 m | 97% | 97% | 98% | 98% |
| 23.2 m | 95% | 94% | 95% | 95% |
| 27.8 m | 95% | 94% | 94% | 94% |

Arrival times are as on the coarse grid, within 2%; the incident impulse is within 3% of the
coarse grid's from 7 m out and up to 6% higher closer in. `blastbench validate` takes 13 s on
0.5 m cells refined against 21 s on 0.25 m cells, and 104 s on 0.25 m cells refined against
about 290 s on 0.125 m cells. Refined by 4, 0.5 m cells give the 0.125 m grid's peaks and
impulses, within 5% (incident peaks 85% to 97%, reflected 66% to 93%), in 116 s, about as long
as 0.25 m cells refined by 2.
The charge is laid on the fine cells (see the
[air-blast model](air-blast-model.md#refining-near-the-shock)); laid on the coarse ones, its
blocky sphere ran the peaks close to the charge up to 30% above those of the finer grid.

### Close in

Below 0.75 m/kg^(1/3) the curves come from few tests and their incident impulse does not even
fall steadily with distance; their reflected values are the better check, and are what loads a
structure. `blastbench closeair` bursts 1 kg in the air at each scaled distance above rigid
ground and records the reflection square on below it, against the surface-burst curves at the
mass divided by 1.8, which stands for a burst in the air:

| Z (free air) | Reference peak | 40 mm | 20 mm | 10 mm | Reference impulse | 40 mm | 20 mm | 10 mm |
|--------------|----------------|-------|-------|-------|-------------------|-------|-------|-------|
| 0.3          | 70.0 MPa       | 25%   | 45%   | 78%   | 3,168 Pa s        | 65%   | 79%   | 93%   |
| 0.5          | 26.6 MPa       | 30%   | 62%   | 83%   | 1,459 Pa s        | 75%   | 86%   | 98%   |
| 0.75         | 10.4 MPa       | 40%   | 66%   | 98%   | 824 Pa s          | 83%   | 93%   | 106%  |
| 1            | 4.7 MPa        | 49%   | 72%   | 91%   | 561 Pa s          | 89%   | 94%   | 92%   |

The impulse converges to the curves' within 8% as the cells shrink, from 0.3 m/kg^(1/3) out,
with the charge started as a ball of hot air: the detonation products' own equation of state
(JWL), which differs from air's only while they are dense, is not needed for the load. Cells of
about a hundredth of the charge's cube root are needed close in; refined by 2, cells twice
that size give the same answers to within 1%. The gauge must be in the cell against the
surface: close in, much of the load arrives as momentum, which becomes pressure only where the
gas is brought to rest, so that two cells out the record is a third of the surface's.

### Afterburning

With [afterburning](air-blast-model.md#afterburning) on (`--afterburn`), and with it and
[hot air](air-blast-model.md#hot-air) together (`--afterburn --air thermal`), on 0.25 m cells:

| Range  | Z    | Incident peak | Incident impulse | Reflected impulse | With hot air: incident peak | incident impulse | reflected impulse |
|--------|------|---------------|------------------|-------------------|------|------|------|
| 3.5 m  | 0.75 | 78%           | 122%             | 90%               | 72%  | 116% | 85%  |
| 4.6 m  | 1    | 80%           | 96%              | 98%               | 74%  | 94%  | 93%  |
| 7.0 m  | 1.5  | 86%           | 97%              | 110%              | 82%  | 95%  | 106% |
| 9.3 m  | 2    | 80%           | 96%              | 113%              | 78%  | 94%  | 110% |
| 13.9 m | 3    | 84%           | 101%             | 115%              | 83%  | 99%  | 113% |
| 18.6 m | 4    | 84%           | 100%             | 113%              | 82%  | 98%  | 110% |
| 23.2 m | 5    | 85%           | 100%             | 110%              | 84%  | 98%  | 107% |
| 27.8 m | 6    | 85%           | 98%              | 108%              | 83%  | 96%  | 106% |

The incident impulse, 13% to 22% low without afterburning, is within 4% beyond 1 m/kg^(1/3)
with it, and within 6% with hot air too. That is by construction: the burning time was chosen
to match it (with the ideal gas), and burning everything at once instead gave 108% to 122%,
with arrival times 10% to 25% early. The reflected impulse, which was not fitted, rises with it
and is 6% to 15% high in the middle ranges: the model's ratio of reflected to incident impulse
there is about 10% above Kingery–Bulmash's, with or without afterburning. Hot air on its own,
without afterburning, lowers incident peaks and impulses by 1% to 6%.

With afterburning and hot air, refining the air by 2 gives the uniform grid twice as fine, as
it does without them (incident peak and reflected impulse):

| Range  | 0.5 m refined | 0.25 m | 0.25 m refined | 0.125 m | Reflected impulse: 0.5 m refined | 0.25 m | 0.25 m refined | 0.125 m |
|--------|------|------|------|------|------|------|------|------|
| 3.5 m  | 72%  | 72%  | 90%  | 90%  | 85%  | 85%  | 94%  | 94%  |
| 4.6 m  | 74%  | 74%  | 89%  | 89%  | 93%  | 93%  | 103% | 103% |
| 7.0 m  | 81%  | 82%  | 93%  | 93%  | 106% | 106% | 113% | 114% |
| 9.3 m  | 77%  | 78%  | 87%  | 87%  | 110% | 110% | 112% | 113% |
| 13.9 m | 83%  | 83%  | 88%  | 88%  | 113% | 113% | 111% | 112% |
| 18.6 m | 82%  | 82%  | 91%  | 91%  | 109% | 110% | 106% | 107% |
| 23.2 m | 84%  | 84%  | 92%  | 92%  | 106% | 107% | 104% | 104% |
| 27.8 m | 84%  | 83%  | 92%  | 92%  | 105% | 106% | 102% | 103% |

The reflected peaks and the incident impulses agree as closely (within 3 points and 4%).
`blastbench validate --afterburn --air thermal` takes 18 s on 0.5 m cells refined against 28 s on
0.25 m cells, and 146 s on 0.25 m cells refined against 419 s on 0.125 m cells.

### Kinney–Graham

The same burst against the Kinney–Graham free-air formulae for 200 kg (a charge on perfectly
rigid ground is equivalent to one of twice the mass in free air):

| Range | Reference peak | 0.5 m cells | 0.25 m cells | 0.125 m cells |
|-------|----------------|-------------|--------------|---------------|
| 5 m   | 1,408 kPa      | 45%         | 60%          | 76%           |
| 10 m  | 300 kPa        | 47%         | 61%          | 68%           |
| 15 m  | 117 kPa        | 54%         | 66%          | 74%           |
| 20 m  | 62 kPa         | 60%         | 72%          | 81%           |
| 25 m  | 39 kPa         | 65%         | 77%          | 86%           |

| Range | Reference impulse | 0.5 m cells | 0.25 m cells | 0.125 m cells |
|-------|-------------------|-------------|--------------|---------------|
| 5 m   | 705 Pa·s          | 117%        | 116%         | 124%          |
| 10 m  | 558 Pa·s          | 84%         | 85%          | 84%           |
| 15 m  | 419 Pa·s          | 81%         | 82%          | 83%           |
| 20 m  | 326 Pa·s          | 81%         | 83%          | 83%           |
| 25 m  | 264 Pa·s          | 82%         | 83%          | 84%           |

This comparison is harsher than the first, and less fair. Real ground is not perfectly rigid:
test data for surface bursts, which Kingery–Bulmash fits, correspond to about 1.8 times the mass
in free air rather than 2. At 10 m the Kinney–Graham peak is about a quarter higher than the
Kingery–Bulmash one. Both formulae (the book's equations 6-2 and 6-12) have been checked
against the book.

### Gas pressure in a closed room

A charge fired in a closed room leaves, once the shocks have died down, hot gas at a steady
pressure. UFC 3-340-02 (Figure 2-152) gives that pressure against the charge per unit of room
volume, from tests. `blastbench gas` fires a charge in the middle of a closed 6 m cube and
reads the pressure at 80 ms:

| Charge per volume | Model    | UFC 3-340-02 | Model / UFC |
|-------------------|----------|--------------|-------------|
| 0.25 kg/m³        | 0.42 MPa | 0.88 MPa     | 48%         |
| 0.5 kg/m³         | 0.84 MPa | 1.48 MPa     | 57%         |
| 1 kg/m³           | 1.67 MPa | 2.16 MPa     | 77%         |
| 2 kg/m³           | 3.35 MPa | 3.50 MPa     | 96%         |
| 4 kg/m³           | 6.69 MPa | 5.88 MPa     | 114%        |

The model's pressure is exactly (γ − 1)E/V, the TNT energy of 4.184 MJ/kg shared through the
room as an ideal gas, as it should be for the source it uses. The tests give up to twice that
for light charges, most likely because the detonation products burn in the room's oxygen
(afterburning; TNT's heat of combustion is about three times its heat of detonation). In heavy
charges there is too little oxygen for that, and the products' lower γ brings the pressure
below the ideal gas's. Afterburning is the
likeliest cause of the incident impulse's shortfall in the open, too (see
[Afterburning](#afterburning)). The digitised curve is in `UFC340.swift`, read off the chart by
hand.

With afterburning (`blastbench gas --afterburn`):

| Charge per volume | Model    | UFC 3-340-02 | Model / UFC | Products burnt by 80 ms |
|-------------------|----------|--------------|-------------|-------------------------|
| 0.25 kg/m³        | 1.15 MPa | 0.88 MPa     | 131%        | 73%                     |
| 0.5 kg/m³         | 1.93 MPa | 1.48 MPa     | 131%        | 55%                     |
| 1 kg/m³           | 2.79 MPa | 2.16 MPa     | 129%        | 28%                     |
| 2 kg/m³           | 4.34 MPa | 3.50 MPa     | 124%        | 12%                     |
| 4 kg/m³           | 7.56 MPa | 5.88 MPa     | 129%        | 5%                      |

The shape of the design curve is now right: the ratio to it is nearly the same at every
density, where without afterburning it ran from 48% to 114%, and the heavier charges burn
less for lack of oxygen. The level is about 30% high, about what treating gas at 2000 to
3000 K as cold air should cost. With [hot air](air-blast-model.md#hot-air) as well
(`--afterburn --air thermal`), nothing else changed:

| Charge per volume | Model    | UFC 3-340-02 | Model / UFC | Products burnt by 80 ms |
|-------------------|----------|--------------|-------------|-------------------------|
| 0.25 kg/m³        | 0.95 MPa | 0.88 MPa     | 108%        | 74%                     |
| 0.5 kg/m³         | 1.54 MPa | 1.48 MPa     | 105%        | 55%                     |
| 1 kg/m³           | 2.21 MPa | 2.16 MPa     | 102%        | 28%                     |
| 2 kg/m³           | 3.43 MPa | 3.50 MPa     | 98%         | 12%                     |
| 4 kg/m³           | 5.96 MPa | 5.88 MPa     | 101%        | 5%                      |

Within 8% of the design curve at every density, from the energies of detonation and
combustion, the oxygen in air and the vibration of its molecules, with nothing fitted to it
(the burning time hardly matters in a closed room). Hot air without afterburning gives 43% to
91%.

Cooper (*Explosives Engineering*, pp. 153–158) works a closed vessel through by hand: 2 kg of
TNT burnt completely in 14.1 m³ of air (0.14 kg/m³) leaves 7.35 atm of overpressure, 0.745 MPa.
At that density (`blastbench gas --per-volume 0.1415 --afterburn --air thermal --time 0.5`)
the products have all burnt by 0.5 s and the model gives 0.67 MPa, 90% of it. Most of the
difference is energy: Cooper burns 14.7 MJ/kg (his heat of combustion, less the latent heat of
the water), the model 14.18 (4.184 for the detonation and 10 for the afterburn), and the rest
his rough allowance for hot gas (a mean γ, with the gas's temperature taken as γ times that of
constant pressure). The design curve gives 0.53 MPa there, where at 80 ms 82% has burnt and the
model gives 0.60 MPa.

## An internal explosion in a reinforced concrete chamber

The one test so far that couples a real charge to a real structure, and the only one that
reaches failure.

### The test

H. Shang, W. Guo, Y. Li, W. Pang and H. Liu, "Experimental Study on the Damage Mechanism of
Reinforced Concrete Shear Walls Under Internal Explosion", *Applied Sciences* 16, 48 (2026).
Two full-scale reinforced concrete chambers stand either side of a 1 m partition. Their walls,
roofs and foundation are 0.8 m of C40 concrete with 16 mm bars at 150 mm in both faces both
ways and 8 mm ties at 450 mm; the inside corners are chamfered, with diagonal bars; the end
walls are 1.8 m thick. Each roof stops 1.2 m short of the partition, leaving a vent open to
the sky. Four 50 kg TNT charges, in open steel sleeves through the partition, were fired
together.

| Measured                                     | Value                                 |
|----------------------------------------------|---------------------------------------|
| Peak reflected pressure, six wall sensors    | 3.2 to 4.4 MPa                        |
| Residual deflection of chamber A's roof edge | 95 mm, read off the paper's Figure 21 |
| Chamber B                                    | Roof edge fractured at the walls, left hanging on a few bars |

Chamber B had been cast in two stages, and failed along the cold joint. The paper's own
LS-DYNA model gives 61 mm for chamber A, and its parametric study (Table 7) gives a second
reference for how the roof responds to the charge: 22, 87 and 251 mm peak for 100, 200 and
300 kg, and the roof thrown off at 400 kg.

### The model

One chamber, with the partition's mid-plane as a mirror, so that each sleeve's charge counts
as 25 kg on the mirror. Air cells and solid elements are 0.1 m (116,760 elements). The
partition and the foundation are rigid; of the 1.8 m end wall, the inner 0.6 m is modelled,
held at its outer face, so that the bars of the roof and walls run on into it. The chamfers
are steps of elements with their diagonal bars as [inclined bars](concrete-model.md#reinforcement),
taken as the mats' (16 mm at 150 mm), 50 mm in from the sloped face and anchored 0.6 m into
each member; the paper gives neither their size nor the down-stand's detailing, which is
taken as the walls': mats on both faces and ties through its width, standing for its
stirrups. The other assumptions, and the geometry read off the paper's drawings, are listed
in `ChamberTest.swift`. `blastbench chamber` runs 300 ms in about 17 s; `--charge-scale`
scales the charges, `--pressures` fills the closed chamber with a steady overpressure instead
(below), and `--progress` reports every 10 ms of a long run.

### Results

Since these runs, cracks slide for good and ride up when they do (see the
[concrete model](concrete-model.md#shear-across-cracks)): the roof's edge is left 16 mm up,
where the runs below leave it 7 mm, with its peak unchanged at 38 mm.

**Pressures.** At gauges placed near the sensors the model gives 4.2 and 6.8 MPa on the side
walls and 3.2 MPa on the roof, against 3.2 to 4.4 MPa measured. The gauge positions are
approximate, and peaks this close to a charge change sharply with position, so this check is
loose: the model is between 0.9 and 1.6 times the measured range.

**The roof.** At the test's charge the roof's free edge rises 38 mm and settles back to 7 mm
with the default gas (ideal, no afterburning), and rises 37 mm and settles to 8 mm with
afterburning and hot air, which bring the gas pressure within 8% of what UFC 3-340-02 gives
for a closed room. The paper's own model gave 87 mm and 62 mm; 95 mm was measured. The model's
roof is about twice as stiff as the paper's model's, and springs back much further. Across the
charge it holds up to about a third more than the paper's model:

| Charge, as a fraction of the test's | Default gas: peak / end of run | Afterburning and hot air | Paper's model (Table 7): peak / residual |
|-------------------------------------|--------------------------------|--------------------------|------------------------------------------|
| 0.5 (100 kg)                        | 8 / 1 mm                       | 8 / 1 mm                 | 22 / 17 mm                               |
| 1 (200 kg)                          | 38 / 7 mm                      | 37 / 8 mm                | 87 / 62 mm; measured residual 95 mm      |
| 1.25                                | 72 / 16 mm                     |                          |                                          |
| 1.5                                 | 141 / 40 mm                    | 145 / 35 mm              | 251 / 168 mm                             |
| 2                                   | 641 / 230 mm                   | 520 / 130 mm             | Roof thrown                              |
| 2.5                                 | Roof thrown                    |                          |                                          |

**The mesh.** On 50 mm elements (942,643) the roof rises 40 mm and is left 7 mm up with 0.1 m
air cells, and 42 and 7 mm with 50 mm air cells, in 2.6 and 3.5 minutes: the same, within
the model's own spread, as on 0.1 m elements. On 25 mm elements (7.5 million) it rises 65 mm
by 30 ms, so the peak has not converged there; and after 50 ms those runs come apart at the
roof's joints with the side walls, where the chamfers' diagonal bars anchor among the mats:
70,000 elements removed between 50 and 60 ms with contact between pieces off, and far more
with it on (an open problem; see below).

**What the detailing did.** Until the chamfers' diagonal bars and the down-stand's
reinforcement were added, the roof rose 73 mm and was left 12 mm up on 0.1 m elements, close
to the paper's model's peak, and the response did not converge with the mesh: 85 to 98 mm on
50 mm elements and 123 mm on 25 mm, with the unreinforced chamfers and down-stand losing tens
of thousands of elements. The down-stand had in fact had no bars at all: a slip in
`ChamberTest.swift` gave its mats to the last chamfer step instead. With its mats the roof
peaks at 46 to 48 mm; the diagonal bars take it to 37 mm; the ties make no difference on
0.1 m elements.

**The crack model, the residual opening and the air grid matter little now.** Cracks on the
lattice planes (`--cracks lattice`), which mishandle an inclined crack (see the
[concrete model](concrete-model.md#cracking)), give 59 mm and 10 mm; cracks fixed at first
cracking 39 and 7 mm; turning cracks without the second crack 36 and 6 mm. A residual crack
opening of 0, 0.3 and 0.5 of the opening (`--crack-residual`) leaves the edge 5, 13 and 19 mm
up. With the air [refined](air-blast-model.md#refining-near-the-shock) by 2 (`--refine 2`) it
rises 40 mm and is left 8 mm up, in 35 s. The side walls bow out 5 mm, and one element fails.

**What brings the roof back down.** Traced through the run before the detailing was added
(`StructureSolver.barPlasticStrain`): the free edge works as a deep beam spanning between the
side walls, the roof slab its flange and the down-stand its web. By the peak both of the
slab's mats at mid-span had yielded in tension, and between 40 and 70 ms, while the gas beneath
still pushed up at 100 to 300 kPa, every hinge closed again. What pushes it down is arching.
Cracking lengthens the beam, the walls restrain it, and it carries 2 to 4 MN of thrust, high in
the slab at the walls and low in the down-stand at mid-span: an inverted arch, which resists
the upward load. The thrust outlasts the load, and with nothing left to oppose it, it pushes
the mid-span back down. Ruled out: the gas above the roof, the elements' hourglass stiffness,
the bars' Bauschinger softening and the side walls' own recovery. In the test the joints were
cut through by oblique shear cracks within a few milliseconds and became hinges held only by
their bars, their cores fragmented, which would have released much of that thrust; the
model's joints crack across a band but no crack runs through the section. Softening the
compression of concrete cracked the other way, by 1 / (0.8 + 170 ε₁) as in the modified
compression field theory, did not cure it and made other cases fail (the slab held down at its
supports came apart, and the two-storey frame fell at 1,000 kg).

**How the model got here.** The first version threw the roof at 0.875 of the test's charge and
beyond. What was found on the way:

- **The gas is not what throws the roof.** With the vent closed and the chamber filled with a
  steady overpressure, applied all at once, the roof deflects 8 mm at 600 kPa and is thrown at
  800 kPa (before the detailing was added). The gas behind the shocks in the real event, 200
  to 500 kPa, is below that. So the shocks of the first few milliseconds were destroying the
  supports.
- **Shear across cracked supports was the weakness.** With aggregate interlock five times
  stronger, the roof peaked at 50 mm and nothing ran away. So the model had too little shear
  transfer across sections cracked through at their supports: interlock fades as a crack
  opens, and the bars crossing it added nothing. The paper found the joints' bars "twisted but
  did not break", holding the shattered concrete in place. The model now has the bars'
  dowel action and kinking across a sliding crack (see the
  [concrete model](concrete-model.md#shear-across-cracks)).
- **Removing the cores of cracked hinges.** An element was removed when its crack passed 5 mm
  and no bar of its own crossed it, so the core of an 0.8 m section at a hinge, between the
  mats, went at 5 mm and took the hinge's interlock and compression with it. A crack crossed
  by intact bars anywhere in the section now counts as bridged (see
  [Removal](concrete-model.md#removal)).
- **Inclined cracks.** The lattice planes mishandled the joints' 45° cracks; cracks now turn
  with the stress until they open, with a second crack where the tension turns further.
- **Contact, the time step and the detailing**, found when the mesh was refined: contact
  between pieces fed energy to crowded debris, dense bars outran the time step, and the
  down-stand had no bars (see the [structural model](structural-model.md#limitations)).
- **Not the end wall's rigidity.** Modelling the inner 0.6 m of the end wall instead of a
  rigid face changed little.

What remains, in rough order:

1. **The joints.** In the test they were cut through within milliseconds and the roof was left
   95 mm up; the model's stay whole enough to carry the arching thrust, and the roof is left
   7 mm up.
2. **The 25 mm mesh.** Its peak (65 mm) is well above the coarser meshes' (38 to 42 mm), and
   on the rebound, as the edge falls from 22 to 9 mm between 50 and 60 ms, the tops of the side
   walls and the roof over them tear and crush: 61,000 elements removed in 10 ms, by every
   rule (cracks past the removal width unbridged, cracks past the hard limit, crushing, and
   collapsed volume), then little more (88,600 by 110 ms with contact off). Elements holding
   the diagonal bars hardly fail (700); their neighbours do. Without the diagonal bars the
   25 mm run holds together (14,000 by 60 ms) but peaks at 107 mm. It looks like the stiffer
   corners pushing the arching thrust into the wall tops, which tear on the finest mesh and not
   on 50 mm elements: failure that depends on the element size. Until it is understood the
   chamber's converged answer is not known.
3. **The detailing the paper does not give**: the diagonal bars' size and anchorage and the
   down-stand's reinforcement are assumptions, and they decide the roof's stiffness (73 mm
   without them, 38 with them).
4. **What the model leaves out of the load path**: the steel sleeves, which take some of the
   charges' energy and were modelled by the paper.

### What this does and does not show

The model reproduces the kind of damage seen (cracking concentrated at the joints and
supports, held together by the bars, and a roof left deflected upwards), and it exposed
missing mechanisms in the concrete model, errors in it and in the contact and time step, and
an error in the test's own set-up, all now dealt with. With the structure as built (so far as
the paper says), its roof is about twice as stiff as both the paper's model and the test
suggest, and springs back far further; its peak wall pressures are within the loose check that
the gauge positions allow. One test, one measured residual, and two pieces of detailing that
had to be assumed: the chamber shows how the model behaves at a full-scale joint, not that it
is right there.

## Consistency across air grids

The 3 m reinforced cantilever wall, 6 m from the charge, coupled to the air solver:

| Charge | 0.5 m cells                | 0.25 m cells       | 0.125 m cells      |
|--------|----------------------------|--------------------|--------------------|
| 50 kg  | Top swings 40 mm, back to 4 mm by 0.1 s | 51 mm, 3 mm | 54 mm, 8 mm |
| 200 kg | Hinged at its base, top 280 mm over, 270 mm by 0.1 s | 326 mm | 353 mm |

![The wall 1 s after 200 kg, cracked through along its base, before the second crack](wall-hinged.png)

The qualitative outcome is the same on every grid. At 200 kg the wall cracks at its base and
swings over on its bars, then back: 202 mm at the top after 1 s on 0.25 m cells. Before the
second crack (see the [concrete model](concrete-model.md#cracking)) it stayed hinged over,
608 mm at 1 s, losing 278 elements at its base by 0.1 s; the second crack takes the inclined
tension there that the cracked planes' shear used to carry, and no element is now removed on
any grid. Before bars
resisted sliding across cracks and cracks were bridged across the section (see the
[concrete model](concrete-model.md#shear-across-cracks)), the wall sheared off at its base on
every grid and toppled. At 50 kg the wall cracks and swings back: 40, 51 and 54 mm at the top
on the three grids, converging. (These were once given as the deflection at 0.1 s, 3 to 8 mm,
which the snapshot command had called the peak; it now reports both.) With the air [refined](air-blast-model.md#refining-near-the-shock) by 2 and the
wall loaded by the fine cells beside it and outlined at their resolution, 0.5 m cells give
323 mm at 200 kg, as 0.25 m cells do (325 mm), and 0.25 m cells give 349 mm, as 0.125 m cells
do (352 mm). With cracks on the lattice planes it gave 15, 25 and 32 mm at 50 kg, growing
with resolution as the peak pressure does, and 315, 437 and 657 mm at 200 kg; that model
mishandled inclined cracks (see the [concrete model](concrete-model.md#cracking)). There is
no test to compare these with.

## Verification against theory

The test suite has 114 tests. The physical checks are:

**Air solver**

| Problem                                         | Check                                          |
|-------------------------------------------------|------------------------------------------------|
| Sod's shock tube, HLLC and HLL                  | Mean density error below 0.004 on 400 cells    |
| The same along x, y and z                       | Profiles agree within 0.002                    |
| Normal shock reflecting off a wall              | Reflected pressure within 2% of theory         |
| Sedov–Taylor point blast                        | Shock radius within 4% along an axis and a diagonal |
| Closed box with an obstacle                     | Mass and energy conserved to 1 part in 10⁴     |
| Centred burst in a cube                         | Mirror-symmetric to 1 part in 10³              |
| Still air around obstacles                      | Stays still                                    |
| Street blast and coupled wall, still air skipped | Identical to sweeping everything, cell for cell |
| Charge burning in a closed room                  | Fuel and oxygen used at 0.74, energy released, mass kept, within 1% |
| A charge burnt out in a closed vessel            | Within 15% of Cooper's worked example (90%)    |
| Heavy charge in a small room                    | Burns no more than the oxygen allows             |
| Hot air: energy and pressure both ways          | Within 0.01% from 250 K to 6000 K; γ = 1.4 cold   |
| Shock tube in cold units, hot air               | Same densities as the ideal gas within 10⁻⁴      |
| Closed room, afterburning and hot air           | Within 15% of UFC 3-340-02 at 0.25 and 1 kg/m³   |
| Cantilever strip, first quarter solid elements, rest shells | Sags within 3% of beam theory (1.3%)     |
| Wall in a blast, solid base, shell top          | Bends between the all-solid and all-shell walls  |
| Concrete and masonry elements pulled apart, joint bonded | Separate at the bond, 0.2 MPa, within 5%   |
| Glass pane, 1 kg at 3 m and 0.5 g at 3 m        | Breaks, and survives                             |
| Blockwork meshed as units and joints            | Joints in running bond; none on coarse elements  |
| Blockwork pulled across and along its bed joints | Parts at the bond within 5%; stronger along, below the units' strength |
| A bed joint pushed sideways, free and pressed   | Slides at cohesion, and cohesion plus friction, within 10% |
| Blockwork wall cracked by a push, left alone    | Kinetic energy never rises; comes to rest        |
| One-dimensional blast, point source             | Energy within 1%; Sedov–Taylor radius within 8%  |
| Charge mapped onto the grid                     | Same energy as the balloon within 3%; gauges passed keep their record |

**Structural solver**

| Problem                                         | Check                                          |
|-------------------------------------------------|------------------------------------------------|
| Bar striking a rigid wall                       | Wave speed and stress ρcv within 5%            |
| Cantilever under its own weight                 | Tip deflection within 5% of beam theory        |
| Cantilever released from rest                   | First natural period within 5%                 |
| Spinning body                                   | Energy within 1%, angular momentum within 0.5% |
| Two blocks colliding                            | No overlap; momentum conserved to 1%           |
| Block dropped onto another                      | Comes to rest on it                            |
| Bar of two materials pulled from one end        | Each half stretches by its own modulus, within 5%; mass and time step per material |
| Masonry panel set into a reinforced wall        | Panel gets no steel; the later piece's material wins |
| Node resting on a support                       | Held up, not held down; lifts off in free flight |
| Two-storey frame under gravity                  | Stands; bridges a removed column               |

**Concrete and reinforcement**

| Problem                                         | Check                                          |
|-------------------------------------------------|------------------------------------------------|
| Tension on two mesh sizes                       | Peak at f_t within 3%; fracture energy within 5% |
| Compression                                     | Peak at f_c within 2%; parabola; 20% residual  |
| Compression released and reapplied              | Permanent strain within 3% of Karsan–Jirsa     |
| Reinforcement stretched, then shortened         | Follows the Menegotto–Pinto curve within 3% of yield |
| Fully restrained compression                    | Passes 5.1 f_c (confinement), never softens; then follows the compaction curve, 3 GPa at 12% |
| Crack opened then closed                        | Closes at its residual opening; then full compressive stiffness |
| Reinforced element in tension                   | Yield, hardening and rupture within 3%         |
| Reinforced tie with one weak slice, two meshes  | Bars break at the same crack opening (13 and 11 mm) |
| Shear across an open crack, two widths          | Interlock law within 5%                        |
| Tension at 0.1 per second                       | Rate law within 6%                             |
| Compression at 100 per second (1 mm cube)       | CEB-FIP rate law above 30 per second within 6% |
| Reinforced beam in three-point bending          | Capacity 11–14% above section analysis on 6 and 12 elements deep; the two agree within 3% |

**Coupling**

| Problem                                         | Check                                          |
|-------------------------------------------------|------------------------------------------------|
| Block immersed in pressurised air               | Hydrostatic stress within 3%; no net force     |
| Free wall closing a shock tube                  | Gains the air's impulse within 1%              |
| Intact wall across a shock tube                 | Far side hears only the flexing wall (50–2000 Pa) |
| The same wall with moving walls switched off    | Far side stays at ambient pressure             |
| Hole knocked in that wall                       | Mask opens; blast passes through               |
| Wall pushed along the tube                      | Mask travels with it; air beyond compressed adiabatically within 5% |
| Wall driven at 100 m/s into still air           | Piston shock and rarefaction within 2% of theory |
| Wall driven 1.1 m at 10, 50 and 150 m/s         | Gas mass conserved within 0.5% of the true volume |
| Sparse loose debris in a steady 100 m/s wind    | Gains the momentum of its drag within 3%; none with the option off |
| Sparse loose debris in a 1 kPa/m pressure gradient | Gains the gradient's push, plus drag, within 2% |
| Debris packed into an air cell in a 300 m/s wind | Air and debris momentum conserved within 1%; the air slowed but never reversed |
| After the blast has gone                        | Air freezes; structure carries on              |
| A wall broken by a 500 kg charge, run twice     | Identical to the last bit                      |

The shell elements have their own checks against plate and beam theory and the same coupling
checks; see the [shell model](shell-model.md#verification).

These establish that the equations are solved as intended. They say nothing about whether the
equations are the right ones.

## What is missing

In rough order of value:

1. Inclined cracking at joints, between the two crack models' errors (a crack that may turn
   until it opens); then the chamber's diagonal bars and stirrups (see
   [above](#an-internal-explosion-in-a-reinforced-concrete-chamber)).
2. A sixth structural test: a wall loaded in the open air, or a member with stirrups that
   failed in shear statically (see the [concrete model's future work](concrete-model.md#future-work)).
   The beams above test bending, shear without stirrups, and impact.
3. The concrete's tensile strain-rate law at 1 to 10 per second, which decides the heavy
   impacts above: tests that separate the material's strengthening from the specimen's
   inertia, or a second impact programme to test a change against.
4. The vented gas impulse of UFC 3-340-02 (Figures 2-153 to 2-164), which would need
   digitising, to check how fast the model's gas leaves a room like the chamber.
5. Close-in damage: slabs that barely spall and are not holed (see
   [above](#slabs-under-close-in-charges)).
6. Any test of collapse or debris.
