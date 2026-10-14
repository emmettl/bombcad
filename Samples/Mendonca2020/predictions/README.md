# Blind test 2: the predictions

The predictor's predictions for [blind test 2](../../../docs/blind-tests.md#test-2-slabs-under-an-open-air-charge-mendonça-et-al)
(Mendonça et al. 2020: slabs 1, 2, 4, 5, 7, 9 and 10 under an open-air charge), made from
`Samples/Mendonca2020/inputs/` alone, on the frozen commit's model and defaults. Nothing here
has been compared with any measurement; the predictor has not seen one.

- **Frozen commit:** `047cee3ccb0b232ee6a496b492174f94fd2e91b5`.
- **Harness:** `Sources/BlastCore/MendoncaSlabTest.swift` and `Sources/blastbench/MendoncaBench.swift`
  (`blastbench mendonca`), added in `26e9a75` on origin/main at `3a950ac` (which differs from the
  frozen commit only in another `blastbench` subcommand and documents). **The primary runs used
  the harness at `c5721b2`** (`26e9a75` plus change 1). Later harness commits add only options
  for secondary runs, each off by default (`e8d594e` timber bearings; `7a49dee` the flight's
  histories and `--awake`). No material, model or default was changed.
- **Commit hashes after the rebase onto main.** The hashes above, and those in the assumptions,
  are the commits the runs were made with, on top of `3a950ac`, whose model is the frozen
  commit's. To push, the branch was rebased onto origin/main, which by then had changed the model
  (the strain-rate window, among others); the predictions were not re-run on it. As rebased:
  `1957cc3` → `a258e45` (FROZEN), `26e9a75` → `9da8b90` (harness), `c298d6b` → `efc6fc6`
  (assumptions), `c5721b2` → `e512afb` (the primary's harness), `e8d594e` → `d1a0abf`, `7a49dee`
  → `339a461`. The harness files and `Samples/Mendonca2020` are byte for byte the same in each pair
  (`git diff` of each pair over them is empty). To reproduce the runs, check out `047cee3` and
  add the two harness files from `e512afb` (or `339a461`) and the two dispatch lines in
  `Sources/blastbench/main.swift`.
- **Assumptions**, declared and committed before the first run (`c298d6b`), with five changes
  since, each dated with its reason, and the interruptions: [assumptions.md](assumptions.md).
- **Run:** `blastbench mendonca --time 0.5` (all seven slabs, 8 elements through, 12.5 mm air);
  the secondary runs' flags are in the assumptions. Raw outputs are kept in the predictor's
  folder, `/Volumes/StudioData/bombcad/mendonca-prediction/`.
- **Files:** `predictions.json` (everything below, per slab and per run, with every gauge),
  `predictions.csv` (the primary, a row a slab), `secondary.csv` (the secondary runs), and per
  slab in `histories/`: the bottom face's centre `slabN-displacement.csv` (0–500 ms every
  0.1 ms, down positive), every gauge's overpressure `slabN-pressure.csv` (0–30 ms every
  0.01 ms), each face's crack field `slabN-bottom.png` and `slabN-top.png` (four pixels an
  element, x along the span to the right and y up the image; white uncracked, black a 1 mm
  opening, red removed, orange bare bars) and as the solver's symbols `slabN-cracks.txt`. All
  are listed in `SHA256SUMS`.

## The predictions (primary)

Units: mm, ms, kPa, kPa ms. Displacements are of the bottom face's centre, from where it
started, down positive. Each slab was run for 500 ms.

| Slab | Layout | Charge | Stand-off | 1. Outcome | 2. Peak down (at) | 3. End (last 10 ms) | 2. uncertainty (declared) |
|---|---|---|---|---|---|---|---|
| 1 | C | 2.76 kg | 1.3 m | **survives** | **10.94** (160 ms) | **8.27** | 5.7–12.7 |
| 10 | C | 2.60 kg | 1.6 m | **survives** | **14.71** (164 ms) | **14.11** | 7.7–17.1 |
| 2 | A | 2.72 kg | 2.0 m | **survives** | **11.67** (191 ms) | **9.44** | 5.7–24.2 |
| 5 | A | 2.58 kg | 2.0 m | **survives** | **13.23** (192 ms) | **11.00** | 6.4–27.4 |
| 4 | B | 2.69 kg | 2.0 m | **survives** | **25.11** (189 ms) | **23.21** | 18.7–79.1 |
| 7 | B | 2.60 kg | 2.0 m | **survives** | **22.77** (224 ms) | **20.76** | 16.9–71.7 |
| 9 | B | 2.72 kg | 2.0 m | **survives** | **21.80** (189 ms) | **20.05** | 16.2–68.6 |

Repeat groups' means of quantity 2: **A (2, 5) 12.45 mm; B (4, 7, 9) 23.23 mm.** (Slabs 1 and 10
share a layout but not a stand-off, so they are not a repeat.)

