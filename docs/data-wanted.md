# Data wanted

Sources that would improve the model, what is needed from each and what it would be used for.
Some could not be retrieved automatically (the site refused automated access, or the material
is only in print); others are open but not yet downloaded. The numbered items are listed with
the most valuable first.

The citations in the older entries were written from memory and may contain small errors in
page numbers or titles; the authors, journals and years should be enough to find each one.
Those found in the search of 10 October 2026 were taken from the publishers' or repositories'
own landing pages, except where marked as seen in search summaries only.

## Where to start: the open leads, ranked

A search on 10 October 2026 for every wanted item below read landing pages and abstracts only;
nothing was downloaded. Many hosts refused automated access and were not retried: DTIC, the
ERDC library (a browser check), DesignSafe, ScienceDirect, MDPI, DOAJ, MOspace, MacSphere,
the Southampton and Loughborough repositories, and ASCE. Those are marked **needs the user to
obtain**. The session's allowance of web searches ran out before some candidates were searched
(named in each item), so an item with nothing found is not proof that nothing exists.

Ranked by how far each would move the validation: first what tests the structural model's
weakest points (limitations 1, 2, 4, 5 and 8 in the
[roadmap](roadmap.md#limitations-most-important-first)), then what would give an effect with
no comparison at all its first one, and open sources ahead of those that need the user.

| # | Source | For | Access | Why |
|---|--------|-----|--------|-----|
| 1 | Wu et al. 2023, *Materials* 16, 4068: 16 slabs, one layer of steel or two, contact and close-in TNT ([1a](#1a-a-slab-with-steel-in-both-faces-under-an-open-air-charge)) | Steel in both faces; close-in damage | Open, CC BY 4.0 | Measured materials, one shot a slab, displacement histories, and the holes' diameters: the breach the model never makes |
| 2 | Peterson et al. 2026, KTH: 18 beams with and without stirrups struck to shear failure, with raw high-speed images ([2d](#2d-interlock-and-tension-stiffening-under-impact)) | Shear under impact; interlock | Open, CC BY 4.0 (Mendeley Data) | Support reactions and images from which crack opening and slip can be read, on beams that fail in shear |
| 3 | Hupfauf and Gebbeken 2022, and Hupfauf's 2024 thesis: 15 slabs under contact charges ([3c](#3c-collapse-and-debris)) | Debris; spall | Open, CC BY 4.0; used ([Validation](validation.md#slabs-under-contact-charges)) | The first debris comparison: secondary debris velocities and spall craters, on documented slabs |
| 4 | Hrynyk 2013, slabs struck by a falling weight, digital records on the VecTor site ([2d](#2d-interlock-and-tension-stiffening-under-impact)) | Tension stiffening under impact | Open download, terms not stated | Raw records of reinforced and fibre-reinforced slabs, which separate what the concrete between cracks carries |
| 5 | FoRDy, the dynamic sister of FoRCy ([3b](#3b-a-footing-or-connection-under-fast-loading)) | Footings | Open, Open Data Commons Attribution on DesignSafe (CC BY-NC-SA 4.0 on DataCenterHub) | Settlement measured under shaking, on the sand family of SSG02_03, where the model settles a tenth as much |
| 6 | Wang et al. 2022, *Materials* 15, 6449: two slabs, steel in both faces, 10 kg at 1.2 m ([1a](#1a-a-slab-with-steel-in-both-faces-under-an-open-air-charge)) | Air and structure together | Open, CC BY 4.0 | Reflected pressures and deflection histories from one open-air shot; but an aluminised charge and nominal materials |
| 7 | Prairie Flat (WES TR N-72-2), the Watching Hill soil data, and Pre-Dice Throw II ([3a](#3a-air-induced-ground-shock)) | Ground shock | Needs the user to obtain (ERDC, DTIC) | Gauges at depth either side of the superseismic limit under a 500-ton surface burst, with the site's soil; Pre-Dice Throw II adds published blind predictions |
| 8 | Pattman 1971, Dial Pack thermal measurements, DREO Report 642 ([3e](#3e-fireball-radiation)) | Fireball radiation | Open (Government of Canada), 1.45 MB | A second 500-ton TNT shot measured by the group behind the one comparison so far |
| 9 | Keys and Clubley 2017, and Keys's 2016 thesis: masonry panels and small buildings under long-duration blast ([3c](#3c-collapse-and-debris)) | Collapse and debris | Needs the user to obtain | Debris distributions on the ground from walls broken by drag, the loading the model's debris feels |
| 10 | Reynolds 2015 (UMKC thesis) and ACI SP-306 (2016) ([1](#1-a-second-structural-test-from-the-same-contest)) | The contest's high-strength slab | Needs the user to obtain | Likely the high-strength slabs' details and histories; nothing open has them |
| 11 | Alsubaei 2015, Western University thesis: perimeter walls under field blasts ([2b](#2b-a-freestanding-wall-under-an-open-air-charge)) | A wall in the open | Open, 8.42 MB, terms not stated | Pressures behind walls; whether it gives the walls' own deflection is unknown |
| 12 | Kasun-III, KLOTZ Group, 2008: debris of five internal shots in small concrete cubes ([3c](#3c-collapse-and-debris)) | Debris | Needs the user to obtain (DTIC; the database by request) | Over 21,500 pieces of debris, mapped; the best debris benchmark known, but not open |
| 13 | Sharon et al. 2012, and the DRDC field trials of 2012 ([3d](#3d-an-he-clouds-growth-after-two-minutes)) | The cloud after two minutes | Paywalled; the DRDC report open, 2.62 MB | Cloud heights against time below Church's charges; lidar extents of small clouds |

The vented gas deflagration ([3f](#3f-a-vented-gas-deflagration)) is not ranked with these: it
serves a second source still being added. The open ones among 1 to 11 have been downloaded with
the user's agreement (see [Downloaded, not yet in use](#downloaded-not-yet-in-use)).

## 1. A second structural test from the same contest

- **Where:** G. Thiagarajan, A. V. Kadambi, S. Robert and C. F. Johnson, "Experimental and
  finite element analysis of doubly reinforced concrete slabs subjected to blast loads",
  *International Journal of Impact Engineering* 75 (2015) 162–173,
  doi:10.1016/j.ijimpeng.2014.07.018 (authors as Crossref gives them; Elsevier's licence, not
  open; needs the user to obtain).
- **Needed:** for the high-strength concrete slab: concrete strength, bar sizes, spacing and
  cover in both faces, yield and ultimate steel strengths, the measured reflected pressure and
  impulse histories, and the measured mid-span displacement history.
- **Use:** a second case in `SlabBenchmark.swift`, with steel in both faces and a different
  concrete, run unchanged against the model.
- **Also needed for the existing slab:** how it was supported in the test rig: the width and
  material of the bearings, and whether the slab was held down against rebound. The model
  springs back after its peak about twice as far as the specimen did, and a rig that
  restrained the rebound would explain part of that; so would photographs or a description
  of the crushing at the top of the mid-span hinge. Modelling
  choices for the supports change the predicted peak by 15–20%.
- **Also useful:** the Blast Blind Simulation Contest data package itself (organised through
  ACI Committee 447 and the University of Missouri–Kansas City), if the digital pressure and
  displacement records are available. They would replace the curves currently digitised from
  presentation slides.
- **Searched, 10 October 2026.** Nothing open gives the high-strength slab's bar spacing,
  cover or ultimate strength, its histories, or the rig. Search summaries of the contest's ACI
  and NDIA material (not read directly) give two concretes, 5 and 15 ksi; #3 bars, Grade 60
  (yield 68 ksi) in the normal slab and vanadium steel (about 83 ksi) in the high-strength one;
  two loads of about 5.4 and 7.0 MPa ms; and the tests in ERDC's Blast Load Simulator. They
  also call both classes single-mat, so the "doubly reinforced" paper above may describe an
  earlier series, not the contest's high-strength slab; that is to be checked. Candidates:
  - *ACI SP-306* (2016), edited by G. Thiagarajan and E. B. Williamson, doi:10.14359/51688861,
    the contest's papers, and in it G. A. Shetye, S. Thadisina and G. Thiagarajan, paper 9,
    doi:10.14359/51688873, on twelve slabs of both strengths at 0.46% and 0.68% steel. Sold by
    ACI; needs the user to obtain. Most likely to hold the high-strength slab's details.
  - K. A. Reynolds, *Experimental behavior of high strength concrete slabs subjected to shock
    loading*, MS thesis, UMKC, 2015,
    [MOspace 10355/48353](https://mospace.umsystem.edu/xmlui/handle/10355/48353): by search
    summaries, pressure, impulse and deflection histories of high-strength slabs at two steel
    ratios. MOspace refused automated access; needs the user to obtain. Whether each slab was
    shot once is not known.
  - A. K. Vasudevan, *FE analysis and experimental comparison of doubly reinforced concrete
    slabs subjected to blast loads*, MS thesis, UMKC, 2012,
    [MOspace 10355/14606](https://mospace.umsystem.edu/xmlui/handle/10355/14606): probably the
    series behind the 2015 paper. Needs the user to obtain. MOspace items 10355/33223 and
    10355/67037 also came up, contents unknown.
  - T. H. Kewaisy's SP-306 paper (doi:10.14359/51688871), his NDIA 2018 paper
    (`ndia.dtic.mil/wp-content/uploads/2018/intexpsafety/Kewaisy2Paper.pdf`) and his ACI
    webinar slides (`concrete.org/portals/0/files/pdf/webinars/ws_S18_AdvancedModelingBlastResponses_Kewaisy.pdf`):
    open PDFs, sizes not stated, not opened; likely to restate the slabs and loads.
  - C. F. Johnson, *Blast Load Simulator experiments for computational model validation*,
    ERDC/GSL TR-16-27: behind ERDC's browser check; probably the loads only.

## 1a. A slab with steel in both faces under an open-air charge

- **Needed:** a slab with steel in both faces, shot once from new in the open, with its
  geometry, steel, measured materials, supports, charge and measured deflection history. The
  model has steel in one face only in its slab tests so far (roadmap step 2).
- **Found, 10 October 2026:**
  - Y. Wu et al., "A research investigation into the impact of reinforcement distribution and
    blast distance on the blast resilience of reinforced concrete slabs", *Materials* 16(11),
    4068 (2023), doi:10.3390/ma16114068, [PMC10254842](https://pmc.ncbi.nlm.nih.gov/articles/PMC10254842/),
    CC BY 4.0. Sixteen slabs 2 × 2 m and 100 mm thick, eight with one layer of 8 mm bars at
    100 mm and eight with a layer in each face at 200 mm, 20 mm cover; concrete measured at
    47.0 MPa, bars at 455 MPa yield and 587.5 MPa ultimate; spanning one way, bolted to a steel
    frame. TNT of 0.2 to 1.6 kg in contact or 0.25 to 0.50 m above (0.43 m/kg^(1/3)), one shot
    a slab. Measured: displacement history 300 mm from the centre on the underside; peak,
    rebound and residual deflection; damaged areas on both faces and the diameter of any hole.
    No pressure gauges. **Gives:** nearly everything, and pairs one layer against two at the
    same charge; the holes test the breach the model never makes (limitations 4 and 8). The
    concrete's 47.0 MPa is the mean of six 150 mm cubes, not cylinders; and the paper prints
    the two layers 600 mm apart in a slab 100 mm thick, a misprint, so their depths are to be
    read from its drawings.
  - W. Wang et al., "Blast resistance of reinforced concrete slabs based on residual
    load-bearing capacity", *Materials* 15(18), 6449 (2022), doi:10.3390/ma15186449,
    [PMC9502281](https://pmc.ncbi.nlm.nih.gov/articles/PMC9502281/), CC BY 4.0. Two slabs
    1,200 × 500 × 100 mm, fixed on four sides, steel in both faces both ways (12 mm and 8 mm
    bars), concrete C30 by grade only; one shot of a 10 kg sphere of TNT, RDX and aluminium,
    1.2 m from both slabs at 0.7 m above the ground. Four reflected pressure gauges and five
    displacement gauges a slab; peaks 19.8 and 14.1 mm. **Gives:** an open-air shot with the
    load and the response measured together (item 2); against it, an aluminised charge whose
    TNT equivalence is uncertain, nominal materials, and a cover printed as 50 mm in a slab
    100 mm thick, to be read from its Figure 1.
  - J. Yao, S. Li, P. Zhang, S. Deng and G. Zhou, "Dynamic response and damage
    characteristics of large reinforced concrete slabs under explosion", *Applied Sciences*
    13(23), 12552 (2023), doi:10.3390/app132312552, CC BY 4.0: by search summaries a slab
    4 × 5 m and 150 mm thick under 0.5 to 1 kg of TNT, with PVDF pressure gauges, displacement
    and acceleration. MDPI refused automated access; needs the user to obtain. Possibly several
    shots on one slab.
  - R. Castedo, P. Segarra, A. Alañón, L. M. Lopez, A. P. Santos and J. A. Sanchidrián, "Air
    blast resistance of full-scale slabs with different compositions: numerical modeling and
    field validation", *International Journal of Impact Engineering* 86 (2015) 145–156,
    doi:10.1016/j.ijimpeng.2015.08.004: seven full-scale slabs at 0.20 to 0.79
    m/kg^(1/3), apparently one shot each. Paywalled; needs the user to obtain.
  - The University of Ottawa's shock-tube theses (Jacques 2011; Melançon 2016,
    [10393/34102](https://ruor.uottawa.ca/handle/10393/34102), 43 MB) shoot each specimen
    repeatedly at rising pressures: only a first, nearly elastic shot would be usable.
- **Not searched** (allowance spent): Schenker et al. 2008, Yao et al. 2016, Zhao and Chen
  2013, Silva and Lu 2007, DesignSafe.

## 2. A test that couples air and structure

- **Where:** any open publication that reports charge mass, stand-off, wall or slab details,
  and measured deflection together. Candidates: A. Schenker et al., "Full-scale field tests of
  concrete slabs subjected to blast loads", *International Journal of Impact Engineering* 35
  (2008); and W. Wang et al., "Experimental study and numerical simulation of the damage mode
  of a square reinforced concrete slab under close-in explosion", *Engineering Failure Analysis*
  27 (2013).
- **Needed:** the specimen geometry, reinforcement and material strengths, the support
  conditions, the charge mass, shape and position, and the measured deflection or damage.
- **Use:** an end-to-end test of both solvers together under an open-air charge. The internal
  explosion of Shang et al. (2026), now obtained, is one such test (see
  [Validation](validation.md#an-internal-explosion-in-a-reinforced-concrete-chamber)); an
  open-air one would separate the structure's error from the gas phase's.
- **Found, 10 October 2026:** Wang et al. (2022) and Wu et al. (2023), both open; see
  [1a](#1a-a-slab-with-steel-in-both-faces-under-an-open-air-charge). Wang's records pressure
  and deflection from the same open-air shot. Schenker et al. (2008) and Wang et al. (2013)
  were not searched again.
- **Also needed, for the chamber test:** the size and spacing of the diagonal bars across the
  chamfers, and how far the bars of the roof and walls are anchored into the end walls. The
  paper says only that diagonal bars were "arranged along the chamfered surfaces". The model
  leaves them out, and the joints decide whether its roof holds.

## 2b. A freestanding wall under an open-air charge

- **Where:** a field test of a wall standing on its own footing, not held at its top. Found
  (2026-10-08) but not readable here, behind the publishers' bot checks: "Experimental and
  numerical study on protective effect of RC blast wall against air shock wave", *Defence
  Technology* (2022, open access, ScienceDirect S2214914722002434), which measured the reflected
  pressure on a reinforced concrete blast wall and the diffracted pressure behind it from TNT
  3 m away; the cantilever-wall tests of Keys and Clubley, and of Ahmad et al., on the
  pressures behind a cantilever blast wall; and the scaled masonry walls of M. Hayman's thesis
  (McMaster University), which were held in frames rather than freestanding.
- **Needed:** the wall's section, reinforcement and footing; the charge and its position; the
  pressures in front of and behind the wall; and its deflection or rotation, peak and left.
- **Use:** the coupled wall study (`blastbench anchorage --air`) found that the wave wrapping
  over and round a freestanding wall, loading its back face, cuts its sway to a third of a
  pulse on its face alone (see [base connections](structural-model.md#base-connections)).
  Pressures behind a wall would check that; a deflection record would check its base too.
- **Searched, 10 October 2026:**
  - The *Defence Technology* paper is X. Nian, Q. Xie, X. Kong, Y. Yao and K. Huang,
    *Defence Technology* 31 (2024) 567–579, doi:10.1016/j.dt.2022.11.005, CC BY-NC-ND 4.0:
    5 and 20 kg of TNT, with pressures in front of and behind the wall. No host outside
    ScienceDirect was found (the journal's KeAi page points there, DOAJ refused); needs the
    user to obtain. Whether it measured the wall's response is not known.
  - F. C. F. Alsubaei, *Performance of protective perimeter walls subjected to explosions in
    reducing the blast resultants on buildings*, Master's thesis, Western University, 2015,
    [hdl:20.500.14721/35930](https://hdl.handle.net/20.500.14721/35930): open, one PDF of
    8.42 MB, terms not stated. Half-scale and full-scale field blasts on plain and canopied
    concrete walls and grouted masonry walls, with the blast measured on a building behind them
    and the walls' damage assessed. Not known: the walls' footing, deflection records, and
    whether walls were shot more than once.
  - A. S. Mazlan, S. M. Syed Mohsin, A. M. A. Zaidi, M. F. S. Koslan and Z. M. Jaini,
    "Experimental of inverted-T shape RC wall subjected to blast load" (Trans Tech
    Publications, 2021), [UMPSA eprint 30661](http://umpir.ump.edu.my/id/eprint/30661/): a
    full-scale cantilever wall on its own base under 13.61 kg of TNT at 1.21 m, by search
    summaries; the only freestanding wall on a footing found. The repository refused the
    connection; needs the user to obtain. What was measured is not known.
  - M. Hayman, *Response of one-way reinforced masonry flexural walls under blast loading*,
    MASc thesis, McMaster University, 2014 (MacSphere 11375/16312), six scaled walls under 5
    to 25 kg at 5 m with reflected and free-field pressures and displacement histories, the
    charges apparently rising on each wall; and M. ElSayed's McMaster thesis (11375/16041),
    twelve third-scale grouted masonry walls under free-field blasts. MacSphere refused
    automated access; needs the user to obtain.
  - Y. Hao et al., *International Journal of Structural Stability and Dynamics* 17(9),
    1750099 (2017), doi:10.1142/S0219455417500997: a fence-type wall against a masonry one under
    1 kg of TNT, pressures behind only. Paywalled.
  - Keys's masonry panels are under [3c](#3c-collapse-and-debris). Fan Jin's Ottawa thesis
    (several shots a wall) stays set aside.

## 2a. Shear across cracks at high rates

- **Where:** any test of shear across a crack (push-off specimens) loaded quickly, or a
  programme of beams without stirrups struck at several drop heights, so that the one at which
  they first break in shear is known.
- **Needed:** how aggregate interlock grows with loading rate. The model raises it with the
  tensile strength's rate factor; under the fib Model Code's tensile law that is about 1.3 at
  Saatci's rates, and the beam without stirrups, SS0a-1, breaks under a drop it survived; with
  interlock doubled it survives (see
  [Validation](validation.md#beams-struck-by-a-falling-weight)).
- **Use:** the rate law for interlock, in place of borrowing the tensile one.
- **Partly answered:** Ando et al. (2000; see Obtained) struck beams without stirrups at
  increasing speeds; with interlock as it is the model follows them to 3 m/s, and breaks the
  heavily reinforced 1.5 m beam at the speed the test did; beyond 3 m/s how the ends were held
  matters more than interlock.
- **Searched, 10 October 2026.** No open test of shear across an existing crack at impact
  rates, with crack width, slip and shear stress against time, was found. The nearest:
  - J. M. Louw, B. C. Koch and E. Koen, "Direct shear strength of concrete under impact",
    *WIT Transactions on the Built Environment* 8 (SUSI 94), doi:10.2495/SU940171,
    [WIT eLibrary](https://www.witpress.com/elibrary/wit-transactions-on-the-built-environment/8/11946),
    open, PDF 579 KB. Push-off specimens struck, 38 plain and 29 with bars across the plane, at
    several strengths and preloads; by its abstract the plane's rate factor exceeded the
    CEB-FIP 1990 factors for tension and compression. The plane was uncracked, so this is not
    interlock proper, but it is the nearest measured rate factor for shear across a plane,
    against borrowing the tensile one. Koch's Stellenbosch thesis (1992,
    hdl:10019.1/69765) is not digitised.
  - Bond at high rates, for bars that slip: H. W. Reinhardt, "Concrete under impact loading,
    tensile strength and bond", *HERON* 27(3) (1982),
    [TU Delft](https://resolver.tudelft.nl/uuid:f1b74b6e-670b-4ee3-ae60-ddd810cdd984), free to
    read, not to be redistributed without consent, 3.56 MB; E. Vos's thesis (TU Delft, 1983,
    [uuid:29419e9e](https://resolver.tudelft.nl/uuid:29419e9e-9b56-41a5-94cb-d363b1c8c15e),
    64.5 MB, same terms); P. Máca's thesis (CTU Prague and TU Dresden, 2017, CC BY-NC-ND) and
    P. Máca et al., "Beam-end bond testing in split Hopkinson bar under high slip rates", 5th
    Bond in Concrete conference (2022), doi:10.18419/opus-12271, open, 0.98 MB, which found
    bond rising by at most about 30% up to 10 m/s of slip; A. Michel et al., *EPJ Web of
    Conferences* 94, 01044 (2015), doi:10.1051/epjconf/20159401044, pull-out at rate; and
    E. Jacques, *Characteristics of reinforced concrete bond at high strain rates*, MASc thesis,
    University of Ottawa, 2016, doi:10.20381/ruor-4941, 41 MB, terms not stated, beam-end and
    lap-splice specimens in a shock tube. These bear on the bond law under impact, not on
    interlock.
  - Programmes of beams struck at rising speeds, to bracket the drop that breaks them in
    shear: Y. Zhao, W. Yi and S. K. Kunnath, "Shear mechanisms in reinforced concrete beams
    under impact loading", *Journal of Structural Engineering* 143(9) (2017),
    doi:10.1061/(ASCE)ST.1943-541X.0001818, impact and reaction forces, deflection and video
    over a range of masses and speeds; and Kishi, Mikami et al.'s companion to Ando et al.
    (about 2002, *International Journal of Impact Engineering*, citation not checked). Both need
    the user to obtain.
  - Direct shear at high rates in slabs: C. A. Ross and H. Krawinkler, "Impulsive direct
    shear failure in RC slabs", *Journal of Structural Engineering* 111(8) (1985) 1661–1677,
    and Kiger and Slawson's one-way slabs (1984). Need the user to obtain.

## 2c. Saatci's records

- **Where:** the digital records of Saatci and Vecchio's drop-weight tests, which their paper
  (ACI Structural Journal 106(1), 2009) says the University of Toronto's VecTor Analysis Group
  publishes.
- **Needed:** the impact force against time for each first impact (from the weight's
  accelerometers), and how the 50 mm plate sat on the beam.
- **Use:** the paper gives one peak, 1,421 kN for SS3a-1 under the light drop; the model's
  weight, striking the plate's top nodes outright, delivers about 3,200 kN, and a pad matched to
  the measured peak changes the beams (see
  [Validation](validation.md#beams-struck-by-a-falling-weight)). The heavy drops' forces, and
  the shape of the pulse, would say what the contact should be.
- **Checked, 10 October 2026:** the VecTor Analysis Group's site
  ([recent projects](http://www.vectoranalysisgroup.com/recentProjects.html)) links Saatci's
  thesis and papers but no data; its only data file is Hrynyk's (see
  [2d](#2d-interlock-and-tension-stiffening-under-impact)). Saatci's old project page at IYTE
  returns 404. The records would have to be asked of the group or of Saatci; needs the user.

## 2d. Interlock and tension stiffening under impact

- **Needed:** a measured case under impact that separates what cracks carry in shear and what
  the concrete between cracks carries in tension. Traced by mechanism, the contest slab's excess
  stiffness lies in tension stiffening, and the beams without stirrups turn on interlock at
  impact rates (see [Validation](validation.md#its-cracks) and 2a).
- **Found, 10 October 2026:**
  - V. Peterson, "Dataset of high-speed camera measurements from impact-tested reinforced
    concrete beams", *Data in Brief* 65, 112487 (2026), doi:10.1016/j.dib.2026.112487
    (PMC12870799); the data, V. Peterson, *High-speed camera dataset from impact tests on
    reinforced concrete beams*, Mendeley Data, doi:10.17632/kn28g6dbj5.3, CC BY 4.0, size not
    stated (high-speed images, so probably large); with V. Peterson, J. Magnusson, M. Hallgren
    and A. Ansell, "Shear-type failure of deep, short and slender impact-loaded RC beams",
    *International Journal of Impact Engineering* 208, 105539 (2026),
    doi:10.1016/j.ijimpeng.2025.105539, and Peterson's KTH thesis (2026,
    [DiVA 2029364](https://kth.diva-portal.org/smash/record.jsf?pid=diva2:2029364), open,
    18 MB). By the landing pages and summaries: eighteen beams 0.80 m long and 150 × 150 mm,
    concrete about 44 MPa, shear spans of 0.4, 1 and 2 depths, no stirrups or stirrups at 90
    or 45 mm, struck by 70 kg dropped 2.4 m; reactions from load cells, accelerations, and raw
    images at 6 kHz for digital image correlation. **Gives:** everything for a beam comparison,
    and from the images the opening and slip of the shear cracks against time; one drop height
    only, so no threshold.
  - T. D. Hrynyk, *Behaviour and modelling of reinforced concrete slabs and shells under
    static and dynamic loads*, PhD thesis, University of Toronto, 2013,
    [TSpace 1807/35851](https://utoronto.scholaris.ca/handle/1807/35851), CC BY 2.5 Canada,
    36.4 MB; and its "Slab Digital Data", a ZIP on the
    [VecTor site](http://www.vectoranalysisgroup.com/recentProjects.html)
    (`theses/Hrynyk/Experimental Data.zip`), size and terms not stated. Eight slabs of
    intermediate size, plain and fibre-reinforced, struck repeatedly by a heavy weight until
    they failed, with unfiltered records. **Gives:** slabs under impact with and without
    fibres, which share the tension between cracks differently; only each slab's first impact
    is on a new specimen.

## 3. Formulae quoted from memory

Ten values in the code were written from memory and should be checked against the original.

- **A rigid footing's static stiffness and Wolf's cones.** G. Gazetas, "Formulas and charts for
  impedances of surface and embedded foundations", *Journal of Geotechnical Engineering* 117(9)
  (1991) 1363–1381, Table 1 for surface foundations; J. P. Wolf, *Foundation Vibration
  Analysis Using Simple Physical Models* (Prentice Hall, 1994), for the cones' apex heights,
  trapped masses, the rocking cone's internal mass and the echoes of a layer; and E. Kausel's
  stratum factors (as quoted by Gazetas), used for rocking over a layer. Used in
  `FootingImpedance`; the vertical and horizontal stiffness of a square agree with the rigid
  disk's within 1% and its rocking within 9%, which checks the memory a little.
- **Embedded footings' stiffness.** The same paper's Table 2 (and G. Mylonakis, S. Nikolaou and
  G. Gazetas, *Soil Dynamics and Earthquake Engineering* 26 (2006), Table 1): the trench and
  sidewall factors for vertical and horizontal stiffness, the rocking factors, and which side
  of the footing his horizontal factors' (h A_w / B L²) and (h A_w / L B²) belong to. Used in
  `Embedment.gazetasFactors`. And a measured embedded footing: TRISEE's (1 g, embedded on
  Gabbia sand; whether FoRCy or FoRDy holds them is open, see 3b).

- **The bond of masonry to concrete** (0.2 MPa in tension, 10 J/m² of fracture energy; any
  study of masonry–frame interfaces, for example P. B. Lourenço's thesis, Delft, 1996) and
  **annealed glass** (45 MPa breaking stress, toughness 0.75 MPa m^(1/2); ASTM E1300 or a
  glass handbook).
- **Mortar joints.** P. B. Lourenço and J. G. Rots, "Multisurface interface model for analysis
  of masonry structures", *Journal of Engineering Mechanics* 123(7) (1997) 660–668, and R. van
  der Pluijm's tests behind it. Needed: the joints' tensile strength and mode I energy (taken
  as 0.25 MPa and 18 J/m²), cohesion, friction and mode II energy (0.35 MPa, 0.75, 125 J/m²),
  and the bricks' tensile strength and energy (2 MPa, 80 J/m²), used in `MasonryUnits.brick`;
  the values for hollow concrete blockwork are scaled from these and from Eurocode 6, and a
  source for them would be better. And any blast or shock-tube test of an unreinforced
  masonry wall with its deflection history, to check the joint model at all.
- **The Holmquist–Johnson–Cook compaction curve.** T. J. Holmquist, G. R. Johnson and
  W. H. Cook, 14th International Symposium on Ballistics, 1993. Needed: the locking pressure
  and strain and the constants K₁, K₂, K₃ (taken as 0.8 GPa, 0.1, and 85, −171, 208 GPa), used
  in `compactionPressure` in `Structure.metal`. A close-in or contact-charge test on a concrete
  slab would then check it.
- **Lighthill's dissociation constants** (θ<sub>d</sub> 113,000 and 59,500 K, ρ<sub>d</sub> 130
  and 150 g/cm³, from Vincenti and Kruger's *Introduction to Physical Gas Dynamics*), used for
  dissociating air in `Solver.metal`; any text on statistical thermodynamics, or the NIST-JANAF
  tables, to check them. (The vibrational temperatures of N2 and O2 used for hot air, 3390 K
  and 2270 K, are checked: a table of diatomic properties from Georgia Tech's AE 6765 gives
  3393 K and 2274 K.)

- **Dowel strength.** B. H. Rasmussen, "The carrying capacity of transversely loaded bolts and
  dowels embedded in concrete", *Bygningsstatiske Meddelelser* 34 (1963), or fib Model Code
  2010, section 6.1. Needed: the dowel capacity of a bar crossing a crack, used as
  1.3 d² √(f_c f_y) in the shear across cracks in `Structure.metal`, and the slip at which it
  is reached.

- **Fracture energy at high strain rates.** M. Schuler, C. Mayrhofer and K. Thoma, "Spall
  experiments for the measurement of the tensile strength and fracture energy of concrete at
  high strain rates", *International Journal of Impact Engineering* 32 (2006); J. Weerheijm and
  J. C. A. M. van Doormaal, "Tensile failure of concrete at high loading rates", same journal,
  34 (2007). Needed: how the fracture energy grows with strain rate beside the tensile
  strength, taken as about twice static where the strength is five times
  (`fractureRateExponent` 0.5).

- **The fib Model Code 2010's tensile rate law** (section 5.1.11.1), now the default: taken as
  (ε̇ / 10⁻⁶)^0.018 to 10 per second and 0.0062 (ε̇ / 10⁻⁶)^(1/3) above, for every strength.
  Needed: the law as printed, and whether the code gives one for fracture energy.

- **Crack dilatancy.** How far a crack opens as it slides, taken as half the slip
  (`crackDilatancy` 0.5). Walraven and Reinhardt's average crack opening paths (*HERON* 26(1A),
  1981, Fig. 10; see Obtained) open by about 0.75 to 0.9 of the slip at 2 mm in concretes of
  20 to 38 N/mm², and about 0.3 in one of 56 N/mm², but their cracks were held shut by bars
  across them, so the free crack's path is still wanted. The 0.5 has been left, since the
  beams struck by a falling weight were checked with it.

- **Karsan–Jirsa unloading.** I. D. Karsan and J. O. Jirsa, "Behavior of concrete under
  compressive loadings", *Journal of the Structural Division*, ASCE 95(ST12) (1969) 2543–2563.
  Needed: the relation between the envelope strain reached and the permanent strain left on
  unloading, as used in `concreteCompression` in `Structure.metal`.

## 3a. Air-induced ground shock

- **Where:** *Structures to Resist the Effects of Accidental Explosions*, UFC 3-340-02 (2008),
  chapter 2; *Fundamentals of Protective Design for Conventional Weapons*, TM 5-855-1 (1986);
  N. M. Newmark and J. D. Haltiwanger, *Air Force Design Manual*, AFSWC-TDR-62-138 (1962), DTIC
  AD0295408. DTIC refused automated access, and the copy of UFC 3-340-02 reached held only its
  front matter.
- **Needed:** the relations as printed: the vertical particle velocity and displacement under
  an air-blast load, the attenuation of the peak with depth and the length it uses, the
  horizontal motion in the superseismic case, and the soils' loading wave speeds and densities
  tabulated for use with them.
- **Also needed:** any measurement of air-induced ground motion under a surface burst of high
  explosive, with the overpressure on the ground recorded beside a velocity gauge at or just
  below the surface.
- **Needed for the layered column** (`SoilColumn.swift`): for each shot, the charge; the
  overpressure history on the ground beside each gauge; velocity or acceleration histories at
  known depths below it; and the site's profile: each layer's thickness, density and seismic
  compression wave speed, its loading and unloading moduli from uniaxial-strain tests if
  possible, and the depth of the water table. Prairie Flat with the Watching Hill soil data,
  and Middle Gust's wet and dry sites (below), come closest. The HEST tests (High Explosive
  Simulation Technique, the air blast simulated over a site) and Misers Bluff are still to be
  looked for. Nothing has been downloaded.
- **Use:** to check `GroundShock.swift`, `SoilColumn.swift` and [Ground shock](ground-shock.md),
  whose relations were re-derived rather than taken from the page.
- **Searched for measurements, 10 October 2026.** A comparison needs the overpressure on the
  ground beside velocity or acceleration gauges at and below the surface, at known ranges, and
  the soil's layers. No open, machine-readable set has all three. The best are the reports of
  the Army's Waterways Experiment Station (WES) on the large HE shots of 1966–76, several
  cleared for unlimited release, on the ERDC library behind a browser check or on DTIC; all
  need the user to obtain:
  - **Prairie Flat**, 500 short tons of TNT, a sphere resting on the ground, Suffield, 1968:
    WES TR N-72-2, earth motion and stress measurements
    ([ERDC 11681/6813](https://erdc-library.erdc.dren.mil/jspui/handle/11681/6813)).
    Accelerometers, velocity gauges and soil stress gauges from 84 to 1,150 ft, at 1.5 to 30 ft
    deep; the ground motion outran the air blast beyond about 560 ft. Both sides of the
    superseismic limit on one shot.
  - **The Watching Hill soil data**, the site of Prairie Flat, Dial Pack and Distant Plain:
    soil tests for the DNA's HE events of 1967–71, probably DTIC AD0741773 (title not
    confirmed). Glacial till and lake deposits under thin silts, sands and clays, with water
    near the surface. The layered column the gauge reports need.
  - **Pre-Dice Throw II**, White Sands, 1976: a 100-ton TNT sphere on the ground and a 120-ton
    ANFO charge on one site, with the ground motion measured and compared with the predictions
    four agencies made before the shots (DTIC ADA048003); the USGS's report on the site's
    motion, OFR 77-143, doi:10.3133/ofr77143, is open, 2.2 MB. A blind benchmark ready made.
  - **Dial Pack**, 500 tons, Suffield, 1970: WES TR N-73-4, gauges at 645 and 840 ft at 1.5 to
    20 ft deep; nearly a repeat of Prairie Flat where the ground motion outruns the blast.
  - **Distant Plain**, Suffield, 1966–67: J. K. Ingram, WES TR N-71-3, five events in the top
    10 ft of the same soil, which gives scatter (the ERDC handle found, 11681/6790, may hold a
    different report; to be checked).
  - **Mixed Company and Middle Gust**: L. F. Ingram, *Ground motions from high-explosive
    experiments*, WES Misc. Paper N-72-10, 1972 (ERDC 11681/6809); Middle Gust had a wet and a
    dry site with their soils' profiles, the only pair found that tests a water table.
  - DNA's master file of ground-shock, air-blast and structure-response data (DTIC ADA020939)
    indexes the rest. Misers Bluff, Minor Scale, Misty Picture, Direct Course, Snowball,
    Sailor Hat and the 1961 Suffield shot were not searched (allowance spent).
- **Open, but weaker:**
  - Humble Redwood III (New Mexico, 2012): 91 kg of TNT 2 m above the ground, on IRIS as
    network 8H (geophones) and 2D_2012 (infrasound, doi:10.7914/SN/2D_2012); far field only, no
    overpressure near the charge or soil column. Analysed by Ford et al., *BSSA* 104(2) (2014)
    608–623.
  - The Large Surface Explosion Coupling Experiment, Nevada, 2020: two surface shots of about
    1 t of C-4, the second in the first's crater, FDSN network 5A, doi:10.7914/1p2e-0167; no
    public metadata found, so possibly not yet released.
  - V. Novoselov, F. Fuchs and G. Bokelmann, *Geophysical Journal International* 223 (2020)
    144–160, doi:10.1093/gji/ggaa304, CC BY, data on EIDA (network 6A) and code open:
    firecrackers and rockets recorded by microphones beside three-component sensors tens of
    metres away, on a site of measured wave speed. The linear, outrunning end only.
  - Two Chinese open papers: Xia et al., *Applied Sciences* 12(16), 7987 (2022),
    doi:10.3390/app12167987, CC BY, ground shock from 1 and 10 t surface shots against
    UFC 3-340-01 (MDPI refused automated access; the soil and overpressure not seen); and Wang,
    Kong and Shang, *Frontiers in Physics* (2023), doi:10.3389/fphy.2023.1114871, CC BY, 300 and
    500 kg 1.5 m above sandy soil, reflected pressure and ground velocity measured together at
    3.5 to 9 m with peaks tabulated, but no layers and a density that reads as the grains'.
  - Small-scale tests of sand in shock tubes (an IIT Delhi thesis, 2024; IISc eprints 81527 and
    59155; DTIC AD0818668, a vertical shock tube over a bin of Ottawa sand) would check
    v = p/(ρc) and its fall with depth under a controlled pulse. Need the user to obtain.

## 3b. A footing or connection under fast loading

- **Needed:** beyond FoRCy's slow rocking (see Obtained), a footing under dynamic or
  blast-like loading with its settlement measured, since the model settles a tenth as much as
  SSG02_03; and a wall–foundation joint, starter bars, dowels or anchors under fast loading with
  slip or rotation measured, for `Anchorage`.
- **Found, 10 October 2026:**
  - **FoRDy**: B. L. Kutter, A. G. Gavras, I. Anastasopoulos, L. Deng, S. Gajan, A. Tsatsis,
    K. Sharma, T. Kouno, M. Hakhamaneshi, G. Gazetas and K. Athipotta Variam, *FoRDy: Rocking
    shallow foundation performance in dynamic experiments*, 2019, doi:10.13019/3rqyd929,
    [DataCenterHub landing page](https://datacenterhub.org/landingpages/529/529_LandingPage.html),
    CC BY-NC-SA 4.0 there; the DOI now resolves to DesignSafe PRJ-3836, where its publication
    record gives the Open Data Commons Attribution License, as for FoRCy, which is the copy to
    use (809 files, 2.34 GB). Described in A. G. Gavras et al., *Earthquake
    Spectra* 36(2) (2020) 960–982, doi:10.1177/8755293019891727. Five centrifuge and three 1 g
    shaking-table series (UC Davis, NTUA, PWRI): 13 structures, 18 soil profiles, over 50
    ground motions, 200 events, each as tab-delimited time series with baseline-corrected
    motions and spectra; drift, rotation, sliding, settlement and the footing's loads. Size not
    stated. **Gives:** settlement under shaking on the same family of sands as SSG02_03, with
    sequences of motions on one model.
  - PWRI's 1 g footings on Toyoura sand (Shirato, Paolucci et al., *EESD* 2008,
    doi:10.1002/eqe.773) are in FoRCy and probably FoRDy already; they add the contact pressure
    under an uplifting footing. Whether TRISEE's embedded footings (ELSA, Ispra) are in FoRCy is
    to be checked in its mastersheet.
  - M. Arabpanahan, S. R. Mirghaderi and A. Ghalandarzadeh, *Dataset on the shake table
    experiments of embedded foundations subjected to increasing and decreasing sequential
    harmonic waves*, Mendeley Data (2023), doi:10.17632/yv98vfc9wv.1, CC BY 4.0, size not
    stated; with *Soil Dynamics and Earthquake Engineering* 140 (2021) 106431. Embedded
    footings, which SSG02_03 is not; what was recorded is to be read from the files.
  - G. Antonellis et al., *Journal of Geotechnical and Geoenvironmental Engineering* (2015),
    doi:10.1061/(ASCE)GT.1943-5606.0001284, rocking bridge columns at a third of full size on
    footings in sand, NEES at UC San Diego; open in Caltrans report CA15-2287 (two PDFs on
    dot.ca.gov, sizes not stated). Settlement small, so a weak test of the gap.
  - Connections: N. Yong, N. Lam, S. Menegon and E. Gad, *Journal of Structural Engineering*
    (2020), doi:10.1061/(ASCE)ST.1943-541X.0002578, a cantilever wall 1.5 × 3 × 0.23 m fixed
    at its base, struck by pendulums of 280 and 435 kg (a copy on the University of Melbourne's
    Minerva Access; whether the base's rotation was measured is not known); the ETH Zürich
    dataset *Cyclic tests on real-scale squat RC shear walls* (Pizarro Pohl, Kovarbašić and
    Stojadinović; *Journal of Structural Engineering* 2025), two of whose four walls slid at the
    base, slowly (the Research Collection returned errors; needs the user to obtain); and
    Oesterle and Reese's walls under internal blast at Tyndall AFB, comparing joint details
    (NDIA paper, `ndia.dtic.mil/wp-content/uploads/2018/intexpsafety/OesterleReesePaper.pdf`,
    not opened). Solomos and Berra's anchors pulled in a Hopkinson bar (JRC34065, 2006) are
    visible only inside the Commission.
  - Footings under blast-like pulses: the WES reports of the 1960s on the dynamic bearing
    capacity of soils (Poplin 1967, small footings on dense dry sand; Jackson and Hadala 1964;
    DTIC AD0654712, AD0680905 and AD0685825, with a 1 ft footing under pulses rising in 4 and
    20 ms). Probably cleared for release, with tabulated load and settlement; DTIC, ERDC and
    HathiTrust refused automated access; need the user to obtain.
- **Not found:** any open record of a wall–foundation joint's slip or rotation under blast or
  impact, or a dowel or shear-friction test at high rates with load and slip.

## 3c. Collapse and debris

- **Needed:** any measurement of collapse or debris under blast (limitation 5: none so far):
  the structure's geometry, steel and materials; the charge and its position; where the debris
  landed, its masses and, ideally, its launch velocities; and repeats or scatter. A small,
  well-documented test is worth more than a large one vaguely described.
- **Found, 10 October 2026.** No open dataset of debris positions and masses from a documented
  reinforced concrete or masonry structure; none on DesignSafe, Zenodo or figshare. Ranked:
  - M. Hupfauf and N. Gebbeken, "Secondary debris resulting from concrete slabs subjected to
    contact detonations", *Advances in Structural Engineering* 25(7) (2022) 1373–1385,
    doi:10.1177/13694332221080614, [athene 141205](https://athene-forschung.unibw.de/141205),
    CC BY 4.0; and M. A. Hupfauf, *Secondary debris resulting from concrete slabs subjected
    to contact detonations*, PhD thesis, Universität der Bundeswehr München, 2024,
    [athene 149703](https://athene-forschung.unibw.de/149703), open, 260 pages, size not
    stated. By search summaries, fifteen slabs of scaled thickness 1.6 to 2.8 cm/g^(1/3); high-speed
    video of the far face gives the debris's velocities, scans the spall crater and the mass
    thrown; the thesis varies thickness, steel fibres and charge. **Gives:** the debris's speed
    and mass off a slab, and its spall, open and documented; close in, not collapse. **Used**
    2026-10-10: fifteen slabs in `Fixtures/Hupfauf`, six run by `blastbench contact` (see
    [Validation](validation.md#slabs-under-contact-charges)).
  - J. Schneider, M. von Ramin, A. Stottmeister and A. Stolz, "Masonry failure and debris
    throw characteristics under dynamic blast loads", *Chemical Engineering Transactions* 77
    (2019) 217–222, doi:10.3303/CET1977037,
    [CET](https://www.cetjournal.it/index.php/cet/article/view/CET1977037), open (AIDIC),
    licence and size not stated. Masonry walls in a shock tube, with stereo high-speed video
    giving fragments' paths, velocities, launch angles and masses. **Gives:** launch velocities
    of masonry debris under a known load, the push the model's loose nodes feel; six pages may
    not describe the walls fully.
  - R. Keys and S. K. Clubley, "Experimental analysis of debris distribution of masonry panels
    subjected to long duration blast loading", *Engineering Structures* 130 (2017) 229–241,
    doi:10.1016/j.engstruct.2016.10.054 (accepted versions at Southampton, eprint 381618, and
    Loughborough); and R. Keys, PhD thesis, University of Southampton, 2016 (eprint 413951):
    ten masonry panels at about 55 and 110 kPa for 150 to 200 ms, all destroyed, their debris
    mapped; the thesis adds 22 structures in five trials, two of nine small masonry buildings
    under 41 kg TNT equivalent. Both repositories refused automated access; needs the user to
    obtain. **Gives:** debris on the ground from walls broken by drag-dominated loading, with
    several panels a trial.
  - Kasun-III, KLOTZ Group, Norway and Sweden, 2008: five internal shots in reinforced concrete
    cubes 2 m inside, one to sixteen 155 mm shells or 6.9 and 110 kg of bare explosive, with
    over 21,500 pieces of concrete, steel and casing logged by mass and position, and external
    pressures. Described in DDESB Explosives Safety Seminar papers of 2010 (DTIC ADA532249,
    title not confirmed); M. M. van der Voort and J. Weerheijm, "A statistical description of
    explosion produced debris dispersion", *International Journal of Impact Engineering* 59
    (2013) 29–37, paywalled. The database itself would have to be asked of KLOTZ or TNO. Needs
    the user to obtain. **Gives:** the best debris benchmark known, a series in charge mass.
  - S. Saburi, S. Kubota, K. Katoh and Y. Ogata, "Experimental studies on debris hazards from
    explosions in subsurface magazines", *Science and Technology of Energetic Materials* 74(3)
    (2013) 53–60, [JES](https://jes.or.jp/mag_eng/stem/Vol.74/No.3.01.html), open: scale
    models of buried magazines under C-4, every piece over 20 g mapped. Earth-covered, so soil
    rather than free break-up.
  - H. S. Lim and J. Weerheijm, "Break-up of concrete structures under internal explosion",
    FraMCoS-6 (2007), [framcos.org](https://framcos.org/paper/break-up-of-concrete-structures-under-internal-explosion/),
    open, 998 KB: clamped slabs under internal blast seen by flash X-ray and video; the
    mechanism and launch speed, probably no map. Its sequel by Fan, Yu, Yang, Lim and Kang
    (DDESB 2010, DTIC ADA532261) needs the user to obtain.
  - Y. Fan, L. Chen, H. Xiang, Q. Fang and F. Han, *Defence Technology* (2023): launch
    angles and speeds of spall from ultra-high-performance concrete slabs under partly embedded
    charges, by search summaries only (DOAJ refused).
  - S. C. Woodson and J. T. Baylot, *Structural collapse: quarter-scale model experiments*,
    ERDC, 1999 (DTIC ADA369355, cleared for public release): blast collapse of quarter-scale
    frames, probably the modes rather than debris. Needs the user to obtain.
  - DDESB TP-21, on collecting and analysing debris
    (`denix.osd.mil/ddes/denix-files/sites/32/2018/02/TP-21-Revision-22c-171130-final.pdf`, not
    opened): no data, but the metrics a comparison would use. TP-13, TP-16, the hardened
    aircraft shelter tests, ESKIMO and the Älvdalen magazine tests were not found open.
- **Cased charges' fragments** ([fragments](fragments.md), never compared with a test): no
  open arena test pairing fragment masses with velocities and directions was found. Open mass
  distributions: L. de Vuyst et al., "A study of the effect of aspect ratio on fragmentation of
  explosively driven cylinders", *Procedia Engineering* (HVIS 2017) 194–201,
  doi:10.1016/j.proeng.2017.09.773, CC BY-NC-ND, 1.48 MB, steel cylinders recovered in water;
  and Wilson, Reedal, Kipp, Martinez and Grady, SAND2000-1406C (OSTI 756417,
  [UNT](https://digital.library.unt.edu/ark:/67531/metadc702231/), 8 pages, open).

## 3d. An HE cloud's growth after two minutes

- **Needed:** the cloud's top, and its width, from two minutes to ten or thirty after an HE
  detonation, with the sounding. The model follows Church's tops within 4% at two minutes but
  stops while his go on growing, 0.69 of them at five minutes, and its spread has never been
  checked (see [the cloud](fireball-rise.md#against-churchs-measured-clouds)).
- **Found, 10 October 2026.** No open source gives the top and the width beyond two minutes with
  a sounding, and none tabulates Church's temperature profiles. The leads:
  - A. Sharon, I. Halevy, D. Sattinger and I. Yaar, "Cloud rise model for radiological
    dispersal devices events", *Atmospheric Environment* 54 (2012) 603–610: the Israeli Green
    Field shots, 0.25 to 100 kg of TNT on the surface, cloud height against time fitted by mass,
    stability and wind. Paywalled; needs the user to obtain. Below Church's charges, and split by
    stability.
  - L. S. Erhardt, D. Quayle and S. Noel, *Completion report for CRTI 07-0103RD: full-scale RDD
    experiments and models*, DRDC TR 2013-056,
    [publications.gc.ca](https://publications.gc.ca/site/eng/9.821120/publication.html), open,
    52 pages, 2.62 MB: three shots of 0.2 kg in 2012 watched by lidar and video, with balloons
    for the sounding; and S. J. Neuscamman, LLNL-TR-745534 (2018), doi:10.2172/1424634, open,
    a summary for modellers. Lidar gives the cloud's extent; the charge is tiny.
  - Sandia and DRDC Valcartier's lidar of debris plumes, Sandia's 9920 site, 2006: fifty shots
    of 1, 5 and 10 lb on six surfaces, followed for up to 7 minutes (Sandia Lab News, 26
    November 2006; SPIE 6367, 63670E, doi:10.1117/12.692452). No open data found; needs the
    user to obtain.
  - *Explosion and Shock Waves* (2019), doi:10.11883/bzycj-2017-0380,
    [bzycj.cn](https://www.bzycj.cn/en/article/doi/10.11883/bzycj-2017-0380), open: three groups
    of TNT shots, with the cloud's height growing about as t^½ and its width linearly at
    first. Masses, times and soundings not on the abstract page.
  - DNA's reports on the large ANFO shots, all on DTIC (needs the user to obtain, titles not
    confirmed): SRI's lidar of the Misers Bluff dust clouds (ADA112425, ADA089720), the Dice
    Throw symposium (ADA160565, ADA048799), Mill Race's dust densities (ADA134723), and
    Norment's DELFIC cloud-rise papers (ADA047372, ADA089187, ADA088367). ADA053465 and
    ADA083346 give clouds' diameters and heights to 10 minutes, possibly of nuclear clouds.
  - Single snapshots: A. S. Mason, D. L. Finnegan and R. C. Hagan, *Lofting of dust by very
    large explosions*, LA-11080-MS (1987), Minor Scale's cloud from 1.7 to 4.6 km; and P.
    Goldstein, *Beirut explosion yield and mushroom cloud height*, LLNL-TR-815803 (2020),
    doi:10.2172/1688581, a top of about 1,600 m from video. Both open.

## 3e. Fireball radiation

- **Needed:** measured heat flux and fluence at known distances from HE fireballs, the
  fireball's temperature and size against time, ideally from 0.1 to 1,000 kg with repeats.
  The model's volume radiates 21% of the charge's energy against 3.8–6.6% measured once, and
  the wrong way round in time, because its gas never cools (see
  [thermal radiation](thermal-radiation.md#the-volume-against-the-shape)).
- **Found, 10 October 2026:**
  - J. D. R. Pattman, *Operation Dial Pack 1970: Canadian project A7 thermal radiation
    measurements*, DREO Report 642 (1971),
    [publications.gc.ca](https://publications.gc.ca/site/eng/9.941855/publication.html), open,
    1.52 MB, 33 pages (downloaded): 500 tons of TNT measured by a high-speed bolometer, filtered
    photodetectors and calorimeters; the total energy radiated, the pulse's timing, the
    spectrum against time and the surface temperature, compared with earlier TNT shots.
    **Gives:** a second shot by the same group and methods as Tate and Pattmann, so a repeat of
    the radiated fraction and the pulse's shape, and through its comparisons perhaps
    Snowball's. **Compared** (10 October 2026), transcribed in Samples/DialPack1970: see
    [thermal radiation](thermal-radiation.md#against-dial-pack).
  - J. J. Rudolphi, N. Kolb and J. Stofleth, "Optical measurements in visible and NIR bands of
    composition C-4 and argon flash hemispheres", *Science and Technology of Energetic
    Materials* 81(1) (2020) 5–9, [JES](https://www.jes.or.jp/mag/stem/Vol.81/No.1.02.html), open:
    C-4 from 0.5 to 136.2 kg, photodiodes in eight bands from 325 to 1,200 nm, with radial
    surveys. A sweep in charge mass; no infrared, and whether calibrated histories are given
    is to be checked.
  - The Illinois group's laser-absorption thermometry inside fireballs (Glumac, Krier and
    others): 2.2 kg of C-4 with gas temperatures measured at 2.3 to 6.3 m over repeated shots,
    which a CFD code over-predicted (APS SCCM 2019, abstract R3.3); and Murzyn, Sims, Krier and
    Glumac, *Optics and Lasers in Engineering* 110 (2018) 186–192,
    doi:10.1016/j.optlaseng.2018.06.005. Paywalled; needs the user to obtain. Measured gas
    temperatures against time bear directly on the gas that never cools.
  - "Gauging the fireball: simulation and testing" (Southampton eprint 354397): 41 kg TNT
    equivalent with temperature, flux and pressure gauges inside the fireball. Refused
    automated access; needs the user to obtain.
  - P. Pei, H. Du and X. Hao, *ACS Omega* 8(32) (2023) 29717–29724,
    doi:10.1021/acsomega.3c03980 (PMC10433483): a 30 kg thermobaric charge seen by an infrared
    imager at 77.8 m, the fireball's temperature and size fitted against time. One shot, no TNT.
  - M. J. Hobbs et al., *Sensors* 22, 6143 (2022), doi:10.3390/s22166143, CC BY 4.0: 50 g of
    PE-4 in a 275 L chamber, temperatures early and late; confined. A. D. Brown et al., AIAA
    SciTech 2022, doi:10.2514/6.2022-1311, imaging pyrometry and optical depth at laboratory
    scale, paywalled. AFIT's Brilliant Flash II spectra of TNT fireballs (theses at
    scholar.afit.edu, etd 2897 and 2447; DTIC ADA496108) and Sandia's fireball radiometry (DTIC
    ADA093517) need the user to obtain.
- **Not found open:** the thermal projects of Snowball, Sailor Hat, Distant Plain and Prairie
  Flat. **Not searched** (allowance spent): Goroshin and Frost's field pyrometry, Lebel, HSE
  and TNO.

## 3f. A vented gas deflagration

- **Needed** (for the vented methane and propane deflagration being added as a second
  source, so far checked only against the EN 14994 and NFPA 68 correlations): the enclosure's
  inner dimensions and volume; the mixture (methane or propane, its fraction, initial
  temperature and pressure, quiescent or not); the ignition point (centre, back wall, near the
  vent); the vent's area, position and device (open, or a panel with its opening pressure and
  mass per area); any obstacles, their positions, sizes and blockage; and for each test the
  peak reduced pressure at named gauges, preferably with pressure histories (digitised will
  do) and the flame's arrival times.
- **Found, 10 October 2026:**
  - C. R. Bauwens, J. Chaffee and S. Dorofeev, "Experimental and numerical study of
    methane-air deflagrations in a vented enclosure", *Fire Safety Science* 9 (2008)
    1043–1054 (IAFSS, open on its publications site, 12 pages, 1.3 MB; downloaded): FM
    Global's chamber, 4.6 × 4.6 × 3.0 m, with a square vent of 5.4 or 2.7 m² in the middle of
    one wall closed by 0.02 mm polypropylene, no obstacles. Six tests (Table 1): methane at
    9.0 to 10.3%, ignited at the centre or 0.25 m from the back wall, after fans had mixed it
    and settled to about 0.1 m/s. Four pressure gauges in the chamber (back wall, vent wall,
    two on a side wall), two outside at 1.17 and 3.45 m from the vent, twenty thermocouples
    for the flame's arrival, sampled at 25 kHz. The peaks are not tabulated: the back wall's
    pressure histories are plotted (Figures 3 and 6 to 9) and would be digitised. The first
    choice. Their propane work (*Combustion Science and Technology*, 2010) and
    *International Journal of Hydrogen Energy* paper (2011) are paywalled.
  - Mercx (1992), IChemE Symposium Series 130, paper 29 (a PDF on icheme.org, title not
    confirmed): by search summaries, methane-air vented from a 38.5 m³ enclosure the size of a
    heating plant, with the vent's area, opening pressure and configuration and the ignition
    point varied.
  - HySEA (EU, 2015–18), hydrogen only and so out of scope for now: T. Skjold et al., "Vented
    hydrogen deflagrations in containers: effect of congestion for homogeneous mixtures",
    ICHS 2017, doi:10.5281/zenodo.998039, CC BY 4.0, 1.7 MB, 34 tests in 20 ft containers;
    and a blind-prediction benchmark with published model results, T. Skjold et al., *Journal of
    Loss Prevention in the Process Industries* 61 (2019) 220–236, doi:10.1016/j.jlp.2019.06.013,
    CC BY-NC-ND 4.0.
- **Not searched** (allowance spent): Cooper, Fairweather and Tite (1986); Kasmani.

## 4. Set aside, for completeness

- A paper on modified shock-wave parameter equations on MDPI, which returned HTTP 403. It is
  not needed now that the Kingery–Bulmash coefficients are in use.
- Fan Jin's 2014 University of Ottawa thesis, which re-used each specimen for several shots.
  Only the first shot on each specimen would be usable, and only if it is reported separately.

## Downloaded, not yet in use

Fetched on 10 October 2026 with the user's agreement, to `/Volumes/StudioData/bombcad/data/`,
one folder a source, each with a `SOURCE.md` giving the citation, terms and how it was fetched.
Nothing here is in the repository; a comparison would commit only small derived fixtures, with
their licence, as `Samples/FoRCy` does.

| Folder | What | Size | Terms |
|---|---|---|---|
| `Wu2023` | The article as HTML and JATS XML (Europe PMC's API), and its figures | 1.3 MB | CC BY 4.0 |
| `Wang2022` | The same for Wang et al. | 1.6 MB | CC BY 4.0 |
| `Peterson2026` | 3,537 files: load cells and accelerometers (.mat) for 16 beams, high-speed frames (.tif) for 18, each checked against its SHA-256 | 2.5 GB | CC BY 4.0 |
| `Hupfauf` | The 2022 paper and the 2024 thesis | 3.5 and 59.7 MB | CC BY 4.0; open access |
| `Hrynyk2013` | `Experimental Data.zip`, 39 spreadsheets for slabs TH2 and TH4 to TH8, unpacked | 183 MB (474 MB unpacked) | Not stated |
| `FoRDy` | DesignSafe PRJ-3836: mastersheet, 550 data files, critical plots, references, photos | 2.34 GB, 809 files, each checked against the listing's size | Open Data Commons Attribution |
| `DialPack1971` | Pattman's DREO Report 642, now compared (see [3e](#3e-fireball-radiation)) | 1.52 MB | Government of Canada |
| `Bauwens2008` | The *Fire Safety Science* 9 paper and a text extract | 1.3 MB | Free to read (IAFSS) |
| `Alsubaei2015` | The Western University thesis | 8.4 MB | Not stated |

PMC's own PDFs of the two *Materials* papers sit behind a proof-of-work check and were not
fetched; the XML and figures carry the same content.

## Obtained

Supplied by hand during development, and now in use:

- P. W. Cooper, *Explosives Engineering*, Wiley-VCH, 1996 (supplied as a scan): TNT's heat of
  combustion, 821 kcal/mol with the water liquid (Table 9.3, p. 130), 15.1 MJ/kg; its heat of
  detonation and afterburn heat (Table 9.4 and §9.6, pp. 132–133); and the closed vessel worked
  through on pp. 153–158. See the [air-blast model](air-blast-model.md#sources).

- J. C. Walraven and H. W. Reinhardt, "Theory and experiments on the mechanical behaviour of
  cracks in plain and reinforced concrete subjected to shear loading", *HERON* 26(1A) (1981),
  open access from the TU Delft repository: their push-off tests and the fit to them,
  τ = −f_cc/30 + [1.8 w^−0.80 + (0.234 w^−0.707 − 0.20) f_cc] Δ (eq. 1a, w and Δ in mm), whose
  slope is the crack shear stiffness in `Structure.metal` (the offset −f_cc/30 is left out).
  Its crack opening paths (Fig. 10) bear on `crackDilatancy` (above). Its specimens
  were restrained, so their cracks carried compression, which the interlock cap leaves out;
  where its laws give no stress across the crack, the model's cap is 3% to 24% above them. The
  paths, shear and stress across the crack of its seven specimens of mix 1 with external
  restraint (Fig. 16) were read off by hand for `blastbench pushoff` (`PushOffTest.swift`).
- G. A. Shetye, *FE analysis and experimental validation of RC single-mat slabs subjected to
  blast loads*, MS thesis, University of Missouri–Kansas City, 2013 (MOspace, open access): a
  photograph of the contest slab's unloaded face after the test (Fig. 6-60b, its slab 2,
  RSC-R1-4in), from which its cracks were counted (see
  [Validation](validation.md#its-cracks)). It gives the panels' clear span as 58 in, where the
  drawing Kewaisy et al. reproduce puts the supports 52 in apart; which is right is still
  wanted.
- J. Santos and A. A. Henriques, "New finite element to model bond–slip with steel strain
  effect for the analysis of reinforced concrete structures", *Engineering Structures* 86
  (2015) 72–83: the fib Model Code 2010's reduction of bond in yielded bars as printed,
  Ω_y = 1 − 0.85 (1 − e^(−5 aᵇ)), b = (2 − f_t / f_y)², which corrected the exponent.

- M. M. Swisdak, *Simplified Kingery Airblast Calculations* (1994): the Kingery–Bulmash
  polynomials, in `KingeryBulmash.swift`.
- G. F. Kinney and K. J. Graham, *Explosive Shocks in Air* (1985): both free-air formulae
  confirmed.
- UFC 3-340-02 (2008): the peak gas pressure in a closed room, in `UFC340.swift`; and the
  dynamic increase factors for bending in the far range used in the slab's sensitivity study
  (Table 4-1: 1.17 on the bars' yield, 1.19 on the concrete), confirmed. Its vented gas
  impulse charts (Figures 2-153 to 2-164) and its support-rotation limits are not yet used.
- P. Bernardi, R. Cerioni, E. Michelini and A. Sirico, "A non-linear procedure for the
  numerical analysis of crack development in beams failing in shear", *Frattura ed Integrità
  Strutturale* 35 (2016), open access: the geometry, concrete strength and measured load
  against deflection of Vecchio and Shim's beam OA1, in `ShearBeamBenchmark.swift`. Still
  wanted: Vecchio and Shim's paper itself (*Journal of Structural Engineering* 130(3), 2004),
  for the bars' measured properties, the bearing plates and the concrete's measured modulus,
  which are assumed.
- J. Xu and Y. Lu, "Numerical modelling for reinforced concrete response to blast load:
  understanding the demands on material models", ACI SP-306 (2016): the dimensions,
  materials and measured moment–deflection curve of one of Janney, Hognestad and McHenry's
  beams (1956), in `BeamBenchmark.swift`. It also models the contest slab, giving its concrete
  as 34.5 MPa (5 ksi) and its bars as Grade 60, where the source used here gives 37 MPa and
  the bars' measured curve (yield 72 ksi); and its own models' peaks, about 100 mm and 113 mm
  against the measured 108 mm. The slab's high-strength companion and the contest's records
  are still wanted (above).
- M. Chiquito et al., "Full-scale field tests on concrete slabs subjected to close-in blast
  loads", *Buildings* 13, 2068 (2023), and S. Martínez-Almajano et al., *International Journal
  of Computational Methods and Experimental Measurements* 9(3), 201–212 (2021), both open
  access: six full-scale slab tests, in `CloseInSlabTest.swift`. Still wanted: R. Castedo et
  al., "Numerical study and experimental tests on full-scale RC slabs under close-in
  explosions", *Engineering Structures* 231, 111774 (2021), for the concrete's measured
  strength, the anchorage and the charges' shapes, which are assumed.
- T. Ando, N. Kishi, H. Mikami and K. G. Matsuoka, "Weight falling impact tests on
  shear-failure type RC beams without stirrups", *Structures under Shock and Impact VI*, WIT
  Press (2000), open access, and its fuller Japanese version (*Structural Engineering* 46A,
  2000): nineteen of its single impacts and the measured materials, in
  `ImpactBenchmark.shearTests`. Still wanted: how the support jig held the beams' ends, which
  decides the faster tests.
- S. Saatci, *Behaviour and modelling of reinforced concrete structures subjected to impact
  loads*, PhD thesis, University of Toronto (2007), open access from the university's
  repository: the beams, materials, drop weights and measured first impacts of eight beams, in
  `ImpactBenchmark.swift`. Its digital records (displacement, reaction and impact force against
  time), once on the VecTor website, are still wanted, to compare histories rather than peaks.
- H. Shang et al., "Experimental Study on the Damage Mechanism of Reinforced Concrete Shear
  Walls Under Internal Explosion", *Applied Sciences* 16, 48 (2026): the chamber test, in
  `ChamberTest.swift`.
- FoRCy, the Foundation Rocking database of Cyclic and monotonic loading (M. Hakhamaneshi,
  B. L. Kutter, A. G. Gavras and others; DesignSafe PRJ-6414, doi:10.13019/t0cq-qf64, Open Data
  Commons Attribution), fetched on 9 October 2026 with the user's agreement: its mastersheet and
  S. Gajan and B. L. Kutter's test SSG02_03, a shear wall on a surface footing on dry dense sand
  rocked slowly, compared with `Footing` in [footings](structural-model.md#footings)
  (`blastbench rocking`, data in `Samples/FoRCy`). Its dynamic sister, FoRDy, and the other
  series (PWRI's 1 g footings on Toyoura sand, TRISEE's embedded ones) are not used yet.
- H. Rodrigues, A. Arêde, A. Furtado, R. Sousa and H. Varum's twelve cyclic tests of a precast
  beam seated on a column corbel (Mendeley Data, doi:10.17632/46xpgbhsw6.1, CC BY 4.0), fetched
  on 10 October 2026 with the user's agreement: concrete on concrete, neoprene pads and dowels
  under three axial loads, compared with a seat's joint (`blastbench precast`, data in
  `Samples/PrecastSeat`). Still wanted: the paper (N. Batalha et al., *Earthquake Eng. Struct.
  Dyn.*, 2022, doi:10.1002/eqe.3606), whose repository copy is restricted, for the seat's
  length, the pads' size and stiffness and the concrete's and dowels' strengths, which the dowel
  tests need.
