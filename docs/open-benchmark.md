# Open benchmark

Part of BombCAD's validation record written down so that any blast code can run it and be scored
the same way: ten cases, each a JSON file holding the scene, the charge, the gauges and the
measured (or reference) values with their uncertainty and full citations; a scorer; and BombCAD's
own entry, quoted from the record. The cases name no code's options. This is a first step: two
other codes, pyro2 and Clawpack, have run two of them ([a second code](#a-second-code-pyro2-20-october-2026),
[a third](#a-third-code-clawpack-22-october-2026)), and none has run the rest
([what this doesn't yet do](#what-this-doesnt-yet-do)).

| Path | What |
|---|---|
| `Benchmarks/open/cases/*.json` | The ten cases |
| `Benchmarks/open/schema/case.schema.json`, `results.schema.json` | JSON Schemas (draft 2020-12) for a case and a results file |
| `Benchmarks/open/results/bombcad-0.6.0-dev.json` | BombCAD's entry |
| `Benchmarks/open/results/pyro2-4.5.1.json`, `Benchmarks/open/other-codes/pyro2/` | A second code's entry for two cases, with its scripts and runs |
| `Benchmarks/open/results/clawpack-5.14.0.json`, `Benchmarks/open/other-codes/clawpack/` | A third code's entry for the same two, from the decks, with its scripts, histories and mesh study |
| `Scripts/open-benchmark/score.py` | The scorer: Python 3, standard library only |
| `Scripts/open-benchmark/make_cases.py`, `make_bombcad_results.py` | The generators that write the cases and BombCAD's entry |
| `Scripts/open-benchmark/test_score.py` | The scorer's tests, and a check that the committed JSON is exactly what the generators write; run by `make ci-test` |

```bash
python3 -I Scripts/open-benchmark/score.py Benchmarks/open/results/bombcad-0.6.0-dev.json
```

**Changing a case or the entry.** The JSON files are generated: edit the values in the
generator, not the file, then write them again and run the tests, which fail if a committed file
differs by a byte from what its generator writes.

```bash
python3 -I Scripts/open-benchmark/make_cases.py               # Benchmarks/open/cases/*.json
python3 -I Scripts/open-benchmark/make_bombcad_results.py     # Benchmarks/open/results/bombcad-0.6.0-dev.json
python3 -I Scripts/open-benchmark/test_score.py
```

Both take `--out` to write elsewhere.

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

## Reproducible two-case controls, 21 October 2026

The [versioned input decks](../Benchmarks/open/decks/README.md) now specify KB's free-field
case and the UFC room as `ideal-gas-balloon-v1`: exact sparse initial states, an EOS, boundaries,
meshes, time origin, sampling and algorithmic read rules. The source is a constant-volume ideal
gas with afterburning off, deliberately distinct from BombCAD's recommended models and from a
physical TNT detonation. The references and historical entry have not changed. The room control
will lack combustion energy relevant to the UFC curve; its score measures that approximation too.

`blastbench open-benchmark` runs these decks without the application charge depositor.
`Scripts/open-benchmark/run_decks.py` runs or imports histories, checks their provenance and
coverage, and extracts the existing scorer format. The portable Python extractor uses only the
standard library. It refuses truncated positive phases, missing gauges, undersampled records,
changed decks and history hash mismatches. Raw histories remain available, with the code version,
source commit, executable hash and initial-budget logs, separately from their scalar scores.

A second code can implement the documented initial states and CSV contract, then use the same
import, extraction and scoring commands. Clawpack has since run the room's deck as written and the
free field's physics on its own mesh ([a third code](#a-third-code-clawpack-22-october-2026)). The handoff no longer
leaves the source and read rules open for these two controls; translation to another solver,
mesh/time-window convergence and a real independent comparison are still outstanding.

### First control run

The [record](../Benchmarks/open/records/ideal-gas-balloon-v1/README.md) at source `32a3583a`
contains 29 predictions from all six shots, with receipts and diagnostics. KB free field passes
12/24 quantities and the room 3/5, with complete coverage. These deliberately simpler controls
are separate from the recommended model and historical entry; they are not a replacement score
for the ten-case benchmark. All input and extraction choices stayed fixed. The full pressure
histories and runtime snapshot are retained on StudioData, rather than committed; the record
states where they are and how to reproduce them. **A second-solver run is still needed.**

## A second code: pyro2, 20 October 2026

A cloud session ran two cases in [pyro2](https://github.com/python-hydro/pyro2) 4.5.1 (BSD-3-Clause,
PyPI `pyro-hydro`), unchanged: an open finite-volume code whose spherical-polar grid, one cell
wide about the equator with reflecting faces, makes a 1-D spherical run. It was chosen because it
installs with no compiler and supports a spherical blast without new numerics; Clawpack needed a
Fortran compiler the machine lacked, and OpenFOAM's packages were out of the machine's reach. The
scripts, the runs and how to rerun them are in
[`Benchmarks/open/other-codes/pyro2/`](../Benchmarks/open/other-codes/pyro2/README.md).

The runs were set up from the cases' prose a day before the decks above existed, yet chose the
decks' physics: a constant-volume balloon of 1,600 kg/m³ holding 4.184 MJ/kg, one ideal gas of
γ 1.4, released at t = 0, no afterburning. The free field is the 200 kg sphere the hemisphere is
half of, on 10 mm cells to 36 m; the room is a closed sphere of the cube's 216 m³, on 20 mm cells,
read as its volume-mean pressure at 80 ms. That is not the decks' 3-D mesh or the room's
100–120 ms window, so it is a deviation from `ideal-gas-balloon-v1`, not an import of it.

| Case | Code | Score | Passed | Coverage | Geometric mean ratio | Typical factor |
|---|---|---|---|---|---|---|
| `kb-surface-burst-free-field` | pyro2 4.5.1 | 0.96 | 23/24 | 24/24 | 0.95 | 1.14 |
| | BombCAD's entry | 1.00 | 16/16 | 16/24 | 1.02 | 1.12 |
| | BombCAD's control | 0.50 | 12/24 | 24/24 | 0.77 | 1.40 |
| `ufc-closed-room-gas-pressure` | pyro2 4.5.1 | 0.60 | 3/5 | 5/5 | 0.74 | 1.55 |
| | BombCAD's entry | 1.00 | 5/5 | 5/5 | 0.99 | 1.04 |
| | BombCAD's control | 0.60 | 3/5 | 5/5 | 0.74 | 1.55 |

- **Free field.** pyro2's peaks are 0.98–1.23 of Kingery–Bulmash (high close in, within 3% from
  Z = 2), its arrivals 1–8% early, and its impulses 0.74–0.93 (Z = 1.5 fails): the shortfall of a
  balloon without afterburning. Its impulses and arrivals have converged by 20 mm; the near peaks
  still rise 2% from 10 to 5 mm.
- **Room.** The volume mean is the energy balance of a charge that does not burn, 0.47–1.14 of
  the curve, as BombCAD's own record gives without afterburning.

**Against BombCAD's control.** The same balloon, so the two differ in numerics and mesh alone.
pyro2's free-field history, thinned to 50 µs, read with the decks' extractor
(`run_decks.incident`), over BombCAD's control on its 0.5 m cells:

| Z, m/kg^⅓ | 0.75 | 1 | 1.5 | 2 | 3 | 4 | 5 | 6 |
|---|---|---|---|---|---|---|---|---|
| Control / pyro2, peak | 0.39 | 0.50 | 0.53 | 0.58 | 0.61 | 0.63 | 0.64 | 0.65 |
| Control / pyro2, impulse | 1.05 | 1.11 | 1.08 | 1.03 | 0.99 | 0.99 | 0.99 | 0.99 |
| Control / pyro2, arrival | 0.79 | 0.90 | 0.90 | 0.92 | 0.95 | 0.97 | 0.98 | 0.98 |

The rooms agree within 0.3% (pyro2 at 80 ms against the control's 100–120 ms mean), and both sit
on the analytic energy bound. So the control's low peaks and early arrivals are its mesh (the
charge in one 0.5 m cell, the gauges read across 0.5 m), not the balloon: resolved, the same
balloon's peaks are within the free field's band. The impulses agree within 1% from Z = 3 out.
This is the first check of the control against a converged run; it does not test the 3-D code
on a finer mesh, which is still to do.

**What the case format left open, as the run found it, and where it stands now.**
- **Settled by the decks** for these two cases: the source (t = 0, density, specific energy, γ),
  the symmetry (the hemisphere as half a sphere), the ambient state, the read rules (arrival at
  half the peak, the positive phase about the peak, the room as a volume mean over a window), the
  sampling and the case version (each deck hashes its case).
- **The sampling still moves a resolved peak.** pyro2's raw maximum at Z = 1 is 1,665 kPa from
  every step and 1,514 kPa from 50 µs samples, 9% lower; at Z = 0.75 its impulse moves 3%. The
  decks' 50 µs is fine for the control's 0.5 m cells, not for a code that resolves the shock close
  in.
- **Still open:** what a code that cannot model the cube should keep (its volume, here); a
  structured set-up in the results file beside the free-text `configuration` (dimension, cells,
  source, ambient, far boundary, read rules); a check that the far boundary returns nothing inside
  the last gauge's positive phase (pyro2's outflow at 36 m does not, by its shock's speed); and
  decks for the other eight cases.

## A third code: Clawpack, 22 October 2026

A cloud session ran the two decks in [Clawpack](https://www.clawpack.org) 5.14.0 (BSD-3-Clause,
PyPI `clawpack`, built with gfortran and used unchanged), through PyClaw's wave-propagation
solver: Roe's Riemann solver, unsplit with transverse waves, the deck's floors and CFL. The
histories were imported and extracted with `run_decks.py`; the scripts, histories, receipts and
mesh study are in [`Benchmarks/open/other-codes/clawpack/`](../Benchmarks/open/other-codes/clawpack/README.md).

- **The room** is the deck as written: the whole cube on its 24-cell mesh from its
  `initial_cells`, its volume mean and window, differing only in the numerics the deck names for
  BombCAD (Roe and minmod, not HLLC). Its means agree with BombCAD's control within 0.07% and sit
  on the energy bound; from 24 to 96 cells a side they move by at most 0.07%.
- **The free field** is the deck's physics, gauges, sampling and read rules on a 2-D axisymmetric
  mesh with the rigid ground as a boundary: a deviation from the deck's 3-D mesh, and labelled so.
  The run was meant to test whether the ground reflection, which a 1-D run cannot have, changes
  the score. It cannot here: a hemisphere centred on the ground has the ground as a plane of
  symmetry, so its reflection is the mirror image and the exact answer is the 1-D sphere's. What
  the 2-D run tests is a code that has the ground as a boundary, on a grid the wave crosses.

| Case | Code | Score | Passed | Coverage | Geometric mean ratio | Typical factor |
|---|---|---|---|---|---|---|
| `kb-surface-burst-free-field` | Clawpack, 2-D, 62.5 mm | 0.96 | 23/24 | 24/24 | 0.92 | 1.12 |
| | pyro2, 1-D, 10 mm | 0.96 | 23/24 | 24/24 | 0.95 | 1.14 |
| | BombCAD's control, the deck, 0.5 m | 0.50 | 12/24 | 24/24 | 0.77 | 1.40 |
| `ufc-closed-room-gas-pressure` | Clawpack, the deck | 0.60 | 3/5 | 5/5 | 0.74 | 1.55 |

**The mesh study** (0.5 m to 62.5 mm over all gauges to 100 ms, and to 16 mm for the four nearest
on a 16 m domain): the free-field score is 0.54, 0.79, 0.96 and 0.96 on 0.5, 0.25, 0.125 and
0.0625 m cells. On the deck's own 0.5 m a second code scores about what BombCAD's control does,
with the same low peaks and early arrivals. The impulses and arrivals converge at about second
order to pyro2's 1-D values (Richardson estimates within 1% and 0.05 ms); the peaks converge at
first order or less and on the finest meshes are 1–7% below pyro2's. The far boundary returns
nothing: a 36 m domain reads every value as the 48 m domain does to five digits. On 16 mm cells
alone the two nearest ground gauges read low and early (at Z = 1, 1,279 kPa against 1,629 on the
axis at the same distance, and 0.08 ms early), an artefact of the scheme at the ground boundary,
which fails two more values: the one way, here, that the ground changed the score.

**What the run found about the contract.** In the README there, in full; the main points:

- No rule for **another mesh or dimension**, and no field in the receipt for a deviation: the
  extractor labels any imported history as the protocol.
- No stated **resolution** or mesh study, though the score depends on it (0.54 to 0.96).
- No bound on **energy drift**: PyClaw's standard axisymmetric source terms are not conservative
  and gained 41% of the charge's energy on 0.5 m cells (2% on 62.5 mm), which the extractor
  cannot see.
- **Floors and startup steps** are named but not defined, and decided whether runs survived; six
  first-order startup steps move near peaks by up to 3.4% on 31 mm cells.
- The **numerics** named are BombCAD's (HLLC), which Clawpack lacks; its 2-D HLLE solver is in
  error and fails within a millisecond.
- **Off the axes** the read rule refuses a scheme's precursor (half a pascal above ambient ahead
  of an undershoot), and ground-flush gauges, read in the first row of cells, read raw peaks 1–3%
  below gauges at the same distance 45° up.
- The 50 µs **sampling** still moves resolved peaks by about 3%.
- The ground can only be tested by a case with a **height of burst**.

## What this doesn't yet do

- **Two other codes have run two cases.** pyro2's 1-D runs found what the prose left open, and
  the decks now settle most of it; Clawpack ran the room's deck as written (3-D) and the free
  field in 2-D. No other code has run the free field on the deck's own mesh, or any structure.
- **Three of the ten are curves, not tests**: Kingery–Bulmash's two and UFC 3-340-02's, each a
  fit or design chart with little or no stated scatter, labelled as such.
- **Peaks and integrals only**: the two controls retain raw pressure histories, but no pressure or displacement histories are scored, so a code can
  pass with the wrong shape of pulse.
- **Eight cases still lack runnable decks and fixed read rules.** Their source and observation choices
  remain the runner's responsibility; structure inputs still include prose.
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
