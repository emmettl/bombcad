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
| Valsamos, Larcher and Casadei, Beirut as a city-scale blast simulation, *Safety Science* 137 (2021), CC BY | [doi:10.1016/j.ssci.2021.105190](https://doi.org/10.1016/j.ssci.2021.105190); [JRC122537](https://publications.jrc.ec.europa.eu/repository/handle/JRC122537) | ScienceDirect, HTTP 403; JRC's firewall | `data/Beirut2020/Valsamos2021/` | The other city-scale model of Beirut: its mesh, charge, buildings, pressure and impulse maps, and run times, to set the Beirut sample beside |
| Denny et al., the grain silos' shielding at 1:250, *Shock Waves* (2025), CC BY | [doi:10.1007/s00193-025-01241-5](https://doi.org/10.1007/s00193-025-01241-5) | Springer's JavaScript challenge | `data/Beirut2020/Denny2025/` | Gauges behind the silos at reduced scale: a direct check of the shielding the Beirut sample shows |

**Then**, when convenient:

| Document | Link | Blocked here by | Save to `/Volumes/StudioData/bombcad/…` | Unlocks |
|---|---|---|---|---|
| Skjold et al., vented hydrogen deflagrations in 20 ft containers, *IJHE* 44 (2019), open access | [doi:10.1016/j.ijhydene.2018.10.010](https://doi.org/10.1016/j.ijhydene.2018.10.010) | ScienceDirect's bot check (the ISHPMIE 2018 paper on Zenodo was read) | `fuels/HySEA/` | HySEA's container tests in full, a second vented [hydrogen](deflagration.md#hydrogen-and-town-gas-1) check beside FM Global's |
| Han, Dai, Gou and Chen, a review of hydrogen burning velocities, *Applications in Energy and Combustion Science* 1 (2020), open access | [doi:10.1016/j.jaecs.2020.100008](https://doi.org/10.1016/j.jaecs.2020.100008) | ScienceDirect's bot check | `fuels/HydrogenSL/` | A modern compilation to set beside Taylor's (1991) table the model takes |
| Cubbage and Marshall (1972), *IChemE Symposium Series* 33; Cubbage and Simmonds (1955), Gas Council GC23 | IChemE archive; Gas Council reports | not found online | `fuels/TownGas/` | The British town gas the model takes and its vented-oven burning velocities, at first hand rather than through Lautkaski (2011) |
| Bauwens, Chao and Dorofeev, *IJHE* 37 (2012) 17599, and Bauwens and Dorofeev, *IJHE* 39 (2014) | [doi:10.1016/j.ijhydene.2012.04.053](https://doi.org/10.1016/j.ijhydene.2012.04.053) | paywalled (the ICHS 2011 paper was read) | `fuels/FMGlobalHydrogen/` | The journal version of the lean hydrogen vented tests, and their richer mixtures |
| Nian et al., an RC blast wall against air shock, *Defence Technology* 31 (2024), open access | [doi:10.1016/j.dt.2022.11.005](https://doi.org/10.1016/j.dt.2022.11.005) | ScienceDirect's bot check | `data/Nian2024/` | Pressures in front of and behind a freestanding wall ([2b](data-survey.md#2b-a-freestanding-wall-under-an-open-air-charge)); obtained 2026-10-17, compared in [validation](validation.md#a-blast-wall-with-its-length-known) ([Fixtures/Nian2024](../Fixtures/Nian2024/README.md)) |
| Yao et al., large slabs under explosion, *Applied Sciences* 13, 12552 (2023) | [MDPI](https://www.mdpi.com/2076-3417/13/23/12552) | MDPI, HTTP 403 (supplied by the user) | `data/Yao2023-RCSlabs/` | A 4 × 5 m slab with pressure gauges, displacement and acceleration ([1a](data-survey.md#1a-a-slab-with-steel-in-both-faces-under-an-open-air-charge)); obtained 2026-10-17, compared in [validation](validation.md#yaos-large-slabs) ([Fixtures/Yao2023](../Fixtures/Yao2023/README.md)): the load agrees, the displacements do not compare, and the 20 kg test is too resistant locally |
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
| An HE crater database of about 200 events, AFWL-TR-71-144 | [DTIC AD0891964](https://apps.dtic.mil/sti/pdfs/AD0891964.pdf) | DTIC | `data/craters/` | Measured craters by charge, soil and height, to judge the crater's scaling far beyond six events ([cratering](cratering.md#against-measured-craters)) |
| Gould, high-explosive field tests, DNA 6187F (1981) | [discover.dtic.mil](https://discover.dtic.mil/) (search the number) | DTIC | `data/craters/` | The large shots' craters, and the crater-volume law the NRC quotes |
| Estimates of crater dimensions for near-surface explosions, RDA-TR-2604-001 | [OSTI 6696719](https://www.osti.gov/biblio/6696719) | osti.gov refuses the connection | `data/craters/` | Near-surface bursts' craters tabulated |
| Jones, Prairie Flat crater and ejecta study (Project LN 3.01, DRES); Roddy, *Impact and Explosion Cratering* (Pergamon, 1977), Snowball's and the Suffield shots' tables | DRDC (search the title); the book | Not found open | `data/craters/` | The Suffield craters' depths, lips and true craters, first hand: Dial Pack's and Snowball's are second-hand here |
| *Fundamentals of Protective Design for Conventional Weapons*, TM 5-855-1 (1986), its cratering chapter | [discover.dtic.mil](https://discover.dtic.mil/) or the Army's publications (search the title) | Not found open here | `data/craters/` | Crater dimensions for near-surface bursts by soil, and how a water table limits them, to test the slumped-wall rule a crater's depth now uses below a water table ([cratering](cratering.md#below-a-water-table)) |
| Kingery and Bulmash, ARBRL-TR-02555 (1984) | [discover.dtic.mil](https://discover.dtic.mil/) (search the number) | DTIC | `data/reference-scatter/` | Their statement that 10% of a surface burst's energy goes into the ground, which the air's share on soft ground rests on, quoted here second-hand |
| Sand under a pulse in a vertical shock tube | [DTIC AD0818668](https://apps.dtic.mil/sti/pdfs/AD0818668.pdf) | DTIC | `data/shock-tube-sand/` | v = p/(ρc) and its fall with depth under a controlled pulse |
| DDESB TP-13, *Fragment and Debris Hazards* | [WHS reading room 10-F-0806](https://www.esd.whs.mil/Portals/54/Documents/FOID/Reading%20Room/Other/10-F-0806_Fragment_and_Debris_Hazards.pdf) | WHS refuses | `fragments/sources/` | Arena tests' hazardous-fragment distances, against which the fragments' ranges and areal densities can be checked ([Fragments](fragments.md#against-coopers-data)) |
| Fragment velocity predictions (DTIC ADB007377; title as listed, distribution may be limited) and NWC TP 7124 | DTIC [ADB007377](https://apps.dtic.mil/sti/pdfs/ADB007377.pdf), [ADA238153](https://apps.dtic.mil/sti/pdfs/ADA238153.pdf) | DTIC | `fragments/sources/` | Measured launch speeds against Gurney's, for cased charges of known geometry |
| McCleskey, fragment drag and presented area, NSWC TR 87-89 (1988) | [discover.dtic.mil](https://discover.dtic.mil/) (search the number) | DTIC | `fragments/sources/` | The irregular fragments' measured drag at low Mach, below the tumbling cubes' 0.5 |
| DDESB Technical Paper 16 (primary fragment characteristics and the hazardous fragment distance) and Technical Paper 12 (Zaker, *Fragment and Debris Hazards*, 1975) | [WHS reading room 10-F-0806](https://www.esd.whs.mil/Portals/54/Documents/FOID/Reading%20Room/Other/10-F-0806_Fragment_and_Debris_Hazards.pdf) (TP-12); TP-16 on denix.osd.mil | WHS and denix refuse; DTIC down | `fragments/sources/` | How DDESB counts the density (the surface, the band of angles) and its arena data: the in-flight hazard distance's method at first hand |
| McCleskey, fragmentation hazard computer model (DTIC ADP004868); the Explosives Safety Seminar minutes with arena pick-up data (DTIC ADA235006, ADA261116) | [DTIC](https://apps.dtic.mil/sti/pdfs/ADP004868.pdf) | DTIC (under maintenance on 17 October) | `fragments/sources/` | Measured fragment densities by distance, to set beside the in-flight count |
| Project THOR, Technical Report 47 (metals) and its companion on non-metallic materials (title and number as Deniz 2010 cites them: TR 51, 1963) | DTIC [AD0322781](https://apps.dtic.mil/sti/pdfs/AD0322781.pdf) (TR 47) | DTIC | `fragments/sources/` | The THOR constants at first hand (now as a thesis reproduces them), and any for glass, plastics or wood, which would replace glass's single measured threshold |
| Walbert, *Ballistic Equations*, SURVICE Monograph 15-001 (2015) | [survice.com](https://www.survice.com/wp-content/uploads/ballistic-equations.pdf) | Refuses the connection | `fragments/sources/` | THOR and JTCG/ME penetration constants collected, to check those used |
| Natural fragmentation of steel cylinders, International Symposium on Ballistics proceedings (open; titles not confirmed here) | DPI [2182](https://dpi-proceedings.com/index.php/ballistics/article/view/2182), [16812](https://dpi-proceedings.com/index.php/ballistics30/article/view/16812), [33205](https://dpi-proceedings.com/index.php/ballistics31/article/view/33205) | Not tried | `fragments/sources/` | Arena tests of cylinders of stated wall and diameter: masses and speeds to set against Mott's B and Gurney's |
| *Cyclic tests on real-scale squat RC shear walls* (Pizarro Pohl, Kovarbašić and Stojadinović) | ETH Research Collection (search the title) | The collection returned errors | `data/ETH-squat-walls/` | Walls sliding at the base, slowly |
| EMERGE final report, Mercx (ed.), 1997 | [OSTI 378238](https://www.osti.gov/biblio/378238) | OSTI refused automated access | `data/EMERGE/` | Congested rigs of 2–8 m at two blockages, methane and propane: the [congestion model](congestion-proposal.md)'s scale trend |
| Johnson, Allason and Cronin, Spadeadam's explosion programmes, *J. Loss Prev.* 89 (2024) 105287, open access | [doi:10.1016/j.jlp.2024.105287](https://doi.org/10.1016/j.jlp.2024.105287) | ScienceDirect refused | `data/Spadeadam-review/` | What the BG/Shell rigs and BFETS measured, for the congestion model |
| Stennett, Gaulter and Akhavan, the Beirut NEQ from public video, *PEP* 45 (2020), CC BY-NC-ND | [Wiley PDF](https://onlinelibrary.wiley.com/doi/pdfdirect/10.1002/prep.202000227); [Cranfield 1826/16030](https://dspace.lib.cranfield.ac.uk/handle/1826/16030) | Wiley and Cranfield, HTTP 403 | `data/Beirut2020/Stennett2020/` | A second set of arrival times and camera positions, beside Rigby's |
| Sadek et al., the port and nearby buildings, *Natural Hazards Review* 23(2) (2022), green open copies | [eScholarship 0jk5d8nh](https://escholarship.org/uc/item/0jk5d8nh); [NSF PAR 10338344](https://par.nsf.gov/servlets/purl/10338344) | HTTP 403 | `data/Beirut2020/Sadek2022/` | The reviewed version of GEER-070 (in hand): revised crater, quay and building damage |

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
| Dewey, the TNT and ANFO equivalences of the Beirut explosion, *Shock Waves* 31 (2021) | [doi:10.1007/s00193-021-00992-1](https://doi.org/10.1007/s00193-021-00992-1) | Peak overpressure against distance from Rigby's arrival times: the nearest to a measured pressure curve for Beirut (more in `data/Beirut2020/TO-FETCH.md`) |

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
| *Downloaded, not yet used:* DRDC TR 2013-056 (lidar of small clouds); USGS OFR 77-143 (read, not suited); the KLOTZ Group's 2018 paper; Vasudevan 2012 (sealed for a blind test) | `DRDC2013`, `USGS-OFR77-143`, `KlotzGroup2018`, `Vasudevan2012` | – |
