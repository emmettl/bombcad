# Blind test 1: the predictions

BombCAD's predictions for Hrynyk's slabs TH2, TH6 and TH7 under impacts 1 to 4 (150, 180, 210
and 240 kg at 8.0 m/s), made under [the protocol](../../../docs/blind-tests.md) without sight of
any measurement. Every choice the inputs left open, and the four changes made after runs (none of
them to bring a result anywhere: two harness errors, a run split off, and the ensemble cut for
time), are in [assumptions.md](assumptions.md), committed before the first run and added to as
the runs went, with the two interruptions of 11–12 October.

| File | Contents |
|---|---|
| `predictions.json` | Quantities 1 to 6 for each slab and impact, the model's input spread for 1 and 3, the 8-element run beside them, and what else each impact recorded |
| `predictions.csv` | Quantities 1 to 5 and the spread of 1 and 3, one row per impact |
| `histories/<slab>-impact<n>-displacement.csv` | Midpoint displacement from the impact's start, 0–200 ms, every 0.1 ms |
| `histories/<slab>-impact<n>-forces.csv` | Total reaction (the load cells' sum, less its value at the impact's start), the seats above, and the impact force filtered and unfiltered, 0–50 ms, every 25 µs |
| `assumptions.md` | Assumptions, mesh, outputs' definitions, secondary runs, and changes |
| `SHA256SUMS` | SHA-256 of every file above |

## How they were made

- **Frozen commit** `1c857744802e8cfd2d536f8379d68dad1a85e743`, on its defaults: no model option
  turned on or off. **Harness** `Sources/BlastCore/HrynykSlabTest.swift` and
  `Sources/blastbench/HrynykBench.swift`, code as of commit `418b9b4` (on the frozen commit; later
  harness-branch commits touch only `assumptions.md`). It reads `inputs/slabs.json` itself.
- **Primary**: `blastbench hrynyk --slabs <slab> --layers 16`, 16 solid elements through the
  thickness (8.108 mm cubes, 793,000 elements a slab), on the Mac Studio (M4 Max) in its shared
  GPU slots, 12 October: TH7 00:30–04:47, TH2 06:59–11:18, TH6 07:37–12:28. (The first full runs,
  of 11 October, are not the prediction: change 4 in assumptions.md.)
- **Mesh check** (secondary): the same on 8 elements through, on the CI Mac mini
  (`secondary_8_through` in `predictions.json`).
- **The model's own uncertainty** (quantities 1 and 3): `--layers 8 --ensemble 4 --seed 1`, a
  Latin hypercube of 4 samples and the middle over the concrete's strength (±5%), ft* (±10%),
  fracture energy (±30%), the bars' yield and ultimate (±3%), impact speed (±2%), bearing plates
  75–150 mm and rupture strain 1.1–1.6 times the strain at fu. The 5th and 95th percentiles of
  each sample's ratio to the ensemble's middle are applied to the 16-element value
  (`input_uncertainty`). Four samples give a rough band only, and it covers the inputs alone, not
  the model's form; the protocol scores the point values. Because the ratios are to the
  ensemble's own middle (the two uniform inputs at their medians, not at the primary's values),
  a band need not contain the point value, and several do not (TH2's first reaction, TH6's
  fourth peak). One sample (TH2, sample 2) all but punched on impact 4 on the coarse mesh (75 mm,
  0.088 m² of the bottom face gone, against the 0.09 m² the punching rule needs), which is what
  stretches TH2's fourth band to 95 mm and 1,190 kN.
- Each impact ran 200 ms; the slab was then brought to rest (damped 80 ms) before the next. The
  impact force is filtered as the tests' (tenth-order Butterworth at 1.2 kHz, forward and
  backward), from the weight's deceleration sampled every 25 µs.

## The standing's error band

The standing has no error band for a drop weight: `ErrorBands` keys its structural bands to a
charge's regime, and this test has no charge. Its evidence for impacts (`EvidentialStanding`,
"Beams struck by a falling weight", and the validation record's summary) is the calibrated
record the protocol compares against: on 16 elements, Saatci's beams with stirrups came within
12–24% (too flexible) of the measured peaks under the light drops and −5% to +3% under the heavy
ones; they were struck about twice as hard as measured (the contact is infinitely stiff, as
here); their reactions were up to 40% low under the heavy drops and 48% high under the light;
Ando's beams came within 15% on average on 16 elements (53% on 24). Read as a band on these
predictions: peak displacements perhaps 0.95–1.25 times the measured on a first impact, the
impact force well above the measured, and the reactions uncertain by ±50%. None of that record
is of a slab, of a corner-supported plate, or of repeated impacts.

## What the model leaves out, which the reveal should be read with

- In impact 1 the weight's face is bonded to the slab and its contact infinitely stiff (no pad,
  as the tests had none); the bond tears the layer of concrete under the face off as it rebounds
  (1,444 elements in every slab, counted in `elements_removed`), which also makes impact 1's
  penetration about one element (8 mm) deep. Impacts 2–4 strike through the solver's contact,
  the face set back on the slab first (`face_reseated_before_impact`), a softer contact than the
  bond.
- The weight leaves once it turns up (the beam benches' rule), so for a moment before then the
  face can pull it down, and it does not strike again after its bounce.
- The seats are rigid stops at one node above and below each corner, on a 100 mm elastic plate;
  the test's ball-jointed load cells, rods and frame have compliance the model has not.
- The mats' tying links are left out.
- Between impacts the slab is brought to rest by damping over 80 ms, not the hours or days the
  test left it.
- Punching is judged by a rule written before the runs (assumptions.md, quantity 5); the
  model's damage is smeared over elements 8 mm across, so a punching cone shows as removed and
  widely cracked elements, not as a clean surface.
