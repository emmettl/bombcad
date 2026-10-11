# Blind tests

Every comparison in the [validation record](validation.md) was designed, run and judged with
its measurements in view, and the model's defaults were chosen with those comparisons in view
(see the [independent review](validation-review.md#1-the-default-strain-rate-laws-were-chosen-on-the-tests-they-are-judged-against)).
The record is therefore a calibration set. A blind test measures what calibration cannot: how
well the model predicts a test nobody has tuned it to. This page is the protocol, fixed before
any prediction is made, and the register of blind tests.

## Roles

- **Extractor and judge**: a session that chose no default and ran no comparison. It extracts
  the inputs, seals the measurements, and after the predictions are committed, unseals,
  scores and writes the result. It changes no model code.
- **Predictor**: a fresh session that has not seen the test's measurements. It builds the test
  in BombCAD from the inputs alone, runs it on the frozen defaults and commits its predictions.
- **Orchestrator**: starts the predictor with the frozen commit's hash, and tells the judge
  when the predictions are committed.

## Rules

1. **Frozen defaults.** The predictor checks out the frozen commit (below) and runs on it. It
   may add a harness: new files that build the test's geometry, supports, impactor and outputs
   from the inputs, and a `blastbench` subcommand to run it. It may not change any material
   law, solver, removal rule, default or option's meaning. Its primary prediction uses the
   defaults throughout: no model option is turned on or off.
2. **Inputs only.** The predictor reads the test's `inputs/` folder in the repository, the
   BombCAD documents (including the validation record) and its code. It does not open the
   sealed folder, the test's data anywhere else, the source's publications or their
   abstracts, or anyone's simulation of the test. Where the inputs leave something open, it
   decides, and writes the decision and its reason down before running.
3. **Declared before running.** Before its first run the predictor commits an
   `assumptions.md`: each assumption, the mesh (elements through the thickness) and air or
   contact settings of the primary prediction, and any secondary runs it will make (another
   mesh, an option) and why. Secondary runs are reported, not scored as the prediction.
4. **No looking, so no tuning.** The predictor may run the model as often as it likes; it
   has nothing to tune against. It may not adjust an assumption to bring a result towards
   what it expects the test gave; if it changes an assumption after a run, it says so and why.
5. **Committed with a hash.** The predictions go to `Samples/<test>/predictions/` with a
   `SHA256SUMS` file of their contents, the frozen commit's hash and the harness commit's hash,
   and are pushed to `origin/main`. The orchestrator passes the prediction commit's hash to the
   judge. Nothing is unsealed until that commit is on `origin/main`.
6. **The reveal.** The judge checks the sealed folder against its committed manifest, then
   scores the predictions exactly as below and writes the result, marked **blind**, into the
   validation record and the standing.
7. **Nothing tuned after the reveal.** The blind result stays in the record as it was scored,
   at the frozen commit. Any later change to the model, its defaults or the harness that moves
   this test's results is calibration, and a rerun after it is reported as calibrated, beside
   the blind result, never in place of it. One exception: a transcription error in the harness
   (a value that contradicts the inputs as written) may be corrected, and the corrected result
   shown beside the blind one, labelled as corrected after the reveal.

## Test 1: Hrynyk's slabs struck by a falling weight

**Source.** T. D. Hrynyk, PhD thesis, University of Toronto, 2013 (TSpace 1807/35851, CC BY 2.5
Canada), and its digital records from the VecTor Analysis Group. Inputs:
[Samples/Hrynyk2013](../Samples/Hrynyk2013/README.md). Sealed:
`/Volumes/StudioData/bombcad/blind/hrynyk-sealed/`, checked by
`Samples/Hrynyk2013/SEALED.sha256`.

**Slabs.** The three plain reinforced concrete slabs with records, TH2, TH6 and TH7: 1.8 m square
and 130 mm thick, steel in both faces both ways at three ratios, held at their corners and
struck at the centre by a 300 mm square steel weight at 8 m/s, repeatedly, the mass rising from
150 kg (see the inputs for everything).

**Frozen commit.** The `origin/main` commit named in `Samples/Hrynyk2013/FROZEN`, which is the
commit that added these inputs. The concrete model's defaults were being changed by another
session at the time; whatever they are at that commit is what is tested.

**What to predict**, for each slab, for impacts 1 to 4 (150, 180, 210 and 240 kg) on the same
model carried from one impact to the next, each run until the slab and weight have come to rest
or for at least 200 ms:

| # | Quantity | Units |
|---|---|---|
| 1 | Peak midpoint displacement in the impact, from the impact's start (bottom face, slab centre) | mm |
| 2 | Residual midpoint displacement of the impact, from its start | mm |
| 3 | Peak total support reaction: the sum of the four corners' upward reactions | kN |
| 4 | Peak impact force, from the weight's deceleration, low-pass filtered with a tenth-order Butterworth filter at 1.2 kHz applied forward and backward | kN |
| 5 | Whether the slab punches in this impact (a punching cone through the thickness, with the bottom face scabbed off round the impact zone), and penetration of the weight into the top face | yes/no, mm |
| 6 | The first impact at which the slab punches, if within the four | impact number |

Also committed: histories of the midpoint displacement (0–200 ms), the total reaction and the
impact force (0–50 ms) for each impact, as CSV, and the predictor's own estimate of the
uncertainty of quantities 1 and 3 if it has one.

A slab the model breaks before the fourth impact is predicted broken from then on; one the
test stopped short of the fourth impact is scored only on the impacts that were made.

**Scoring.** For each recorded impact, the ratio of predicted to measured for quantities 1 to
4, against the thesis's tabulated peaks and residuals (its Tables 4.5 and 4.6) and the impact
force processed from the records by the sealed script; and for quantities 5 and 6, a match or
not against the thesis's observations. Then:

- **Primary score**: quantity 1 on each slab's first impact, the only impact on an undamaged
  slab: three ratios.
- **Secondary scores**: for each quantity, the geometric mean of the ratios and the mean
  absolute error over every recorded impact; for punching, how many of the three slabs' first
  punching impact is predicted exactly, or one impact early or late.
- **Against the calibrated record.** On 16 elements through the depth the calibrated
  drop-weight beams came within 12–24% under Saatci's light drops and 5% under his heavy ones,
  and Ando's beams within 15% on average (53% on 24 elements). The blind result is read as
  *as good as the calibrated record* if the three primary ratios lie within 0.75–1.25 and the
  mean absolute error of quantity 1 over all impacts is under 25%; *worse* if any primary
  ratio lies outside 0.5–2 or that mean error exceeds 50%; and *between* otherwise. Either
  way the numbers are reported, not only the verdict.

**Known limits of the test.** One programme, one impactor, one speed; the slabs are struck
repeatedly, so only the first impact on each is on an undamaged slab; the impactor's contact
stiffness, the bearing plates' size and the bars' rupture strain are not given; the impact
force is measured on only some impacts (accelerometers saturated on others) and the thesis
flags one of its own values as possibly unrepresentative; the measured reactions are from load
cells beneath ball-jointed supports, whose own compliance the model may not have.

## Register

| # | Test | Frozen commit | Predictions committed | Revealed | Result |
|---|---|---|---|---|---|
| 1 | Hrynyk 2013, plain slabs TH2, TH6, TH7 | see `Samples/Hrynyk2013/FROZEN` | | | |
