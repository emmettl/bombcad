# Reference calculations

Independent Python implementations of the published methods BombCAD is judged against, so that its
outputs can be checked against them without trusting its own copies of those methods. They live in
`Scripts/reference/`, need Python 3 and NumPy only, and were written from the published sources
before BombCAD's own implementations were read; BombCAD's were read afterwards, to match inputs
and outputs and to list where the methods differ (below, under each reference).

| Reference | File | What it gives |
|---|---|---|
| [Kingery–Bulmash](#kingerybulmash) | `kingery_bulmash.py` | Incident and normally reflected peak pressure, impulse, arrival, positive duration and shock speed of TNT against scaled distance, surface and free-air bursts |
| [Oblique reflection](#oblique-reflection) | `oblique.py` | The reflected pressure coefficient against the angle of incidence |
| [Biggs SDOF](#biggs-sdof) | `sdof.py` | The elastic–plastic response of one-way members to triangular and bilinear pulses |
| [One-dimensional blast](#one-dimensional-blast) | `blast1d.py` | A spherical burst of TNT (JWL products) or of an ideal-gas balloon in air, gauge by gauge |
| [Comparison](#running-the-comparison) | `compare.py` | BombCAD's gauges against the above, by scaled distance |

The tests run with the other scripts' in `make ci-test`:

```bash
python3 Scripts/reference/test-kingery-bulmash.py
python3 Scripts/reference/test-sdof.py
python3 Scripts/reference/test-blast1d.py
python3 Scripts/reference/test-compare.py
```

## Kingery–Bulmash

**Source.** C. N. Kingery and G. Bulmash, *Airblast parameters from TNT spherical air burst and
hemispherical surface burst*, ARBRL-TR-02555, US Army Ballistic Research Laboratory, 1984: the
fits in the report's form, U = K0 + K1 log10 Z and the parameter 10^(Σ C_i U^i), with the
hemispherical surface burst's metric coefficients as the United Nations SaferGuard calculator and
IATG 01.80 carry them. The report and IATG could not be reached from the cloud session that wrote
it (its network reached only GitHub and the Python package index), so the coefficients were taken
from an open-source port of the SaferGuard calculator (github.com/mbozkaya/the-kingery-bulmash-blast-parameter-calculator,
MIT licence) and checked three ways:

- against IATG 01.80 (3rd ed., 2021) Table 5's worked examples, 1, 10 and 100 t at 50 m (Z 5,
  2.32 and 1.08 m/kg^(1/3)): every parameter within 0.6% (the fifteen numbers, in
  `tables/iatg-01.80-table5.json`, are as `KingeryBulmash.swift` transcribes them, read after the
  reference was written; IATG itself was out of reach, so this check shares that transcription);
- against the Rankine–Hugoniot relations that tie the independent fits together far from the
  charge: the reflected pressure within 2% of the normal reflection of the incident pressure
  beyond 4 m/kg^(1/3), the shock speed within 1.5% of the incident pressure's beyond 2, and the
  arrival time's slope within 5% of the shock speed from 0.3 to 35;
- the pieces meeting at their joins within 2%.

That last check found one slip in the transcription: the middle piece of the positive duration
(1.01 to 2.78 m/kg^(1/3)) had K0 = +2.12492525216, which takes the curve to 10⁻¹³ ms by Z = 1.5.
With −2.12492525216 it meets its neighbours within 1.5% and 0.9%, its U spans −2 to 2 like every
other piece, and it agrees with Swisdak's independent fit (below) within 1.6%. The sign is
restored in the code, with a comment; the Studio should confirm it against the report.

**Range.** 0.0674 to 40 m/kg^(1/3) (the positive duration from 0.178); NaN outside, never
extrapolated.

**Free air.** A spherical free-air burst of W is taken as a hemispherical surface burst of W / 1.8,
UFC 3-340-02's reflection factor for a burst on the ground (§2-13.3). Kingery and Bulmash's own
free-air fits are not implemented, so the free-air values hold only as well as that factor.

**Against BombCAD's.** `KingeryBulmash.swift` evaluates M. M. Swisdak's simplified fits (1994):
polynomials in ln Z, not log10 Z, fitted to the same curves. Over 0.2 to 40 m/kg^(1/3) the two
agree within 0.7% in incident pressure, 0.95% in reflected pressure, 0.3% in arrival, 1.6% in
positive duration (at Z 1.18), 2.1% in incident impulse (at Z 2.38, a join of Swisdak's pieces),
0.01% in reflected impulse and 1.0% in shock speed. Swisdak's incident pressure starts at 0.2
m/kg^(1/3), so BombCAD has no reference closer in; these start at 0.0674. The reference columns of
docs/validation.md's Kingery–Bulmash tables (100 kg, 0.75 to 6 m/kg^(1/3)) all agree with these
within 1.4% (the largest, an arrival rounded to 2.2 ms against 2.17). BombCAD takes a charge on
rigid ground as one of **twice** its mass in free air, where UFC takes 1.8; that matters only when
a surface burst is set beside a free-air curve (its Kinney–Graham comparison), where it moves the
scaled distance by 3.6%.

## Oblique reflection

UFC 3-340-02's Figure 2-193 (the reflected pressure coefficient C_r against the angle of
incidence) was not available to the cloud session, so `oblique.py` gives two stand-ins:

- **Two-shock theory** (`coefficient`): von Neumann's regular reflection of an ideal-gas shock,
  γ = 1.4 (H. W. Liepmann and A. Roshko, *Elements of Gasdynamics*, 1957, §4.11–4.13; G. Ben-Dor,
  *Shock Wave Reflection Phenomena*, 2nd ed., 2007, chapter 1), exact up to the detachment angle
  (about 40° for strong shocks, rising towards 90° as they weaken). Beyond it, in Mach reflection,
  C_r is taken to fall linearly in angle to 1 at grazing incidence: an approximation of the chart's
  trend, not a theory of the Mach stem.
- **UFC's own, as its Figure 2-9 implies it** (`ufc_coefficient`): the digitised Figure 2-9 in
  `Fixtures/UFC-3-340-02/oblique-reflection.json` (reflected pressure against angle for ten scaled
  normal distances) divided by Kingery–Bulmash's free-air incident pressure at each slant range,
  interpolated in angle and in log pressure. It holds from 0 to 80° over the figure's pressures.

**Tests.** Head-on, the Rankine–Hugoniot reflection; 1 at grazing; 2 for an acoustic wave at any
angle short of grazing; the strong-shock detachment angle between 38.5° and 41°; and, head-on at
30 kPa, the Figure 2-9 coefficient within 5% of the ideal gas's.

**Validity and the two set side by side.** The ideal gas holds for weak shocks: head-on at 30 kPa
C_r is 2.24 against UFC's 2.16, and at 100 kPa 2.74 against 2.73. It falls short of real air for
strong ones (2,000 kPa and more, within about 1 m/kg^(1/3)), where dissociation raises C_r past the
ideal gas's limit of 8. In the Mach region it departs from UFC's chart, which rises well before
detachment for moderate shocks (at 45°, 3.05 against the theory's 2.32 at 30 kPa, 3.67 against
3.17 at 100 kPa). The Figure 2-9 coefficient is itself rough: it carries Kingery–Bulmash's
free-air curve through the 1.8 factor and the digitising, and it is not smooth across the curves
(at 300 kPa it dips to 2.9 at 40° between 4.1 head-on and 3.8 at 60°). Use the theory where the
reflection is regular and the shock weak, and either only as a guide beyond.

**Against BombCAD's.** BombCAD computes oblique loads with the air solver itself, not from a chart;
its only use of these figures is the digitised fixture above, in comparisons. There is no BombCAD
implementation of C_r to compare.

## Biggs SDOF

**Source.** J. M. Biggs, *Introduction to Structural Dynamics*, McGraw-Hill, 1964, chapters 2 and
5, as UFC 3-340-02 §3-12 to §3-19 restates it: K_LM M x″ + R(x) = F(t) for a member's total mass M,
total load F and resistance R, with the transformation factors of Biggs's Table 5.1 (UFC Table
3-12) for simply supported, fixed and cantilever one-way members under a uniform load or a point
load (mid-span, or the cantilever's tip). The load–mass factor follows the regime, elastic,
elastic–plastic (fixed members, after the supports yield) and plastic, the velocity carried across
each change. Resistances and stiffnesses are UFC Table 3-1's and Biggs's; a fixed member's bilinear
backbone gives Biggs's equivalent elastic deflection X_E by equal energy, which reproduces UFC's
K_E = 307 EI/L⁴ for a uniform load and equal moments. Rebound is to the same resistance. Pulses
are piecewise linear (triangular and UFC's bilinear). Integration is Newmark's average
acceleration at a thousandth of the elastic period.

**Tests.** K_LM as tabulated (0.78/0.66 simple, 0.77/0.78/0.66 fixed, 0.65/0.66 cantilever, and the
point loads'); K_E = 307 EI/L⁴ within 0.2%; the elastic dynamic load factor of a triangular pulse
against Biggs's closed form within 0.5% for t_d/T from 0.05 to 3 (and the closed form's limits, π
t_d/T and 2, and 1.55 at t_d/T = 1); the elastic–perfectly plastic
ductility against the energy solution for an impulse (within 3%) and for a suddenly applied
constant load, μ = r / (2(r − 1)) with r = R_u/F (within 0.5%), the two asymptotes of Biggs's
response charts. Biggs's charts themselves were not to hand for readings in between; the
`python3 Scripts/reference/sdof.py` table gives the reference's values on the charts' axes for
the Studio to set against them.

**Validity.** One-way members, small deflections, no membrane or arching action, no damping by
default, no shear failure, rate effects only through the resistance given.

**Against BombCAD's.** `EnvelopeSDOF.swift` and `EnvelopeComponentResistance.swift` follow the same
equation per unit area, with these differences in method:

- **Load–mass factor.** BombCAD follows UFC §3-17.4: the elastic factor until first yield, then the
  mean of the elastic and plastic up to 2° of support rotation, then the plastic. The reference
  switches as Biggs does, at the regime boundaries.
- **Fixed one-way members.** `reinforcedOneWay` with fixed edges is elastic–perfectly plastic on
  the fully fixed stiffness 384 EI/L⁴ up to r_u = 8(M_N + M_P)/L², with no elastic–plastic stage
  after the supports yield. Biggs's bilinear backbone (384 EI/L⁴ to 12 M/L², then 384 EI/(5L⁴))
  is equivalent to K_E = 307 EI/L⁴, so BombCAD's fixed strips are 25% stiffer than the reference's
  equivalent system and reach their ultimate resistance at 0.80 of the deflection. Its elastic
  K_LM, 0.77, is also used up to r_u, where Biggs uses 0.78 between the supports' yield and r_u.
- **Rebound.** BombCAD takes a rebound resistance as a fraction of the inward one (UFC §3-19); the
  reference rebounds to the full resistance, as Biggs's charts do.
- **Load.** BombCAD holds the pressure constant over each recorded bin; the reference interpolates
  linearly.
- **Two-way panels.** BombCAD's walls, roofs and panes are two-way panels with Biggs's Table 5.5
  factors and yield-line resistances, which the reference does not implement.

## One-dimensional blast

**Source.** J. von Neumann and R. D. Richtmyer, *J. Appl. Phys.* 21 (1950) 232, in spherical
symmetry as R. D. Richtmyer and K. W. Morton, *Difference Methods for Initial-Value Problems* (2nd
ed., 1967), chapter 12, set it out: a Lagrangian staggered grid of shells, leapfrog, the work p dV,
and an artificial viscosity (quadratic coefficient 2, linear 0.05). Each shell keeps its material,
so the products and the air never mix. Two charges:

- **TNT**, detonated all at once (a constant-volume explosion) at 1,630 kg/m³, its products on the
  Jones–Wilkins–Lee equation of state with B. M. Dobratz and P. C. Crawford's parameters (*LLNL
  Explosives Handbook*, UCRL-52997 change 2, 1985): A 371.2 GPa, B 3.231 GPa, R1 4.15, R2 0.95,
  ω 0.30, E0 7.0 GPa (4.29 MJ/kg).
- **A balloon**, the pressurised ideal-gas sphere of H. L. Brode (*J. Appl. Phys.* 26, 1955, 766;
  *Phys. Fluids* 2, 1959, 217), γ 1.4, with any energy and density: `--energy 4.184e6 --density
  1600` is BombCAD's.

The air is an ideal gas, γ 1.4, 101,325 Pa, 1.225 kg/m³. Gauges at fixed radii record the pressure
of the shell containing them; the arrival is at half the peak (as `blastbench validate` takes it),
the positive phase runs from there to the first fall below ambient, and the impulse integrates it.

**Comparisons.** Brode's published overpressure–distance fit (6.7/Z³ + 1 bar above 10 bar; 0.975/Z
+ 1.455/Z² + 5.85/Z³ − 0.019 bar from 0.1 to 10 bar, as A. S. Smith and G. Hetherington, *Blast and
Ballistic Loading of Structures*, 1994, give it) and Kingery–Bulmash's free-air burst. Brode's
1959 tables for TNT were not to hand; the fit is the comparison here. Per kg^(1/3), 150 shells
across the charge and 3 mm/kg^(1/3) of air (`Scripts/reference/tables/blast1d-*.json`):

| Z, m/kg^(1/3) | TNT peak / KB | / Brode | TNT impulse / KB | TNT arrival / KB | Balloon peak / KB | Balloon impulse / KB | Balloon arrival / KB |
|---|---|---|---|---|---|---|---|
| 0.5 | 1.16 | 0.75 | 0.87 | 0.96 | 1.08 | 0.88 | 1.04 |
| 0.75 | 1.16 | 1.13 | 0.81 | 0.93 | 1.17 | 0.78 | 0.97 |
| 1 | 1.11 | 1.19 | 0.70 | 0.93 | 1.13 | 0.70 | 0.95 |
| 1.5 | 0.98 | 1.14 | 0.72 | 0.96 | 0.99 | 0.72 | 0.96 |
| 2 | 0.95 | 1.10 | 0.78 | 0.98 | 0.95 | 0.78 | 0.99 |
| 3 | 0.96 | 1.09 | 0.82 | 1.00 | 0.96 | 0.82 | 1.00 |
| 4 | 0.96 | 1.07 | 0.81 | 1.00 | 0.98 | 0.81 | 1.00 |
| 6 | 0.99 | 1.10 | 0.80 | 1.00 | 1.00 | 0.80 | 1.00 |
| 10 | 0.98 | - | 0.79 | 1.00 | 0.98 | 0.79 | 1.00 |
| 20 | 0.93 | - | 0.77 | 1.00 | 0.93 | 0.78 | 1.00 |

The balloon is BombCAD's (4.184 MJ/kg at 1,600 kg/m³, ideal gas); "-" where Brode's fit ends (below 0.1 bar).

- **Convergence.** Halving the air shells from 4 to 2 mm/kg^(1/3) moves the peaks by under 1% and
  the arrivals by 0.3% from 1 m/kg^(1/3); 8 mm reads 1–3% lower.
- **The viscosity.** Its linear term damps weak shocks as they travel: beyond 10 m/kg^(1/3) the
  peak moves by about 5% between linear coefficients of 0.02 and 0.05, and falls 10–15% further at
  0.15; the impulse and arrival move by under 1%. Without the term the shock rings and the peak
  overshoots by 12% at 20 m/kg^(1/3). Far-field peaks are therefore good to about ±5%.
- **Energy** is kept within 10⁻⁵ of the charge's.

**Validity.** The impulse is 77–82% of Kingery–Bulmash's from 2 m/kg^(1/3), as the products are not
burnt in the air (BombCAD's own ideal-gas runs read 13–22% low for the same reason). Close in,
within about 1 m/kg^(1/3), ideal-gas air (no dissociation) and the instantaneous detonation decide
the peak, which reads up to 17% above Kingery–Bulmash at 0.75; the positive duration there is cut
short by the products' own rarefaction and the second shock, and reads a sixth to two fifths of
the curves', so it is not a reference inside 1.5 m/kg^(1/3). Brode's fit itself is above both
inside 0.5 m/kg^(1/3).

**Against BombCAD's mapped start.** BombCAD's one-dimensional start (`RadialBlast`; air-blast
model, "A finely resolved start") solves the same problem with differences in method:

- an Eulerian MUSCL–Hancock scheme with HLLC fluxes on a radial grid of a twentieth of the charge's
  radius, against Lagrangian shells and artificial viscosity here;
- by default a balloon of the air's own gas (the ideal gas or hot air) at 1,600 kg/m³ and 4.184
  MJ/kg, against the reference's JWL products (4.29 MJ/kg at 1,630 kg/m³) or ideal-gas balloon; its
  JWL option carries the products as a tracer mixing with the air, where here they never mix;
- afterburning, hot air and an eddy diffusivity for the products and oxygen, none of which the
  reference has; compare its ideal-gas balloon runs (`--no-afterburn`) with
  `tables/blast1d-balloon-bombcad.json`;
- a charge on rigid ground spread as one of twice the mass, mirrored; the comparison reads the
  free-air oracle at Z / 2^(1/3) for a surface burst, the same assumption;
- it reaches at most 6 m/kg^(1/3); the bundled tables reach 20.

## Running the comparison

`compare.py` reads what `blastbench` and `scenebench` write and prints, gauge by gauge, BombCAD's
peak overpressure, positive impulse and arrival as ratios of Kingery–Bulmash's at the same scaled
distance and, with `--oracle`, of the one-dimensional solution's:

```bash
swift run -c release blastbench validate --histories runs --until 0.25
python3 Scripts/reference/compare.py runs --mass 100 --oracle
```

```bash
python3 Scripts/reference/compare.py Benchmarks/StreetInteraction/m4-max/report.json \
    --oracle Scripts/reference/tables/blast1d-balloon-bombcad.json
```

```bash
python3 Scripts/reference/compare.py --self-test
```

It recognises each output by its contents:

| Output | Gauges | Notes |
|---|---|---|
| `blastbench validate --histories DIR` | One CSV per gauge, its Z in the name | Peak, impulse and arrival worked out from the history; `--mass` (validate's default, 100 kg), `--tag` |
| `blastbench groundmotion --out DIR` | `runs[].air`, mass in the file | Surface burst |
| `scenebench street` and `envelopes` `report.json` | The open layout's run, charge from `<layout>-layout.json` beside it | A burst 1 m up compared as a surface burst at the slant range; impulse over the whole window; arrival at 1 kPa |
| `scenebench envelope-openings --out` | The incident peak at the front wall, 28 m | Peak only |
| `scenebench district-compare` `comparison.json` | The `line` peaks and the `arrivals` | Arrival 500 Pa above the first sample |
| `{"mass_kg", "burst", "gauges": [{"z" or "range_m", "peak_pa", "impulse_pa_s", "arrival_s"}]}` | Anything else, and `blast1d.py --json` | |

`blastbench validate` writes no JSON of its own, only its printed tables and, with `--histories`,
the incident histories; no output carries the reflected (wall) gauges, so those are compared by
hand from validate's printed tables. The arrival is defined differently in each output (half the
peak, 1 kPa, 500 Pa), which moves arrival ratios by a few per cent close in.

`--self-test` runs on the bundled tables alone: Kingery–Bulmash against IATG 01.80's examples, the
bundled one-dimensional TNT solution against Kingery–Bulmash, and each reader on a made-up output
holding Kingery–Bulmash's own values.

**The committed street benchmark**, its open-ground control (2 kg 1 m up, 0.125 m cells, today's
defaults), reads 0.73–0.87 of Kingery–Bulmash's peak at 7 to 21 m/kg^(1/3), 1.00–1.07 of its impulse
(over the whole window, the ground's reflection included) and 1.00–1.02 of its arrival.

## Limitations

- The Kingery–Bulmash coefficients were checked against IATG's examples, physics and Swisdak's fit,
  not against the 1984 report itself, which was out of reach.
- UFC's Figure 2-193 was not available; its stand-ins are theory (regular reflection) and a
  coefficient backed out of Figure 2-9, which is rough.
- Biggs's response charts were not available for readings between their asymptotes.
- The one-dimensional solver has no afterburning, real-gas air or programmed burn, and its
  far-field peaks depend on its viscosity by about ±5%.
- The references need NumPy (`sdof.py` needs nothing beyond Python); without it their tests print
  SKIP and pass, so a machine without NumPy runs none of them.
