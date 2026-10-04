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
| Structural response  | One slab test: solid elements converge to 105 mm (98%), shells to 124 mm (115%) | Low to moderate: one test, sensitive to supports |
| Internal explosion   | One full-scale chamber test: peak wall pressures 0.9 to 1.6 times those measured; the roof's peak follows the paper's model, but its edge is left 12 mm up against 95 mm | Low: the joints' inclined cracking decides it, and the crack models disagree |
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
| Model, 32 elements through       | 105 mm (98%)    | 26 ms | 74 mm    | 32 of 4,423,680 |
| Model, 16 elements through       | 108 mm (100%)   | 27 ms | 80 mm    | 1 of 552,960    |
| Model, 8 elements through        | 101 mm (94%)    | 26 ms | 67 mm    | 0 of 68,608     |
| Model, 4 elements through        | 101 mm (93%)    | 26 ms | 80 mm    | 0 of 8,704      |

Mid-span deflection through the record, in millimetres:

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
108 mm**, at most 3% below the measurement: 101, 101, 108 and 105 mm from 4 to 32 elements
through. (The 32-element run predates steps 22 and 23 of the
[concrete model](concrete-model.md#how-the-model-got-here), the residual opening kept where a
crack opened and a second crack, which moved the others by a millimetre or two at most.)
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
| Load 5% lower                                | 88 mm (82%)     | 0               |
| Load 5% higher                               | 116 mm (107%)   | 0               |
| Aggregate 10 mm instead of 16 mm             | 102 mm (94%)    | 0               |
| Crack spacing 50 mm instead of 100 mm        | 98 mm (91%)     | 0               |
| Crack spacing 200 mm                         | 101 mm (94%)    | 0               |
| Fracture energy halved                       | 101 mm (94%)    | 0               |
| Tensile strength 20% lower                   | 104 mm (96%)    | 0               |
| Cracks close fully (no residual opening)     | 101 mm (94%)    | 0               |
| Residual crack opening 30% instead of 10%    | 101 mm (94%)    | 0               |
| Residual crack opening 50%                   | 101 mm (94%)    | 0               |
| Crushing spread over at least 50 mm          | 102 mm (94%)    | 0               |
| Crushing averaged over 48 mm (nonlocal)      | 101 mm (94%)    | 0               |
| Supports as 1 in bearings, held down         | 81 mm (75%)     | 0               |
| Supports as 1 in bearings, free to lift      | 88 mm (81%)     | 0               |
| 16 elements through the thickness            | 108 mm (100%)   | 1               |
| Fixed UFC 3-340-02 factors, no rate laws     | 121 mm (112%)   | 0               |
| Static strengths                             | 208 mm, failing | 3,933           |

Reading this table:

- **The rate treatment decides the outcome.** The load is far above the slab's static
  capacity, so it survives only because steel and concrete are stronger when loaded quickly.
  With static strengths the model predicts failure. With the fixed design factors of
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
- **The supports matter by 15–20%.** The default is a pin and a roller on single lines of
  nodes. Bearings one inch wide lower the peak to 80–87 mm. The source does not
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
are steps of elements, without their diagonal bars. The other assumptions, and the geometry
read off the paper's drawings, are listed in `ChamberTest.swift`. `blastbench chamber` runs
300 ms in about 17 s; `--charge-scale` scales the charges, and `--pressures` fills the closed
chamber with a steady overpressure instead (below).

### Results

**Pressures.** At gauges placed near the sensors the model gives 4.2 and 6.8 MPa on the side
walls and 3.2 MPa on the roof, against 3.2 to 4.4 MPa measured. The gauge positions are
approximate, and peaks this close to a charge change sharply with position, so this check is
loose: the model is between 0.9 and 1.6 times the measured range.

**The roof.** At the test's charge the roof's free edge rises 73 mm and settles back to
12 mm with the default gas (ideal, no afterburning), and rises 82 mm and settles to 14 mm with
afterburning and hot air, which bring the gas pressure within 8% of what UFC 3-340-02 gives
for a closed room (the default gas, at this room's 0.58 kg/m³, holds about 60% of it). The
paper's own model gave 87 mm and 62 mm; 95 mm was measured. The peak is close to the paper's
model's, but the roof springs back too far, as the slab does (see the
[concrete model](concrete-model.md#limitations)). Across the charge the response follows the
paper's model, with a cliff at the same place:

| Charge, as a fraction of the test's | Default gas: peak / end of run | Afterburning and hot air | Paper's model (Table 7): peak / residual |
|-------------------------------------|--------------------------------|--------------------------|------------------------------------------|
| 0.5 (100 kg)                        | 9 / 1 mm                       | 9 / 1 mm                 | 22 / 17 mm                               |
| 1 (200 kg)                          | 73 / 12 mm                     | 82 / 14 mm               | 87 / 62 mm; measured residual 95 mm      |
| 1.25                                | 160 / 35 mm                    |                          |                                          |
| 1.5                                 | 432 / 109 mm                   | 479 / 87 mm              | 251 / 168 mm                             |
| 2                                   | Roof thrown                    | Roof thrown              | Roof thrown                              |

**The crack model decides it.** The joints crack at 45°. With cracks on the lattice planes
(`--cracks lattice`), which mishandle an inclined crack (see the
[concrete model](concrete-model.md#cracking)), the roof rises 264 mm and is left 134 mm up
with the default gas, with 1,777 elements removed; when last run it was thrown at 1.25 times
the charge, and with afterburning and hot air its edge was left 889 mm up. With cracks fixed
at first cracking (`--cracks fixed`) it gives 71 / 12 mm and 77 / 13 mm, much as the default
turning cracks do. A second crack where the tension turns from fixed axes (on by default; see
the [concrete model](concrete-model.md#cracking)) raised the peak from 66 to 73 mm, and 71 to
82 mm with afterburning and hot air, and the edge left up from 10 to 12 and 14 mm.

**Nor does the residual crack opening.** A crack keeps a tenth of its opening when it closes,
the value recommended for the concrete damaged plasticity model. With more, the roof is left
higher, but not by enough: 4, 12, 19, 26 and 38 mm at the end of the run for 0, 0.1, 0.2, 0.3
and 0.5 (`--crack-residual`), with peaks of 76 to 65 mm. Looking into this found a fault: the
residual had followed histories that diagonal cracks raise on planes held closed, and from 0.4
up it made every structure run away (see the [concrete model](concrete-model.md), step 22).
**What brings the roof back down.** Traced through the run (`StructureSolver.barPlasticStrain`):
the free edge works as a deep beam spanning between the side walls, the roof slab its flange
and the down-stand its web. By the peak (35 ms) both of the slab's mats at mid-span have
yielded in tension, the top to 8% and the bottom to 4%, while the bars at the joints yield
less (up to 5%). Between 40 and 70 ms the edge drops from 72 to 6 mm while the gas beneath
still pushes up at 100 to 300 kPa, and every hinge closes: the mid-span bars yield back to 1%,
the joints' to about 1%. What pushes it down is arching. Cracking lengthens the beam, the walls
restrain it, and it carries 2 to 4 MN of thrust, high in the slab at the walls and low in the
down-stand at mid-span: an inverted arch, which resists the upward load. The thrust outlasts
the load (1.2 MN remains after 100 ms), and with nothing left to oppose it, it pushes the
mid-span back down, its moment there reversing to −0.6 MN m. How far the hinges then close
depends on when the cracks' faces bear (above). Ruled out: the gas above the roof (it never
passes 60 kPa), the elements' hourglass stiffness (a quarter or four times it leaves 12 and
13 mm), the bars' Bauschinger softening (sharp reversals leave 12 mm), and the side walls'
own recovery (with their outer faces held the roof peaks at 27 mm and is left 3 mm up). In the
test the joints were shattered, which would have released much of that thrust; the model's
joints stay whole enough to carry it, and with lattice cracks, which soften inclined cracking
more, the roof keeps 138 of 265 mm.

At the test's charge the side walls bow out 5 mm, and 3 elements fail in all; the measured
structure was itself close to its cliff, since chamber B nearly lost its roof edge.

With the air [refined](air-blast-model.md#refining-near-the-shock) by 2 (`--refine 2`, fine
cells of 50 mm), the roof's edge rises 79 mm and settles to 14 mm, against 73 and 12 mm: the
roof answers to impulse, which the 0.1 m cells already resolve. The peak pressures at the
gauges are 5.3 to 6.6 MPa against 3.2 to 6.8 MPa unrefined and 3.2 to 4.4 MPa measured: a
sharper shock beside four charges, read at approximate gauge positions. The run takes 38 s
instead of 17 s. With afterburning and hot air as well, refined, the edge rises 89 mm and
settles to 19 mm, against 82 and 14 mm unrefined, in 47 s.

**How the model got here.** The first version threw the roof at 0.875 of the test's charge and
beyond. What was found on the way:

- **The gas is not what throws the roof.** With the vent closed and the chamber filled with a
  steady overpressure, applied all at once, the roof deflects 8 mm at 600 kPa and is thrown at
  800 kPa. The gas behind the shocks in the real event, 200 to 500 kPa, is below that. So
  the shocks of the first few milliseconds were destroying the supports.
- **Shear across cracked supports was the weakness.** With aggregate interlock five times
  stronger, the roof peaked at 50 mm and nothing ran away. So the model had too little shear
  transfer across sections cracked through at their supports: interlock fades as a crack
  opens, and the bars crossing it added nothing. The paper found the joints' bars "twisted but
  did not break", holding the shattered concrete in place. The model now has the bars'
  dowel action and kinking across a sliding crack (see the
  [concrete model](concrete-model.md#shear-across-cracks)). With them the side walls stopped
  running away, and the roof stopped at about 1 m.
- **Removing the cores of cracked hinges** was the rest. An element was removed when its crack
  passed 5 mm and no bar of its own crossed it, so the core of an 0.8 m section at a hinge,
  between the mats, went at 5 mm and took the hinge's interlock and compression with it. A
  crack crossed by intact bars anywhere in the section now counts as bridged (see
  [Removal](concrete-model.md#removal)), as the shells already judged it. With that the roof
  edge settles at 123 mm.
- **Not the end wall's rigidity.** Modelling the inner 0.6 m of the end wall instead of a
  rigid face changed little; the hinge just beyond it was real.
- **Not stiffness.** With elastic concrete the edge swings ±7 mm. In the first version, 50 mm
  elements (about 670,000) gave the same response as 0.1 m elements within 10%; that no longer
  holds (below).
- **The chamfers matter.** Without them the first version's cliff came between 0.5 and 0.75
  of the charge.

What remains, in rough order:

1. **The joints' detailing**: no diagonal bars across the chamfers, and mats smeared over a
   band one element thick. In the test the joints were cut through by oblique shear cracks
   from the chamfers' edges within a few milliseconds and became hinges held only by their
   bars, their cores fragmented; in the model they crack (1 to 3% across a band running up
   from the chamfer's edge) but no crack runs through the section. Two changes were tried and
   neither kept. Bars in the chamfers (as lattice bars in both directions, more steel than the
   diagonal bars) stiffen the roof: 56 to 58 mm peak, 8 mm left. Softening the compression of
   concrete cracked the other way, by 1 / (0.8 + 170 ε₁) as in the modified compression field
   theory, raised the roof's peak to 78 mm (97 mm with afterburning and hot air) and left it
   14 to 16 mm up, but stripped the unreinforced chamfers and the down-stand (1,100 elements)
   and made other cases fail: the slab held down at its supports came apart, and the
   two-storey frame fell at 1,000 kg.
2. **The down-stand**, which loses about 40% of its elements; its stirrups are not modelled.
3. **What the model leaves out of the load path**: the steel sleeves, which take some of the
   charges' energy and were modelled by the paper, and afterburning, which would raise the
   gas pressure.
4. **The springback**: the roof is left 12 mm up against 95 mm, pulled back down by arching
   thrust that the model's joints carry and the test's shattered joints probably could not
   (above). This is the joints' detailing again (item 1), and the mesh (item 5).
5. **The mesh.** The roof has not converged on 0.1 m elements. On 50 mm elements (942,643 of
   them, `--h 0.05`) it rises 85 mm and is left 20 mm up with 0.1 m air cells, and 98 and
   24 mm with 50 mm air cells (`--dx 0.05`), and it comes down far more slowly: 83 mm at 40 ms
   and 68 mm at 60 ms, against 69 and 15 mm on 0.1 m elements. The paper's authors found the
   same, 100 mm elements under-predicting both peak and residual, and used 50 mm. The runs take
   3 and 4.3 minutes against 17 s; one on 25 mm elements did not finish within two hours.

### What this does and does not show

The model reproduces the kind of damage seen (cracking and crushing concentrated at the
joints and supports, held together by the bars, and a roof left deflected upwards), and it
exposed two missing mechanisms in the concrete model and one error (inclined cracks
mishandled), now dealt with from published mechanics with the slab test little changed. With the
gas as strong as the design manual says, the roof's peak and its cliff follow the paper's own
model, but its permanent deflection is a sixth of the 95 mm measured: the model springs back
too far. Peak wall pressures are within the loose check that the gauge positions allow.

## Consistency across air grids

The 3 m reinforced cantilever wall, 6 m from the charge, coupled to the air solver:

| Charge | 0.5 m cells                | 0.25 m cells       | 0.125 m cells      |
|--------|----------------------------|--------------------|--------------------|
| 50 kg  | 4 mm peak deflection by 0.1 s | 3 mm            | 7 mm               |
| 200 kg | Hinged at its base, top 270 mm over by 0.1 s | 325 mm | 352 mm |

![The wall 1 s after 200 kg, cracked through along its base, before the second crack](wall-hinged.png)

The qualitative outcome is the same on every grid. At 200 kg the wall cracks at its base and
swings over on its bars, then back: 202 mm at the top after 1 s on 0.25 m cells. Before the
second crack (see the [concrete model](concrete-model.md#cracking)) it stayed hinged over,
608 mm at 1 s, losing 278 elements at its base by 0.1 s; the second crack takes the inclined
tension there that the cracked planes' shear used to carry, and no element is now removed on
any grid. Before bars
resisted sliding across cracks and cracks were bridged across the section (see the
[concrete model](concrete-model.md#shear-across-cracks)), the wall sheared off at its base on
every grid and toppled. At 50 kg the wall barely cracks, and its few millimetres show no trend
with the grid. With the air [refined](air-blast-model.md#refining-near-the-shock) by 2 and the
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
2. A second and third structural test, of different kinds (see the
   [concrete model's future work](concrete-model.md#future-work)).
3. The vented gas impulse of UFC 3-340-02 (Figures 2-153 to 2-164), which would need
   digitising, to check how fast the model's gas leaves a room like the chamber.
4. Blast loads closer in than 0.75 m/kg^(1/3).
5. Any test of collapse or debris.
