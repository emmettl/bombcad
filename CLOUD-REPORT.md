# Cloud report: data fetch, 18 October 2026

A cloud session (Linux, no Metal) was asked to fetch each source in
[Data wanted](docs/data-wanted.md)'s "To fetch" and "To request", in the order given, and to
digitise what the [Data survey](docs/data-survey.md) and [Validation](docs/validation.md) need
from each into `Fixtures/`. **It fetched nothing and digitised nothing.** The container's network
policy refused every source host, so this report records what it found by web search instead:
corrected titles and numbers, direct links, open mirrors, prices and routes. The access notes in
Data wanted now carry these findings, one column per table. No `Fixtures/` folder was added, and
no document, PDF or scan was committed.

## What the network allowed

- **Through the session's proxy** (curl), only GitHub and the package registries answered. Every
  other host got HTTP 403 at the tunnel, the proxy's policy denial. Among the hosts tried:
  `apps.dtic.mil`, `discover.dtic.mil`, `ndia.dtic.mil`, `www.osti.gov`,
  `erdc-library.erdc.dren.mil`, `umpir.ump.edu.my`, `zenodo.org`, `figshare.com`,
  `data.mendeley.com`, `babel.hathitrust.org`, `archive.org`, `web.archive.org`,
  `upload.wikimedia.org`, `commons.wikimedia.org`, `usace.contentdm.oclc.org`,
  `www.nwo.usace.army.mil`, `www.denix.osd.mil`, `scholar.afit.edu`, `www.icheme.org`,
  `op.europa.eu`, `www.foi.se`, `www.ct.upt.ro`, `dspace.upt.ro`, `www.survice.com`,
  `dpi-proceedings.com`, `www.research-collection.ethz.ch`, `mospace.umsystem.edu`,
  `eprints.soton.ac.uk`, `repository.lboro.ac.uk`, `www.ideals.illinois.edu`, `iieta.org`,
  `www.mdpi.com`, `ntrs.nasa.gov`, `publications.gc.ca`, `pubs.usgs.gov`, `ntrl.ntis.gov`,
  `wrap.warwick.ac.uk`, `api.crossref.org`, `api.openalex.org`, `core.ac.uk` and `www.google.com`.
- **The page reader** (WebFetch) could not resolve any host, `en.wikipedia.org` included.
- **Web search** worked, until the turn's allowance of 200 searches ran out. It returns
  search-engine summaries, not documents, so nothing in it was used as data. Every link below
  appeared in a search result; none was opened.
- **Hugging Face's hub**, searched for blast, explosion and ground-shock datasets and papers,
  held nothing relevant.

A later cloud session could fetch these if the environment's network access is widened (in the
environment's settings, Network access: a broader level, or the hosts above added as allowed
domains). Otherwise the Studio's browser is the route, and several sources now have mirrors that
avoid the blocks met there (below).

## Per source

"Blocked" means refused from this container. Titles in italics are as search results gave them.

### To fetch, first

| Source | Fetched | Status and what was found |
|---|---|---|
| Pre-Dice Throw II ground motion and predictions, DNA 4363F, DTIC ADA048003 | No | Blocked. *Analysis of ground motion data and prediction techniques from the Pre-DICE Throw II events* (GE TEMPO for DNA, 1977). Public and indexed, so the Studio's 403 is DTIC refusing the client. DTIC's other URL forms (`/sti/tr/pdf/<number>.pdf`, `/sti/html/tr/<number>/index.html`) are worth a try there |
| Pre-Dice Throw II seismic measurements, DTIC ADA064605 | No | Blocked. ERIM's seismic measurements of Pre-Dice Throw II-1, II-2 and Dice Throw, about 1978 (authors garbled in the index) |
| Prairie Flat, WES TR N-72-2 (Murrell, 1972) | No | Blocked. **An open copy on Wikimedia Commons** (link in Data wanted), which has no browser check. Companion with the codes' predictions: Zelasko and Baladi, MP S-71-6, DTIC AD0722403 |
| Kasun-III, Forsén, Berglund and Grønsten, DDESB 2010, DTIC ADA532249 | No | Blocked. Title confirmed; public DTIC PDF |
| Companion on internal-blast break-up, DTIC ADA532261 | No | Blocked. Fan, Yu, Yang, Lim and Kang (NTU and DSTA), *Study of debris throw and dispersion after break-up of reinforced concrete structure under internal explosion*: probably numerical, so of less use than listed |
| Glass under blast waves, EMRTC, OSTI 658184 | No | Blocked. Beauchamp and Matalucci, *Dynamics of window glass fracture in explosions*, SAND98-0598 (1998), doi:10.2172/658184. Whether OSTI holds the text was not shown |

### To fetch, then

