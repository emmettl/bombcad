# Data wanted

What would test the model and is not yet in hand, as things to do: documents to fetch in a
browser, datasets to ask their owners for, and, last, what has been fetched and where it is
used. The full survey behind this list, each source with what it would give and what was
searched, is in [Data survey](data-survey.md).

## To fetch

Open documents that this machine's scripts cannot download: the sites refuse automated access.
In a browser each is a click. Save each into the folder given, with a `SOURCE.md` beside it (the
citation, the link and the date), and tell a session it is there; nothing goes into the
repository. DTIC's links are the public PDFs as its listings gave them on 11 October 2026; if one
fails, search the number at [discover.dtic.mil](https://discover.dtic.mil/).

**First**, in this order:

| Document | Link | Blocked here by | Save to `/Volumes/StudioData/bombcad/…` | Unlocks |
|---|---|---|---|---|
| Pre-Dice Throw II: ground motion and the predictions made before the shots, DNA 4363F (1977) | [DTIC ADA048003](https://apps.dtic.mil/sti/pdfs/ADA048003.pdf) | DTIC: "request is blocked", HTTP 403 | `data/PreDiceThrowII/` | A blind ground-shock test ready made: four agencies' predictions beside the motion measured at 305–1,220 m ([3a](data-survey.md#3a-air-induced-ground-shock)) |
| Pre-Dice Throw II: the seismic measurements | [DTIC ADA064605](https://apps.dtic.mil/sti/pdfs/ADA064605.pdf) | DTIC, HTTP 403 | `data/PreDiceThrowII/` | The shots' measured motion, to set the soil column against (title not seen here) |
| Prairie Flat: earth motion and stress, WES TR N-72-2, 3.17 MB | [ERDC 11681/6813](https://erdc-library.erdc.dren.mil/jspui/handle/11681/6813) | ERDC's browser check | `data/PrairieFlat/` | Gauges at depth either side of the superseismic limit under 500 t on the surface: the soil column's first measured test |
| Kasun-III: Forsén et al., DDESB 2010 | [DTIC ADA532249](https://apps.dtic.mil/sti/pdfs/ADA532249.pdf) | DTIC, HTTP 403 | `data/Kasun2010/` | The cubes, charges and debris of the best debris benchmark known ([3c](data-survey.md#3c-collapse-and-debris)); the database itself is by request, below |
| Its companion: concrete breaking up under internal blast, DDESB 2010 | [DTIC ADA532261](https://apps.dtic.mil/sti/pdfs/ADA532261.pdf) | DTIC, HTTP 403 | `data/Kasun2010/` | How concrete walls break up and are thrown under an internal charge |
| Annealed and tempered glass under blast waves, EMRTC, Socorro | [OSTI 658184](https://www.osti.gov/biblio/658184) | osti.gov refuses the connection | `envelope-damage/sources/` | Panes that held beside panes that broke, over a range of overpressure and impulse: the breaking threshold, which Monk and Clubley's tests, all broken, cannot give ([3h](data-survey.md#3h-window-glass-breaking-under-a-blast)) |

**Then**, when convenient:

| Document | Link | Blocked here by | Save to `/Volumes/StudioData/bombcad/…` | Unlocks |
|---|---|---|---|---|
| Nian et al., an RC blast wall against air shock, *Defence Technology* 31 (2024), open access | [doi:10.1016/j.dt.2022.11.005](https://doi.org/10.1016/j.dt.2022.11.005) | ScienceDirect's bot check | `data/Nian2024/` | Pressures in front of and behind a freestanding wall ([2b](data-survey.md#2b-a-freestanding-wall-under-an-open-air-charge)); obtained 2026-10-17, compared in [validation](validation.md#a-blast-wall-with-its-length-known) ([Fixtures/Nian2024](../Fixtures/Nian2024/README.md)) |
| Yao et al., large slabs under explosion, *Applied Sciences* 13, 12552 (2023) | [MDPI](https://www.mdpi.com/2076-3417/13/23/12552) | MDPI, HTTP 403 (supplied by the user) | `data/Yao2023-RCSlabs/` | A 4 × 5 m slab with pressure gauges, displacement and acceleration ([1a](data-survey.md#1a-a-slab-with-steel-in-both-faces-under-an-open-air-charge)); obtained 2026-10-17, compared in [validation](validation.md#yaos-large-slabs) ([Fixtures/Yao2023](../Fixtures/Yao2023/README.md)): the load agrees, the displacements do not compare, and the 20 kg test is too resistant locally |
| Xia et al., ground shock from 1 and 10 t surface shots, *Applied Sciences* 12, 7987 (2022) | [MDPI](https://www.mdpi.com/2076-3417/12/16/7987) | MDPI, HTTP 403 | `data/Xia2022/` | Ground shock against UFC 3-340-01 at two large charges |
| "Gauging the fireball: simulation and testing" | [Southampton eprint 354397](https://eprints.soton.ac.uk/354397/) | Southampton refuses | `data/GaugingFireball/` | Temperatures measured inside a 41 kg fireball: the gas the model never cools ([3e](data-survey.md#3e-fireball-radiation)) |
| Hayman, one-way reinforced masonry walls under blast (McMaster MASc, 2014); ElSayed's thesis (11375/16041) beside it | [MacSphere 11375/16312](https://macsphere.mcmaster.ca/handle/11375/16312) | MacSphere refuses | `data/Hayman2014/` | Masonry walls' displacement histories, the joint model's first check ([3](data-survey.md#3-formulae-quoted-from-memory)); obtained 2026-10-17, used for envelope damage's [one-way walls](building-envelopes.md#one-way-walls) ([Fixtures/Hayman2014](../Fixtures/Hayman2014/README.md)) |
| Mazlan et al., an inverted-T RC wall under 13.6 kg of TNT (2021) | [UMPSA eprint 30661](http://umpir.ump.edu.my/id/eprint/30661/) | Refuses the connection | `data/Mazlan2021/` | The only wall on its own footing found, under an open-air charge |
| Kingery, BRL Report 1344 (1966) | [DTIC AD0811673](https://apps.dtic.mil/sti/pdfs/AD0811673.pdf) | DTIC | `data/reference-scatter/` | Kingery–Bulmash's data by distance, so its scatter is not pooled ([3g](data-survey.md#3g-the-reference-curves-own-scatter)) |
| Bogosian, Ferritto and Shi, uncertainty in simplified blast models (2002) | [DTIC ADA526954](https://apps.dtic.mil/sti/pdfs/ADA526954.pdf) | DTIC | `data/reference-scatter/` | ConWep's error against many tests, as a mean and spread |
| WES on the dynamic bearing capacity of soils (1960s) | DTIC [AD0654712](https://apps.dtic.mil/sti/pdfs/AD0654712.pdf), [AD0680905](https://apps.dtic.mil/sti/pdfs/AD0680905.pdf), [AD0685825](https://apps.dtic.mil/sti/pdfs/AD0685825.pdf) | DTIC, ERDC, HathiTrust | `data/WES-bearing/` | Footings under 4–20 ms pulses with load and settlement ([3b](data-survey.md#3b-a-footing-or-connection-under-fast-loading)) |
| The Watching Hill soil data (probably; title not confirmed) | [DTIC AD0741773](https://apps.dtic.mil/sti/pdfs/AD0741773.pdf) | DTIC | `data/PrairieFlat/` | The layers under Prairie Flat and Dial Pack, for the soil column |
| Newmark and Haltiwanger, *Air Force Design Manual* (1962) | [DTIC AD0295408](https://apps.dtic.mil/sti/pdfs/AD0295408.pdf) | DTIC | `data/NewmarkHaltiwanger1962/` | The ground-shock relations as printed, written here from memory ([3a](data-survey.md#3a-air-induced-ground-shock)) |
| Woodson and Baylot, quarter-scale structural collapse (ERDC, 1999) | [DTIC ADA369355](https://apps.dtic.mil/sti/pdfs/ADA369355.pdf) | DTIC | `data/WoodsonBaylot1999/` | Frames collapsing under blast; probably the modes, not debris |
| Johnson, Blast Load Simulator experiments, ERDC/GSL TR-16-27 | [ERDC library](https://erdc-library.erdc.dren.mil/jspui/) (search the number) | ERDC's browser check | `data/Johnson2016/` | The contest slabs' loads in the simulator ([1](data-survey.md#1-a-second-structural-test-from-the-same-contest)) |
| Dial Pack, WES TR N-73-4; Mixed Company and Middle Gust, WES MP N-72-10 | [ERDC library](https://erdc-library.erdc.dren.mil/jspui/) (N-73-4); [ERDC 11681/6809](https://erdc-library.erdc.dren.mil/jspui/handle/11681/6809) | ERDC's browser check | `data/PrairieFlat/` | A repeat of Prairie Flat's ground motion, and a wet site against a dry one |
| SBEDS papers; the update to UFC 3-340-02 for masonry; Meyers et al. on window design | DTIC [ADA532096](https://apps.dtic.mil/sti/pdfs/ADA532096.pdf), [ADA532092](https://apps.dtic.mil/sti/pdfs/ADA532092.pdf), [ADA532371](https://apps.dtic.mil/sti/pdfs/ADA532371.pdf), [ADA532093](https://apps.dtic.mil/sti/pdfs/ADA532093.pdf), [ADA507460](https://apps.dtic.mil/sti/pdfs/ADA507460.pdf) | DTIC | `envelope-damage/sources/` | The single-degree-of-freedom methods and window design behind envelope damage, as their authors wrote them |
| PDC-TR 06-08, the response limits, April 2025 edition | [USACE Protective Design Center](https://www.nwo.usace.army.mil/Missions/Centers-of-Expertise/Protective-Design-Center/) | HTTP 403 | `envelope-damage/sources/` | The current limits (the 2008 edition is in hand) |
| DNA's reports on the large ANFO shots' clouds | DTIC ADA112425, ADA089720, ADA160565, ADA048799, ADA134723, ADA047372, ADA089187, ADA088367, ADA053465, ADA083346 | DTIC | `data/cloud/` | Clouds after two minutes ([3d](data-survey.md#3d-an-he-clouds-growth-after-two-minutes)) |
| Brilliant Flash II spectra of TNT fireballs; Sandia's fireball radiometry | AFIT theses (`scholar.afit.edu`, etd 2897 and 2447), DTIC ADA496108, ADA093517 | AFIT and DTIC refuse | `data/fireball/` | Measured fireball spectra and radiometry ([3e](data-survey.md#3e-fireball-radiation)) |
| Sand under a pulse in a vertical shock tube | [DTIC AD0818668](https://apps.dtic.mil/sti/pdfs/AD0818668.pdf) | DTIC | `data/shock-tube-sand/` | v = p/(ρc) and its fall with depth under a controlled pulse |
| DDESB TP-13, *Fragment and Debris Hazards* | [WHS reading room 10-F-0806](https://www.esd.whs.mil/Portals/54/Documents/FOID/Reading%20Room/Other/10-F-0806_Fragment_and_Debris_Hazards.pdf) | WHS refuses | `fragments/sources/` | Arena tests' hazardous-fragment distances, against which the fragments' ranges and areal densities can be checked ([Fragments](fragments.md#against-coopers-data)) |
| Fragment velocity predictions (DTIC ADB007377; title as listed, distribution may be limited) and NWC TP 7124 | DTIC [ADB007377](https://apps.dtic.mil/sti/pdfs/ADB007377.pdf), [ADA238153](https://apps.dtic.mil/sti/pdfs/ADA238153.pdf) | DTIC | `fragments/sources/` | Measured launch speeds against Gurney's, for cased charges of known geometry |
| McCleskey, fragment drag and presented area, NSWC TR 87-89 (1988) | [discover.dtic.mil](https://discover.dtic.mil/) (search the number) | DTIC | `fragments/sources/` | The irregular fragments' measured drag at low Mach, below the tumbling cubes' 0.5 |
| Natural fragmentation of steel cylinders, International Symposium on Ballistics proceedings (open; titles not confirmed here) | DPI [2182](https://dpi-proceedings.com/index.php/ballistics/article/view/2182), [16812](https://dpi-proceedings.com/index.php/ballistics30/article/view/16812), [33205](https://dpi-proceedings.com/index.php/ballistics31/article/view/33205) | Not tried | `fragments/sources/` | Arena tests of cylinders of stated wall and diameter: masses and speeds to set against Mott's B and Gurney's |
| *Cyclic tests on real-scale squat RC shear walls* (Pizarro Pohl, Kovarbašić and Stojadinović) | ETH Research Collection (search the title) | The collection returned errors | `data/ETH-squat-walls/` | Walls sliding at the base, slowly |

**Behind a paywall**, for library access:

| Document | Link | Unlocks |
|---|---|---|
| ACI SP-306 (2016), the slab contest's papers | [doi:10.14359/51688861](https://doi.org/10.14359/51688861) | The contest's high-strength slab ([1](data-survey.md#1-a-second-structural-test-from-the-same-contest)) |
| Thiagarajan et al., doubly reinforced slabs under blast, *IJIE* 75 (2015) | [doi:10.1016/j.ijimpeng.2014.07.018](https://doi.org/10.1016/j.ijimpeng.2014.07.018) | The same, and the contest rig |
| Castedo et al., full-scale slabs, *IJIE* 86 (2015); and *Eng. Struct.* 231 (2021) | [2015](https://doi.org/10.1016/j.ijimpeng.2015.08.004), [2021](https://doi.org/10.1016/j.engstruct.2020.111774) | Seven slabs, one shot each; Chiquito's slabs' measured materials |
| Zhao, Yi and Kunnath, shear in beams under impact, *JSE* 143(9) (2017) | [doi:10.1061/(ASCE)ST.1943-541X.0001818](https://doi.org/10.1061/(ASCE)ST.1943-541X.0001818) | The drop that first breaks a beam in shear ([2a](data-survey.md#2a-shear-across-cracks-at-high-rates)) |
| Sharon et al., cloud rise, *Atmospheric Environment* 54 (2012) | Elsevier | Cloud heights against time below Church's charges |
| Murzyn, Sims, Krier and Glumac, *Optics and Lasers in Engineering* 110 (2018) | [doi:10.1016/j.optlaseng.2018.06.005](https://doi.org/10.1016/j.optlaseng.2018.06.005) | Gas temperatures inside a fireball against time |
| van der Voort and Weerheijm, debris dispersion, *IJIE* 59 (2013) | Elsevier | Kasun's debris statistics |
| Netherton and Stewart, blast load variability, *IJPS* 1(4) (2010) | SAGE | Model error of blast-load predictions |
| Johns and Clubley, annealed glazing under long-duration blast, *J. Struct. Eng.* (2016) and *Int. J. Solids Struct.* 97–98 (2016) | ASCE; Elsevier | Glass near its threshold under long pulses ([3h](data-survey.md#3h-window-glass-breaking-under-a-blast)) |

The survey names a few more, each under its item: Hao et al. (2017), Ross and Krawinkler (1985),
Kiger and Slawson (1984), Bauwens et al.'s propane and hydrogen papers, Kingery and Bulmash
(1984), and Oswald (2017).

## To request

Datasets in no open document, which have to be asked of their owners. Drafts, with contacts
and routes checked on 11 October 2026, are in [Data requests](data-requests.md); nothing has
been sent.

| Dataset | Ask | Draft | Unlocks |
|---|---|---|---|
| Kasun-III's debris database (21,500 pieces by mass and position), and first the FOI test report FOI-R--2749--SE, orderable in [FOI's report search](https://www.foi.se/rapportsammanfattning?reportNo=FOI-R--2749--SE) | FOI, Forsvarsbygg or the KLOTZ Group | [1](data-requests.md#1-kasun-iii-debris-database-klotz-group-2008) | The best debris benchmark known, a series in charge mass |
| Prairie Flat's and Pre-Dice Throw II's digital gauge records; the Watching Hill soil data | ERDC's Geotechnical and Structures Laboratory; DRDC Suffield | [2](data-requests.md#2-prairie-flat-the-watching-hill-soil-data-and-pre-dice-throw-ii) | Ground shock as histories, with the site's soil |
| The slab contest's records (pressure and displacement), and the high-strength slab's details | UMKC and ACI Committee 447 | [3](data-requests.md#3-the-contests-high-strength-slab-thiagarajan-et-al-2015-reynolds-2015) | The contest's records in place of curves digitised from slides |
| Keys's logged masonry debris data, UK MoD property | University of Southampton and the MoD | [4](data-requests.md#4-masonry-debris-under-long-duration-blast-keys-and-clubley-2017-keys-2016) | Debris on the ground as data, not read off figures |
| Saatci's digital drop-weight records (no draft yet) | The VecTor Analysis Group, or Saatci | | Impact force against time, to say what the contact should be ([2c](data-survey.md#2c-saatcis-records)) |

## Fetched and used

Each source's files are in `/Volumes/StudioData/bombcad/data/<folder>/` with a `SOURCE.md`, never
in the repository; a comparison commits only small derived fixtures, with their licence. A dash
means an open paper whose numbers were transcribed into the code. The survey's
[Downloaded, not yet in use](data-survey.md#downloaded-not-yet-in-use) and
[Obtained](data-survey.md#obtained) give sizes, terms and what each holds.

| Source | Folder | Compared in |
|---|---|---|
| Wu et al. 2023; Wang et al. 2022: slabs with steel in both faces | `Wu2023`, `Wang2022` | [Validation](validation.md#slabs-with-steel-in-both-faces) |
| Peterson 2026: short beams struck to shear failure, with images | `Peterson2026` | [Validation](validation.md#short-beams-struck-to-a-shear-failure) |
| Hupfauf and Gebbeken 2022, Hupfauf 2024: slabs under contact charges | `Hupfauf` | [Validation](validation.md#slabs-under-contact-charges) |
| Hrynyk 2013: slabs struck by a falling weight | `Hrynyk2013` (sealed) | [Blind test 1](validation.md#blind-test-1-hrynyks-slabs-struck-by-a-falling-weight) |
| Mendonça 2020: slabs under an open-air charge | `Mendonca2020` (sealed) | [Blind test 2](validation.md#blind-test-2-mendonças-slabs-under-an-open-air-charge) |
| Reynolds 2015: the contest's high-strength slabs | `Reynolds2015` (sealed) | [Blind test 3](validation.md#blind-test-3-reynoldss-high-strength-slabs-in-the-blast-load-simulator) |
| Pattman 1971: Dial Pack's thermal radiation | `DialPack1971` | [Thermal radiation](thermal-radiation.md#against-dial-pack) |
| Bauwens, Chaffee and Dorofeev 2008: a vented methane deflagration | `Bauwens2008` | [Gas deflagrations](deflagration.md#bauwens-chaffee-and-dorofeev-2008) |
| Monk and Clubley: annealed windows in the Shoeburyness air blast tunnel (supplied by hand) | – (`Fixtures/MonkClubley`) | [Validation](validation.md#window-glass) |
| Bradley, Lawes and Mumby, cellular flame instabilities; Molkov et al., IChemE Symposium Series 150 (2004) | `Bradley-instability`, `Molkov-LES` | [Gas deflagrations](deflagration.md) |
| Alsubaei 2015: perimeter walls under field blasts | `Alsubaei2015` | [Validation](validation.md#perimeter-walls-under-field-blasts) |
| Keys and Clubley 2017, Keys 2016: masonry panels' debris | `KeysClubley2017`, `Keys2016` | [Validation](validation.md#brick-walls-debris) |
| Schwer 2015: the slab contest's assessment | `Schwer2015` | [Validation](validation.md#the-contests-repeat-its-lower-shot-and-its-other-entries) |
| Farrimond 2024, Rigby 2014, Rae and McAfee 2018, Oswald: the reference curves' scatter | `reference-scatter` | [Validation](validation.md#kingerybulmash-the-design-practice-standard) |
| UFC 3-340-02: the negative phase, the closed room's gas pressure | `UFC-3-340-02` | [Validation](validation.md#the-negative-phase-against-ufc-3-340-02) |
| Swisdak 1994; Cooper 1996; Kinney and Graham 1985; Xu and Lu 2016 (the user's copies) | `Swisdak1994`, `Cooper1996`, `KinneyGraham1985`, `XuLu2016` | [Air-blast model](air-blast-model.md#sources); the Janney beam |
| FoRCy: a footing rocked slowly | – (`Samples/FoRCy`) | [Footings](structural-model.md#footings) |
| FoRDy: footings shaken at the base | `FoRDy` | [Validation](validation.md#a-footing-shaken-on-dry-sand) |
| Rodrigues et al.: a precast beam on a corbel | – (`Samples/PrecastSeat`) | `blastbench precast` |
| Walraven and Reinhardt 1981; Bernardi et al. 2016 (OA1); Ando et al. 2000; Saatci 2007; Chiquito et al. 2023; Shang et al. 2026; Shetye 2013; Santos and Henriques 2015 | – | [Validation](validation.md) and the [survey's list](data-survey.md#obtained) |
| *Downloaded, not yet used:* DRDC TR 2013-056 (lidar of small clouds); USGS OFR 77-143 (read, not suited); the KLOTZ Group's 2018 paper; Vasudevan 2012 (sealed for a blind test) | `DRDC2013`, `USGS-OFR77-143`, `KlotzGroup2018`, `Vasudevan2012` | – |
