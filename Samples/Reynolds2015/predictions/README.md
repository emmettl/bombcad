# Blind test 3: the predictions

The predictor's predictions for [blind test 3](../../../docs/blind-tests.md#test-3-high-strength-slabs-in-the-blast-load-simulator-reynolds-2015)
(Reynolds 2015: the high-strength slabs HSCV1–6 in the blast load simulator), made from
`Samples/Reynolds2015/inputs/` alone, on the frozen commit's model and defaults. Nothing here
has been compared with any measurement; the predictor has not seen one.

- **Frozen commit:** `b524a9dd567645e2d97dd888c5cd2e35604386ee` (v0.3.0, build 7).
- **Harness:** `Sources/BlastCore/ReynoldsSlabTest.swift` and `Sources/blastbench/ReynoldsBench.swift`
  (`blastbench reynolds`), added in `c855088` on origin/main at `f1d5e6a`, whose `Sources/`
  differ from the frozen commit only in the standing's wording (`ErrorBands.swift`,
  `EvidentialStanding.swift`; no material, solver or default). **Every run used the harness at
  `1ec6085`** (`c855088` plus change 1, reading `loads.csv`'s CR LF lines). No material, model or
  default was changed and no option was turned on or off. Hashes are those the runs were made
  with; if the branch is rebased to push, the commit message of the predictions gives the
  rebased hashes, and the harness files are byte for byte the same.
- **Assumptions**, declared and committed before the first run (`f1cd52a`), with the one change
  since: [assumptions.md](assumptions.md). The choices, in short: width 33.75 in; supports lines
  of nodes 52 in apart (the contest slab's harness and band); nine bars at 4 in and five at
  8 in, as drawn; main bars 1.0625 in from the back face (cross bars outermost); fc 108.6 MPa
  (56 days), density 2,454 kg/m³; bars yield 572 MPa, ultimate 724 MPa at 7%, rupture at 9.1%
  plastic strain; the digitised load as read plus a tail carrying Table 1's impulse; 8 elements
  through, the band's derived mesh.
- **Run:** `blastbench reynolds --time 0.3` (all six slabs, 300 ms each, about 2–4 minutes a
  slab on the Studio). The ensemble and secondary runs' flags are in the assumptions. Raw
  outputs are kept in the predictor's folder, `/Volumes/StudioData/bombcad/reynolds-prediction/`.
- **Files:** `predictions.json` (everything below, per slab and per run, with every ensemble
  sample's inputs), `predictions.csv` (the primary, a row a slab), `secondary.csv` (the
  secondary runs), and per slab in `histories/`: `HSCVn-displacement.csv` (the centre of the
  face away from the blast, 0–300 ms every 0.1 ms, away from the blast positive),
  `HSCVn-load.csv` (the pressure as applied), each face's crack field at 300 ms as
  `HSCVn-back.png` and `HSCVn-blast.png` (four pixels an element, x along the 64 in span to the
  right, y across the width up the image; white uncracked, black a 1 mm opening, red removed,
  orange bare bars) and as the solver's symbols `HSCVn-cracks.txt`. All are listed in
  `SHA256SUMS`.

## The predictions (primary)

Units: mm, ms. Displacements are of the centre of the face away from the blast, from where it
started, away from the blast positive; times from the load's arrival (t = 0). Residual: the
mean over 250–300 ms, with its range over those 50 ms.

| Slab | Bars | Load applied (peak kPa / impulse kPa ms) | 1. Peak (at) | 2. Residual (range) | 3. Outcome | 1. Uncertainty (declared band) | Ensemble samples standing: their range |
|---|---|---|---|---|---|---|---|
| HSCV1 | No. 3 at 4 in | 341 / 6,986 | **94.2** (26.4) | **74.9** (0.6) | **holds** | 62.7–749 | 7 of 8: 62.7–102.7 |
| HSCV2 | No. 3 at 4 in | 341 / 6,878 | **94.2** (26.4) | **74.7** (0.5) | **holds** | 62.7–749 | 7 of 8: 62.7–102.7 |
| HSCV3 | No. 3 at 4 in | 263 / 5,336 | **52.4** (21.1) | **34.1** (0.7) | **holds** | 34.3–82.1 | 8 of 8: 34.3–82.1 |
| HSCV4 | No. 3 at 8 in | 262 / 5,198 | **678** (113, breaking through) | **−543** (282, not at rest) | **fails** | 662–690 | 0 of 8 |
| HSCV5 | No. 3 at 8 in | 206 / 3,527 | **66.3** (26.0) | **51.0** (0.7) | **holds** | 45.2–98.6 | 8 of 8: 45.2–98.6 (one counted failed by the 1 mm rule, bars intact) |
| HSCV6 | No. 3 at 8 in | 228 / 3,972 | **91.2** (29.5) | **71.1** (0.5) | **holds** | 59.9–699 | 6 of 8: 59.9–95.4 |

HSCV1 and HSCV2 share one digitised trace (the inputs give one for both), so their loads differ
only after 54 ms, in the tail that carries each one's Table 1 impulse; their peaks are the same.

**HSCV4 breaks through.** Its centre passes 98 mm at 20 ms and 155 mm at 30 ms and never turns:
the five bars rupture across the full width 44–70 mm from mid-span (towards the roller) and
the slab folds there; the centre reaches 678 mm at 113 ms. The declared peak and residual are
those of a broken slab (the halves, still pinned at the supports with no gravity, swing back
through the plane, hence the negative "residual"); quantity 3 is the prediction that matters.
All eight ensemble samples, every secondary run and the 16-element mesh break HSCV4 the same way.

**Uncertainty of quantity 1.** As declared: eight Latin-hypercube samples of fc (92.9–115 MPa),
the tensile strength, fracture energy, bar yield and ultimate, the load (3%), the supports
(lines or 1 in bearings free to lift), the main bars' depth (0.6875–1.0625 in) and their area
(the drawn count to the nominal spacing), each run 150 ms; their smallest and largest peaks as
ratios to their median, applied to the primary. Where samples break through, the declared band
reaches the broken slab's runaway; the last column gives the standing samples' range the same
way, and how many stand. The ensemble's medians are 85.0 (HSCV1/2), 47.5, 62.5 and 87.4 mm
(HSCV3, 5, 6): the primary sits above them chiefly because it takes the main bars at the
deepest end of the ensemble's range for their depth, the choice that moves the peak most
(secondary run 2). The standing samples' peak times are 17–27 ms (4 in) and 22–31 ms (8 in).

**Quantity 4, the damage**, at 300 ms (images in `histories/`):

- **Blast face: no crushing and no spalling on any standing slab** (no element of that face past
  0.0035 plastic strain; none removed). The 108 MPa concrete stays below crushing at these
  rotations. Fine cracks parallel to the supports open on it near mid-span (to 0.4–0.6 mm on
  HSCV1, 2 and 5, 0.9 mm on HSCV3, 1.7 mm on HSCV6), with short cracks along the span between
  them, from about 100–220 mm towards the pin to 60–80 mm towards the roller from mid-span.
  They are most likely opened in tension as the slab rebounds from its peak (not traced).
- **Back face: cracks parallel to the supports right across the width**, banded about
  mid-span over about ±300 mm (±235–350 mm), widest within ±130 mm of mid-span. Main cracks
  (local maxima of the opening averaged across the width, above 0.5 mm; mm from mid-span,
  + towards the roller): HSCV1 and 2 at −222, −184, −133, −108, −57, −19, +19, +57, +95, +133 and
  +222 (widest 1.8 mm at −19; largest single element 2.3 mm); HSCV3 at −159, −70, −44, −6, +32,
  +57, +83, +108, +146 (widest 1.0 mm; most 1.3 mm); HSCV5 at −210, −95, −70, +19, +44, +95, +121
  (widest 1.3 mm; most 2.5 mm); HSCV6 at −222, −108, −83, +6, +44, +70, +95, +133 (widest 2.1 mm;
  most 2.9 mm). The 8 in slabs crack in fewer, wider cracks than the 4 in. No scabbing.
- **HSCV4:** broken through across the width 44–70 mm from mid-span, bars ruptured there,
  concrete removed through the depth along that band (0.016 m² of the blast face, 0.019 m² of
  the back); wide cracks across the width (to 3.5 mm averaged) over −235 to +121 mm on the back
  face. No crushing.

## Secondary runs (reported, not scored)

Peak (mm, at ms) / outcome, 150 ms each. "Fails" is the declared rule; † marks a failure by the
1 mm rule with no bar broken and the slab standing; every other failure is a break-through with
ruptured bars.

| Run | HSCV1 | HSCV2 | HSCV3 | HSCV4 | HSCV5 | HSCV6 |
|---|---|---|---|---|---|---|
| Primary (300 ms) | 94.2 (26.4) | 94.2 (26.4) | 52.4 (21.1) | fails | 66.3 (26.0) | 91.2 (29.5) |
| 1. Load scaled to Table 1 (×1.008–1.049) | 108.3 (27.7) | 103.9 (27.3) | 59.9 (22.2) | fails | 70.1 (26.6) | 99.4 (30.6) |
| 2. Main bars outermost (0.6875 in) | 70.4 (22.5) | 70.4 (22.5) | 39.6 (18.4) | fails | 53.2 (22.7) | 71.3 (25.9) |
| 3. Bars by the nominal spacing | 107.5 (28.4) | 107.5 (28.4) | 59.8 (22.8) | fails | 88.7 (31.1) | fails |
| 4. Span 58 in | fails | fails | 112.0 (30.2) | fails | 135.4 (37.6) fails† | fails |
| 5. 16 elements through | 97.6 (26.6) | | | fails | | |

The bars' depth moves the peaks most of the open choices (−20 to −25% for bars 0.375 in nearer
the face), then the load's definition (+6 to +15% scaled to Table 1's impulse) and the bar count (+14%
and +34% at the nominal spacing). The mesh moves HSCV1 by +4% at 16 through. On 58 in every slab
but HSCV3 fails, as the record's contest slab collapsed on 58 in under its own load.

## Limits the predictor sees, without measurements

- **Bar rupture decides HSCV4 (and the failing samples of HSCV1, 2 and 6)**, and the bars'
  ultimate strain and elongation are assumed (Grade 80's minimum elongation, test 1's ratio); the
  ensemble varies the ultimate stress but not the rupture strain.
- The load acts on the whole blast face, as in the contest slab's harness, where Fig 5's front
  tubes cover 6 in at each end; the supports are lines of nodes, not the 8 in tubes and the
  honeycomb pad; no negative phase is applied.
- The concrete's tensile strength, fracture energy and modulus follow the model's correlations,
  extrapolated to 108 MPa, beyond any concrete in the validation record.
- The crack openings are the smeared model's, element by element, averaged across the width for
  the main cracks; they are not discrete cracks.
