# Ground motion under Prairie Flat, 500 tons of TNT on the surface

`ground-motion.json` holds Table 3.1 of D. W. Murrell, *Operation Prairie Flat, Project LN302:
Earth Motion and Stress Measurements*, Technical Report N-72-2, U.S. Army Engineer Waterways
Experiment Station, February 1972 (unlimited distribution; the open copy is USACE's digital
library's, [p266001coll1/7076](https://usace.contentdm.oclc.org/digital/collection/p266001coll1/id/7076),
also on Wikimedia Commons), and what the report says of the site. Only these derived numbers are
kept here, with citation; the report is on StudioData, `bombcad/sources/prairie-flat/`.
`Scripts/compare-prairie-flat.py` sets `blastbench groundmotion`'s run against them (see
[Ground shock](../../docs/ground-shock.md#against-prairie-flat)).

**The test.** 500 short tons of TNT, a sphere resting on the ground, fired in August 1968 on the
Watching Hill Blast Range at DRES, Suffield, Alberta. Accelerometers (AV vertical, AH horizontal)
and velocity gauges (UV, UH) at 84 to 1,150 ft from ground zero and 1.5 to 30 ft deep; the
velocities and displacements of the accelerometers are their integrals.

**Each record** (`gauges`) gives its range and depth (in feet as printed, and in metres), its
location code, its arrival in seconds and its peak acceleration (g), velocity (m/s) and
displacement (m), upward and downward. Positive is upward or outward; the airblast-induced
vertical peak is the downward one. Where the table gives a footnote instead of a number, the
letter is kept: `a` negative peaks not reported for horizontals, `b` no reliable negative peak,
`d` the displacement cut off by gauge or cable damage, `e` no peak data, `f` no reliable
positive peak, `g` no reliable integrals; `arrivalNote` `c` marks an arrival the slow rise makes
questionable. `null` is the table's "--". No arrivals were read at 560 ft and beyond.

**The site,** as far as the report gives it: lacustrine clays and silts; the upper 5.5 ft a
sandy, silty clay and sandy silt below it to about 30 ft, both about 40% air and highly
compressible (23% strain at 4,000 psi in a dynamic uniaxial test, 2% of it recovered). The
arrivals gave 1,270 ft/s (387 m/s) in the upper layer and 6,100 ft/s (1,859 m/s) in the
saturated soil below the water table, which Figure 3.1 draws at about 23 ft (7.0 m); the text
does not state its depth. **No densities, shear speeds or strengths are given:** the canisters'
100 pcf (1,600 kg/m³) is said to match the soil, which is all there is for its density in it.

**The soil measured** (`soil-profile.json`, 20 October 2026), from J. G. Jackson, Jr., *Physical
Property and Dynamic Compressibility Analysis of the Watching Hill Blast Range*, WES TR S-72-4,
April 1972 (unlimited distribution; USACE's digital library,
[p266001coll1/5071](https://usace.contentdm.oclc.org/digital/collection/p266001coll1/id/5071),
also on Wikimedia Commons; on StudioData, `bombcad/sources/watching-hill/`). It reads as a
SoilProfile, five layers from the surface down:

- **The layers** follow the DRES boring at the Prairie Flat GZ (Figure 2.4): silty clay to about
  7.7 ft, very fine silty sand to medium sand below it, and the water table at about elevation
  2141 ft, 24 ft under the GZ's 2165 (the shallow refraction survey's first layer, 21–23 ft, and
  Murrell's Figure 3.1's 23 ft agree).
- **Densities** are the means of the wet unit weights of the specimens from the Prairie Flat
  borings in Tables 3.1–3.6: 91.8 pcf (1,470 kg/m³) for the clays above the water table, 95.9 pcf
  (1,536) for the sands, 119.1 pcf (1,908) below it.
- **Loading stiffness** is the secant constrained modulus to 100–200 psi of the recommended
  uniaxial-strain curves (Figures 4.12, 4.19a, 4.20a), read off the figures at 300 dpi on their
  grids, at the loading-rate category Jackson gives for each depth under 400–1,600 psi of
  overpressure (IV to 2 ft, III to 5, II to 10, I below): 11,800, 6,300 and 2,900 psi in the clay,
  6,700 psi in the sands (the geometric mean of Groups 5 and 6), each the layer's `waveSpeed` as
  √(M/ρ), 235 down to 117 m/s. Below the water table, his single curve for all saturated soil,
  550,000 psi (1,410 m/s), not hysteretic.
- **Unloading stiffness** is the slope of the curves' unloading branches, about 45,000 psi in the
  clay and 60,000 psi in the sands (459 and 519 m/s, `unloadingWaveSpeed`).
- **Shear speeds are not given** there either (Jackson defers lateral pressure and triaxial data to
  another report); `shearWaveSpeed` is the loading speed at a Poisson's ratio of 0.3, and the
  saturated soil's the sand's above it.

Read by eye from figures to about ±0.2% strain, so each modulus is good to perhaps a quarter.
These loading speeds, 117 to 235 m/s, are a third to two-thirds of the arrival and seismic
speeds (387 m/s; 1,150 ft/s by refraction): a crushable soil's first motion runs ahead of its
stress.

**Checks.** Transcribed by hand from the page image (PDF page 32, landscape), the values checked
against the scan a second time; the text layer's OCR agrees where it is legible. The report's text gives
the vertical velocities as "84 to 0.33 ft/sec"; the table's largest is 74 (UV, 84 ft, 1.5 ft
deep) and its smallest 0.33 (AV, 1,150 ft, 5 ft), so the 84 is taken to be a slip.
