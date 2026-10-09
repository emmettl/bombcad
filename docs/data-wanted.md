# Data wanted

Sources that would improve the model but could not be retrieved automatically during
development. Either the site refused automated access, or the material is only in print. Each
entry says what is needed from the source and what it would be used for. They are listed with
the most valuable first.

The citations below were written from memory and may contain small errors in page numbers or
titles; the authors, journals and years should be enough to find each one.

## 1. A second structural test from the same contest

- **Where:** A. Thiagarajan, A. V. Kadambi and G. Morrill, "Experimental and finite element
  analysis of doubly reinforced concrete slabs subjected to blast loads", *International
  Journal of Impact Engineering* 75 (2015) 162–173.
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

## 3. Formulae quoted from memory

Eight values in the code were written from memory and should be checked against the original.

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
- **Use:** to check `GroundShock.swift` and [Ground shock](ground-shock.md), whose relations
  were re-derived rather than taken from the page.

## 4. Set aside, for completeness

- A paper on modified shock-wave parameter equations on MDPI, which returned HTTP 403. It is
  not needed now that the Kingery–Bulmash coefficients are in use.
- Fan Jin's 2014 University of Ottawa thesis, which re-used each specimen for several shots.
  Only the first shot on each specimen would be usable, and only if it is reported separately.

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
  where its laws give no stress across the crack, the model's cap is 3% to 24% above them.
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
