# Blind test 2: the predictor's assumptions

Written and committed before the first run of the test, as [the protocol](../../../docs/blind-tests.md)
asks (rule 3). Frozen commit: `047cee3ccb0b232ee6a496b492174f94fd2e91b5`. The harness is
`Sources/BlastCore/MendoncaSlabTest.swift` and `Sources/blastbench/MendoncaBench.swift`
(`blastbench mendonca`), added in `26e9a75` on top of origin/main at `3a950ac`, which differs
from the frozen commit only in another `blastbench` subcommand and documents (no model code,
material or default). It reads `Samples/Mendonca2020/inputs/slabs.json` itself, so that the
numbers given there as numbers come from the inputs as written; those given only in words are
quoted in the harness where they are set.

## What the predictor has and has not read

- Read: `docs/blind-tests.md` in full (including the register's one-line result of test 1, which
  it could not help seeing there); `Samples/Mendonca2020/README.md`, `inputs/slabs.json` and
  `SEALED.sha256` (its hash lines); `docs/roadmap.md`'s pointer to this test; in
  `docs/validation.md` the sections on slabs with steel in both faces (Wu, Wang), the model of
  the close-in slabs (Chiquito), the contest slab's test, model and first results, and
  convergence on today's defaults; test 1's predictor's `assumptions.md`, as a model of the form
  (written before test 1's reveal); BombCAD's code (the open-air slab benches, the blast and
  structure solvers' API and defaults, the regime defaults, the standing's model options and
  error bands, the ensemble helpers).
- Not read or listed: anything under `/Volumes/StudioData/bombcad/blind/`, the source's papers
  (2018, 2020, 2021) or their abstracts, the Dataverse records, any copy of the test's data,
  anyone's simulation of these slabs; no web search. Test 1's reveal
  (`Samples/Hrynyk2013/reveal/`) and its section of the validation record were not opened. No
  other session's transcript was read. This session's memory index, shown to it automatically,
  has one-line entries naming this test's frozen commit and that its data are sealed; no memory
  note about this test was opened, and those lines hold no result.

## The model

**Defaults throughout.** No model option is turned on or off (rule 1). The concrete carries
`rateDependent = true`, as the app's reinforced concrete preset and every calibrated slab bench
do (the standing counts *rate-independent* as the option); the regime the solver detects for
every slab is the far field (the nearest point of the slab 0.93–1.46 m/kg^(1/3) from the
charge) and the loading impulsive, which set their own defaults. Bars perfectly bonded and
smeared; contact after failure; gravity on; the air an ideal gas with no afterburning,
**unrefined (shock refinement is an option) and started from the default sphere of hot gas
(the mapped start is an option)**; coupled both ways with moving walls.

**Mesh: 8 solid elements through the 80 mm (10 mm cubes, 100 × 100 × 8 = 80,000 elements).**
The calibrated open-air slabs were compared on 8 through (Wu's slabs, the contest slab); 8
divides the 1.0 m plan and the thickness exactly and puts the slab's centre on a node.

**Air: uniform 12.5 mm cells, 240 × 240 × 256 (14.7 million) over 3.0 × 3.0 × 3.2 m**, the
ground at z = 0 reflecting (the default), the other faces open. 12.5 mm is the fine cell of the
calibrated open-air slabs' air (25 mm refined by 2), here everywhere; about 0.009 m/kg^(1/3).
The slab spans x and y from 1.0 to 2.0 m, so the open faces are 1 m from its edges.

**Run: 200 ms**, sampled every 0.1 ms, from the charge's detonation; at least the protocol's
100 ms, and long enough for a slab broken through to drop visibly.

**The slab**: 1.0 × 1.0 × 0.080 m, its bottom face 0.40 m above the ground (the trestles'
height). Density from the slab's mass where the inputs give it: slab 2 180 kg, 2,250 kg/m³;
slab 5 175 kg, 2,188 kg/m³; **the others, not given, 2,219 kg/m³, the mean of the two** (cast in
the same forms). The bars' mass is in these.

**Concrete**: the tested strengths, 42, 53 and 62 MPa, as the compressive strength. **Tensile
strength, modulus, fracture and crushing energy from the model's own correlations with it**
(0.3 fc^(2/3), 4,700 √fc, 73 fc^0.18; not measured; the 2021 paper's analyses' 10% of fc is a
choice of theirs, not a measurement, and the default stands); aggregate 16 mm (the default; not
stated); Poisson's ratio 0.2.

**Bars**: one mat, smeared through a band one element (10 mm) deep **centred 25 mm above the
bottom face** ("2.5 cm from the bottom face to the bars' level"), both directions in the one
band. The 5 mm mesh at 7 bars a metre (15 cm; 137 mm²/m) for layouts A and C and 10 a metre
(10 cm; 196 mm²/m) for B. **Slab A's two 10 mm bars: 100 mm apart about the slab's centre line,
smeared over a strip 200 mm wide** (each over its 10 cm, which reconciles "two bars side by
side" with Table 1's "10 mm at 10 cm"), **running along the span in the primary prediction**:
a designer adding two bars one way would put them where the slab bends. Steel: **yield 350
MPa, the stated estimate**; not given beyond it, so the ultimate, the strain at it and the
rupture strain are the model's typical 500 MPa bar's (`SteelProperties.grade500`) scaled to it:
ultimate 1.15 × 350 = 402.5 MPa at 7.5% plastic strain, rupture at 12%; modulus 200 GPa; the
bars' strain-rate law the default.

**Supports**: each trestle's timber taken as **100 mm wide** under each supported edge, **flush
with the slab's edge** (clear span 0.80 m, bearings' centres 0.90 m apart), **0.80 m long (the
trestle's length) centred on the edge**, so the slab's last 0.1 m at either end of each
supported edge overhangs. The bottom face's nodes over the timber rest on it (pushed up, free
to lift off); the line of them along the near bearing's middle is held along the span and the
middle node of each bearing's middle line across it (a pin and a roller, as the contest slab).
Nothing holds the slab down. In the air, each trestle's top rail is a rigid block 100 mm wide,
100 mm deep and 0.8 m long under its bearing; the trestles' legs (open frames) are left out of
the air, as is **the steel box under the slab's centre (its size not given)**. The clay is the
model's rigid ground.

**The charge**: TNT of each slab's stated equivalent (2.58–2.76 kg), a sphere, **its centre
the stated stand-off (1.3, 1.6 or 2.0 m) above the slab's top face**, over its centre. The
inputs' scaled distances are the stand-off over the cube root of the mass, which is the
convention for the distance to the charge's centre. The cylinder's shape and its firing from
the top (which throw more of the blast downwards than a sphere does) are not represented; that
is the model's spherical charge, not a choice.

**Gauges** (quantity 4): in the air against the slab's top face (5 mm above it; the cell
against the surface), **50 mm in from both edges at each corner**, and at the centre. Named as
the inputs' sketch with its rows along the supported edges: 6, 7 (mid-side), 4 over the far
support (x high), 2 and 8 at mid-span, 3, 5, 1 over the near support (x low), y rising from 6
to 4. The four mid-sides, on the surface 50 mm in, and one under the centre of the bottom face
are recorded too, not as predictions (the mid-side gauges' heights are not given).

## The outputs, as the harness measures them

1. **Collapse**: judged at the end of the run. An element is *broken* if it is removed, left as
   bare bars, or has cracked open by **1 mm** or more (its largest crack strain reached times
   10 mm). The slab **collapses if no path of unbroken elements, face to face, joins the
   concrete over one bearing to that over the other**: it has broken through its thickness
   right across. It survives otherwise. Also recorded, as description, not the criterion:
   whether the mat's unruptured bars still join the bearings, how many pieces (face-joined
   elements, at least 10) the slab is left in, and the centre's final sag.
2. **Peak displacement**: the largest downward displacement of the bottom face's centre node
   (the lowest node there still held by an element) in the 200 ms, from where it started.
3. **End displacement**: that node's displacement averaged over the last 10 ms of the run (and
   its last value, recorded).
