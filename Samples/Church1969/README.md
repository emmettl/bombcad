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
