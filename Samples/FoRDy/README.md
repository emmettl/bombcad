# A wall on a footing on dry sand, shaken

Eight events of S. Gajan's centrifuge tests at UC Davis, the dynamic sisters of FoRCy's slow
SSG02_03 ([../FoRCy](../FoRCy/README.md)): the same aluminium footing, 2.8 m long along the
shaking, 0.65 m wide and 0.65 m thick (3.2 Mg), on the same dry Nevada sand at a relative
density of 80% (1,657 kg/m³, peak friction angle about 42°, ultimate bearing pressure 814 kPa),
4 m deep in a rigid container, prototype units throughout. Each event is a tapered sine of 12
cycles at about 1.2 Hz on the container's base; an event's settlement and rotation start
where the last left them.

| File | Test | Footing | Structure on it | P, q, FS | Peak base acceleration |
|---|---|---|---|---|---|
| `SSG04-1-DSW-3`, `-4`, `-5` | SSG04, 17 Dec 2003 | on the surface | DSW: 33.6 Mg of aluminium wall, centre of mass 5.76 m above the base, 143,200 kg m² about it | 361 kN, 198 kPa, 4.0 | 0.13, 0.53, 0.73 g |
| `SSG04-1-SHW-3`, `-4` | SSG04 | on the surface | SHW: 54.8 Mg of steel wall, 5.26 m, 385,000 kg m² | 569 kN, 313 kPa, 2.6 | 0.12, 0.60 g |
| `SSG03-1-DSW-3`, `-4`, `-5` | SSG03, 18 Nov 2002 | its base 0.7 m down | DSW as above | 361 kN, 198 kPa, 11.5 | 0.13, 0.49, 0.97 g |

DSW is a pair of walls side by side, joined at the top across the shaking, each on its own
footing; the database gives everything per footing. The structure's centre of mass, footing
included, is 5.29 m (DSW) or 4.98 m (SHW) above the footing's base. FS is the database's static
factor of safety against vertical load.

| Column | Meaning |
|---|---|
| `time_s` | from the start of the event |
| `base_acceleration_g` | the container base's acceleration along the shaking, baseline corrected |
| `rotation_rad` | the footing's rotation |
| `normalized_moment` | M / (P L / 2), the moment about the centre of the footing's base, L = 2.8 m |
| `normalized_shear` | V / P |
| `normalized_sliding` | u / L, the base centre's sliding against the free field |
| `normalized_settlement` | s / L, the base centre's settlement (positive down) |

SSG04 was sampled at 204.8 Hz and every second sample is kept; SSG03 at 100 Hz, all kept.
`extract.py` derives the files from the database (`python3 extract.py /path/to/PRJ-3836`).

The database's notes say that the moment and shear were worked out from the structure's
accelerations (low-pass filtered at 10 Hz), that two smaller shakes (events 1 and 2, not in the
database, "quasi-elastic") came first, that SSG03's dynamic sliding may be poor, and that
SSG04's settlement might be relative to the free field rather than absolute (still to be
settled; S. Gajan's dissertation gives his settlements as absolute, and the free field settling
a fifth to a quarter as much as the footing in his event SSG04_09_b, here SHW-4).

**Source.** FoRDy, Rocking Shallow Foundation Performance in Dynamic Experiments:
B. L. Kutter, A. G. Gavras, I. Anastasopoulos, L. Deng, S. Gajan, A. Tsatsis and others,
published on DesignSafe as PRJ-3836, [doi:10.13019/3rqyd929](https://doi.org/10.13019/3rqyd929),
under the Open Data Commons Attribution License; described in A. G. Gavras et al., "Database
of rocking shallow foundation performance: Dynamic shaking", *Earthquake Spectra* 36(2), 2020.
The files are `2_Data Files/Critical Plots Data Files/<event>-CriticalData.txt` and
`2_Data Files/Baseline Corrected Motions Data Files/<event>-BaselineCorMotions.txt`, fetched on
10 October 2026; the structures' properties are the mastersheet's
(`FoRDy_Mastersheet_v1.0.0_20180821_2322`). The tests: S. Gajan and B. L. Kutter, "Capacity,
settlement, and energy dissipation of shallow footings subjected to rocking", *J. Geotech.
Geoenviron. Eng.* 134(8) (2008) 1129–1141; S. Gajan, PhD dissertation, UC Davis, 2006.
