# Cloud report: independent reference calculations

Branch `cloud/reference-calculations`, from `main` at 40665a0. Written on a Linux cloud box that
cannot build or run BombCAD: nothing here was built or tested in Swift or Metal, and every BombCAD
number quoted below comes from its committed documents, tables and benchmark files.

## What is done

- `Scripts/reference/kingery_bulmash.py`: Kingery–Bulmash (ARBRL-TR-02555) for TNT, in the
  report's log10 polynomial form, hemispherical surface burst from 0.0674 to 40 m/kg^(1/3) (incident
  and reflected peak, impulses, arrival, positive duration, shock speed), and free air as a surface
  burst of W / 1.8 (UFC 3-340-02 §2-13.3).
- `Scripts/reference/oblique.py`: the reflected pressure coefficient against the angle of incidence,
  by two-shock theory for an ideal gas (regular reflection, exact) with a stated linear taper in the
  Mach region, and the coefficient UFC's own Figure 2-9 implies (the repository's digitised fixture
  over Kingery–Bulmash), standing in for Figure 2-193, which was not available.
- `Scripts/reference/sdof.py`: Biggs's elastic–plastic SDOF for simple, fixed and cantilever one-way
  members, uniform or point load, Table 5.1 / UFC Table 3-12 factors switching with the regime,
  triangular and bilinear pulses, the closed-form elastic DLF and the impulsive and step asymptotes.
- `Scripts/reference/blast1d.py`: a Lagrangian (von Neumann–Richtmyer) spherical solver for TNT with
  JWL products (Dobratz and Crawford 1985) or an ideal-gas balloon, compared with Brode's fit and
  Kingery–Bulmash; fine solutions to 20 m/kg^(1/3) bundled in `Scripts/reference/tables/` (TNT, and
  BombCAD's balloon of 4.184 MJ/kg at 1,600 kg/m³).
- `Scripts/reference/compare.py`: reads `blastbench validate --histories`, `blastbench
  groundmotion`, `scenebench street`/`envelopes` reports, `scenebench envelope-openings`,
  `scenebench district-compare` and a simple gauges format, and prints BombCAD's peak, impulse and
  arrival as ratios of Kingery–Bulmash and of the 1-D oracle by scaled distance; `--self-test` runs
  on the bundled tables alone.
- Four test files, added to `make ci-test`; `Scripts/check-affected.py` now counts
  `Scripts/reference/` (its scripts and tables) as documents-and-scripts, with a test.
- `docs/reference-calculations.md` (sources, validity, differences in method from BombCAD, how to
  run the comparison), linked from docs/validation.md's "Blast loads against empirical references"
  and from the README's document table.

Independence: each reference was written from the published method before BombCAD's version was
read. Two exceptions, both stated in the docs: the comment header of `KingeryBulmash.swift` (which
names Swisdak and IATG, no coefficients) was seen while surveying the repository before the task
began; and IATG 01.80's fifteen worked-example numbers were copied from `KingeryBulmash.swift`
after the reference was written, because IATG was out of reach, so that one check shares BombCAD's
transcription of IATG.

The cloud box reached only GitHub and the Python package index: not the 1984 report, IATG, UFC
3-340-02's chart data on WBDG, nor Brode's or Biggs's books. The Kingery–Bulmash coefficients came
from an MIT-licensed open-source port of the UN SaferGuard calculator and were checked against
IATG's examples, the Rankine–Hugoniot relations and Swisdak's independent fit (all within 2.1%).
That found one slip in the port: the middle piece of the positive duration (1.01–2.78
m/kg^(1/3)) had K0 = +2.12492525216, which sends the curve to 10⁻¹³ ms; −2.12492525216 joins its
neighbours within 1.5% and agrees with Swisdak within 1.6%. **Please confirm that sign against
ARBRL-TR-02555.**

## Test results

Run on the cloud box with Python 3.13 and NumPy:

| Test | Result |
|---|---|
| `python3 Scripts/reference/test-kingery-bulmash.py` | 14 tests, OK |
| `python3 Scripts/reference/test-sdof.py` | 11 tests, OK |
| `python3 Scripts/reference/test-blast1d.py` | 8 tests, OK (about 12 s) |
| `python3 Scripts/reference/test-compare.py` | 5 tests, OK |
| `python3 Scripts/reference/compare.py --self-test` | 0 failed |
| `python3 Scripts/test-check-affected.py` | OK |
| `python3 Scripts/check-doc-links.py` | OK |

The references need NumPy (`sdof.py` needs only Python). Without it, their tests print SKIP and
exit 0, so `ci-test` stays green on a machine without NumPy but checks nothing there; the Mac mini
should have NumPy for these to count (`Scripts/plot-*.py` already use it). The other `ci-test`
scripts were not rerun here.

## Where BombCAD's documentation or tables disagree with the references

Nothing in BombCAD's own Kingery–Bulmash numbers disagrees: its Swisdak fits agree with the 1984
form within 0.7% (incident pressure), 0.95% (reflected), 0.3% (arrival), 1.6% (duration), 2.1%
(incident impulse, at a join of Swisdak's pieces), 0.01% (reflected impulse) and 1.0% (shock speed)
from 0.2 to 40 m/kg^(1/3), and the reference columns of docs/validation.md's Kingery–Bulmash tables
(100 kg, 0.75–6 m/kg^(1/3)) within 1.4%. The differences found:

1. **Fixed one-way members in the SDOF are 25% stiffer than Biggs's equivalent system.**
   `EnvelopeComponentResistance.reinforcedOneWay` with fixed edges is elastic–perfectly plastic on
   384 EI/L⁴ up to r_u = 8(M_N + M_P)/L², with no elastic–plastic stage after the supports yield, and
   its comment cites UFC Table 3-8. Biggs's bilinear backbone (384 EI/L⁴ to 12 M/L², then
   384 EI/(5 L⁴) to r_u) is equivalent by energy to K_E = 307 EI/L⁴ (the reference reproduces this
   within 0.2%), so BombCAD's fixed strips reach r_u at 0.80 of the deflection and have a period 0.89
   as long in that equivalent sense. Its elastic K_LM 0.77 is used up to r_u, where Biggs takes 0.78
   between the supports' yield and r_u. Simply supported and cantilever strips match. Worth
   checking against Table 3-8 itself, which the cloud box could not open.
2. **The SDOF's load–mass factor is averaged, not switched.** BombCAD follows UFC §3-17.4 (the mean
   of the elastic and plastic factors up to 2° of support rotation); Biggs, and the reference,
   switch at the regime boundaries. A documented choice, not an error, but the two will differ once
   a member yields; the reference can measure by how much on any given system.