| Source | Fetched | Status and what was found |
|---|---|---|
| Cubbage and Marshall 1972; Cubbage and Simmonds 1955 (GC23) | No | Blocked. **Cubbage and Marshall is free** in IChemE's Hazards archive, as is Simmonds and Cubbage on oven reliefs (the symposium version, probably not GC23). GC23 itself not found |
| Bauwens, Chao and Dorofeev 2012; Bauwens and Dorofeev 2014 | No | Paywalled; no price shown. ICHS versions on the H2 Knowledge Centre; an open Warwick review (Vendra et al. 2017) tabulates the tests |
| Mazlan et al. 2021, inverted-T wall | No | Blocked. Full citation found (Abu Seman et al., Trans Tech 2021, vol. 879, pp. 254–262); the eprint links a PDF; charge in a companion paper |
| Kingery, BRL 1344 (1966) | No | Not found online; its 1964 predecessor (AD443102) is on NTRL |
| Bogosian, Ferritto and Shi 2002, DTIC ADA526954 | No | Blocked. Public DTIC PDF: three fast-running codes against about 300 measurements |
| WES bearing capacity, AD0654712, AD0680905, AD0685825 | No | Blocked. AD0654712 is NCEL's (White 1967, strip footing on saturated sand); AD0685825 is Poplin, WES TR S-69-3 (1969); AD0680905 unresolved. Poplin's Report 2 (1967) is on HathiTrust, said to be full view |
| Watching Hill soils, DTIC AD0741773 | No | Blocked. Given as Jackson, WES TR S-72-4 (1972): open, so not only by request |
| Newmark and Haltiwanger 1962; Woodson and Baylot 1999; Johnson TR-16-27; Dial Pack and Mixed Company | No | Not searched (allowance spent). Dial Pack and Mixed Company may share Prairie Flat's route through USACE's digital library or Commons |
| SBEDS papers, masonry update, Meyers on windows | No | Blocked. Three of five titles found (ADA532096, ADA532093, ADA507460); a 2025 SBEDS paper is hosted by DDESB on denix |
| PDC-TR 06-08, 2025 edition | No | Blocked. Exact file link found on the Protective Design Center's host, which refuses the Studio; no other copy |
| DNA's cloud reports (ten numbers) | No | Blocked. Five titles found (ADA089720, ADA083346, ADA053465, ADA134723, ADA048799); five unresolved |
| Brilliant Flash II and Sandia radiometry | No | Blocked. Gross (AFIT PhD 2007) and Slagle (AFIT MS 2009, = ADA496108); ADA093517 unresolved |
| AFWL-TR-71-144 crater database, AD0891964 | No | Blocked. Dillon (1971), released in 1974 |
| Gould, DNA 6187F | No | Blocked. **Number found: DTIC ADA135737**, unlimited distribution |
| RDA-TR-2604-001, OSTI 6696719 | No | Blocked. H. F. Cooper Jr. (1976), 54 pp, through NTIS |
| Jones's Prairie Flat crater study; Roddy et al. 1977 | No | Not found open. A better lead: Jones, Suffield Special Publication 177 (1995), listed as digitised by Government of Canada Publications; NTRS has the book's chapter records |
| TM 5-855-1 (1986) | No | No open copy; sold through GlobalSpec |
| Kingery and Bulmash, ARBRL-TR-02555 | No | No DTIC number found |
| Vertical shock tube on sand, AD0818668 | No | Blocked. *Calibration of a vertical shock tube and its associated soil bin* (CERF) |
| DDESB TP-13 | No | Appears to be the DISPRE debris model (1991), not arena data: of less use than listed |
| ADB007377 and NWC TP 7124; McCleskey NSWC TR 87-89; TP-16; ADP004868 and the seminar minutes; THOR TR 47; Walbert; the DPI ballistics papers; ETH squat walls; EMERGE | No | Not searched (allowance spent); every host refused from here |

### Behind a paywall

None was bought or fetched. Open alternatives found, each to be confirmed when opened:

- **Castedo et al.**: two open papers on full-scale slabs under air blast, *IJSSE* 9(1) (2019)
  and *Buildings* 13 (2023) 2068, and Alañón's 2015 thesis.
- **Johns and Clubley**: accepted manuscripts at Loughborough and Southampton, and Johns's thesis.
- **Murzyn et al.**: Murzyn's 2018 thesis on IDEALS.
- **Dinu et al.**: the SDSS 2016 paper is open on UPT's site (which refuses the Studio), and
  Marginean's 2017 thesis on UPT's DSpace likely holds the connection tests.
- **Batalha et al.**: three open conference papers from the same campaign.
- **Netherton and Stewart**: a Newcastle research report on repeated field trials.
- **Thiagarajan et al.**: probably the tests of Vasudevan's thesis, which is in hand and sealed
  for a blind test. Nobody should read the paper until that test is run.

