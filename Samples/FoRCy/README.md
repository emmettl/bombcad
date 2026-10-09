# A rocking footing on dry sand, measured

`ssg02_03.csv` is test SSG02_03 of S. Gajan and B. L. Kutter's centrifuge experiments at UC
Davis: an essentially rigid shear wall of 29.0 Mg (centre of mass 4.5 m up) on a surface footing
2.8 m long and 0.65 m wide on dry Nevada sand at a relative density of 80%, pushed slowly to
and fro by an actuator 4.9 m above the footing's base in five packets (a to e) of three cycles
each, prototype units throughout. It is compared with the model in
[footings](../../docs/structural-model.md#footings) (`FootingRockingTest`, `blastbench rocking`).

| Column | Meaning |
|---|---|
| `packet` | a to e, each of three cycles, larger than the last |
| `normalized_shear` | V / P, P = 285 kN the static weight of wall and footing |
| `normalized_moment` | 2 M / (L P), the moment about the centre of the footing's base, M = V h + P Δ |
| `normalized_settlement` | s / L, settlement of the base centre (positive down), L = 2.8 m |
| `normalized_sliding` | u / L |
| `rotation_rad` | the footing's rotation |

Every fourth sample of the database's time histories is kept (the time column was not given).

**Source.** FoRCy, the Foundation Rocking database of Cyclic and monotonic loading:
M. Hakhamaneshi, B. L. Kutter, A. G. Gavras, S. Gajan, A. Tsatsis and others, published on
DesignSafe as PRJ-6414, [doi:10.13019/t0cq-qf64](https://doi.org/10.13019/t0cq-qf64), under the
Open Data Commons Attribution License; described in "Database of rocking shallow foundation
performance: Slow-cyclic and monotonic loading", *Earthquake Spectra* 36(3), 2020. The files are
`TestSeries_SSG_2_SSG_3_SSG_4 -Gajan/Data -Response Time Histories/time_history_ssg_02_03_a.xlsx`
to `_e.xlsx`, fetched on 9 October 2026. The test: S. Gajan and B. L. Kutter, "Capacity,
settlement, and energy dissipation of shallow footings subjected to rocking", *J. Geotech.
Geoenviron. Eng.* 134(8) (2008) 1129–1141; the sand's ultimate bearing pressure, 814 kPa, is
the database's (`q_ult_tot`).
