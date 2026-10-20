# Church's measured clouds

`church-1969.json` holds what the [fireball's rise and cloud](../../docs/fireball-rise.md#against-churchs-measured-clouds)
is compared with, and what it is compared from:

- **`shots`**: Tables I and II of H. W. Church, *Cloud Rise from High-Explosives Detonations*,
  Sandia Laboratories, SC-RR-68-903, May 1969
  ([OSTI 4798257](https://www.osti.gov/biblio/4798257)), transcribed from the scanned report: 23
  surface detonations of 118 to 2,800 lb of TNT (or its equivalent by heat of explosion) on dry
  lake beds in Nevada in April to June 1963, with the date, the local time (PDT), the yield in
  pounds, the stability S = 1 − γ/Γ (γ the mean lapse rate from the ground to the cloud's top at
  2 minutes, Γ the dry adiabatic), the mean wind over the cloud's height in m/s (none given for
  the preliminary shots P3 to P8), and the cloud's top in metres above the ground at ½, 1, 2, 3,
  4 and 5 minutes as the cameras and the theodolites saw it, `null` where not seen. For Double
  Tracks and Clean Slate 1 the fourth value is at 2½ and 2⅔ minutes (`lateTimes`, in seconds).
  Church gives the data as reliable to within 15 to 20%. The report is a US government work.
- **`handOvers`**: the air model's hand-overs for those charges, from runs of an open, flat
  ground with the charge on it, on the medium grid (0.25 m cells), 64 × 64 × 32 m up to 560 lb and
  96 × 96 × 48 m above, run for 0.17 s × (W / 100 kg)^⅓, with afterburning and hot air
  (`afterburning`) and, for three charges, without (`default`); everything at least 500 K, as
  `BombCAD run --cloud` hands it over, made on 9 October 2026.

`Scripts/compare-church-cloud.py` follows each shot's cloud with `BombCAD cloud` and prints the
comparison; `CloudAtmosphereTests` checks its two-minute heights.

`church-1969-profiles.json` holds the appendix of the same report, transcribed on 20 October
2026 ([the comparison in them](../../docs/fireball-rise.md#in-churchs-own-air-20-october-2026)):

- **`soundings`**: the temperature profiles of Figures A-1 to A-13, in °C against metres above
  the ground: every 10 m to 600 m for the June series and Roller Coaster (Figures A-1 to A-12),
  and at their corners to 300 m for the preliminary shots P3 to P8 (Figure A-13). The figures
  were rendered at 300 dpi, their axes calibrated by least squares through the tick marks (the
  dashed isentropes then come out at 9.8 K/km, the dry adiabat), and each solid curve traced row
  by row along a hand-placed guide; the values on the axis lines (the ground, 600 m) are carried
  on from the two samples nearest. Two figures draw a sounding twice: 0300 (A-6 and A-7, the
  same within 0.05 K but where A-6's trace crosses the isentrope) and 2259 (A-4 and A-5, the
  latter up to 0.4 K warmer above 300 m).
- **`winds`**: each figure's wind speed and direction (from) against height, read at the
  profiles' corners off a calibrated grid, from the 9 m anemometer up. The direction axes' labels
  do not always sit on their ticks, so the directions may be off by up to a tick (50°) in
  offset; their changes with height, the shear, are not.
- **`shots`**: which sounding and wind each shot takes. Where a shot falls between two
  soundings, the one Church's own stabilities in Table I match is used: 1656 for shots 1 to 3,
  A-4's 2259 for 5 to 7, 0300 for 8 to 11. With those, the stabilities worked out from the
  transcribed profiles over each cloud's height at two minutes are within 0.07 of Table I's for
  14 of the 17 shots; Clean Slate 1 is 0.13 off, shot 4 0.22 (0.64 against 0.86) and shot 11
  0.32 (2.05 against 1.73).

Only these numbers are kept here; the report is on StudioData, `bombcad/sources/church-1969/`.
