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

## 3. Formulae quoted from memory

One formula in the code was written from memory and should be checked against the original.

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
- H. Shang et al., "Experimental Study on the Damage Mechanism of Reinforced Concrete Shear
  Walls Under Internal Explosion", *Applied Sciences* 16, 48 (2026): the chamber test, in
  `ChamberTest.swift`.
