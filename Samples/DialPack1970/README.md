# Dial Pack's thermal radiation

`dial-pack-1970.json` holds what the [fireball's thermal radiation](../../docs/thermal-radiation.md#against-dial-pack)
is compared with: numbers transcribed from J. D. R. Pattman, *Operation Dial Pack 1970: Canadian
Project A7 thermal radiation measurements*, DREO Report 642, Defence Research Establishment
Ottawa, August 1971 ([Government of Canada
Publications](https://publications.gc.ca/site/eng/9.941855/publication.html), catalogue
DR52-17/4-1971E-PDF), an archived publication of the Government of Canada, reproduced here as a few
numbers with attribution under its terms. The report itself is not redistributed.

Dial Pack was 500 tons of cast TNT, taken here as short tons (453.6 t), stacked as a sphere 13.46 ft
(4.10 m) in radius resting on the ground at Suffield on 23 July 1970.

- **`bolometer`**: Table II, the silica band (200 to 4,500 nm) at 1,700 m, from 1 ms to 15 s: the
  irradiance at the site (cal/cm²/s × 10⁻³), the report's atmospheric transmission factor a, and
  the radiant intensity J = H r² / a (cal/sr/s × 10⁷), corrected for the atmosphere.
- **`photocell`**: Table III(b), the fireball's apparent area seen from 1,700 m (cm² × 10⁶) and its
  emittance temperatures in the green and the near infrared (K × 10³), to 100 ms.
- **`calorimeters`**: Table V, the radiant density u (cal/cm² × 10⁻³) at 600 and 1,700 m over 20 s
  behind silica windows, with the transmissions and the windows' factor the report applies.
- **`thermalYield`**: Table VI, the radiant energy, 4πr²u / a, 3.5 to 3.7 × 10¹⁰ cal, 7.0% to 7.4%
  of the report's blast yield of 10⁹ cal a ton (2.2% of the heat of combustion).
- **`yieldHistory`**: Fig. 12, the share of the total radiated by each time, read from the figure
  to about 0.02.
- **`otherShots`**: Table VI's earlier shots by the same group, 5 to 500 tons, 1961 to 1966.

Integrating Table II's intensity over 15 s (4π ∫ J dt) gives 3.57 × 10¹⁰ cal, as the report's
bolometer figure. `blastbench dialpack` runs the shot and `Scripts/compare-dial-pack.py` compares
it.