4. **Pressure**: each gauge's peak overpressure, and its positive impulse over the first
   positive phase (from arrival, the first 2 kPa, until the overpressure first falls below
   zero); also the impulse of all the positive overpressure in the run, recorded.
5. **Damage**: maps of each face's crack opening by element (PNG and the solver's crack symbols
   as text); the areas of the top face removed or bare (spalled), crushed past 0.0035 strain,
   and of the bottom face removed or bare (scabbed); words written from these.

Histories: the centre's displacement 0–200 ms every 0.1 ms, and every gauge's overpressure
0–30 ms every 0.01 ms, as CSV.

## Secondary runs (reported, not scored)

1. **The calibrated record's air**: 25 mm cells refined by 2 near the shock with the mapped
   start (two model options on, as Wu's open-air slabs ran), all seven slabs: how much the air's
   settings move the answer.
2. **16 elements through** (5 mm cubes), the primary's air, all seven slabs if each run takes
   under about three hours; otherwise slabs 1, 2 and 4 (one per group).
3. **Slab A's other layout**, the two 10 mm bars across the span: slabs 2 and 5.
4. **The stand-off to the cylinder's bottom face** (the charge's centre 0.1 m higher), all seven.
5. **The model's spread over its uncertain inputs**: a Latin hypercube of 8 samples (seed 1) on
   slabs 1, 2 and 4, one per group, on the primary's mesh and air: fc ±5% (normal), ft × (1 ±
   15%) (log-normal), fracture energy × (1 ± 30%) (log-normal, the ensembles' own), yield 0.85
   to 1.6 times 350 MPa (uniform: 300 to 560 MPa, as CA-50 or CA-60 bars may have been), TNT
   equivalence ± 10% (normal), the charge's centre 0 to 0.1 m above the stand-off (uniform),
   and the bearing 50 to 150 mm wide (uniform). Sample 0 is the primary itself. **The
   uncertainty of quantity 2** is the smallest and largest of the samples' peaks as ratios to
   the primary's, applied to each slab of the group (slab 1's to slabs 1 and 10, slab 2's to 2
   and 5, slab 4's to 4, 7 and 9); how many samples collapse is reported too.

If time runs short, run 2 is cut to fewer slabs first and run 5 to fewer samples second, and
that is said.

Nothing in these assumptions will be changed after a run to bring a result towards what the
test may have given. If a run shows a harness error (a value contradicting the inputs, or a
crash), the fix and its reason will be added below, numbered and dated, before the predictions
are committed.

## Changes after the first run

**1. 2026-10-12, after a 20 ms smoke run (slab 4, the primary's settings, on the Studio): the
gauges follow the slab's face.** The gauges were fixed points in the air 5 mm above the top
face. Over the bearings the slab's edges rotate up by a millimetre or so as it bends, the face
passed the gauge cells' centres, those cells turned solid, and the gauges went on reading their
frozen state: the four corner gauges and the two mid-side gauges over the supports held 340 and
1,130 kPa from 1.6 ms to the end, giving positive impulses of 6,400 to 21,000 kPa ms, where
the gauges at mid-span read normally. The test's gauges sat on the slab and moved with it, so
this is a harness error against the inputs. From now on, between every batch of air steps
while the air is awake, each gauge reads the first air cell beyond the slab's face at its point
as the face is now (the cell is moved and its history kept). Nothing else changed. The smoke
run's peaks (reached before the freezing) and its displacements are kept in the predictor's
folder and are not the prediction. The same run showed the slab lifting off its trestles after
its first downward peak (the air under its centre peaking at 0.85 MPa, the ground's
reflection), which the inputs allow (not tied down) and which is left as it is.

**2. 2026-10-12, after the first full secondary run (slab 4 on the calibrated record's air, 200
ms, on the mini), before any primary run had started: every run is 500 ms.** That run's slab
peaked 4.3 mm down at 3.9 ms, then the air beneath it threw it off its trestles at about 0.9 m/s:
its centre rose 44 mm by 100 ms and was still coming down, 1 mm above where it started, at
200 ms. The protocol asks for each run to go on until the slab has come to rest, which at 200
ms it had not, so the declared 200 ms was too short for the inputs' unrestrained slab. Runs
are now 500 ms, by when a slab thrown up this far has landed and settled (the air has gone to
sleep by about 80 ms, so the extra time is cheap); the end displacement is still the mean over
the last 10 ms. Nothing else changed. The 200 ms run is kept in the predictor's folder and is
not reported.

**3. 2026-10-12 20:45, before any of these runs: secondary runs 3, 4 and 5 on the calibrated
record's air, on the CI mini.** The Studio's GPU is shared by other sessions and gives this
work one slot at a time (a primary run takes about 17 minutes there), and the mini takes about
seven times as long on the primary's 14.7 million uniform cells but about 19 minutes a slab on
25 mm cells refined by 2. So slab A's other layout (3), the higher charge (4) and the ensemble
(5) are run on that air (secondary run 1's settings), and each is compared with secondary run
1's slab on the same air: the ensemble's sample 0 is secondary run 1's run, and its spread, as
ratios to that, is applied to the primary's peaks as declared. The primary runs and the
16-element runs stay on the Studio with the primary's air. No result of these runs had been
seen; the reason is time alone.

**4. 2026-10-12 21:05, after the primary runs of slabs 5 and 7 and secondary run 1's slab 4:
a sixth secondary run, timber bearings; the primary unchanged.** In those runs the slab is
thrown up off its trestles by the air beneath it (35 to 50 mm, at about 1 m/s) and lands on them
at 190 to 225 ms, and the landing, not the blast, makes the largest downward displacement and
what is left: slab 5 13.2 mm (10.9 left), slab 7 22.8 mm (20.8 left), slab 4 on the calibrated
air 7.1 mm (6.3 left), where the blast's own first peak was about 4 mm. The supports are rigid
in the model, so the bearing lines stop dead as the slab lands, which a slab on timber trestles
on clay would not. That was a declared assumption and does not contradict the inputs, so the
primary prediction keeps it and its declared quantities (the largest downward displacement in
the run and the mean of its last 10 ms); the README reports the blast's first peak beside it as
description. **Secondary run 6** gives the bearings compliance: each trestle's top rail
(100 mm wide, 100 mm deep, 0.8 m long, as in the air) is elastic softwood loaded across its grain
(EN 338 C24: mean modulus perpendicular to the grain 370 MPa, mean density 420 kg/m³), bonded
under the slab and resting on its supports in the slab's place, so slab and rails lift off and
land together; the rigid rails leave the air, the rails being in it as part of the structure.
All seven slabs, on the Studio, on the primary's mesh and air, after the primary runs and before
the 16-element runs. It is reported, not scored.
