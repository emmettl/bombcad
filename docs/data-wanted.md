# Data wanted

Sources that would improve the model but could not be retrieved automatically during
development. Either the site refused automated access, or the material is only in print. Each
entry says what is needed from the source and what it would be used for. They are listed with
the most valuable first.

The citations below were written from memory and may contain small errors in page numbers or
titles; the authors, journals and years should be enough to find each one.

## 1. Kingery–Bulmash polynomial coefficients

- **Where:** M. M. Swisdak, *Simplified Kingery Airblast Calculations*, Naval Surface Warfare
  Center, 1994 (DTIC accession ADA526744). The same coefficients appear in NATO AASTP-1 and in
  C. N. Kingery and G. Bulmash, ARBRL-TR-02555, 1984.
- **Needed:** the coefficient tables for surface (hemispherical) bursts of TNT, covering
  incident and reflected peak overpressure, incident and reflected positive impulse, arrival
  time and positive duration, together with the valid range of scaled distance for each.
- **Use:** replace the three tabulated points in `KingeryBulmash.swift` with the full curves,
  extending the blast-load comparison in [Validation](validation.md) closer in and farther out.
- **Why it failed:** DTIC returned HTTP 403 to automated requests.

## 2. A second structural test from the same contest

- **Where:** A. Thiagarajan, A. V. Kadambi and G. Morrill, "Experimental and finite element
  analysis of doubly reinforced concrete slabs subjected to blast loads", *International
  Journal of Impact Engineering* 75 (2015) 162–173.
- **Needed:** for the high-strength concrete slab: concrete strength, bar sizes, spacing and
  cover in both faces, yield and ultimate steel strengths, the measured reflected pressure and
  impulse histories, and the measured mid-span displacement history.
- **Use:** a second case in `SlabBenchmark.swift`, with steel in both faces and a different
  concrete, run unchanged against the model.
- **Also needed for the existing slab:** how it was supported in the test rig: the width and
  material of the bearings, and whether the slab was held down against rebound. Modelling
  choices for the supports change the predicted peak by 15–20%.
- **Also useful:** the Blast Blind Simulation Contest data package itself (organised through
  ACI Committee 447 and the University of Missouri–Kansas City), if the digital pressure and
  displacement records are available. They would replace the curves currently digitised from
  presentation slides.

## 3. A test that couples air and structure

- **Where:** any open publication that reports charge mass, stand-off, wall or slab details,
  and measured deflection together. Candidates: A. Schenker et al., "Full-scale field tests of
  concrete slabs subjected to blast loads", *International Journal of Impact Engineering* 35
  (2008); and W. Wang et al., "Experimental study and numerical simulation of the damage mode
  of a square reinforced concrete slab under close-in explosion", *Engineering Failure Analysis*
  27 (2013).
- **Needed:** the specimen geometry, reinforcement and material strengths, the support
  conditions, the charge mass, shape and position, and the measured deflection or damage.
- **Use:** the first end-to-end test of both solvers together, rather than the structure alone
  under a prescribed load.

## 4. Formulae quoted from memory

Two formulae in the code were written from memory and should be checked against the original.

- **Kinney–Graham positive impulse.** G. F. Kinney and K. J. Graham, *Explosive Shocks in Air*,
  2nd ed., Springer, 1985. Needed: the scaled-impulse formula for free-air bursts, as used in
  `KinneyGraham.swift`. Only the peak-overpressure formula has been confirmed.
- **Karsan–Jirsa unloading.** I. D. Karsan and J. O. Jirsa, "Behavior of concrete under
  compressive loadings", *Journal of the Structural Division*, ASCE 95(ST12) (1969) 2543–2563.
  Needed: the relation between the envelope strain reached and the permanent strain left on
  unloading, as used in `concreteCompression` in `Structure.metal`.

## 5. Design-manual reference

- **Where:** UFC 3-340-02, *Structures to Resist the Effects of Accidental Explosions*, US
  Department of Defense, 2008 (with later changes). It is publicly released.
- **Needed:** the dynamic increase factors for concrete and reinforcement (chapter 4), and the
  support-rotation and ductility limits used to classify damage.
- **Use:** confirm the fixed design factors in the slab benchmark's sensitivity study, and give
  the app a damage classification that engineers would recognise.

## 6. Set aside, for completeness

- A paper on modified shock-wave parameter equations on MDPI, which returned HTTP 403. It is
  not needed if the Kingery–Bulmash coefficients are obtained.
- Fan Jin's 2014 University of Ottawa thesis, which re-used each specimen for several shots.
  Only the first shot on each specimen would be usable, and only if it is reported separately.
