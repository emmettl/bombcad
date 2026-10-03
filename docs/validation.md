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
| Blast loads          | Kingery–Bulmash curves from 0.75 to 6 m/kg^(1/3): impulse on a wall within 6% on 0.25 m cells beyond 1.5 m/kg^(1/3) | Good for impulse on walls; peaks under-resolved; incident impulse 13–22% low |
| Gas in a closed room | UFC 3-340-02: 48% to 114% of the design curve        | Low for light charges (no afterburning) |
| Structural numerics  | Beam and wave theory                                 | High                               |
| Concrete material    | Its own curves; section analysis of a beam           | High that it does what is intended |
| Structural response  | One slab test: solid elements converge to 112 mm (104%), shells to 124 mm (115%) | Low to moderate: one test, sensitive to supports |
| Internal explosion   | One full-scale chamber test: peak wall pressures 0.9 to 1.6 times those measured; the roof is thrown at the test's charge, which left it 95 mm deflected | Low: the structure is too weak by about 1.6 on the charge |
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
| Model, 32 elements through       | 112 mm (104%)   | 27 ms | 88 mm    | 83 of 4,423,680 |
| Model, 16 elements through       | 112 mm (104%)   | 27 ms | 90 mm    | 0 of 552,960    |
| Model, 8 elements through        | 105 mm (98%)    | 26 ms | 74 mm    | 0 of 68,608     |
| Model, 4 elements through        | 101 mm (93%)    | 26 ms | 81 mm    | 0 of 8,704      |

Mid-span deflection through the record, in millimetres:

| Time  | Measured | 16 through | 8 through | 4 through |
|-------|----------|------------|-----------|-----------|
| 5 ms  | 9        | 10         | 9         | 9         |
| 10 ms | 35       | 37         | 36        | 35        |
| 15 ms | 66       | 69         | 68        | 66        |
| 20 ms | 88       | 96         | 93        | 90        |
| 25 ms | 103      | 110        | 105       | 100       |
| 30 ms | 108      | 110        | 102       | 97        |
| 35 ms | 107      | 99         | 90        | 87        |
| 40 ms | 98       | 87         | 81        | 83        |
| 45 ms | 95       | 80         | 79        | 87        |
| 50 ms | 98       | 81         | 83        | 91        |
| 55 ms | 98       | 86         | 90        | 88        |
| 60 ms | 96       | 93         | 90        | 81        |
| 65 ms | 92       | 96         | 82        | 78        |
| 70 ms | 90       | 90         | 74        | 81        |

