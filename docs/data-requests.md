# Data requests

Draft requests for the closed sources ranked in [Data survey](data-survey.md#where-to-start-the-open-leads-ranked),
for the user to send in their own name if they choose. Nothing here has been sent. Contacts
and access were checked on 11 October 2026 from repositories' landing pages and search
listings; DTIC was down for maintenance that day and the ERDC library sits behind a browser
check, so their entries rest on search listings and are marked so.

Checking the routes turned up that several of the documents need no request at all: they are
open downloads behind sites that refuse automated access, and a person with a browser can
simply download them. Those are listed first in each section. The requests are for what is not
in any open document: digital records, debris maps and test details.

## What every request says

- **Who is asking:** a single developer of an open-source simulator,
  [BombCAD](https://github.com/emmettl/bombcad) (MIT licence), not a company, university or
  government body, with no funding and no commercial use.
- **What it is for:** the simulator's public validation record
  ([Validation](validation.md)), which sets the model's predictions beside measurements and
  says where they disagree.
- **What would be published:** only derived figures (peaks, times, plotted comparisons,
  summary tables), never the records themselves, unless the holder agrees otherwise; any
  conditions the holder sets are kept.
- **Credit:** the source cited in the documentation and in the code that uses it, as each
  section gives, and the holder thanked by name if they wish.
- **Distribution limits are respected.** Where a report carries a limited distribution
  statement or export control, the draft asks whether it can be released, through the route
  its statement names, and does not ask for anything to be passed on informally.

Sign each with your name; the drafts have `[Your name]` and `[your email]` where they go.

## 1. Kasun-III debris database (KLOTZ Group, 2008)

**What is wanted.** The debris database of the five internal shots in reinforced concrete cubes
2 m inside (over 21,500 pieces of concrete, steel and casing logged by mass and position), with
the cubes' drawings and materials, the charges, and the external pressure records. Most useful
are the two bare-explosive shots, since the model has no casing.

**Open already.** R. Forsén (FOI) et al., "The effects of cased ammunition explosions confined
in concrete cubicles: KASUN-III", 34th DDESB Explosives Safety Seminar, Portland, July 2010,
DTIC [ADA532249](https://apps.dtic.mil/sti/pdfs/ADA532249.pdf): served as a public PDF, so
distribution A by DTIC's practice (statement not read, DTIC down on 11 October). Its companion
from the same seminar, [ADA532261](https://apps.dtic.mil/sti/pdfs/ADA532261.pdf), is public
likewise. J. Weerheijm's slides and papers for the 2018 International Explosives Safety
Symposium on debris are open on `ndia.dtic.mil`. M. M. van der Voort and J. Weerheijm,
*International Journal of Impact Engineering* 59 (2013) 29–37, is paywalled.

**Order first: the test report.** R. Berglund, A. Carlberg, R. Forsén and G. A. Grönsten,
*Break up tests with small "ammunition houses" using cased charges: Kasun III*, FOI-R--2749--SE,
October 2009, 169 pp., in English, listed in
[FOI's report search](https://www.foi.se/rapportsammanfattning?reportNo=FOI-R--2749--SE) with a
"Beställ rapport" (order report) button, not a download. By its summary it holds the
compilation of fragment sizes and throw distances, the high-speed films' findings and the
blast pressures around the cubes: much of what the database request asks for. Ordering takes a
name and address in FOI's form, so it is the user's to place. The Kasun II report, FOI-R-2202-SE
(2006), is likely ordered the same way. If the report has the tables, the request below can
shrink to the database file only, or be dropped.

The 2018 KLOTZ Group paper (J. Weerheijm and R. Conway, International Explosives Safety
Symposium, `ndia.dtic.mil`, downloaded to `KlotzGroup2018`) gives the cubes' design: 2 m inside,
0.15 m walls and roof of B35 concrete, 12 mm FeB400 bars at 100 mm both ways in both faces,
covers 25 mm outside and 20 mm inside.

**Who holds it.** The tests were a joint effort of the Swedish Defence Research Agency (FOI) and
the Norwegian Defence Estates Agency (Forsvarsbygg), funded by the KLOTZ Group with the two
countries' authorities. The KLOTZ Group is an international working group of explosives safety
experts from eight countries (Germany, Norway, the Netherlands, Singapore, Sweden, Switzerland,
the United Kingdom and the United States); it has no public contact point found, and its
databases are built for its members. By the 2018 paper, its permanent chairman, in Norway, is
the group's official point of contact, with a technical chairman in the Netherlands (TNO).

**Route.** Write to FOI's registry, which receives requests for official documents
(registrator@foi.se, FOI, 164 90 Stockholm), asking it to pass the request to the Kasun-III
project's holder, and copy Forsvarsbygg (post@forsvarsbygg.no). Sweden's principle of public
access covers FOI's official documents, but defence material can be classified, and a database
built for the KLOTZ Group may be the group's to release rather than FOI's alone; the request
asks, and does not press. Forsvarsbygg can forward it to the KLOTZ Group's chairman.

**Status.** Not public. Release by request is possible but uncertain; expect a refusal or a
partial release (aggregated tables). If the holders say it is for members only, that is the
answer.

**Draft.**

> Subject: Request: Kasun-III debris data for an open-source simulator's validation
>
> Dear Sir or Madam,
>
> I develop BombCAD, an open-source, non-commercial blast simulator
> (https://github.com/emmettl/bombcad). I work on it alone and have no institutional
> affiliation. Its documentation keeps a public validation record setting the model's
> predictions beside published measurements.
>
> The Kasun-III tests of 2008, described by R. Forsén et al. at the 34th DDESB Explosives Safety
> Seminar (DTIC ADA532249) and in FOI-R--2749--SE, would be the best test I know of for how the
> model's concrete breaks up and throws debris. Beyond what that report gives, I would be
> grateful to know whether any of the following could be released, in whole or in part:
>
> 1. the debris database for the two shots with bare plastic explosive (and, if possible, the
>    three with shells): each piece's mass, material and position;
> 2. the cubes' drawings, reinforcement and measured concrete and steel strengths;
> 3. the charges' masses and positions, and the external blast pressure records.
>
> If the database itself cannot be released, aggregated tables (for example, debris mass or
> number per area by distance and direction) would still be very useful.
>
> I would publish only derived comparisons (plots and summary figures), not the data, unless you
> agree otherwise, and would cite the tests as Forsén et al. (2010) and the Kasun-III programme
> of FOI, Forsvarsbygg and the KLOTZ Group, with any acknowledgement you prefer. I understand
> the data may be restricted and would of course respect any decision or conditions.
>
> If this should go to someone else, I would be grateful to be told whom to ask.
>
> Yours faithfully,
> [Your name]
> [your email]

## 2. Prairie Flat, the Watching Hill soil data, and Pre-Dice Throw II

**What is wanted.** For the ground-shock comparison (`GroundShock.swift`, `SoilColumn.swift`):
the gauge records (acceleration, velocity and soil stress at depth, with the overpressure on the
ground beside them) and the site's layered soil profile.

**Open already.**

- **Prairie Flat:** WES Technical Report N-72-2, *Earth motion and stress measurements*,
  [ERDC 11681/6813](https://erdc-library.erdc.dren.mil/jspui/handle/11681/6813): by the ERDC
  library's listing, approved for public release, distribution unlimited, a 3.17 MB PDF. The
  library's browser check stops automated access; open it in a browser.
- **Pre-Dice Throw II:** DNA 4363F, *Analysis of ground motion data and prediction techniques
  from the Pre-Dice Throw II events* (1977), DTIC
  [ADA048003](https://apps.dtic.mil/sti/pdfs/ADA048003.pdf): served as a public PDF. The USGS's
  OFR 77-143 (doi:10.3133/ofr77143) is open.
- **Dial Pack** (WES TR N-73-4) and **Mixed Company and Middle Gust** (WES MP N-72-10,
  [ERDC 11681/6809](https://erdc-library.erdc.dren.mil/jspui/handle/11681/6809)) are in the
  same library and, being of the same series, probably public too (not checked).

So the reports need only a browser. The request is for what the printed reports do not give:
digital records, and the Watching Hill soil data, whose report was not identified.

**Status of the Watching Hill soil data.** The likely report, DTIC AD0741773, was not confirmed
(title and distribution unknown; DTIC was down). Search it on DTIC when it is back: if it is
distribution A, download it; if it carries another statement, use the request route below.
The site is now Canada's Experimental Proving Ground at DRDC Suffield, so the Canadian side may
hold the site's own soil investigations.

**Route.**

- *Digital gauge records (1968–76):* ERDC's Geotechnical and Structures Laboratory (GSL),
  successor to WES, which took over its explosion-effects work. Write
  through ERDC's public contact or the library's "contact us" page once past the browser check.
  Records this old may exist only on paper or film; the request asks whether any were
  digitised.
- *A DTIC report with a limited distribution statement:* request it from the controlling office
  the statement names, or file a Freedom of Information Act request with DTIC's FOIA Requester
  Service Center (foia@dtic.mil; 8725 John J. Kingman Road, Fort Belvoir, VA 22060). FOIA is the
  public route for documents not cleared for release; a report under export control
  (distribution X, or ITAR) may still be withheld, and that is the answer.
- *Watching Hill site data on the Canadian side:* DRDC, through its public contact on
  canada.ca, asking for DRES reports on the Watching Hill blast range's soil.

**Draft (ERDC GSL).**

> Subject: Request: digital ground-motion records from Prairie Flat (WES TR N-72-2)
>
> Dear Sir or Madam,
>
> I develop BombCAD, an open-source, non-commercial blast simulator
> (https://github.com/emmettl/bombcad), on my own and with no institutional affiliation. Its
> documentation keeps a public validation record comparing the model with published tests.
>
> I would like to compare its model of air-induced ground shock with the Prairie Flat event of
> 1968, using WES Technical Report N-72-2 (earth motion and stress measurements), which the ERDC
> library lists as approved for public release. I would be grateful to know whether any of the
> following exist in digital form and could be shared:
>
> 1. the acceleration, particle velocity and soil stress records of N-72-2, with the airblast
>    overpressure measured on the ground near each gauge station;
> 2. the soil profile of the Watching Hill site used to interpret them (layer depths,
>    densities, seismic wave speeds, and any uniaxial-strain test results), or the report that
>    gives it;
> 3. the same for Pre-Dice Throw II (DNA 4363F, DTIC ADA048003) and Dial Pack (WES TR N-73-4),
>    if held.
>
> If the records survive only on paper, a pointer to where they are held would still help, and
> I would digitise from the published figures myself.
>
> I would publish only derived comparisons, not the records, unless you agree otherwise, and
> would cite the reports and ERDC (as successor to WES), with any acknowledgement you prefer. I
> would of course respect any restriction on release.
>
> Yours faithfully,
> [Your name]
> [your email]

**Draft (DTIC FOIA, only if the Watching Hill report is not distribution A).** Fill in the
accession number and statement once DTIC is back.

> Subject: FOIA request: [accession number], [title]
>
> Under the Freedom of Information Act, I request a copy of DTIC [accession number],
> "[title]" ([year]), currently marked [distribution statement], on soil properties at the
> Watching Hill blast range, Suffield, Alberta, used for the high-explosive events of 1967–71.
>
> I am a private individual developing an open-source, non-commercial blast simulator
> (https://github.com/emmettl/bombcad) and would use the report to set up a soil model for
> comparison with published ground-motion measurements. I am not requesting anything
> classified or export-controlled; if the report cannot be released in full, I would accept a
> release with exempt parts withheld. I agree to pay fees up to US$[amount]; please tell me
> before exceeding that.
>
> [Your name]
> [postal address and email, as FOIA requires]

## 3. The contest's high-strength slab (Thiagarajan et al. 2015; Reynolds 2015)

**What is wanted.** For a second case in `SlabBenchmark.swift`: the high-strength slab's
concrete strength, bars (size, spacing, cover in each face), steel yield and ultimate
strengths, the measured reflected pressure and displacement histories in digital form; and,
for the existing contest slab, how it sat in the rig (bearing width and material, whether held
down against rebound).

**Open already.**

- K. A. Reynolds, *Experimental behavior of high strength concrete slabs subjected to shock
  loading*, MS thesis, UMKC, 2015,
  [hdl:10355/48353](https://hdl.handle.net/10355/48353): **open**, 6.29 MB, in the collection
  "2015 UMKC Theses – Freely Available Online". Pressure, impulse and deflection histories of
  high-strength slabs at two steel ratios, damage photographs, and a comparison with the
  normal-strength slabs.
- A. K. Vasudevan, *Finite element analysis and experimental comparison of doubly reinforced
  concrete slabs subjected to blast loads*, MS thesis, UMKC, 2012,
  [hdl:10355/14606](https://hdl.handle.net/10355/14606): **open**, 2.96 MB; high- and
  normal-strength slabs with two mats of HSLA vanadium steel.
- The 2015 paper (*International Journal of Impact Engineering* 75, 162–173) and *ACI SP-306*
  are paywalled: an accepted manuscript can be asked of the authors, or read through a library.

**Both theses are now reserved for blind test 3** ([Blind tests](blind-tests.md)): downloaded,
sealed unread in `$BOMBCAD_DATA/blind/reynolds-sealed/` and `vasudevan-sealed/`,
and no session opens them, or the contest's high-strength results anywhere, until the judge has
assessed them. So this request should wait for that assessment, or be sent with whatever comes
back going straight into the sealed folder unread. It asks for what the theses plot but do not
tabulate: the digital histories and the rig.

**Who holds it.** Ganesh Thiagarajan, Professor of Civil Engineering at UMKC, the NSF CAREER
project's principal investigator (CMMI 0748085) and organiser of the ACI 447/370 Blast Blind
Simulation Contest; the tests were run in ERDC's Blast Load Simulator, Vicksburg. His address
is on UMKC's directory (a 2010s article gives a umkc.edu address; check it is current).

**Status.** Theses open, and sealed for blind test 3. The digital records are the group's;
NSF-funded, so a polite request has a fair chance. Some may be ERDC's to release. Ask the
blind-test judge before sending.

**Draft.**

> Subject: Request: digital records of the UMKC blast slab tests (contest and high-strength slabs)
>
> Dear Professor Thiagarajan,
>
> I develop BombCAD, an open-source, non-commercial blast simulator
> (https://github.com/emmettl/bombcad), on my own and without institutional affiliation. Its
> public validation record already compares the model with the normal-strength slab of the
> ACI 447/370 Blast Blind Simulation Contest, using curves digitised from presentation slides,
> and I would like to add the high-strength slab described in K. A. Reynolds's 2015 thesis and
> your 2015 paper with Kadambi, Robert and Johnson.
>
> Would it be possible to share any of the following?
>
> 1. the measured reflected pressure and mid-span displacement histories, as digital records,
>    for the contest slab and for the high-strength slabs;
> 2. for the high-strength slabs, the bar size, spacing and cover in each face, and the
>    measured steel yield and ultimate strengths, if not in the thesis;
> 3. how the slabs were supported in the Blast Load Simulator: the bearing width and material,
>    and whether the slab was restrained against rebound. The model springs back about twice as
>    far as the contest slab did, and the rig's restraint would explain part of that.
>
> I would publish only derived comparisons (plots, peaks and timing), not the records, unless
> you agree otherwise, and would cite Thiagarajan et al. (2015), Reynolds (2015) and the contest,
> with any acknowledgement you prefer. If the records are ERDC's to release, I would be grateful
> to know whom to ask.
>
> With thanks and kind regards,
> [Your name]
> [your email]

## 4. Masonry debris under long-duration blast (Keys and Clubley 2017; Keys 2016)

**What is wanted.** For the debris comparison: the debris maps of the panels and small buildings
(position, and if logged, mass or size of each fragment or each area's collected mass), the
panels' geometry and materials, and the pressure records at the panels.

**Open already.** Both documents are open in the University of Southampton's repository, which
refuses automated access but opens in a browser:

- R. A. Keys, *Experimental & computational structural analysis of masonry panels subject to
  long duration blast loading*, PhD thesis, University of Southampton, 2016, 368 pp.,
  [eprint 413951](https://eprints.soton.ac.uk/id/eprint/413951/): **open**, 14 MB, under the
  University of Southampton Thesis Licence. Five trials, 22 structures; supervised by S. K.
  Clubley.
- R. Keys and S. K. Clubley, "Experimental analysis of debris distribution of masonry panels
  subjected to long duration blast loading", *Engineering Structures* 130 (2017) 229–241,
  doi:10.1016/j.engstruct.2016.10.054: accepted manuscript **open** at
  [eprint 381618](https://eprints.soton.ac.uk/id/eprint/381618/), 7 MB, under the University's
  Accepted Manuscript Licence; also on Loughborough's repository.

Both are now on StudioData (`Keys2016`, `KeysClubley2017`). No dataset DOI was found on either
record. The thesis plots each structure's debris mass distribution in bins of 0.5 to 1 m
(Figures 4.11 to 4.74) but does not tabulate them; each piece was logged by mass, position and
material over a 0.5 m grid. The plots can be digitised for a first comparison; the request is
for the logged data behind them.

**Who holds it.** The thesis's acknowledgements settle it: the trials were run at MoD
Shoeburyness (the Windrush Arena and the Air Blast Tunnel) with Spurpark Ltd's trials division,
and all data obtained there "remains the property of the UK MoD". So the records are the
Ministry of Defence's to release, not the university's. Simon K. Clubley, University of
Southampton (ORCID 0000-0003-3779-242X), Keys's supervisor, is still the right first contact:
he will know whether MoD has cleared any of it and whom to ask; his address is on
Southampton's people directory.

**Route.** Ask Clubley first. If MoD's permission is needed and he cannot obtain it, the public
route is a request under the UK Freedom of Information Act 2000 to the Ministry of Defence
(through its FOI request page on gov.uk), naming the trials, the years and the thesis. MoD may
withhold trial data on defence or commercial grounds; that is the answer if so.

**Status.** Documents open and downloaded; the logged data is UK MoD property, release
uncertain.

**Draft.**

> Subject: Request: debris distribution data from the long-duration blast masonry trials
>
> Dear Professor Clubley,
>
> I develop BombCAD, an open-source, non-commercial blast simulator
> (https://github.com/emmettl/bombcad), on my own and with no institutional affiliation. Its
> public validation record compares the model with published tests, and it has so far no test
> of debris thrown by drag-dominated, long-duration loading.
>
> The trials in your 2017 *Engineering Structures* paper with Richard Keys, and in his 2016
> thesis, would fill that gap. Would it be possible to share any of the following, for a few
> of the panels?
>
> 1. the debris distribution maps as data: the positions (and masses or sizes, if recorded) of
>    the fragments, or the collected mass per grid cell;
> 2. the panels' as-built dimensions, brick and mortar properties, and how they were fixed;
> 3. the overpressure records at or near the panels.
>
> I understand from the thesis that the trial data remains the property of the UK Ministry of
> Defence. If you are not able to share it, I would be grateful to know whether MoD has cleared
> any of it for release, or whom there I should ask; I would of course respect any restriction.
> I would publish only derived comparisons, not the data, unless agreed otherwise, and would
> cite Keys and Clubley (2017) and Keys (2016), with any acknowledgement you prefer.
>
> With thanks and kind regards,
> [Your name]
> [your email]

## After a reply

Record what was received, its terms and where it is kept in the matching item of
[Data wanted](data-wanted.md), as the open sources are; keep the data on the scratch volume, not
in the repository, unless its licence allows; and cite it as agreed.
