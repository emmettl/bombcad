# ADBLAST substructure reference: stage 1, 21 October 2026

The twelve Table 17 rows are already transcribed in [the canonical fixture](../tests.json),
under `substructureTests`. `AdblastCladdingTest.substructureTests(from:)` reads all twelve;
this directory does not duplicate the measurements. [rig.json](rig.json) separates reported
inputs from candidates and unknowns. Source: Hoffmeister et al., *ADBLAST*, EUR 27487 EN (2015),
sections 3.3.4.5-7, Tables 13, 16-17 and Figure A5. Reproduction is authorised with attribution;
the report itself stays outside the repository, as described in [the parent README](../README.md).

## Audit of the measurements

Visually checked Table 17 on printed p. 37 (PDF page 43) against all twelve existing rows.
No measured values were changed. F2 in shots 1 and 2 is a dash, and the first dynamic deflection
in shot 8 is `(?)`: these remain null, not zero and not interpolated. The TR84 1.5 mm purlin
sets are reported zero. Signs are retained exactly as printed.

Table 16 (p. 33) gives impulses of 215 and 165 kPa ms for shots 3 and 4; Table 17 gives
212 and 161. Table 17 remains the declared comparison reference. Keep the alternatives visible
in load sensitivity work; do not select one by which gives the better deflection.

## What the report establishes about the rig

- Table 17: four sheets of TR35 1 mm, TR84 0.75 mm or TR84 1.5 mm, on a U 60 x 30 x 6 mm
  middle purlin. Section 3.3.4.7 calls the bolted support fixed and the slotted-hole support free.
- Section 3.3.4.7 (p. 32): C4 charges of 0.25, 0.5, 1 and 1.5 kg, 3.5 m above the middle.
  The paragraph says three panels, whereas Table 17 says four; do not silently reconcile that.
- Figure A5 (p. A-9): Hacierba TR35/207, 207 mm pitch, 34 mm outside height, 119 mm crest,
  40 mm trough, 1035 mm cover width. `SheetProfile.tr35` uses those dimensions, straight walls
  and the caller's thickness and yield. Its name's 35 is nominal. Coupon strengths remain in
  `coupons.TR35_1.0` in the canonical fixture.

The two 1.27 m sheet spans and SHS edge purlins in the draft plan come from **static** Table 13.
They are candidates for the blast rig, not confirmed blast dimensions. The text says the fixings
were as in the static tests; it does not establish that all lengths were the same. Figure 21
(p. 33) is an undimensioned photograph. Annex A-40 is a different design example with U-240
purlins spanning 7 m. Neither gives the U-60 test span or defensible upper and lower bounds.
Slot travel, force-slip behaviour, and charge assignments to individual rows are also missing.

## Load protocol fixed before judging deflections

1. Use the four reported C4 charges, in ascending order. Once the rig and air setup are fixed,
   compute each charge's centre reflected positive-phase impulse in kPa ms. Record the solver
   version, source/start model, TNT-equivalence rule, grid, gauge location and integration window.
2. For each shot, select the candidate with the smallest **absolute** impulse difference from
   Table 17. An exact tie selects the lower mass. `AdblastCladdingTest.substructureCharge` applies
   this rule and refuses missing, non-positive or non-finite predictions.
3. Publish all four predicted impulses and the residual, beside the selected mass labelled
   **inferred**, before examining any predicted deflection, purlin set, detachment or support force.
   A shared selected charge for different shots is allowed; an impulse match is not a peak match.
4. Judge peak pressure separately. A poor impulse/peak match is a load-model limitation; do not
   retune the mass using mechanical outcomes. Repeat with Table 16's alternative impulses as a
   declared sensitivity, without replacing the primary Table 17 result.

No per-shot charges have been inferred in this desk stage: no air comparisons have run.

## Recorded stop before a judged harness

The reference rows, TR35 profile and charge-selection rule are ready. A dimensioned blast rig
(or justified span bounds) is still needed before a judged `adblast --substructure` run. Request
D4-D6 through the existing [data survey](../../../docs/data-survey.md#3i-profiled-cladding-on-its-fixings),
particularly the blast layout, U-60 support spacing, slot details, shot log and pressure histories.
A guessed span can be explored as an illustrative sensitivity, but cannot establish validation
or justify changing the sheeting's standing. No shell kernel, warehouse preset or default changed.