**Quantity 4**, the gauges in the air against the top face, 50 mm in from both edges at the
corners (the dataset's 1, 3, 4, 6) and at the centre; peak overpressure / positive impulse of
the first positive phase. The corners agree within 1–3% of one another, the slab and charge being
symmetric:

| Slab | Corner 1 | Corner 3 | Corner 4 | Corner 6 | Centre | Arrival, corner / centre |
|---|---|---|---|---|---|---|
| 1 | 3925 / 494 | 3932 / 493 | 3990 / 500 | 4049 / 502 | 5393 / 787 | 0.75 / 0.62 ms |
| 10 | 2157 / 366 | 2152 / 366 | 2157 / 368 | 2172 / 369 | 2752 / 586 | 1.07 / 0.93 ms |
| 2 | 1239 / 281 | 1234 / 281 | 1236 / 282 | 1236 / 282 | 1464 / 477 | 1.54 / 1.41 ms |
| 5 | 1167 / 270 | 1169 / 270 | 1175 / 271 | 1173 / 271 | 1385 / 459 | 1.57 / 1.43 ms |
| 4 | 1236 / 279 | 1233 / 279 | 1239 / 281 | 1236 / 281 | 1445 / 473 | 1.55 / 1.41 ms |
| 7 | 1195 / 272 | 1206 / 272 | 1199 / 273 | 1193 / 273 | 1396 / 462 | 1.56 / 1.43 ms |
| 9 | 1246 / 281 | 1240 / 281 | 1249 / 283 | 1247 / 283 | 1464 / 477 | 1.54 / 1.41 ms |

The impulse of all the positive overpressure in the run, the mid-side gauges and a gauge under
the slab's centre are in `predictions.json`. On the calibrated record's air (secondary run 1)
the peaks are 20–32% lower and the impulses 4–18% lower.

**Quantity 5, the damage.** No slab collapses: in every one, unbroken concrete still joins the
two bearings, no element is removed or left as bare bars, and no bar ruptures. **Bottom face:**
cracks parallel to the supports right across the width, banded about mid-span and fanning faintly
towards the corners (widest 4.0 mm on slab 1, 3.2 mm on slab 10, 2.1–5.9 mm on the 2.0 m slabs),
and one straight crack along the near bearing's held line (where the harness pins the slab, not
a prediction). **Top face:** cracks over the bearings' inner edges, parallel to them (0.4–3.2 mm),
and on slab 5 one along the span at mid-width (7.9 mm). **No crushing** (no top-face element past
0.0035 strain), **no spalling** of the top face and **no scabbing** of the bottom. On the 2.0 and
1.6 m slabs most of this cracking comes from the landing described below.

## What drives quantities 2 and 3: read this before scoring them

The runs give, for every slab, a sequence the declared quantities do not show on their own:

1. **The blast** bends the slab down to a first peak within 3–8 ms: **3.6–4.4 mm on the 2.0 m
   slabs, 5.9 mm on slab 10 (1.6 m), 10.3 mm on slab 1 (1.3 m)** (`blast_peak_mm` in
   `predictions.json`). This is the blast's own deflection.
2. **The air beneath then throws the slab off its trestles.** The incident wave runs round the
   slab's free edges and reflects off the ground 0.4 m below; the gauge under the centre peaks at
   0.85 MPa on the 2.0 m slabs. The slab (not tied down, as the inputs say) leaves its trestles at
   about 0.95 m/s and rises 44–51 mm (2.0 m slabs), 19 mm (slab 10) or 4 mm (slab 1). A diagnostic
   run shows it in flight under gravity alone until 140 ms. This is the model's physics, computed
   while the air is awake.
3. **The landing.** The air goes to sleep at 78 ms by its five-crossings limit (a default), and
   while it sleeps the structure moves on through the frozen air on a frozen solid mask. As the
   slab comes back down through the cells frozen as solid where it was, it is pushed down at up
   to about 9 g before either edge lands. It slams onto its rigid supports and is left sagging.
   **That landing makes the declared quantity 2 (the largest downward displacement in the run)
   and quantity 3 for every slab but slab 1**, at 160–225 ms, and it is an artefact of the frozen
   defaults for a slab thrown this far (change 5 in the assumptions has the evidence).
4. **With the air kept awake** (secondary run 7, a non-default setting), the 2.0 m slabs land
   at 200–220 ms only 1.8–3.9 mm down, short of their blast peaks, and no slab's landing goes
   below its blast peak. The
   largest downward displacement is then the blast peak of step 1 for every slab. After landing, though,
   the awake air feeds energy into a slab bouncing on its supports: slab 4 on the primary's air is
   thrown 0.45 m up after 300 ms, which no quiet air could do. So **nothing after the first
   landing, awake or asleep, is trustworthy**. That includes quantity 3 and the declared
   quantity 2 on the 2.0 and 1.6 m slabs.

