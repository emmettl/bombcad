# Independent review of the validation record

A review of BombCAD's [validation record](validation.md), its [evidential standing](standing.md)
(`StandingTable` in `Sources/BlastCore/EvidentialStanding.swift`), the
[roadmap](roadmap.md)'s standing and limitations, [data wanted](data-wanted.md) and the model
documents, made on 10 October 2026 by a session that had no part in building or judging any
of the comparisons. It reads them as an outside structural or blast engineer would: are the
claims as strong as the evidence, and no stronger?

The record is unusually candid. Nearly every weakness found here is stated somewhere in its
sections: the slab test's sensitivity to load, the supports, the strain-rate laws, the
blow's stiffness, the chamber's joints. The problems are mostly in the **summaries** (the
README's table, validation.md's summary, the roadmap's limitation 1 and the standing table),
which select the best mesh or the best case, carry numbers from earlier model versions, or
drop the caveats the sections give. A reader who reads only the summaries comes away with a
better opinion of the model than the sections support.

Findings are ranked by severity: **high** where a summary's standing would change if the
caveat were carried; **medium** where a number or wording is wrong or a caveat material to a
user is missing; **low** for small inconsistencies. Each gives the evidence and a fix. Those
marked *fixed* were corrected in the documents with this review (wording and numbers only;
no model code or result was changed), so the quotations below are of the documents as they
were found. The rest are listed for the user at the end.

## High

### 1. The default strain-rate laws were chosen on the tests they are judged against

**Evidence.** Both default laws were adopted after, and because of, the drop-weight
comparisons:

- validation.md, [the slab](validation.md#results): the tables "were made with Malvar and
  Ross's tensile law and Malvar and Crawford's for the bars, the defaults until the
  drop-weight impacts and close-in slabs below showed them too stiff".
- validation.md, [the tensile law decides it](validation.md#beams-struck-by-a-falling-weight):
  the fib Model Code 2010's law "brings the beams with stirrups within the scatter, and is the
  default".
- validation.md, Ando's B36 pushed slowly: "That led to the CEB's law for the bars".
- concrete-model.md, steps 27–28 and the strain-rate section: the CEB's law "brings the
  impacts closer ... and that law ... became the default".

Yet the impact section concluded "with nothing fitted" and its model paragraph said
"nothing is fitted". Choosing between published laws by their agreement with a test is a
fit of one discrete parameter; the test is then not independent evidence for that choice.

The choice moves the other headline result too: the contest slab gives 93–99% under the old
laws and 105–115% under the new ([table](validation.md#results)). The spread across
published laws, 93% to 115%, is the honest measure of the model's uncertainty on that slab.

Mitigation, which the record also gives: the CEB's law for bars is supported independently
by Lin et al.'s tension tests of HRB400 bars (within 7%, concrete-model.md, strain-rate
effects). The Model Code's tensile law has no such independent support here, and is itself
written from memory ([data wanted §3](data-wanted.md#3-formulae-quoted-from-memory); its two
branches do meet at 10 per second, 1.336, which checks it a little).

The slab test is not independent of the model either: concrete-model.md's
[how the model got here](concrete-model.md#how-the-model-got-here) opens "The model was built in
steps, each tested against the slab benchmark", and mechanisms or defaults were added because
the slab or one of its sensitivity cases failed (the hourglass control's compressive term, bar
rupture judged over a debonded length, the bars' rate taken along them, when crack axes freeze).
validation.md said "Nothing was fitted to the test". Likewise permanent crack slip with a
dilatancy of 0.5 (a recalled value) was added to make Ando's beams keep their deflection, and a
known error (slip widening cracks) is kept as the default because correcting it makes the
beams too strong (declared, concrete-model.md, shear across cracks).

**Fix.** Say in the impact section, the summary and the standing that the tensile law was
selected among published laws on Saatci's beams, and the bars' on Ando's (with Lin et al.'s
independent support); drop "nothing fitted" for the impacts; quote the slab's spread across
laws; say the slab was the model's development benchmark. *Fixed* in validation.md (summary,
the slab's model and the impact section). A held-out test (a second
impact programme, such as Hrynyk's slabs in data wanted) would turn this calibration into
validation.

### 2. The contest slab's convergence is claimed but not shown

**Evidence.**

- validation.md, [results](validation.md#results): with the default laws the peak is "105–115%
  on 4 to 32 elements, converging at about 124 mm". The meshes give 114, 113, 121 and 124 mm
  on 4, 8, 16 and 32 elements, rising from 8 on, and on 32 the slab loses 60,152 elements.
- The 25 mm strip, which bends as the slab does, is quoted as 121, 127 and 131 mm on 8, 16 and
  32 elements ([finer still](validation.md#structural-response-against-a-real-test), from the
  8 October version), still rising by about 5 mm a halving. But the later table of
  [bars that slip across the tests](validation.md#bars-that-slip-across-the-tests), dated
  10 October and "on the present defaults", gives the same strip **127 mm on 16 and 278 mm on
  32, with 233 elements removed**: the hinge running away on the finest mesh.
- [What this does and does not show](validation.md#what-this-does-and-does-not-show) still says
  "within about 7% at the peak on meshes of 4 to 32 elements through the thickness, converging
  at 3% below the measurement", which describes the earlier laws (93–99%), not the defaults.
- The bold "**The peak has converged at 105 to 107 mm**" is also under the earlier laws, in a
  paragraph a reader can take as current.
- **Rerun with this review** (`blastbench slab --strip 25 --layers 8,16,32`, outputs in
  `/Volumes/StudioData/bombcad/review/slab-strip-8-16-32.txt`): **121, 127 and 278 mm**, the
  32-element strip still going at 80 ms with 233 elements failed (RMS 7.2, 10.9 and 61.1 mm). The
  10 October table stands; the 131 mm is stale. On today's defaults the finest strip fails.

The slab test is the record's best-supported structural result (README: "Moderate"); a
monotone rise with refinement and a runaway on the finest strip are not convergence.

**Fix.** Say the peak rises with refinement under the defaults (113 to 124 mm from 8 to 32
elements) and has not been shown to converge; give both strip results with their dates; say
the "converged at 105–107 mm" and "within about 7% ... 3% below" statements are for the
earlier laws. *Fixed* in validation.md and concrete-model.md. A rerun of the full slab on 32
elements on today's defaults (36 minutes or more) would say whether it fails as the strip does.

### 3. The impact standing rests on one mesh and one beam family, and omits what disagrees

**Evidence.** README ("Impact: Moderate: drop-weight beams within 12–24% under light drops,
−5% to +3% under heavy ones"), the summary and the standing quote Saatci's beams with
stirrups on 16 elements. The sections also show:

- **Mesh dependence.** On 24 elements Saatci's heavy drops are +2% to +18% (−1% to +17% in
  the 10 October rerun) and the light ones +17% to +28%; Ando's fourteen faster beams are off
  by 15% on average on 16 elements but **53% on 24**, A24 at 5 and 6 m/s, A36 at 4 m/s and B48
  at 6 m/s two to three times too far. The finer mesh is much worse. (I recomputed both
  averages from the table: 14.6% and 53.1% mean absolute error, median 5% on 16.)
- **The 24-element columns are stale**: they "predate confinement taken from the stresses
  carried ... which moved the 16-element ones by up to a fifth".
- **The blow is about twice too hard**: the model strikes with about 3,200 kN (light) and
  4,800 kN (heavy), against 1,421 kN measured for SS3a-1 under the light drop (2.3 times), and the reactions under the
  heavy drops are 350–650 kN against 592–682 kN measured (up to 40% low), under the light
  ones 400–450 against 305–356 kN (up to 48% high).
- **Ando's supports are chosen against the paper's description.** The paper's jig lets the
  beams "turn and nothing else"; the model clamps them, which statically carries 112 kN
  against 68 kN measured (about 53 kN simply supported). Pins and plates were tried and gave
  2.0 m beams twice as far and every beam two to five times too far; the clamps are kept
  ("How the jig held the beams decides much of this").
- "**Within the scatter of the tests**" (impact section, what this shows): Saatci tested one
  beam of each kind, and no scatter is given.
- Saatci's beam without stirrups is damaged (246 elements) by a light drop it survived, and on
  24 elements splits along its bars.

**Fix.** Quote both meshes, the blow and the reactions in the summary; replace "within the
scatter" with the numbers; say the Ando supports are the stiffest of three idealisations and
are stiffer than the test's static stiffness. Consider "Low to moderate" for impact until a
mesh-converged result exists. *Fixed* in validation.md's summary and impact section, and the
README row; the standing's impact evidence is passed to the standing session.

### 4. Agreement found among support idealisations, not carried to the summaries

**Evidence.** Supports were assumed in every structural test (the sources rarely describe
them), and they move results by more than the agreement claimed:

| Test | Supports as modelled | Alternatives tried | Effect |
|---|---|---|---|
| Contest slab | Pin and roller on lines of nodes | 1 in bearings held down / free | 113 mm → 79–87 mm (73–81% under the old laws); "the supports matter by 15–25%" |
| Wu's slabs | Held lengthwise at one edge | Both edges | 14.4–14.9 mm → 11 mm, a quarter stiffer |
| Ando's beams | Clamps | Pins; turning plates | Clamps best on average; pins 59%, plates 2–5 times too far |
| Chiquito P7 | Ends held lengthwise | Free to slide | 113 → 92 mm permanent |
| Wang's slabs | Fixed edges | Sliding edges; hinge lines | 3.1 → 6.3 mm against 19.7; hinge lines tear |

The sections say so; the summaries don't. Where the chosen idealisation is the one that
agrees best, the agreement is partly a selection.

**Fix.** Add a sentence to the summary that support conditions are assumed and move the
structural results by 15–25% (slab, Wu) or more (Ando, Wang). *Fixed* (summary note).
Larger: carry a support-condition band into the standing.

### 5. "Contact charges hole them" describes a numerical runaway

**Evidence.** validation.md summary: "contact charges hole them, not to size"; README;
roadmap limitation 1 ("are holed by contact charges, though not to size"). The section
says "These holes were mostly the step running away": the 18.9 and 50.5 cm holes came at the
default time step, where compacted concrete is "several times stiffer than the step allows";
at a stable quarter step they are 14.0 and 8.3 cm against 27.5 and 23.5 cm measured, half and
a third of the size. The [holes section](validation.md#holes-under-close-in-and-contact-charges)
confirms that under its default rules the model holes no other slab that the tests holed
(Chiquito's at 0.5 m, Hupfauf's 20 and 25 cm slabs, Wu's under 0.2 kg).

The standing's note for "Fragments removed" says the option "holed Hupfauf's and Wu's slabs
near size"; the table it cites gives Wu's S4 at 43.2 cm against 27.5 (157%) and D4 at 15.5
against 23.5 (66%), and it holed Hupfauf's 30 cm slabs, which held.

**Fix.** "Contact charges hole them only at a stable step's half to a third of the measured
size; the larger holes at the default step are the step running away." *Fixed* in validation.md
(summary and section), the roadmap and the standing's note.

### 6. The chamber is compared with the paper's model more than with the measurement

**Evidence.** README: "Low: the chamber's roof about twice as stiff as the paper's model".
The measurement is a residual of 95 mm; the model leaves 15 mm, **a sixth**. The comparison
"twice as stiff" is with the paper's own LS-DYNA model (87 mm peak). The peak also has not
converged: 38–42 mm on 0.1 m and 50 mm elements, 65 mm by 30 ms on 25 mm elements, which then
tear at the wall tops ("Until it is understood the chamber's converged answer is not known").
The summary row omits that. The error is on the unsafe side: too stiff, too little residual
damage.

**Fix.** Lead with the measurement: "its edge left 15 mm up against 95 mm measured (a sixth),
the peak about half the paper's model's, and not converged on the finest mesh". *Fixed* in
the README, the summary and the roadmap's standing paragraph.

## Medium

### 7. Janney's beam: stale numbers in four places

The summary, README, roadmap limitation 1 and the standing give "peak moment 97–99%; failure
at 38–52 mm". The section's table gives 98% and 99% (40.5 and 41.0 kN m), failing at 57 mm on
12 elements and holding to 60 mm on 24; it says 38 and 52 mm were "before crack widths were
read over each crack's own band". The later tables, on the present defaults, give 42.0 and
41.2 kN m (101% and 99%), failing at 53 mm on 12 and holding on 24 (concrete-model.md step 29:
"on 12 elements it fails at 53 mm, from 57"). Nothing gives 97%. *Fixed* in validation.md,
README, roadmap and the standing. (Six elements through are 17% strong, the unsafe
direction; the summary now says so.)

### 8. Reflected impulse "within 5% everywhere on 0.125 m cells"

[Reading these](validation.md#kingerybulmash-the-design-practice-standard): the 0.125 m column
is 96, 102, 102, 105, 104, 98, 95 and 94%: within 6%, not 5%. *Fixed.*

### 9. Close-in numbers

- Summary: "the impulse under the charge 86–95% of Kingery–Bulmash's"; the section gives
  84–95% (3.7 kPa s against 4.4 is 84%). *Fixed.*
- Summary: "gauges beside the slab 75–80% of those measured": against the paper's text
  (2.5 MPa). Its Figure 9 gives 3.3–3.6 MPa, against which the model's 1.98 MPa is 55–60%. The
  source disagrees with itself, and the summary picks the kinder value. *Fixed* (both given).
- README: "Close-in and contact charges: Good for the load". In contact the hot-air charge
  loads a slab with about twice the impulse of the products' own equation of state
  ([contact charges](validation.md#slabs-under-contact-charges)). Good for the load only from
  0.3 m/kg^(1/3) out. *Fixed.*

### 10. TNT equivalence is not caveated where agreement is quoted

Chiquito's PG2 and dynamite are "given as TNT equivalents"; Hupfauf's SEMTEX 10 is converted
by "the thesis's own factors" for energy-equivalent impulse; Wang's aluminised charge is taken
"as 10 kg of TNT, as the paper states" (and its impulse proves 75–82% of that, 94–104% with
afterburning). The load's agreement close in ("within about a tenth") is only as good as the
equivalence, which for commercial explosives is commonly uncertain by 10–20% and depends on
whether peak or impulse is matched. The summaries don't say this. *Fixed* (a note in the
summary).

### 11. Design curves and fits are called "measured agreement" without their scatter

Kingery–Bulmash is a polynomial fit to many tests, and UFC 3-340-02's Figure 2-152 is a
design chart read off by hand (`UFC340.swift`); Church's fit and Molkov's correlation are
fits too. The standing's top level, "Measured agreement", and the README's "Good" are
earned against these, but neither the record nor the standing gives the references' own
scatter, so "within 6%" cannot be weighed against it. The agreement may well be inside the
reference's own uncertainty, which would make the match less informative than it looks.
**Not fixed** (needs the scatter from the sources); listed below.

### 12. Peterson's beams: impact force fitted, then reported as agreement; missing from the summary

The fibreboard pad is "set so that the struck beams' impact forces come out about as measured";
the result then reads "At a shear span of one depth the forces come out as measured: impact
within the scatter". The reactions are partly independent, the impact force is not. The test
is missing from validation.md's summary table altogether, though it holds the record's clearest
unsafe-side result: the deep and short beams with stirrups hold where every test beam crushed
its strut. *Fixed* (a clause in the summary; "the impact force set by the pad" in the section).

### 13. Ando's beams "up to 3 m/s within 15%", and "break at the speed the tests did"

At 1 m/s A24 gives 1.4 mm against 2 (−30%) and A36 2.2 against 1.5 (+47%): within the 2 mm
reading, not within 15%. The roadmap says Ando's beams "break at the speed the tests did":
A36 does; B36, which broke in the test at 5 m/s, "bends but holds"; A24, broken in the test
at 5 and 6 m/s, is not said to break. *Fixed* in validation.md and the roadmap.

### 14. Wu's slabs: "Moderate for bending under the larger charges"

The larger charges are one charge size, two shots (S8, D8), on one mesh (8 elements through),
with lengthwise restraint at one edge (both edges: a quarter stiffer). Six of the eight
non-contact shots come out at 40–70% of the measured peak: too stiff, the unsafe direction,
and not explained by the load or the mesh. "Moderate" from two shots is generous; the summary
now says "two shots". *Fixed* (wording); the level is the user's call.

### 15. The slab's sensitivity to its load is larger than the agreement claimed

A 5% change in load moves the peak 13–14%, and the pressure record was read off a plot by hand
([sensitivity](validation.md#sensitivity)). The section says "Agreement within a few per cent
on one test with this much sensitivity is partly luck". The summary and README quote 105–115%
without this. *Fixed* (a clause in the summary).

### 16. Stale statements across the documents

- roadmap.md, [standing of the project](roadmap.md#standing-of-the-project): "Against
  measurements it is close on one test (a slab) and too stiff on another (a full-scale
  internal explosion)". There are now eleven member tests. *Fixed.*
- roadmap.md limitation 1: "compared with eight tests". *Fixed* (eleven member tests, a crack
  test and two footing tests).
- roadmap.md planned work 2 ("Done" notes): OA1 "11–12% strong on fine meshes" (now 11–15%);
  Saatci "light drops within 10%, heavy ones within −8% to +16%" (now 12–24% and −5% to +3% on
  16 elements). *Fixed.*
- roadmap.md limitation 3: "rooms' gas half the design value": 48–114% by default, half only
  for light charges. *Fixed.*
- validation.md, slab section: "The combination has still not been compared with a test":
  the close-in slabs, Wu's and Wang's slabs and the chamber all couple the air solver to a
  structure. *Fixed.*
- validation.md, chamber: "The one test so far that couples a real charge to a real
  structure, and the only one that reaches failure". *Fixed.*
- validation.md, verification: "The test suite has 114 tests"; there are about 1,050 `@Test`
  functions. *Fixed* (no count).
- validation.md, what is missing: item 1 (cracks that turn until they open) is done; item 2
  asks for "a sixth structural test ... a member with stirrups that failed in shear", which
  Peterson's beams are. *Fixed.*
- The section openings number the tests ("the fifth structural test", "the sixth and
  seventh") in an order that skips Ando's and Peterson's beams. *Fixed* (numbering dropped).

### 17. Footings: a non-default sand, and a default chosen after the shaken tests

Both footing comparisons use sand of 80 MPa shear modulus, "the one input not taken from the
test ... an estimate", twice the default sand's 40 MPa. On 40 MPa the first packet's moment is
0.34 of P L / 2 against 0.53/0.37 measured. Users on the default sand get a different footing
from the one compared. The cyclic sand became the default "since the shaken tests" and takes
its share given back from Gajan's push on the same sand, so the FoRDy comparison is not wholly
independent of it. And the summary's "peak rotation within 22% where the test did not lurch"
holds for the surface footing only: the embedded footing's first event rocks a third as far.
*Fixed* (the summary names the surface footing and the 80 MPa sand).

### 18. Stale numbers in the structural model documents

- concrete-model.md limitation 1: "**Validated against three tests**", "Nothing in shear,
  punching or direct shear has been compared with a test", Janney's beam "99% and 97%", "six
  elements run 20% strong"; limitation 4 "no test of a member that failed in shear has been
  run"; item 4 OA1 "11–12% strong". *Fixed.*
- shell-model.md: the solid elements' row (108 mm, 100%) is under Malvar and Crawford's law;
  "where the solid elements come within 5%"; limitation 5 "15% over the measured peak, against
  4% for the solid elements" where its own table gives 125% and validation 105–115%. *Fixed.*
- The slowly rocked footing settles "1.7 to 2.2 times" as much as measured, but packet d in its
  own table is 0.0399 / 0.0173 = 2.31; the moment levels off "5–16% low" where 0.80 against
  0.96 is 17% low. *Fixed* in validation.md, structural-model.md, the roadmap and the standing.
  Its "within 11% to 14 mrad" holds against the larger of the two directions; against the
  smaller, packet a is 57% high. *Noted* in the summary.
- **Not fixed** (another session is editing the concrete model's document): its crack-model
  tables (slab 101–107 mm, chamber 71–82 mm peaks) predate the chamber's detailing and the
  CEB's law, yet conclusions still rest on them ("the chamber moves towards the paper's model");
  its bond-slip table (Janney 41.6 kN m failing at 51 mm, slab 104 mm, Saatci 31.5–37.5 mm) is
  from earlier versions; the strain-rate section's Saatci "−6% to 0%" and Ando "13%" predate step
  29; the chamber's residual at a 0.5 crack residual is 35 mm there and 19 mm in validation.md;
  SS0a-1 with slip has its two meshes swapped against validation.md; and step 28 says the strip
  "converges" on 121, 127 and 131 mm. The structural documents also never say the chamber's
  roof is too stiff, nor mention Peterson's beams, whose struts are too strong.

### 19. Gas deflagrations: ratios and a fitted constant

- Lit in the middle the peaks are "a fifth to a seventh" of the tests' in six places; the
  ratios are 1/7.2, 1/6.8 and 1/5.6, which the body calls "a seventh ... and a sixth". *Fixed* to
  a sixth to a seventh.
- "Their LES 30–60%" is 26–62% by the table; "their LES came within 20%" lit in the middle is
  67–117%. *Fixed.*
- The flame "runs at the tests' measured speeds" (deflagration.md's opening, the standing):
  its own table gives half the measured speed over the first 2 m, within a fifth beyond 3 m.
  *Fixed* in deflagration.md, validation.md, the roadmap and the standing.
- K_G "converging from below": 35, 41 and 51 bar m/s on 12, 24 and 48 cells against 76, the
  increments growing. That is not convergence. *Fixed.* The laminar rise times' "within 1–3%" is
  "partly two errors cancelling" (deflagration.md), now said in validation.md.
- The sub-grid wrinkling's constant, a = 0.7, was fitted by Bauwens et al. in the same chamber
  it is compared in; declared in deflagration.md but not where the agreement is quoted. *Fixed*
  in validation.md. The standing's "flame acceleration is modelled but uncalibrated" then
  contradicts it; passed to the standing session.
- The vented peak "does not converge" (0.64, 0.30 and 0.42 kPa on three grids; "a single run's
  peak is uncertain by about ±40%"); the summary omits it. Listed.

### 20. Thermal radiation: the 100 t comparison is a scaled 100 kg run

The "100 t" total is that of a 100 kg run in the street canyon on 0.25 m cells at 170 ms, scaled
by the cube root (thermal-radiation.md, against a TNT fireball), and 21% against 3.8% and 6.6% is
3.2–5.5 times, not three to five (12.8% with cooling: 1.9–3.4, not two to three). The standing
said "one measurement" where the record compares two shots. *Fixed* in the summary and the
standing. Listed: the rise against the cloud's integral model is "a tenth to a fifth" where its
rise speed is 37% low (12 against 19 m/s); thermal-radiation.md's limitations still say the
air model has no gravity.

### 21. The cloud's agreement with Church is missing from the summary, and leans on choices

The model's cloud tops are within 4% of Church's 22 clouds on average for two minutes, the
"21% shot by shot" a geometric standard deviation, not a bound (the worst shots at 1.28 and
0.80). It needs afterburning (without it the tops are a third low), whose burning time was
fitted to the open blast's impulse, and the entrainment coefficient, "the least certain",
moves the tops by −9% to +13%, more than the agreement. The atmospheres were assumed where
Church's profiles were not transcribed. The comparison was absent from validation.md's summary.
*Fixed* (a row added). Large scenes, terrain and freestanding objects' checks are also absent
from the summary and verification tables; listed.

### 22. The fitted burning time reappears as agreement elsewhere

large-scenes.md: "With afterburning and hot air ... it is 90–108% out to Z = 40", of the
incident impulse the burning time was fitted to, unflagged. The closed room's "nothing
fitted" rests on the burning time hardly mattering there, but with the extinction limit 6 ms
and 4 ms move rooms to 104–114% and 107–117% against 98–107%. Listed.

## Low

23. Slab: shells "converged too, 18% above the solid elements" compares shells and solids
    under the earlier laws; under the defaults it is 135 against 113–124 mm, 9–19% above.
    *Fixed.*
24. Slab: "94–97 mm at the end of the record against 91 mm measured" beside 90 mm at 70 ms in
    the table; static strengths "143 mm (133%)" is 132%. Left (the record ends at 80 ms; 143 may
    be rounded from 143.4).
25. Wang: "94% with afterburning" is P1's; the three gauges give 94–104%. "Three fifths of the
    peak" is P1's; they give 59–77%. *Fixed* in the summary.
26. Thermal: the standing's summary says "one measurement of a TNT fireball's radiation",
    where the record compares two shots (DREO's 100 t and Dial Pack). *Fixed* (finding 20).
27. The standing's structural summary says reinforced concrete is "close to beam tests";
    the beam tests include a shear beam 11–15% strong, struck beams of the wrong failure
    mechanism and a 53% mean error on 24 elements. *Fixed.*
28. Deflagration: the summary's "with the measured flame speeds" is "within a fifth beyond
    3 m" in the section. *Fixed* (finding 19).
29. data-wanted.md's ranked table does not mark Wu, Peterson and Wang as used, and calls
    Dial Pack "a second 500-ton TNT shot measured by the group behind the one comparison so
    far". *Fixed.*
30. Commit messages carry the numbers of their day (footing moment "within 6%", Ando "13%" and
    "14% off"); the documents are the authority. Not fixable.

## Missing comparisons and larger issues, for the user

These need runs, sources or a decision, not wording.

1. **No held-out test.** Every default (the strain-rate laws, perfect bond over slip, the
   interlock cap, the removal rules, the supports in each test) was chosen with all the
   comparisons in view, by the sessions that ran them. The record is therefore a calibration
   set, not a validation set. Running one documented test blind on frozen defaults, judged by
   a session that did not choose them (the contest's high-strength slab, or Hrynyk's slabs),
   would be the strongest single addition.
2. **Convergence of the structural results.** Contest slab (finding 2), Saatci and Ando on
   16 against 24 elements (finding 3), the chamber's 25 mm mesh, the close-in slab whose hinge
   breaks on 8 elements and holds on 6. No structural result has been shown to converge on
   today's defaults. The standing session's advice to "use 6 through for the slab's bending"
   picks the mesh that agrees, which should be stated as such or dropped.
3. **Input uncertainty.** The slab's ±5% load moves its peak ±13%; supports move several
   results 15–25% or more; TNT equivalence 10–20%. A band from these (an ensemble session is
   already running over contest-slab, OA1, Saatci, Janney, Peterson and Wu cases) would show
   whether the claimed agreement is inside the input uncertainty, where it would mean little.
4. **The references' scatter** (finding 11): Kingery–Bulmash's and UFC 3-340-02's own scatter
   from their sources, to weigh "within 6%" and "98–108%" against.
5. **Single specimens.** The contest slab, Janney's beam, OA1, each of Saatci's beams and the
   chamber are single tests. Peterson's pairs are the only repeats; their spread (for example
   impact 195–260 kN in one pair of kinds) is the only measure of test scatter in the record
   and could be quoted as such.
6. **"Measured agreement" is a level of evidence, not of agreement.** A result compared and
   found a sixth of the measurement (the chamber's residual, close-in damage) still carries
   the top badge, beside peaks on 0.5 m cells at 20–69%. The bands now being added help; the
   badge's wording could say "compared with measurement" to avoid reading as "agrees".
7. **Unsafe-side errors** should lead wherever they occur: shear 11–15% strong (37% on coarse
   meshes), the chamber's roof too stiff, close-in slabs a third to a half as far down and
   never holed, Wu's small charges 40–70%, Peterson's strut too strong, slip "too stiff nearly
   everywhere", six elements through 17% strong in bending. Most summaries say "low" without
   the direction; a user needs to know these predict too little damage.
