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
100 pcf (1,600 kg/m³) is said to match the soil, which is all there is for its density. The
Watching Hill soil reports (Jackson and Windham's for Distant Plain, WES TR S-72-4) would give
them.

**Checks.** Transcribed by hand from the page image (PDF page 32, landscape), the values checked
against the scan a second time; the text layer's OCR agrees where it is legible. The report's text gives
the vertical velocities as "84 to 0.33 ft/sec"; the table's largest is 74 (UV, 84 ft, 1.5 ft
deep) and its smallest 0.33 (AV, 1,150 ft, 5 ft), so the 84 is taken to be a slip.