The predictor's reading, as description (rule 1 keeps the declared quantities as the
prediction): **the model's sound deflection prediction is the blast peak**: 10.3 mm (slab 1),
5.9 mm (slab 10), and 3.6–4.4 mm on slabs 2, 4, 5, 7 and 9, group means A 3.71 mm and B 4.23 mm.
In the model the 2.0 and 1.6 m slabs are thrown off their trestles by the reflected wave beneath
them.

**Uncertainty of quantity 2.** As declared (secondary run 5): eight Latin-hypercube samples of
fc, ft, fracture energy, bar yield, TNT equivalence, the charge's height and the bearing width,
on the calibrated record's air. Their smallest and largest peaks, as ratios to that air's own
run, are applied to the primary in the table above: slab 1's group × 0.52–1.16, slab 2's ×
0.49–2.07, slab 4's × 0.74–3.15. No sample collapses. On slabs 2 and 4 every sample's largest
peak is a landing, so those bands measure the artefact's sensitivity. On slab 1, six of the
eight peaks are the blast's, so **× 0.52–1.16 is the best guide to the spread of the blast peak
from the inputs' uncertainty**. The secondary runs move the blast peak by −25% (charge 0.1 m
higher, slab 1) to +23% (timber bearings, slab 1); on the 2.0 m slabs by −13% (charge higher) to
+22% (slab A's bars across the span), and by under 10% for the air, the mesh or the bearings. The
standing's error band for a slab's peak deflection under a blast on solid elements, from the
calibrated contest slab, is 0.79–1.17 of measured.

## Secondary runs (reported, not scored)

Blast peak / largest downward displacement / end (mm). Every slab survives in every run.

| Run | 1 | 10 | 2 | 5 | 4 | 7 | 9 |
|---|---|---|---|---|---|---|---|
| Primary | 10.3 / 10.9 / 8.3 | 5.9 / 14.7 / 14.1 | 3.8 / 11.7 / 9.4 | 3.6 / 13.2 / 11.0 | 4.3 / 25.1 / 23.2 | 4.1 / 22.8 / 20.8 | 4.4 / 21.8 / 20.1 |
| 1. Calibrated air (25 mm refined by 2, mapped start) | 10.4 / 10.4 / −0.3 | 5.9 / 5.9 / −0.6 | 3.8 / 5.9 / 4.2 | 3.6 / 4.8 / 3.6 | 4.3 / 7.1 / 6.3 | 4.1 / 7.4 / 6.4 | 4.4 / 7.6 / 6.8 |
| 2. 16 elements through | 9.3 / 19.1 / 18.1 | 6.1 / 23.6 / 22.6 | 3.7 / 3.7 / thrown 1.4 m up | 3.6 / 3.6 / thrown 1.4 m up | 4.1 / 31.3 / 29.4 | 4.1 / 16.6 / 15.9 | 4.2 / 31.2 / 29.3 |
| 3. Slab A's 10 mm bars across the span (calibrated air) | | | 4.4 / 8.9 / 8.1 | 4.4 / 9.0 / 8.2 | | | |
| 4. Charge centre 0.1 m higher (calibrated air) | 7.9 / 7.9 / −4.1 | 5.2 / 8.7 / 7.6 | 3.5 / 5.9 / 4.5 | 3.4 / 11.3 / 9.2 | 3.8 / 7.5 / 6.9 | 3.6 / 6.9 / 5.8 | 4.0 / 11.1 / 10.0 |
| 6. Timber bearings | 12.8 / 17.6 / 17.1 | | | | 4.6 / 25.1 / 23.6 | | |
| 7. Air never sleeps (calibrated air) | 10.4 / 10.4 / −5.0 | 5.9 / 5.9 / 2.8 | 3.8 / 3.8 / −21.8 | 3.6 / 3.6 / −24.2 | 4.3 / 4.3 / −9.2 | 4.1 / 4.1 / −15.3 | 4.4 / 4.4 / −25.2 |
| 7. Air never sleeps (primary air) | 10.3 / 10.3 / 5.1 | | | | 4.3 / 4.3 / thrown 0.45 m up | | |

(A negative end is above where the slab started: in mid-bounce at 500 ms.) The blast peak is
steady across air, mesh and supports, within about 10% on the 2.0 m slabs. Everything after the
first landing is not, which is the point of the section above.

## Limits the predictor sees, without measurements

The charge is a sphere of TNT at the cylinder's centre; the real one was a vertical cylinder fired
from its top, which throws more of the blast downwards. The ground is rigid, where the test's was
clay, with a steel box under the slab's centre and trestles whose legs are left out of the air;
all of this bears on the reflected wave that throws the slab up. The supports are rigid lines
that cannot drop. The steel's grade, the bearing width and the concrete's tensile strength are
assumed (see the assumptions).