The root-mean-square difference over the record is 8.1 mm for 16 elements through the
thickness, 10.3 mm for 8 and 9.7 mm for 4. The peak rises with refinement, from 101 mm to
105 mm to 112 mm, so the model is close to converged but still rising by about 5% per halving
of the elements; the measured 108 mm lies between the two finer meshes. The 16-layer mesh
responds smoothly to the load: 109, 112 and 115 mm at 0.99, 1.00 and 1.01 times it. The rise
to the peak is reproduced within a few millimetres on every mesh. After the peak every mesh
rebounds further than the specimen did (about 30 mm against 13 mm) before settling. The
rebound is set by a hinge at mid-span: once its crushed compression zone unloads, the section
cracks through its depth and the two halves swing back about the bars. The
[concrete model](concrete-model.md#how-the-model-got-here) gives the evidence.

**Finer still.** The full-width slab with 32 elements through the thickness (4.4 million
elements of 3.2 mm, 32 minutes) peaks at 112 mm at 27 ms, as with 16, with a history within
6.9 mm of the measured one; 83 elements, cover below a wide flexural crack, are lost. **The
peak has converged at 112 mm**, 4% above the measurement. A narrower strip of the slab, 25 mm
wide, bends the same way at a thirtieth of the cost (`blastbench slab --strip 25 --layers
8,16,32`) and agrees: 105, 111 and 112 mm.

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
have converged too, 11% above the solid elements. They rebound about as little as the specimen
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
| None                                         | 105 mm (98%)    | 0               |
| Load 5% lower                                | 92 mm (85%)     | 0               |
| Load 5% higher                               | 120 mm (112%)   | 0               |
| Aggregate 10 mm instead of 16 mm             | 106 mm (98%)    | 0               |
| Crack spacing 50 mm instead of 100 mm        | 102 mm (94%)    | 0               |
| Crack spacing 200 mm                         | 106 mm (98%)    | 0               |
| Fracture energy halved                       | 106 mm (98%)    | 0               |
| Tensile strength 20% lower                   | 107 mm (99%)    | 0               |
| Cracks close fully (no residual opening)     | 106 mm (98%)    | 0               |
| Residual crack opening 30% instead of 10%    | 105 mm (98%)    | 0               |
| Crushing spread over at least 50 mm          | 105 mm (98%)    | 0               |
| Crushing averaged over 48 mm (nonlocal)      | 105 mm (98%)    | 0               |
| Supports as 1 in bearings, held down         | 84 mm (78%)     | 0               |
| Supports as 1 in bearings, free to lift      | 92 mm (85%)     | 0               |
| 16 elements through the thickness            | 112 mm (104%)   | 0               |
| Fixed UFC 3-340-02 factors, no rate laws     | 130 mm (120%)   | 67              |
| Static strengths                             | 368 mm, failing | 10,272          |

Reading this table:

- **The rate treatment decides the outcome.** The load is far above the slab's static
  capacity, so it survives only because steel and concrete are stronger when loaded quickly.
  With static strengths the model predicts failure. With the fixed design factors of
  UFC 3-340-02, which are deliberately conservative, it predicts 130 mm, 20% more than was
  measured, with some elements failing at the hinge: conservative, as intended. (Before bar
  rupture was judged over a debonded length, these factors gave a collapse.) The test is
  therefore a sharp check on the rate treatment, and a poor check on anything else.
- **A 5% change in load moves the peak by about 13%.** The hand-read pressure record could
  easily be 5% out in its shape, though its impulse is pinned.
- **No material assumption tips the slab into failure any more.** Earlier versions sat near a
  shear failure, which one assumption or another (a lower load, smaller aggregate, a wider
  crack spacing, 5% more load) would trigger, never the same one twice. Those failures went
  when the hourglass control was fixed, which suggests they were the zigzag modes, not shear.
- **The concrete's tensile properties barely matter** here, as expected for a slab whose
  resistance comes from its bars.
- **The supports matter by 15–20%.** The default is a pin and a roller on single lines of
  nodes. Bearings one inch wide lower the peak to 84–92 mm. The source does not
  describe the rig; [Data wanted](data-wanted.md) lists it.

### What this does and does not show

It shows that the model reproduces the flexural response of a lightly reinforced one-way slab
under a uniform dynamic load, including the influence of strain rate, to within about 7% at
the peak on meshes of 4 to 16 elements through the thickness, with the peak still rising
slowly as the mesh is refined. The rebound after the peak is too large on every mesh.

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
likeliest cause of the incident impulse's shortfall in the open, too. The digitised curve is in
`UFC340.swift`, read off the chart by hand.

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
as 25 kg on the mirror. Air cells and solid elements are 0.1 m (83,536 elements). The end wall,
the partition and the foundation are rigid. The chamfers are steps of elements, without their
diagonal bars. The other assumptions, and the geometry read off the paper's drawings, are
listed in `ChamberTest.swift`. `blastbench chamber` runs 300 ms in about 15 s;
`--charge-scale` scales the charges.

### Results

**Pressures.** At gauges placed near the sensors the model gives 4.3 and 6.8 MPa on the side
walls and 3.0 MPa on the roof, against 3.2 to 4.4 MPa measured. The gauge positions are
approximate, and peaks this close to a charge change sharply with position, so this check is
loose: the model is between 0.9 and 1.6 times the measured range.

**The roof.** At the test's charge the model's roof is torn from its walls and thrown: its
free edge is still rising at more than 2 m after 300 ms, against a residual of 95 mm. The
response has a cliff, as the paper's own model does, but the model's cliff comes at a smaller
charge:

| Charge, as a fraction of the test's | Model: peak / end of run | Paper's model (Table 7): peak / residual |
|-------------------------------------|--------------------------|------------------------------------------|
| 0.5 (100 kg)                        | 15 / 2 mm                | 22 / 17 mm                               |
| 0.625                               | 66 / 34 mm               |                                          |
| 0.75                                | 313 / 206 mm             |                                          |
| 0.875                               | Roof thrown              |                                          |
| 1 (200 kg)                          | Roof thrown              | 87 / 62 mm; measured residual 95 mm      |
| 1.5                                 |                          | 251 / 168 mm                             |
| 2                                   |                          | Roof thrown                              |

The model behaves like the paper's model with about 1.6 times the charge. Even so, the
measured structure was close to its own cliff: chamber B nearly lost its roof edge.

**What throws the roof.** Some variations narrow it down:

- **Not the removal of elements.** With removal switched off entirely, the roof edge still
  rose 293 mm in 60 ms, as fast as with it.
- **Not a mistake in stiffness.** With elastic concrete the edge swings only ±7 mm.
- **Not the mesh.** With 50 mm elements (about 670,000) the edge rises
  118, 374 and 746 mm at 30, 60 and 100 ms, against 127, 423 and 818 mm on 0.1 m elements.
- **The gas left behind by the shocks.** The roof gauge reads 200 to 500 kPa from 10 ms to
  past 60 ms while the gas vents through the strip, and a hand estimate of the roof's
  yield-line resistance is 250 to 350 kPa. Once yielded, the roof is pushed for as long as the
  gas lasts, and nothing stops it. The model's gas pressure is if anything low (at this
  room's 0.58 kg/m³, below the design manual's in the previous section), so the load is
  unlikely to be too high.

