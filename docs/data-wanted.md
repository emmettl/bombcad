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

## 3. Formulae quoted from memory

Nine values in the code were written from memory and should be checked against the original.

- **TNT's heats of detonation and combustion.** P. W. Cooper, *Explosives Engineering*,
  Wiley-VCH, 1996, or any standard table. Needed: the heat of combustion of TNT (taken as about
  15 MJ/kg) and its heat of detonation (about 4.6 to 5 MJ/kg), whose difference, 10 MJ/kg, is
  the afterburn energy.
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
- **Vibrational temperatures of N2 and O2** (3390 K and 2270 K), used for hot air in
  `Solver.metal`, and **Lighthill's dissociation constants** (θ<sub>d</sub> 113,000 and
  59,500 K, ρ<sub>d</sub> 130 and 150 g/cm³, from Vincenti and Kruger's *Introduction to
  Physical Gas Dynamics*), used for dissociating air; any text on statistical thermodynamics,
  or the NIST-JANAF tables, to check them.

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

- **Karsan–Jirsa unloading.** I. D. Karsan and J. O. Jirsa, "Behavior of concrete under
  compressive loadings", *Journal of the Structural Division*, ASCE 95(ST12) (1969) 2543–2563.
  Needed: the relation between the envelope strain reached and the permanent strain left on
  unloading, as used in `concreteCompression` in `Structure.metal`.

## 4. Set aside, for completeness

- A paper on modified shock-wave parameter equations on MDPI, which returned HTTP 403. It is
  not needed now that the Kingery–Bulmash coefficients are in use.
- Fan Jin's 2014 University of Ottawa thesis, which re-used each specimen for several shots.
  Only the first shot on each specimen would be usable, and only if it is reported separately.

## Obtained

Supplied by hand during development, and now in use:

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
- S. Saatci, *Behaviour and modelling of reinforced concrete structures subjected to impact
  loads*, PhD thesis, University of Toronto (2007), open access from the university's
  repository: the beams, materials, drop weights and measured first impacts of eight beams, in
  `ImpactBenchmark.swift`. Its digital records (displacement, reaction and impact force against
  time), once on the VecTor website, are still wanted, to compare histories rather than peaks.
- H. Shang et al., "Experimental Study on the Damage Mechanism of Reinforced Concrete Shear
  Walls Under Internal Explosion", *Applied Sciences* 16, 48 (2026): the chamber test, in
  `ChamberTest.swift`.