Prices shown: SP-306 €67.92 before VAT from a reseller; the BFETS Phase 2 summary £200 as a PDF
(£250 printed); CCPS's guidelines $159 printed or €139.99 as an e-book. No other price was shown.

### To request

| Dataset | Status and what was found |
|---|---|
| Kasun-III database and its FOI report | Not requested (drafts only, as before). **The report number may be wrong**: search summaries give FOI-R--2479--SE (Forsvarsbygg 68/2009), and FOI-R--2749--SE was never found. Check it before ordering, and correct [Data requests](docs/data-requests.md) if so |
| Kasun-II's 80 kg cubicle, FOI-R--2202--SE | Identified as Forsvarsbygg report 51/06 (2006); no download or price found |
| Prairie Flat and Pre-Dice Throw II records; Watching Hill soils | No digital records anywhere; the Watching Hill report appears open (above) |
| The slab contest's records | No public dataset |
| Keys's debris data | No data DOI |
| ADBLAST D4–D6 | The final report is free as EUR 27487 EN; the deliverables were not found. Whether that report is the one already behind `Fixtures/ADBLAST2015` should be checked |
| Saatci's records | No VecTor page found; an open İzmir MSc thesis (2010) re-analyses the beams |
| "Still to find" (struts, CLT joints, footings on a slope, cracked brick walls) | Not searched (allowance spent) |

## Ranked by what each would change

No new data arrived, so nothing has changed BombCAD's evidential standing yet. Below, the open
routes found are ranked by how far each would move it once fetched, against the gaps in
Validation's [summary](docs/validation.md#summary) and [What is missing](docs/validation.md#what-is-missing).
Three of them (1, 2 and 4) have not been read by any session here. That makes them candidates
for blind tests under the [protocol](docs/blind-tests.md), which is the record's third gap. They
should be sealed by an extractor before anyone reads their results.

1. **Castedo et al. 2019 and 2023 (open)**: full-scale slabs under air blast, close in. This is
   gap 6 (close-in damage, where the model leaves slabs a third to a half as far down and never
   holes them) on a second series, and a possible blind test.
2. **Mazlan et al. 2021**: a reinforced wall on its own footing under 13.6 kg in the open. This
   is gap 2: a wall in the open whose whole length and deflection are recorded, which
   Alsubaei's lack. One wall only, so the gain is narrow.
3. **Prairie Flat (on Commons) with Pre-Dice Throw II and the Watching Hill soils**: ground
   shock rests on one test (Xia et al.), judged "illustrative", taken near and past the
   outrunning limit. These would give three shots of 100–500 t with gauges inside the limit and
   the site's soil. Pre-Dice Throw II also brings four agencies' predictions made before the
   shots, a ready-made yardstick. This is the largest move for a whole area, but outside the
   structural gaps that Validation ranks first.
4. **Kasun-III's paper (DTIC ADA532249)**: gap 7, a second test of debris. The paper gives debris
   densities by source; the database is still by request.
5. **The glass threshold**: Beauchamp and Matalucci (SAND98-0598) and Johns's thesis and
   manuscripts. Window glass is "moderate" on timing, but its threshold is "not measured"; panes
   that held would give one.
6. **Bogosian, Ferritto and Shi (ADA526954)**: about 300 measurements against ConWep and others.
   The record notes that Kingery–Bulmash's own scatter is not given; this would set the blast
   loads' error against the reference's.
7. **Craters**: Gould (ADA135737), Dillon's database (AD0891964) and Jones's SSP 177, to judge
   the crater's scaling beyond six events.
8. **The fireball**: Murzyn's thesis (temperatures inside a fireball) and Gross's and Slagle's
   theses (spectra and radiometry), for an area that is "illustrative".
9. **The rest**: Dinu's frame tests and Marginean's connections; Cubbage and Marshall (free, for
   town gas at first hand); Poplin's footings; the DNA cloud reports; the 2025 response limits;
   the SBEDS papers. Each refines a comparison already made, or one with no gap ranked in
   Validation.

## Corrections to the lists

- Kasun-III's FOI number, as above.
- AD0654712 is NCEL's, not WES's.
- DDESB TP-13 is apparently DISPRE, a building-debris model, not arena data.
- DTIC ADA532261 is probably a numerical study.
- The Watching Hill soil report (AD0741773) appears open, not only by request.
- Puttock et al.'s 104659 is *Part 1: small-scale*, perhaps not the MERGE, ERGOS and Buxton
  comparison wanted.

All of these come from search summaries and are to be confirmed against the documents.

## Checks

`python3 Scripts/check-doc-links.py` passes. No Python code was changed, so no Python tests were
run. Swift and Metal were not built: they cannot be built here.
