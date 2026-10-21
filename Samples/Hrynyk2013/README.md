# Hrynyk's slabs struck by a falling weight: blind-test inputs

Inputs for the record's first held-out test, run under [the blind-test protocol](../../docs/blind-tests.md).
Three plain reinforced concrete slabs from T. D. Hrynyk's programme at the University of
Toronto (*Behaviour and modelling of reinforced concrete slabs and shells under static and
dynamic loads*, PhD thesis, 2013, TSpace 1807/35851, CC BY 2.5 Canada): 1.8 m square and
130 mm thick, held at their corners, struck at the centre by a 300 mm square steel weight at
8 m/s, again and again with a rising mass.

| File | Contents |
|---|---|
| `inputs/slabs.json` | Geometry, reinforcement, the bars' and concrete's measured properties, supports, impactor, loading protocol, and what was measured |
| `SEALED.sha256` | SHA-256 of the sealed folder's files, which hold the measured responses (the raw folder as one archive, `raw.tar`, so that its file names do not tell how many impacts each slab took) |
| `FROZEN` | The frozen commit the predictor runs on |

| Slab | Bars, each layer both ways | Reinforcement ratio per layer | Concrete at test |
|---|---|---|---|
| TH2 | #3 (9.5 mm) at 130 mm | 0.420% | 69.4 MPa |
| TH6 | #3 at 200 mm | 0.273% | 59.0 MPa |
| TH7 | 10M (11.3 mm) at 130 mm | 0.592% | 60.3 MPa |

## What was left out, and why

- **Every measured response**: displacements, reactions, impact forces, accelerations, strains,
  crack widths, penetration, damage descriptions and photographs. They are in
  `$BOMBCAD_DATA/blind/hrynyk-sealed/`, off the repository, with the raw
  records and the thesis.
- **How many impacts each slab took.** The data's file names (one spreadsheet per impact) and
  the thesis's slab-by-slab chapter give it, and a slab's last impact is when it was judged
  failed. The inputs give the full ten-impact protocol and its termination rule instead.
- **The record files' notes sheets**, which list sensors damaged or removed before or during
  each impact: a sign of how the slab was faring.
- **Test dates**, which tell how soon a slab was struck again and so hint at the outcome.
- **The fibre-reinforced slabs** (TH3, TH4, TH5, TH8): BombCAD has no model of steel fibres.
  **TH1**, the pilot, had a different mass sequence and extra links, and no records in the
  data set.
- **Hrynyk's own analyses** (his chapter 7) and their element mesh: they are compared there
  with the measurements.

## Assumptions the predictor must make

The thesis does not give: the bearing plates' plan size; the bars' rupture strain; the number
and placement of the mat-tying links; the impactor's stiffness (only that it is a concrete-filled
steel section with a flat steel face); the exact directions of the one-way rollers, read here
from its Figure 3.8. The predictor records each assumption, with its reason, before running.

## The sealed data

The sealed folder holds the raw records, the thesis and its text (in `raw.tar`, unpacked beside it as `raw/`), `measured.json` (the
thesis's tabulated peaks, residuals, reactions, damage and observations for every recorded
event of these slabs), `measured-records.json` (impact forces, reactions and displacement histories
processed from the raw records by `seal_measured.py`, before any prediction), and the
processing scripts. `SEALED.sha256` lets anyone check that nothing in it changed between
sealing and the reveal:

```bash
cd $BOMBCAD_DATA/blind/hrynyk-sealed && shasum -a 256 -c "$OLDPWD/Samples/Hrynyk2013/SEALED.sha256"
```
