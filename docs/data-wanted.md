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
| Prairie Flat: earth motion and stress, WES TR N-72-2, 3.17 MB | [ERDC 11681/6813](https://erdc-library.erdc.dren.mil/jspui/handle/11681/6813) | ERDC's browser check | `data/PrairieFlat/` | Gauges at depth either side of the superseismic limit under 500 t on the surface: the soil column's first test where it claims to hold (Xia et al.'s, the only one so far, stood near and past the outrunning limit) |
| Kasun-III: Forsén et al., DDESB 2010 | [DTIC ADA532249](https://apps.dtic.mil/sti/pdfs/ADA532249.pdf) | DTIC, HTTP 403 | `data/Kasun2010/` | The cubes, charges and debris of the best debris benchmark known ([3c](data-survey.md#3c-collapse-and-debris)); the database itself is by request, below |
| Its companion: concrete breaking up under internal blast, DDESB 2010 | [DTIC ADA532261](https://apps.dtic.mil/sti/pdfs/ADA532261.pdf) | DTIC, HTTP 403 | `data/Kasun2010/` | How concrete walls break up and are thrown under an internal charge |
| Annealed and tempered glass under blast waves, EMRTC, Socorro | [OSTI 658184](https://www.osti.gov/biblio/658184) | osti.gov refuses the connection | `envelope-damage/sources/` | Panes that held beside panes that broke, over a range of overpressure and impulse: the breaking threshold, which Monk and Clubley's tests, all broken, cannot give ([3h](data-survey.md#3h-window-glass-breaking-under-a-blast)) |

**Then**, when convenient:

| Document | Link | Blocked here by | Save to `/Volumes/StudioData/bombcad/…` | Unlocks |
|---|---|---|---|---|
| Cubbage and Marshall (1972), *IChemE Symposium Series* 33; Cubbage and Simmonds (1955), Gas Council GC23 | IChemE archive; Gas Council reports | not found online | `fuels/TownGas/` | The British town gas the model takes and its vented-oven burning velocities, at first hand rather than through Lautkaski (2011) |
| Bauwens, Chao and Dorofeev, *IJHE* 37 (2012) 17599, and Bauwens and Dorofeev, *IJHE* 39 (2014) | [doi:10.1016/j.ijhydene.2012.04.053](https://doi.org/10.1016/j.ijhydene.2012.04.053) | paywalled (the ICHS 2011 paper was read) | `fuels/FMGlobalHydrogen/` | The journal version of the lean hydrogen vented tests, and their richer mixtures |
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
| An HE crater database of about 200 events, AFWL-TR-71-144 | [DTIC AD0891964](https://apps.dtic.mil/sti/pdfs/AD0891964.pdf) | DTIC | `data/craters/` | Measured craters by charge, soil and height, to judge the crater's scaling far beyond six events ([cratering](cratering.md#against-measured-craters)) |
| Gould, high-explosive field tests, DNA 6187F (1981) | [discover.dtic.mil](https://discover.dtic.mil/) (search the number) | DTIC | `data/craters/` | The large shots' craters, and the crater-volume law the NRC quotes |
| Estimates of crater dimensions for near-surface explosions, RDA-TR-2604-001 | [OSTI 6696719](https://www.osti.gov/biblio/6696719) | osti.gov refuses the connection | `data/craters/` | Near-surface bursts' craters tabulated |
| Jones, Prairie Flat crater and ejecta study (Project LN 3.01, DRES); Roddy, *Impact and Explosion Cratering* (Pergamon, 1977), Snowball's and the Suffield shots' tables | DRDC (search the title); the book | Not found open | `data/craters/` | The Suffield craters' depths, lips and true craters, first hand: Dial Pack's and Snowball's are second-hand here |
| *Fundamentals of Protective Design for Conventional Weapons*, TM 5-855-1 (1986), its cratering chapter | [discover.dtic.mil](https://discover.dtic.mil/) or the Army's publications (search the title) | Not found open here | `data/craters/` | Crater dimensions for near-surface bursts by soil, and how a water table limits them, to test the slumped-wall rule a crater's depth now uses below a water table ([cratering](cratering.md#below-a-water-table)) |
| Kingery and Bulmash, ARBRL-TR-02555 (1984) | [discover.dtic.mil](https://discover.dtic.mil/) (search the number) | DTIC | `data/reference-scatter/` | Their statement that 10% of a surface burst's energy goes into the ground, which the air's share on soft ground rests on, quoted here second-hand |
| Sand under a pulse in a vertical shock tube | [DTIC AD0818668](https://apps.dtic.mil/sti/pdfs/AD0818668.pdf) | DTIC | `data/shock-tube-sand/` | v = p/(ρc) and its fall with depth under a controlled pulse |
| DDESB TP-13 (WHS's 10-F-0806, once listed here for it, turned out to be TP-12, now in hand) | [discover.dtic.mil](https://discover.dtic.mil/) (search the title) | Not found open | `fragments/sources/` | Arena tests' hazardous-fragment distances, against which the fragments' ranges and areal densities can be checked ([Fragments](fragments.md#against-coopers-data)) |
| Fragment velocity predictions (DTIC ADB007377; title as listed, distribution may be limited) and NWC TP 7124 | DTIC [ADB007377](https://apps.dtic.mil/sti/pdfs/ADB007377.pdf), [ADA238153](https://apps.dtic.mil/sti/pdfs/ADA238153.pdf) | DTIC | `fragments/sources/` | Measured launch speeds against Gurney's, for cased charges of known geometry |
| McCleskey, fragment drag and presented area, NSWC TR 87-89 (1988) | [discover.dtic.mil](https://discover.dtic.mil/) (search the number) | DTIC | `fragments/sources/` | The irregular fragments' measured drag at low Mach, below the tumbling cubes' 0.5 |
| DDESB Technical Paper 16 (primary fragment characteristics and the hazardous fragment distance) | denix.osd.mil | denix refuses; DTIC down | `fragments/sources/` | DDESB's test protocol for the hazardous fragment distance, which DoD's test-derived distances follow. TP-12 (Zaker, 1975) was fetched by the user on 18 October 2026 (`fragments/sources/`, WHS 10-F-0806; [read](fragments.md#against-ddesb-tp-12)): it has the density's surface and procedure but no band of angles and only one table of arena masses |
| McCleskey, fragmentation hazard computer model (DTIC ADP004868); the Explosives Safety Seminar minutes with arena pick-up data (DTIC ADA235006, ADA261116) | [DTIC](https://apps.dtic.mil/sti/pdfs/ADP004868.pdf) | DTIC (under maintenance on 17 October) | `fragments/sources/` | Measured fragment densities by distance, to set beside the in-flight count |
| Project THOR, Technical Report 47 (metals) and its companion on non-metallic materials (title and number as Deniz 2010 cites them: TR 51, 1963) | DTIC [AD0322781](https://apps.dtic.mil/sti/pdfs/AD0322781.pdf) (TR 47) | DTIC | `fragments/sources/` | The THOR constants at first hand (now as a thesis reproduces them), and any for glass, plastics or wood, which would replace glass's single measured threshold |
| Walbert, *Ballistic Equations*, SURVICE Monograph 15-001 (2015) | [survice.com](https://www.survice.com/wp-content/uploads/ballistic-equations.pdf) | Refuses the connection | `fragments/sources/` | THOR and JTCG/ME penetration constants collected, to check those used |
| Natural fragmentation of steel cylinders, International Symposium on Ballistics proceedings (open; titles not confirmed here) | DPI [2182](https://dpi-proceedings.com/index.php/ballistics/article/view/2182), [16812](https://dpi-proceedings.com/index.php/ballistics30/article/view/16812), [33205](https://dpi-proceedings.com/index.php/ballistics31/article/view/33205) | Not tried | `fragments/sources/` | Arena tests of cylinders of stated wall and diameter: masses and speeds to set against Mott's B and Gurney's |
| *Cyclic tests on real-scale squat RC shear walls* (Pizarro Pohl, Kovarbašić and Stojadinović) | ETH Research Collection (search the title) | The collection returned errors | `data/ETH-squat-walls/` | Walls sliding at the base, slowly |
| EMERGE final report, Mercx (ed.), 1997 | [OSTI 378238](https://www.osti.gov/biblio/378238) | OSTI refused automated access | `data/EMERGE/` | Congested rigs of 2–8 m at two blockages, methane and propane: the [congestion model](congestion-proposal.md)'s scale trend |

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
| Popat et al., the MERGE code comparison, *J. Hazard. Mater.* 45 (1996) 1–25 | Elsevier | How codes fared on MERGE: the [congestion model](congestion-proposal.md)'s bar |
| Pierorazio et al., the BST tests, *Process Saf. Prog.* 24 (2005) 59 | Wiley | The congestion classes' measured flame speeds |
| Puttock et al., PDR model against MERGE, ERGOS and Buxton, *J. Loss Prev.* (2021) 104659 | Elsevier | The reference implementation's errors |
| BFETS Phase 2 report, BG R-1579 | FABIG (purchase) | Full-scale module explosions, 27 tests |
| CCPS, *Guidelines for Vapor Cloud Explosion…*, 2nd ed. (2010) | Wiley/AIChE | Congestion and blast curves in industry practice |
| Kenny, *Dynamic pulse buckling of slender beams with geometric imperfections subjected to an axial impact*, PhD thesis, Dalhousie (2001), 10 MB, open | [hdl:10222/55746](http://hdl.handle.net/10222/55746), too large for this machine's fetcher; save to `data/Kenny2001/` | Impact tests of imperfect slender beams, elastic and plastic, beside his models: the steel beams' [dynamic buckling](shell-model.md#buckling) under a measured pulse, now checked only against Lindberg's closed form |
| Culache, steel moment connections at high rates, PhD thesis, Southampton (2017), open | [eprints.soton.ac.uk/436596](https://eprints.soton.ac.uk/436596/) | The joints' rotation and failure under rapid loading: the first test of the steel frames' connections ([steel members](validation.md#steel-beams-and-columns-in-the-open)) |
| Sadek et al., steel moment connections under column removal, NIST TN 1669 (2010), open | [nvlpubs.nist.gov](https://nvlpubs.nist.gov/nistpubs/TechnicalNotes/NIST.TN.1669.pdf) | Full-scale beam–column assemblies pulled down at a lost column: the frames' catenary action and connection failure |
| Dinu et al., close-range blasts on steel frames, SDSS 2016 | [UPT](https://www.ct.upt.ro/centre/cemsig/codec_files/3.c15-%20Effects%20of%20close%20range%20blasts%20on%20steel%20frames.%20Experimental%20testing%20and%20numerical%20validation.pdf) | Beam–column assemblies under charges close in: a frame's members and joints together |
| Ari-Gur, Weller and Singer, columns under axial impact, *IJSS* 18(7) (1982) 619–641 | Elsevier | The classic tests of columns struck at an end, imperfections measured |
| Batalha et al., precast beam-to-column seats under cyclic load, *Earthquake Eng. Struct. Dyn.* 51(5) (2022) 1096–1114; save to `concrete-stages/seat-research/pdfs/` | [doi:10.1002/eqe.3606](https://doi.org/10.1002/eqe.3606); the Porto repository copy is restricted | The seats' pad size, thickness and hardness, the concrete's strength and the dowels' grade, embedment and grout, which the [measured seats](structural-model.md#base-connections) now take from companion papers; and the group's calibrated dowel parameters, without which the dowels' pinched, degrading cycles are left unmodelled |
| Dewey, the TNT and ANFO equivalences of the Beirut explosion, *Shock Waves* 31 (2021) | [doi:10.1007/s00193-021-00992-1](https://doi.org/10.1007/s00193-021-00992-1) | Peak overpressure against distance from Rigby's arrival times: the nearest to a measured pressure curve for Beirut (more in `data/Beirut2020/TO-FETCH.md`) |

The survey names a few more, each under its item: Hao et al. (2017), Ross and Krawinkler (1985),
Kiger and Slawson (1984), Bauwens et al.'s propane and hydrogen papers, Kingery and Bulmash
(1984), and Oswald (2017).

**Still to find**: needs no source in hand meets yet.

| Need | What a test would have to show | Unlocks |
|---|---|---|
| Struts crushing under impact, inside the section | Short or deep beams struck to a strut failure (as Peterson's), with strain measured through the core of the strut, not only on its painted face (embedded gauges, or DIC of a beam sawn to show its middle, or X-ray), and the strut's force: when the core passes its peak and when it carries less, against when the face spalls or the end block plugs out and when the beam loses its load, so that post-peak spalling or plugging can be told from the failure itself | Whether the model's struts, which crush on their face but are not asked for more, should fail as [Peterson's](validation.md#short-beams-struck-to-a-shear-failure) did; without it, any strut law that fails them would be fitted to the face's spalling |
| Timber panels' screwed angle connections under fast loading | CLT walls joined to a slab and to floors as at Tyndall (a continuous hot-rolled angle, or clip angles, with self-tapping screws), loaded out of plane at blast rates, inbound and in rebound: the force through the connection against its own slip and rotation, measured at the connection rather than inferred from the panel's deflection, to failure (screw yield, withdrawal, head pull-through, wood splitting) | Joints for [Tyndall's CLT buildings](validation.md#cross-laminated-timber-buildings-at-tyndall), which are rigid now. What is in hand measures the panel, not the joint. Côté (Ottawa, 2017) shock-tube tests 5-ply panels on angles and screws and gives only midspan deflection and failure mode: no reactions, and one joint slipped 17.9 mm on video. Nagy and Weaver (K&C TR-16-42.1, 2016) load panels slowly on L4×4×1/4 angles with Tyndall's screws, measuring deflections only, with the end pieces braced. Rezvani (Victoria, 2021) and Kržan and Azinović (2021) cycle proprietary brackets at 0.05–2 mm/s. A joint law built on these would be fitted to Tyndall's deflections; once a law exists, Côté's stiff-angle tests would be its first check |
| Footings on or near a slope under fast loading | Footings on a slope's face or near its crest, on sand of known density and strength, loaded to failure quickly (a drop, a blast, or a centrifuge shake) beside the same footing on level ground: the load against settlement and slip, how far back from a crest the capacity is regained, and the footing's stiffness on the slope | The [footings on a slope](validation.md#footings-on-a-slope), now judged on Meyerhof's 1957 charts and Vesić's factor alone; their stiffness, taken as level ground's for want of any |
| Brick walls' blast resistance once cracked | Unreinforced brick walls (a cavity wall's 102.5 mm leaves, a solid 215 mm wall) built between returns or other stiff ends, blasted past cracking: deflection histories to the end of the motion, whether each wall stood, the axial load on it and how stiff its ends were, so that arching across between the returns, arching up between floors and rocking under the load above can be told apart | Whether the [terraced houses'](validation.md#terraced-houses-against-wartime-bomb-damage) cracked front walls should stand, as most surveyed houses did; without it any resistance added would be fitted to that judge |

## To request

Datasets in no open document, which have to be asked of their owners. Drafts, with contacts
and routes checked on 11 October 2026, are in [Data requests](data-requests.md); nothing has
been sent.

| Dataset | Ask | Draft | Unlocks |
|---|---|---|---|
| Kasun-III's debris database (21,500 pieces by mass and position), and first the FOI test report FOI-R--2749--SE, orderable in [FOI's report search](https://www.foi.se/rapportsammanfattning?reportNo=FOI-R--2749--SE) | FOI, Forsvarsbygg or the KLOTZ Group | [1](data-requests.md#1-kasun-iii-debris-database-klotz-group-2008) | The best debris benchmark known, a series in charge mass |
| Kasun's 80 kg cubicle: its debris piece masses, their pickup by distance, and any bounce and roll, in the FOI and Forsvarsbygg reports (first FOI-R--2202--SE), orderable in [FOI's report search](https://www.foi.se/rapportsammanfattning?reportNo=FOI-R--2202--SE) | FOI or Forsvarsbygg | | The spread of piece sizes and launch angles that the [envelope debris](hazards.md#debris-from-failed-envelope-components) lacks: no one size, drag or angle reaches the tests' 290–315 m (best 189 m) |
| Prairie Flat's and Pre-Dice Throw II's digital gauge records; the Watching Hill soil data | ERDC's Geotechnical and Structures Laboratory; DRDC Suffield | [2](data-requests.md#2-prairie-flat-the-watching-hill-soil-data-and-pre-dice-throw-ii) | Ground shock as histories, with the site's soil |
| The slab contest's records (pressure and displacement), and the high-strength slab's details | UMKC and ACI Committee 447 | [3](data-requests.md#3-the-contests-high-strength-slab-thiagarajan-et-al-2015-reynolds-2015) | The contest's records in place of curves digitised from slides |
| Keys's logged masonry debris data, UK MoD property | University of Southampton and the MoD | [4](data-requests.md#4-masonry-debris-under-long-duration-blast-keys-and-clubley-2017-keys-2016) | Debris on the ground as data, not read off figures |
| ADBLAST's deliverables D4, D5 and D6: each cladding shot's charge and records, and the sub-structure rig's drawings (no draft yet) | RWTH Aachen's Institute for Steel Structures (B. Hoffmeister) or the Royal Military Academy, Brussels | | Cladding pulled off a purlin that deforms, compared ([3i](data-survey.md#3i-profiled-cladding-on-its-fixings)) |
| Saatci's digital drop-weight records (no draft yet) | The VecTor Analysis Group, or Saatci | | Impact force against time, to say what the contact should be ([2c](data-survey.md#2c-saatcis-records)) |

## Fetched and used

Each source's files are in `/Volumes/StudioData/bombcad/data/<folder>/` with a `SOURCE.md`, never
in the repository; a comparison commits only small derived fixtures, with their licence. A dash
means an open paper whose numbers were transcribed into the code. The survey's
[Downloaded, not yet in use](data-survey.md#downloaded-not-yet-in-use) and
[Obtained](data-survey.md#obtained) give sizes, terms and what each holds.

| Source | Folder | Compared in |
|---|---|---|
| Langdon 2003: corrugated blast wall panels under pulse pressure | `../profiled-sheeting/langdon-2003` | [Profiled sheeting](profiled-sheeting.md#against-langdons-corrugated-panels) |
| ADBLAST 2015: trapezoidal cladding on screws under C4 | `../profiled-sheeting/adblast` | [Profiled sheeting](profiled-sheeting.md#against-adblasts-cladding-tests) |
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
| Xia et al. 2022: ground motion 0.5 m deep under 1 t on the ground (supplied by hand; CC BY, `Fixtures/XiaChen2022`) | `XiaChen2022-GroundShock` | [Ground shock](ground-shock.md#against-measured-ground-motion), [Validation](validation.md#ground-motion-under-a-1-t-surface-burst) |
| Keys and Clubley 2017, Keys 2016: masonry panels' debris | `KeysClubley2017`, `Keys2016` | [Validation](validation.md#brick-walls-debris) |
| Schwer 2015: the slab contest's assessment | `Schwer2015` | [Validation](validation.md#the-contests-repeat-its-lower-shot-and-its-other-entries) |
| Farrimond 2024, Rigby 2014, Rae and McAfee 2018, Oswald: the reference curves' scatter | `reference-scatter` | [Validation](validation.md#kingerybulmash-the-design-practice-standard) |
| UFC 3-340-02: the negative phase, the closed room's gas pressure | `UFC-3-340-02` | [Validation](validation.md#the-negative-phase-against-ufc-3-340-02) |
| Swisdak 1994; Cooper 1996; Kinney and Graham 1985; Xu and Lu 2016 (the user's copies) | `Swisdak1994`, `Cooper1996`, `KinneyGraham1985`, `XuLu2016` | [Air-blast model](air-blast-model.md#sources); the Janney beam |
| FoRCy: a footing rocked slowly | – (`Samples/FoRCy`) | [Footings](structural-model.md#footings) |
| FoRDy: footings shaken at the base | `FoRDy` | [Validation](validation.md#a-footing-shaken-on-dry-sand) |
| Rodrigues et al.: a precast beam on a corbel | – (`Samples/PrecastSeat`) | `blastbench precast` |
| Walraven and Reinhardt 1981; Bernardi et al. 2016 (OA1); Ando et al. 2000; Saatci 2007; Chiquito et al. 2023; Shang et al. 2026; Shetye 2013; Santos and Henriques 2015 | – | [Validation](validation.md) and the [survey's list](data-survey.md#obtained) |
| Nian et al. 2024: an RC blast wall against air shock | `Nian2024-BlastWall` | [Validation](validation.md#a-blast-wall-with-its-length-known) ([Fixtures/Nian2024](../Fixtures/Nian2024/README.md)) |
| Yao et al. 2023: 4 × 5 m slabs under explosion (supplied by the user) | `Yao2023-RCSlabs` | [Validation](validation.md#yaos-large-slabs) ([Fixtures/Yao2023](../Fixtures/Yao2023/README.md)) |
| Hayman 2014: one-way reinforced masonry walls under blast | `Hayman2014` | [One-way walls](building-envelopes.md#one-way-walls) ([Fixtures/Hayman2014](../Fixtures/Hayman2014/README.md)) |
| DDESB TP-12, Zaker 1975, *Fragment and Debris Hazards* (WHS 10-F-0806, fetched by the user 18 October 2026) | `../fragments/sources` | [Fragments](fragments.md#against-ddesb-tp-12) |
| *Fetched 18 October 2026, not yet compared:* Valsamos, Larcher and Casadei 2021, JRC's city-scale Beirut model (CC BY); Sadek et al. 2022, the reviewed GEER-070; Stennett, Gaulter and Akhavan 2020, Beirut's NEQ from video; Denny et al. 2025, the grain silos' shielding at 1:250 | `Beirut2020/Valsamos2021`, `Beirut2020/Sadek2022`, `Beirut2020/Stennett2020`, `Beirut2020/Denny2025-Siloes` | With the Beirut session, for [Beirut 2020](beirut-2020.md) |
| *Fetched, not yet compared:* Skjold et al. 2019, HySEA's vented hydrogen containers with congestion; Han, Dai, Gou and Chen 2020, hydrogen burning velocities reviewed; AIAA 2000-0574, hydrogen flames' stretch; "Gauging the fireball"; Johnson, Allason and Cronin 2024, Spadeadam's large VCE programmes (*J. Loss Prev.* 89, 105287) | `Skjold2019-HySEA-congestion`, `HanDai2020-H2-flame-speeds`, `Kwon2000-HydrogenStretch`, `GaugingFireball`, `Spadeadam-review` | For [hydrogen](deflagration.md#hydrogen-and-town-gas-1), the [congestion model](congestion-model.md) and the [fireball](thermal-radiation.md) when next worked on |
| *Downloaded, not yet used:* DRDC TR 2013-056 (lidar of small clouds); USGS OFR 77-143 (read, not suited); the KLOTZ Group's 2018 paper; Vasudevan 2012 (sealed for a blind test) | `DRDC2013`, `USGS-OFR77-143`, `KlotzGroup2018`, `Vasudevan2012` | – |
