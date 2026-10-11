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
   abstracts, anyone's simulation of the test, or other sessions' transcripts and memory notes
   about it (the judge's session handled the measurements). Where the inputs leave something open, it
   decides, and writes the decision and its reason down before running.
   Its working folder lies outside `/Volumes/StudioData/bombcad/blind/`, which holds the
   sealed folders (for example `/Volumes/StudioData/bombcad/<source>-prediction/`), and it
   never lists or opens anything under `blind/`. (Test 1's predictor was started with its
   folder at `blind/predictor/`, before this rule; it was told not to list or open anything
   else under `blind/`, and to say in its `assumptions.md` if it had.)
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

## Test 2: slabs under an open-air charge (Mendonça et al.)

**Source.** F. B. Mendonça, G. S. Urgessa, A. S. Augusto and J. A. F. F. Rocco, "Experimental
records from blast tests of ten reinforced concrete slabs", *CivilEng* 1(2), 2020, with the
records on the George Mason University Dataverse (doi:10.13021/ORC2020/MVTEFA, CC0) and two
companion papers (2018, 2021). Inputs: [Samples/Mendonca2020](../Samples/Mendonca2020/README.md).
Sealed: `/Volumes/StudioData/bombcad/blind/mendonca-sealed/`, checked by
`Samples/Mendonca2020/SEALED.sha256`.

**Why this test.** It differs from test 1 in load and in what it asks: an open-air charge, so
the air solver loads the structure, on thin slabs simply supported on two sides, which may
survive cracked or collapse. Two groups are repeats (slabs 2 and 5; slabs 4, 7 and 9), so the
tests' own scatter is measured, not assumed. No session had read these sources before.

**Slabs.** The seven without foam: 1, 2, 4, 5, 7, 9 and 10. 1.0 m square and 80 mm thick,
steel in the bottom face only, resting on timber trestles along two opposite sides 0.4 m above
the ground, under about 2.7 kg TNT-equivalent of unconfined PBX hung 1.3, 1.6 or 2.0 m above
their centres (see the inputs).

**Frozen commit.** Named in `Samples/Mendonca2020/FROZEN` when the predictor starts, which is
after test 1's reveal, so that test 2 runs on whatever defaults stand then.

**What to predict**, for each of the seven slabs, each run until the slab has come to rest or
for at least 100 ms:

| # | Quantity | Units |
|---|---|---|
| 1 | Whether the slab collapses: breaks through its thickness right across and falls from its supports or is left in pieces, as against cracked but still spanning | collapses / survives |
| 2 | Peak downward displacement of the bottom face's centre | mm |
| 3 | Displacement of the bottom face's centre at the end of the run | mm |
| 4 | Peak pressure and positive impulse at the slab's top surface at each of its four corners and at its centre | kPa, kPa ms |
| 5 | The damage: where the main cracks run on the bottom face, and whether the top face crushes or spalls | words, and an image of the crack field if the harness draws one |

Also committed: the displacement history of the bottom face's centre (0–100 ms) and the
pressure histories at the five points, as CSV, and the predictor's own estimate of the
uncertainty of quantity 2 if it has one. For slab A's two layouts of the span (which way the
10 mm bars run is not given) the predictor declares one as primary before running; the other
may be run as a secondary.

**Scoring.** Against the measured outcomes and the records, processed once by the sealed
script before any prediction:

- **Primary score**: quantity 1 on all seven slabs, as the number predicted rightly; and
  quantity 2 on the slabs that survived, as the ratio of predicted to measured, each slab and
  each repeat group's mean.
- **Secondary scores**: quantity 2 against each repeat group's measured range (inside it, or by
  how far outside); quantity 3 as a ratio, with the caveat below; quantity 4's peaks and
  impulses against the corner gauges as the dataset's readme places them, as ratios; quantity 5
  against the papers' descriptions.
- **Against the calibrated record.** The calibrated open-air slabs came out a third to a half as
  far down as measured close in (Chiquito et al.), within −20% to +7% under Wu et al.'s largest
  charge and at 40–70% under the smaller ones, and several times too stiff on Wang et al.'s
  supports. The blind result is read as *as good as the calibrated record* if at least six of
  the seven outcomes are right and each repeat group's mean ratio for quantity 2 lies within
  0.75–1.25; *worse* if four or fewer outcomes are right or a group's ratio lies outside 0.5–2;
  and *between* otherwise. The numbers are reported as well as the verdict.

**Known limits of the test.** A field test on a modest budget: the supports, steel grade,
charge geometry and gauge positions are partly undocumented (the inputs list each gap); the
TNT equivalence of the PBX is the authors' and its method unstated; the charge is a vertical
cylinder fired from its top, which BombCAD's spherical charge does not represent; the trestles
stood on clay, and the source's pre-test check found the supports moving in it, which rigid
supports in the model leave out; and the displacement meters are pull-wires whose records the judge
reads as they stand, by a rule fixed before any prediction.

## Register

| # | Test | Frozen commit | Predictions committed | Revealed | Result |
|---|---|---|---|---|---|
| 1 | Hrynyk 2013, plain slabs TH2, TH6, TH7 | `1c85774` (2026-10-11) | | | |
| 2 | Mendonça et al. 2020, unretrofitted slabs 1, 2, 4, 5, 7, 9, 10 | named when its predictor starts, after test 1's reveal | | | |
| 3 | *Reserved candidate:* K. A. Reynolds, UMKC MS thesis, 2015 (probably the contest's high-strength slabs, on the calibrated slab's rig). Unread; moved to `/Volumes/StudioData/bombcad/blind/reynolds-sealed/` on 2026-10-11. No session opens it, or the contest's high-strength results anywhere, until the judge has assessed it after test 1's reveal | | | | |
