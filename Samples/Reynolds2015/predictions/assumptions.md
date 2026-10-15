# Blind test 3: the predictor's assumptions

Declared and committed before the first run, under [the protocol](../../../docs/blind-tests.md#test-3-high-strength-slabs-in-the-blast-load-simulator-reynolds-2015).
Changes after any run are logged at the end, numbered, each with its reason.

## What the predictor read

- `Samples/Reynolds2015/README.md`, `FROZEN`, and everything in `Samples/Reynolds2015/inputs/`
  (`slabs.json`, `loads.csv`, `digitise/`).
- `docs/blind-tests.md`: Roles, Rules and Test 3 (and the register's rows).
- Of `docs/validation.md`, only what the inputs point to: the contest slab's "The test" and
  "The model" (its table of properties and how it is meshed and held), and the paragraph and
  table on "The span" with the rows above it in the disagreements table (bars' yield, concrete,
  load, span). Nothing else of the contest slab's sections, nor anything of Schwer's.
- Code: `SlabBenchmark.swift` (the contest slab's harness, which this one copies), the contest
  slab's ensemble case and the solid slab's band in `ValidationEnsemble.swift` and
  `ErrorBands.swift`, the material and reinforcement code in `StructureTypes.swift`, and test 1's
  and 2's harnesses and predictions (`Samples/Hrynyk2013/predictions/assumptions.md`'s steel
  paragraph, `Samples/Mendonca2020/predictions/README.md`) for the form of the deliverables.
- Nothing under `/Volumes/StudioData/bombcad/blind/` was listed or opened; nothing about the
  test was searched for on the web. The working folder is
  `/Volumes/StudioData/bombcad/reynolds-prediction/`.

## Model and defaults

The frozen commit is `b524a9d` (v0.3.0, build 7). The harness was written on origin/main at
`f1d5e6a`, whose `Sources/` differ from `b524a9d` only in the standing's text
(`ErrorBands.swift` and `EvidentialStanding.swift`: wording of bands' validity and evidence, no
material, solver or default); `git diff b524a9d f1d5e6a -- Sources Packages Package.swift
Package.resolved` shows it. Every material law, solver setting and default is the frozen
commit's: the solid elements' concrete with the strain-rate laws (`rateDependent`, the default
for reinforced concrete) and the 100 µs strain-rate window, default crack spacing (100 mm),
aggregate size (16 mm), bond spreading and removal rules. No option is turned on or off. The
recommended air (afterburning, hot air, far-field faces) and terrain cut cells do not enter: as
in the contest slab's harness, the simulator's measured reflected pressure is applied to the
slab's face and no air is computed.

**Harness:** `Sources/BlastCore/ReynoldsSlabTest.swift` and `Sources/blastbench/ReynoldsBench.swift`
(`blastbench reynolds`), with two dispatch lines in `Sources/blastbench/main.swift`. It copies
`SlabBenchmark.run` (the contest slab's) for the mesh, supports and load application, and takes
the concrete, bars and load from the inputs as below.

## Choices the inputs leave open

1. **Width: 33.75 in (857 mm).** Figs 3 and 4 draw the slab itself 33.75 in wide, and the
   frame's side plates are 33.75 in apart; the text's 36 in is a round figure and Schwer's
   37.75 in is for the contest's slabs, not these. It is also the calibrated contest slab's
   width in the record, so the rig is held exactly. (Under a uniform load on a one-way slab the
   width matters only through the bars per unit width; see 4.)
2. **Span: supports 52 in (1321 mm) apart, as lines of nodes**, the contest slab's harness
   unchanged: a pin and a roller on the unloaded face, each a line of nodes across the width, held
   against moving towards and away from the blast. Figs 5 and 6 put the back tubes' inner edges
   6 in from each end, 52 in clear. The text's 58 in "center-to-center" reads as the centres of the
   6 in of each tube the slab bears on (3 in from each end, 64 − 6 = 58), but a slab bending
   under load rotates onto the bearings' inner edges, so the span that bends is the clear 52 in.
   The record reached the same reading for the contest slab in this fixture (photographs, crack
   positions), and the band's derived mesh holds the slab this way. Holding both lines against
   moving away from the blast stands for the front HSS tubes that stop the slab rebounding.
3. **Bearings: lines of nodes** (as 2), not the honeycomb pad or the tubes' width, as the
   contest slab's harness and band. The cardboard honeycomb is left out (its stiffness is not
   given).
4. **Bars along the span: nine No. 3 at 4 in (HSCV1–3), five at 8 in (HSCV4–6)**, smeared
   across the 33.75 in width: 0.745 and 0.414 mm² per mm. Fig 3's dimension chain read from the
   slab's edge (3/4, 2, six of 4, 2 in) places bars at 0.75, 2.75, 6.75, … 26.75 and 28.75 in:
   nine bars, the same count as the record's contest slab (nine at 4 in, Kewaisy's drawing of
   what the inputs call the same layout). Fig 4's (3/4, 6, 8, 8, 6 in) places five, at 0.75,
   6.75, 14.75, 22.75 and 28.75 in. The chains' last 2.875 in leaves them 2.125 in short of the
   width, which changes no count. The thesis's 0.69% and 0.35% are 71 mm² over the nominal
   spacing times the gross 4 in depth (71/(101.6 × 101.6) = 0.69%), a nominal ratio, not a count;
   at the nominal spacing the slab would carry 8.4 and 4.2 bars (secondary run 3).
5. **Which bars lie nearer the face: the cross bars.** The main bars' centres are 1/2 in clear
   cover + one cross bar (0.375 in) + half a bar (0.1875 in) = **1.0625 in (27.0 mm)** from the
   face away from the blast. The contest slab, by the same group in the same layout, had its main
   bars 1 in from that face (the record's table), which only this order matches; the other
   order (main bars outermost, 0.6875 in) is secondary run 2.
6. **Cross bars:** No. 3 smeared at 12 in (71 mm² per 12 in), in the same band, as the contest
   slab's harness (the first 8 in from each end then 12 in apart puts five across 64 in).
7. **Concrete: fc = 108.6 MPa (15,757 psi), the 56-day cylinders**, the latest measured and the
   nearest to the design 15 ksi. The slabs' age at test is not stated; a shock-tube series is
   rarely shot within two months of casting, and high-strength mixes gain little after 56 days,
   so the latest measurement is taken as the strength on the day. Its stiffness, tensile strength
   and fracture energy follow the model's default correlations: E = 4700√fc = 49.0 GPa (the
   thesis's own SDOF assumption was 48.1 GPa), ft = 0.3 fc^(2/3) = 6.8 MPa, Gf = 73 fc^0.18 =
   170 N/m, crushing energy 250 Gf. **Density 2,454 kg/m³**, the 56-day cylinders' (the model's
   default is 2,400). The 28-day strength is the ensemble's low end (see below).
8. **Steel: yield 572.3 MPa (83 ksi) as tested.** Ultimate, the strain at it and elongation are
   not given. 83 ksi exceeds Grade 75 and suits ASTM A615 Grade 80, whose specified minimum
   tensile strength is 105 ksi; the companions' bars are called Grade 60, so these are the higher
   grade. **Ultimate 724 MPa (105 ksi, fu/fy 1.27) at 7% plastic strain, rupture at 9.1% plastic
   strain** (1.3 times the strain at ultimate, test 1's ratio of fracture to uniform elongation;
   A615 Grade 80's minimum elongation for No. 3 is 7%). Linear hardening from yield to ultimate
   (the model's curve when no measured curve is given); modulus 200 GPa; the bars' default
   strain-rate law.
9. **Load: the digitised average reflected pressure of `loads.csv`, as read, then falling
   linearly from its last point to zero so that the whole carries Table 1's average impulse.**
   Applied uniformly to the whole blast face from t = 0 (the load's arrival: each trace starts at
   0 at t = 0 and rises within the first millisecond). Why this and not the others:
   - The traces' peaks match Table 1's (HSCV1/2 341 kPa against 343 and 339; the others 3–8%
     lower, the 1 ms markers missing the sharpest point), so their shape and level are right
     as read and are not scaled.
   - The figures' own impulse curves end (at 54–58 ms) below Table 1's averages by 49, 73, 19,
     7, 2 and 4 psi ms (`slabs.json`), and those shortfalls follow the pressure still acting at
     the figures' ends (5.8 psi on HSCV1/2, 2.2 on HSCV3, 2.1 on HSCV4, 0.5 on HSCV5 and 6): a
     tail cut off by the figures' time axis, not a lower level. So the missing impulse is put
     after the trace, where the figures stop.
   - Tables 6 and 7 are coarse (10 ms) and integrate as the traces do; they are not used.
   - Applied over the whole face as the contest slab's harness applies its record, though Fig 5's
     front tubes cover the 6 in at each end; the harness cannot load part of a face, and this
     is what the calibrated record did.

   The loads as applied (peak; impulse; zero at):

   | Slab | Trace | Peak (kPa) | Trace impulse (kPa ms) | Tail added (kPa ms) | Zero at (ms) |
   |---|---|---|---|---|---|
   | HSCV1 | HSCV1 and HSCV2 (Fig 9, one trace) | 341.3 | 6,541 | 445 | 76.3 |
   | HSCV2 | the same | 341.3 | 6,541 | 337 | 70.8 |
   | HSCV3 | HSCV3 | 263.0 | 5,063 | 273 | 90.1 |
   | HSCV4 | HSCV4 | 261.8 | 5,084 | 114 | 73.5 |
   | HSCV5 | HSCV5 | 206.2 | 3,497 | 31 | 77.3 |
   | HSCV6 | HSCV6 | 228.1 | 3,862 | 110 | 128.9 |

   HSCV1 and HSCV2 share the trace (the inputs give one for both), so they differ only after
   54 ms; their peaks will be nearly the same. No negative phase is applied (not given).
10. **Gravity ignored**, the slab standing upright, as the contest slab's harness.
11. **Mesh: cubic elements 12.7 mm, 8 through the 4 in thickness** (128 along, 68 across with the
    last row partly unused), the contest slab's and its band's derived mesh ("calibrated on 8").

## The primary prediction

`blastbench reynolds --time 0.3` on all six slabs with the settings above, each run **300 ms**
from the load's arrival, sampled every 0.1 ms.

**Declared quantities**, for each slab:

1. **Peak deflection** of the centre of the face away from the blast (the node at mid-length
   and mid-width of the unloaded face, displacement away from the blast positive), in mm, and
   its time in ms from the load's arrival (t = 0).
2. **Residual deflection:** that point's mean displacement over the run's last 50 ms (250–300 ms),
   with its range over those 50 ms reported to show whether the slab is at rest.
3. **Fails or holds:** fails if intact concrete (active, cracked less than 1 mm, test 2's rule)
   no longer joins the elements beside the two supports face to face (it breaks through), or
   any bar element ruptures. The supports hold both ways, so the slab cannot leave them in the
   primary; in the ensemble's bearing samples it may lift, which is reported.
4. **Damage:** blast face crushed (elements of that face past 0.0035 plastic strain: area and
   extent along the span), spalled (removed or bare); the back face's crack field and its main
   cracks (local maxima of the crack opening averaged across the width, above 0.1 mm, with their
   positions from mid-span), scabbing; images of both faces' crack fields
   (`histories/HSCVn-back.png`, `-blast.png`) and the solver's symbol plans.

Also committed: each centre's displacement history (0–300 ms, every 0.1 ms) as CSV, the load as
applied, and the uncertainty of quantity 1 from the ensemble below.

## Uncertainty of quantity 1: the predictor's ensemble

Eight Latin-hypercube samples (seed 3) of these inputs, each slab run 150 ms, on the primary's
mesh; the smallest and largest peak of the eight, as ratios to the ensemble's own median, are
reported as the uncertainty (the primary is not one of the samples):

| Input | Spread | Why |
|---|---|---|
| fc | uniform 92.9–115 MPa (E, ft, Gf following) | the age at test is not stated: from the 28-day cylinders to 6% above the 56-day |
| ft | log-normal, 18% about 0.3 fc^(2/3) | not measured; the ensembles' Model Code spread |
| Gf | log-normal, 30% | the ensembles' |
| fy | normal, 3% | tested; the ensembles' coupons |
| fu | uniform 0.9–1.15 × 724 MPa | not given: 1.14–1.45 times yield |
| load | normal, 3% | digitised to about 0.5 psi; the figures' impulse curves 1–3% from the traces |
| supports | lines of nodes or 1 in bearings free to lift, equally | as the contest slab's ensemble |
| main bars' depth | uniform 0.6875–1.0625 in | which bars lie nearer the face is not stated |
| main bars' area | uniform 0.84–1 × the drawn count | the drawn count against the nominal spacing |

## Secondary runs (reported, not scored)

Each on all six slabs, 150 ms unless stated, changing one choice:

1. **The load scaled to Table 1's impulse** (`--load scaled`): the trace, then to zero at 60 ms
   as Tables 6 and 7 end, the whole scaled by 1.008–1.049, as the record scaled the contest's
   record to its stated impulse.
2. **Main bars outermost** (`--bar-depth 0.6875`).
3. **Bars by the nominal spacing** (`--nominal-bars`): 71 mm² per 4 in or 8 in of width.
4. **Span 58 in** (`--span 58`), the text's figure taken as the supports' lines.
5. **16 elements through** (`--layers 16`) on HSCV1 and HSCV4 only, if the machines allow: the
   band's mesh range reaches 32; this checks the mesh, not the prediction.

## Changes after running

(none yet)
