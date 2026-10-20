# Open benchmark

Part of BombCAD's validation record written down so that any blast code can run it and be scored
the same way: ten cases, each a JSON file holding the scene, the charge, the gauges and the
measured (or reference) values with their uncertainty and full citations; a scorer; and BombCAD's
own entry, quoted from the record. The cases name no code's options. This is a first step: no
other code has run them yet ([what this doesn't yet do](#what-this-doesnt-yet-do)).

| Path | What |
|---|---|
| `Benchmarks/open/cases/*.json` | The ten cases |
| `Benchmarks/open/schema/case.schema.json`, `results.schema.json` | JSON Schemas (draft 2020-12) for a case and a results file |
| `Benchmarks/open/results/bombcad-0.6.0-dev.json` | BombCAD's entry |
| `Scripts/open-benchmark/score.py` | The scorer: Python 3, standard library only |
| `Scripts/open-benchmark/test_score.py` | Its tests, run by `make ci-test` |

```bash
python3 -I Scripts/open-benchmark/score.py Benchmarks/open/results/bombcad-0.6.0-dev.json
```

## The cases

| Case | Category | Reference | What is compared | Source, licence |
|---|---|---|---|---|
| `kb-surface-burst-free-field` | free field | fit | 100 kg TNT on rigid ground: incident peak, impulse and arrival at 0.75–6 m/kg^(1/3) | Kingery and Bulmash 1984 (ARBRL-TR-02555), Swisdak 1994; US Government |
| `kb-surface-burst-reflected` | reflected | fit | The same against a rigid wall at each stand-off: reflected peak and impulse | As above |
| `alsubaei2015-anfo-columns` | free field | measured | 2.4–15 kg of ANFO (0.82 TNT), 0.5 m up: peaks on pipe columns 8–13 m away, 40 gauges | Alsubaei 2015, Western University thesis; no terms stated, numbers only |
| `nian2024-rc-blast-wall` | shielded | measured | 5 and 20 kg before a free-standing 6 m RC wall: beside, on the face, and 2–6 m behind | Nian et al. 2024, *Defence Technology*; CC BY-NC-ND, numbers only |
| `wang2022-aluminised-close-in` | reflected | measured | An aluminised charge stated as 10 kg TNT, 1.2 m from a plate: peak, arrival, impulse | Wang et al. 2022, *Materials*; CC BY |
| `yao2023-slab-top-pressure` | reflected | measured | 0.5–1 kg hung 0.8–1 m over a 4 × 5 m slab: top-face peaks | Yao et al. 2023, *Applied Sciences*; CC BY |
| `ufc-closed-room-gas-pressure` | confined | design curve | TNT in a closed 6 m cube, 0.25–4 kg/m³: quasi-static gas pressure | UFC 3-340-02 Figure 2-152; US Government; scatter from Oswald 2018 |
| `wu2023-slabs-hung-charges` | structural response | measured | 2 m RC slabs under 0.2–1.6 kg hung above: underside peak and residual displacement | Wu et al. 2023, *Materials*; CC BY |
| `osnes2019-laminated-panes` | glazing | measured | 15 laminated panes in a shock tube under given Friedlander pulses: cracked or held, centre deflection | Osnes et al. 2019, *IJIE*; CC BY |
| `xia2022-surface-burst-ground-motion` | ground shock | measured | 1 t on the ground: vertical acceleration, vertical velocity and horizontal speed 0.5 m deep at 21 and 42 m | Xia et al. 2022, *Applied Sciences*; CC BY |

Each was chosen from the [validation record](validation.md) because its numbers come from an
open paper or a public US Government reference and are already transcribed in the repository
(`Fixtures/`, the record's tables, the test sources); nothing was digitised again or invented.
Every value carries its source's table, figure or page. Where a paper is not openly licensed
(Alsubaei's thesis, Nian's CC BY-NC-ND paper) only the measured numbers are kept, as facts with
their citation; none of the sources' text or figures. Each case's `redistribution` block says
what it holds and each source's `redistribution` says whether its values are included or it is
only cited.

**Left out, and why:**

- **The 2013 blast blind simulation contest slab**, BombCAD's main structural comparison
  ([structural response](validation.md#structural-response-against-a-real-test)): its load and
  displacement records are read off plots in papers that are not open, and its test programme
  overlaps one the [blind-test register](blind-tests.md) keeps sealed. Left out until both are
  settled.
- **Monk and Clubley's windows, Keys's brick walls**: the papers say the trial data remain the
  UK Ministry of Defence's property. The format can cite a case and withhold its values
  (`"withheld": true`), but a case with every value withheld scores nothing, so neither is here.
- **Shang et al.'s chamber** (CC BY): the sensors' positions are only in the paper's figures, and
  BombCAD's record has gauges near them rather than at them; for a later pass.
- **The blind tests** (Hrynyk, Mendonça, Reynolds) keep their own protocol and are not used.
- Candidates for later cases: Hupfauf's contact-charge slabs and Peterson's beams (CC BY),
  Langdon's corrugated panels (her connections' springs would have to be given), and Beirut's
  arrival times.

## A case

A case is one JSON object (`case.schema.json`; field by field there). In short:

| Field | Holds |
|---|---|
| `format`, `format_version` | `"open-blast-benchmark-case"`, 1 |
| `id`, `title`, `category`, `summary` | The file is named `<id>.json`. Category: `free-field`, `reflected`, `shielded`, `confined`, `structural-response`, `glazing`, `ground-shock` |
| `reference_kind` | `measurement`, `empirical-fit` (Kingery–Bulmash) or `design-curve` (UFC 3-340-02): whether the values are tests or curves through them |
| `sources` | Each with authors, year, title, venue, a DOI, URL or report identifier, its licence, and `values-included` or `cited-only` |
| `redistribution` | Whether the case holds the measured values, and why |
| `coordinates` | Where the origin is; metres, z up |
| `geometry` | The ground (`rigid-plane`, `soil`, `none`, `not-stated`); obstacles as boxes, rigid or deformable; a structure described in words with its materials and supports |
| `runs` | One per shot: its charges, or a given load (a Friedlander pulse), any obstacles of its own, and its gauges |
| `scoring` | The rule and its factors |
| `notes`, `provenance` | What a runner should know; where in this repository the numbers were transcribed from |

**A charge** gives the explosive, its mass, its TNT equivalence (factor, basis and source), the
TNT-equivalent mass, its shape, its centre and its height of burst. The equivalence is stated
even for TNT (factor 1), and where a paper gives only the equivalent (Wang's aluminised charge)
the case says so: whether the stated equivalence holds is part of what that case tests.

**A gauge** has an id, a position, how it is mounted (`ground-flush`, `face-flush`,
`column-face`, `free-air`, `on-structure`, `buried`, `room-average`) and one or more measured
quantities, each with its unit, its value (or a range where the source allows two readings),
an optional uncertainty and its source. Every quantity is a magnitude, positive, in a fixed unit:

| Quantity | Unit | Meaning |
|---|---|---|
| `peak_incident_overpressure` | kPa | Side-on peak above ambient |
| `incident_positive_impulse` | kPa\*ms | Its positive phase's integral (kPa·ms = Pa·s) |
| `arrival_time` | ms | From detonation to the shock's arrival |
| `peak_reflected_overpressure` | kPa | Peak on a surface facing the charge |
| `reflected_positive_impulse` | kPa\*ms | Its positive phase's integral |
| `quasi_static_gas_pressure` | kPa | A closed room's pressure once the shocks have died down |
| `peak_displacement`, `residual_displacement` | mm | Away from the load, at the gauge |
| `cracked` | boolean | A pane's outcome |
| `peak_acceleration_vertical` | m/s² | Largest vertical excursion (written `m/s^2`) |
| `peak_particle_velocity_vertical`, `peak_particle_speed_horizontal` | m/s | Ground motion |

**Uncertainty** is `sd`, `half-width` or `reading`, given absolutely (`value`) or as a fraction
(`relative`). Few sources state one: Kingery–Bulmash's incident curves carry the scatter of the
tests behind them (Kingery 1966 as Swisdak tabulates it, roughly one standard deviation), the
closed room Oswald's 11%, and values read off figures their reading error.

## The scoring rule

One rule so far, `within-factor`. A prediction passes when it lies within the measured band
widened by the case's factor either way:

(m_low − u) / f ≤ p ≤ (m_high + u) · f

where m_low and m_high are the measured value (or the ends of its range), u the uncertainty and
f the factor (per quantity where `factor_by_quantity` says so). A boolean passes when it matches.
The case's score is the share of its predicted values that pass; its coverage the share of its
measured values predicted (`--strict` counts the rest as failures). The scorer also gives each
case's geometric mean ratio, predicted over measured (the centre of a range is its geometric
mean), and its typical factor, exp of the root mean square of the log ratios. The factors were
set by hand for each case from how well its reference is known: 1.15 for the closed room's
design curve, 1.2 for Kingery–Bulmash (1.1 on arrival), 1.25–1.3 for field gauges, 1.5 for
structural response and glazing, 2 for ground motion.

## A results file

One code's predictions (`results.schema.json`):

```json
{
  "format": "open-blast-benchmark-results",
  "format_version": 1,
  "code": {"name": "SomeCode", "version": "1.2", "commit": "…", "url": "…"},
  "prepared": "2026-10-20",
  "cases": [
    {
      "case": "kb-surface-burst-free-field",
      "configuration": "2-D axisymmetric, 25 mm cells, JWL products, no afterburning",
      "predictions": [
        {"run": "100kg", "gauge": "Z3", "quantity": "peak_incident_overpressure", "unit": "kPa", "value": 112.0},
        {"run": "100kg", "gauge": "Z3", "quantity": "arrival_time", "value": 16.1}
      ]
    }
  ]
}
```

A prediction gives a `value`, a `range` (scored at its geometric centre, its ratio shown as a
range), or a `ratio` to the case's value where a code recorded only that. The scorer refuses a
run, gauge or quantity the case does not have and a unit that is not the case's. Cases a file
leaves out are listed as not entered.

```bash
python3 -I Scripts/open-benchmark/score.py RESULTS.json                  # every case in Benchmarks/open/cases
python3 -I Scripts/open-benchmark/score.py RESULTS.json --case nian2024-rc-blast-wall --json
python3 -I Scripts/open-benchmark/score.py --check                       # validate the cases only
```

## BombCAD's entry

`bombcad-0.6.0-dev.json` quotes the record at `6115dbcb` (main after 0.5.1); no simulation was run
for it. Each case gives the commit that recorded its numbers and the configuration they came
from, and these differ: Kingery–Bulmash, Nian, Wang and Wu are on today's defaults (the mapped
start), the closed room on today's gas, Yao, the ground motion and Alsubaei on earlier defaults,
as the record left them; Osnes's panes take their load as given. Where the
record kept only percentages of the reference (Kingery–Bulmash, the closed room) they are entered
as ratios, and values the record does not give gauge by gauge (Kingery–Bulmash's arrivals on the
mapped start, Osnes's deflections, Wu's six smaller charges on today's defaults) are not entered.

| Case | Score | Passed | Coverage | Geometric mean ratio | Typical factor |
|---|---|---|---|---|---|
| `alsubaei2015-anfo-columns` | 0.68 | 27/40 | 40/40 | 1.10 | 1.25 |
| `kb-surface-burst-free-field` | 1.00 | 16/16 | 16/24 | 1.02 | 1.12 |
| `kb-surface-burst-reflected` | 0.62 | 10/16 | 16/16 | 0.82 | 1.54 |
| `nian2024-rc-blast-wall` | 0.54 | 7/13 | 13/13 | 0.95 | 1.59 |
| `osnes2019-laminated-panes` | 0.47 | 7/15 | 15/30 | – | – |
| `ufc-closed-room-gas-pressure` | 1.00 | 5/5 | 5/5 | 0.99 | 1.04 |
| `wang2022-aluminised-close-in` | 0.33 | 2/6 | 6/9 | 0.65 | 1.62 |
| `wu2023-slabs-hung-charges` | 1.00 | 4/4 | 4/16 | 1.16 | 1.25 |
| `xia2022-surface-burst-ground-motion` | 0.00 | 0/2 | 2/6 | 35.8 | 37.1 |
| `yao2023-slab-top-pressure` | 0.83 | 5/6 | 6/6 | 0.93 | 1.26 |

The mean case score is 0.65, 83 of 123 values passing. It says what the record says in its own
words: impulses and the closed room good, reflected peaks low close in on 0.25 m cells, the
shielding behind Nian's wall too little (the safe side), every Osnes pane cracked at E1300's
median strength where eight held, and the vertical ground motion twenty to sixty times the
measured. Several of these comparisons helped choose BombCAD's defaults, so its entry is partly a
calibration result ([validation](validation.md#summary)).

## Running two cases with another code

What a second code, for instance an open finite-volume Euler solver, would do for the two
simplest scenes. Neither has been tried.

**`kb-surface-burst-free-field`.** The scene is axisymmetric: a 100 kg hemisphere of TNT on
a reflecting plane, which is half of a 200 kg sphere in free air.

1. Set up a 2-D axisymmetric (or 1-D spherical, using the symmetry) domain out past 28 m with
   non-reflecting far boundaries far enough out not to return a wave inside the 27.85 m gauge's
   positive phase.
2. Start the charge as the code does (JWL products, or an energy-equivalent balloon of 4.18 MJ/kg),
   and say which in `configuration`; whether the products burn in the air is the code's choice too,
   and moves the impulse.
3. Put probes on the ground at the eight positions in the case (`position_m`), record pressure
   against time from detonation, and take the peak above 101.325 kPa, the positive phase's
   integral (kPa·ms) and the time the shock arrives.
4. Write 24 predictions (run `100kg`, gauges `Z0.75` … `Z6`) and score them.

**`ufc-closed-room-gas-pressure`.** A closed rigid 6 m cube with the charge at its centre,
54 to 864 kg (0.25 to 4 kg/m³).

1. Model an eighth of the room with three symmetry planes, rigid adiabatic walls and no vent.
2. Fire the charge, run until the reverberations have decayed (tens of milliseconds), and read the
   room's mean pressure above ambient. Say when it was read, and whether the products burn in the
   room's oxygen: at the light charges the curve is about twice what detonation energy alone gives.
3. Write five predictions (runs `0.25kg-m3` … `4kg-m3`, gauge `room`, `quasi_static_gas_pressure`)
   and score them.

What would hold a second code up, found in writing these:

- **The source model is left open.** The cases give the charge, not how to start it; codes that
  differ only there will score differently, and the `configuration` text is the only record of it.
- **Read times and positive phases are not defined beyond the words above.** Two codes could read
  the room at different times, or end a positive phase differently on a noisy record; the case
  gives no algorithm.
- **No input decks or meshes.** Geometry is boxes and prose; a structure's supports, bars and
  materials are words a person has to turn into a model.

## What this doesn't yet do

- **No other code has run it.** The format is untested by anyone but its author; the first outside
  run will find what is missing.
- **Three of the ten are curves, not tests**: Kingery–Bulmash's two and UFC 3-340-02's, each a
  fit or design chart with little or no stated scatter, labelled as such.
- **Peaks and integrals only**: no pressure or displacement histories are scored, so a code can
  pass with the wrong shape of pulse.
- **Positions are approximate where the papers are**: the direction of Wu's gauge from the slab's
  centre, the side Yao's 1 m gauge sat on, how Alsubaei's columns stood relative to one another,
  Nian's ground, Wang's plate size. Each case's notes say which.
- **Uncertainty is mostly missing.** Few papers give it; most cases carry none and lean on the
  factor.
- **The factors are judgement**, set case by case, not from a statistical model; the summary
  weighs every case equally whatever its number of gauges or its reference's quality.
- **BombCAD's entry mixes configurations and dates** across cases, quotes ratios where the record
  kept only those, and leaves gaps where it never recorded a value; a fresh run of every case on
  one build would replace it.
- **The scorer checks the format itself** in the standard library; the JSON Schemas are there for
  other tools and are not run by it.
- **Licences vary**: two cases rest on sources without an open licence for their text (numbers
  only), which a reuser should check for their purpose; there is no versioned release of the
  benchmark, no DOI and no way yet to submit an entry.