3. **The IATG agreement is understated.** docs/validation.md says the curves agree with IATG
   01.80's examples "within 6%"; Swisdak's fits agree with those fifteen numbers within 0.5% (and the
   1984 form within 0.6%). The test's tolerance (`ScenarioTests`, 6% on three of the five
   parameters) could be tightened to 1% and cover all five.
4. **A charge on rigid ground is twice its mass in free air, against UFC's 1.8.** It matters only
   where BombCAD sets a surface burst beside a free-air curve (its Kinney–Graham comparison), where
   it shifts the scaled distance by 3.6%.
5. **No Kingery–Bulmash reference inside 0.2 m/kg^(1/3).** Swisdak's incident pressure fit starts at
   0.2, so `KingeryBulmash.point(at:)` returns nil closer in, where close-in comparisons are
   quoted; the 1984 form here holds from 0.0674.
6. **The mapped start's close-in impulse against the oracle (to check, not a finding).** docs/
   air-blast-model.md reports the mapped start's incident impulse at 125–175% of Kingery–Bulmash at
   0.5–0.75 m/kg^(1/3), with afterburning and hot air. The 1-D oracle without afterburning reads
   0.78–0.88 of it there, BombCAD's balloon included; the gap is afterburning's to explain. Running
   the mapped start on the ideal gas without afterburning (`blastbench validate --no-afterburn
   --histories DIR --z 0.5,0.75,1,2,4,6`) through `compare.py --oracle
   Scripts/reference/tables/blast1d-balloon-bombcad.json` would isolate the scheme from the
   chemistry.
7. **Machine-readable outputs.** `blastbench validate` writes no JSON, and no output anywhere
   carries the reflected (wall) gauges, so the wall comparison can only be read from validate's
   printed tables. Arrival is defined three ways across the outputs (half the peak, 1 kPa, 500 Pa
   above the first sample) and impulse two (positive phase, or the whole window's positive part in
   the street reports). A `--json` on `validate` with incident and wall gauges would let
   `compare.py` cover the main comparison directly.
8. **One digitised curve in the UFC Figure 2-9 fixture may be mislabelled (low confidence).** Backed
   out against Kingery–Bulmash, the curve labelled 3.0 ft/lb^(1/3) in
   `Fixtures/UFC-3-340-02/oblique-reflection.json` jumps from 1.23 to 1.47 of two-shock theory
   between 35° and 40° while its neighbours (1.9 and 5.3) fall; it would be worth a look against the
   figure.

The committed street benchmark's open-ground control (2 kg 1 m up, 0.125 m cells) reads 0.73–0.87
of Kingery–Bulmash's peak from 7 to 21 m/kg^(1/3), 1.00–1.07 of its impulse (whole window) and
1.00–1.02 of its arrival, consistent with validation.md's "peaks read low".
