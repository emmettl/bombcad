# A precast beam's seat on its corbel, cycled

Twelve full-scale tests of an industrial precast beam's end seated on a column's corbel, pushed
slowly to and fro along the seat by a horizontal actuator at 0.2 mm/s in cycles of growing
amplitude (to about ±48 mm), under a constant axial load pressing the seat. Each file is one
test, named `spc_<interface>_<axial load in kN>`:

| Interface | Meaning |
|---|---|
| `i0` | concrete on concrete |
| `i1` | one neoprene pad between them |
| `i2` | two neoprene pads |
| `c1` | concrete, two dowels of 16 mm 13 cm from the column's inner face |
| `c2` | concrete, two dowels of 16 mm 6 cm from the column's inner face |

| Column | Meaning |
|---|---|
| `displacement_mm` | the actuator's displacement |
| `force_kN` | the actuator's force |

Every tenth sample of the original files is kept (the time was not given). Compared with the
model in [structural model](../../docs/structural-model.md#base-connections)
(`PrecastSeatTest`, `blastbench precast`).

**Source.** H. Rodrigues, A. Arêde, A. Furtado, R. Sousa and H. Varum, "Cyclic behaviour of
precast beam-to-column connections with low seismic detailing", Mendeley Data V1, 2022,
[doi:10.17632/46xpgbhsw6.1](https://doi.org/10.17632/46xpgbhsw6.1), under CC BY 4.0; the files
`SPC_*.xlsx`, fetched on 10 October 2026. The tests: N. Batalha, H. Rodrigues, A. Arêde,
A. Furtado, R. Sousa and H. Varum, "Cyclic behaviour of precast beam-to-column connections with
low seismic detailing", *Earthquake Engineering & Structural Dynamics* (2022),
[doi:10.1002/eqe.3606](https://doi.org/10.1002/eqe.3606). The columns are 0.50 × 0.35 m and the
beam 0.35 m wide, 0.50 m deep near its end; the seat's length, the pads' size and the concrete's
and dowels' strengths are in the paper, which was not read for this.