The chamfers matter: without them the cliff came between 0.5 and 0.75 of the charge. That
points to the joints, which the paper also found decisive. Its chamber A's joints were
shattered but held together by bars that "did not break", and its parametric roof with
14 mm bars instead of 16 mm deflects 58% more. The likeliest causes of the model's weakness,
in order:

1. **The joints' detailing**: no diagonal bars across the chamfers, and mats smeared over a
   band one element thick instead of lying 50 mm from the face.
2. **Rigid end wall, partition and foundation**, held as fixed nodes. Elements beside fixed
   nodes fail early (failures gather along the line where the side walls meet the partition).
3. **What the model leaves out of the load path**: the steel sleeves, which take some of the
   charges' energy and were modelled by the paper, and any compressive membrane action that
   the rigid supports or the walls' flexibility misrepresent.

### What this does and does not show

The model reproduces the kind of failure seen (the roof yielding at the joints under the
lingering gas pressure, with damage concentrated at the supports) and a response with a
cliff, but it puts the cliff between 0.75 and 0.875 of the charge, where the test and the
paper's model put it beyond 1. Against this test the structural model is on the weak side by
a factor of about 1.6 on the charge, which near a cliff means its deflections can be wrong by
an order of magnitude. Peak wall pressures are within the loose check that the gauge
positions allow.

## Consistency across air grids

The 3 m reinforced cantilever wall, 6 m from the charge, coupled to the air solver:

| Charge | 0.5 m cells                | 0.25 m cells       | 0.125 m cells      |
|--------|----------------------------|--------------------|--------------------|
| 50 kg  | 16 mm deflection at 0.1 s  | 28 mm              | 37 mm              |
| 200 kg | Sheared off at its base    | Sheared off        | Sheared off        |

![The wall toppling after 200 kg sheared it off at its base](wall-toppling.png)

The qualitative outcome is the same on every grid. The deflection at 50 kg has not converged:
it grows with resolution as the peak pressure does, although the impulse on the wall changes
little. There is no test to compare these with.

## Verification against theory

The test suite has 98 tests. The physical checks are:

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
| Fully restrained compression                    | Peak at 5.1 f_c within 3% (confinement)        |
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

1. Why the chamber's roof is too weak: the joints' detailing first (see
   [above](#an-internal-explosion-in-a-reinforced-concrete-chamber)).
2. A second and third structural test, of different kinds (see the
   [concrete model's future work](concrete-model.md#future-work)).
3. Afterburning in the charge model, checked against the gas pressures of UFC 3-340-02 and the
   incident impulse of Kingery–Bulmash; then the vented gas impulse of UFC 3-340-02
   (Figures 2-153 to 2-164), which would need digitising.
4. Blast loads closer in than 0.75 m/kg^(1/3).
5. Any test of collapse or debris.
