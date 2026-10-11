# Slabs under an open-air charge in Brazil: blind-test inputs

Inputs for the record's second held-out test, run under [the blind-test protocol](../../docs/blind-tests.md#test-2-slabs-under-an-open-air-charge-mendonça-et-al).
Field blast tests at the Science and Technology Aerospace Department (DCTA), São José dos
Campos: reinforced concrete slabs 1.0 m square and 80 mm thick, resting on timber trestles
along two sides 0.4 m above clay ground, under about 2.7 kg TNT-equivalent of unconfined PBX
hung 1.3 to 2.0 m above their centres. Published, with the records, by F. B. Mendonça,
G. S. Urgessa and colleagues (2018, 2020, 2021; all CC BY 4.0; the records CC0).

| File | Contents |
|---|---|
| `inputs/slabs.json` | Geometry, concrete, reinforcement, supports, charge and instruments for the seven slabs |
| `SEALED.sha256` | SHA-256 of the sealed folder's files, which hold the measurements |
| `FROZEN` | Added when the predictor starts: the frozen commit it runs on |

| Slab | Concrete (tested) | Bottom steel | Charge, TNT eq. | Stand-off | Group |
|---|---|---|---|---|---|
| 1 | 42 MPa | 5 mm at 15 cm both ways | 2.76 kg | 1.3 m | C |
| 10 | 42 MPa | the same | 2.60 kg | 1.6 m | C |
| 2, 5 | 53 MPa | 5 mm at 15 cm both ways, and two 10 mm bars one way | 2.72, 2.58 kg | 2.0 m | A |
| 4, 7, 9 | 62 MPa | 5 mm at 10 cm both ways | 2.69, 2.60, 2.72 kg | 2.0 m | B |

Groups A and B are repeats: nominally identical slabs under nominally the same charge, which
give the tests' own scatter.

## What was left out, and why

- **Every measured response**: displacements, pressures, accelerations, crack patterns,
  photographs, and whether each slab survived. They are in
  `/Volumes/StudioData/bombcad/blind/mendonca-sealed/`, off the repository, with the records
  and the papers.
- **The papers' account of the series** beyond the set-up: its order and reasons, which refer
  to results.
- **Which instruments failed on which slab.** The dataset's readme lists records missing
  because sensors failed, which tells how some slabs fared.
- **The three foam-retrofitted slabs** (3, 6 and 8): BombCAD has no model of the foam.
- **The authors' own simulations** (Abaqus, in the 2020 paper; SDOF analyses elsewhere), which
  are compared there with the measurements.

## Assumptions the predictor must make

The sources do not give: the clear span and bearing width on the trestles; which way slab A's
10 mm bars run relative to the span; the steel's grade (only an estimated 350 MPa yield); the
concrete's tensile strength and aggregate; how the TNT equivalence was found, and which point
of the charge the stand-off is measured to; the heights of the mid-side pressure gauges (and
the sources disagree on which gauges sat on the slab's surface). The predictor records each
choice, with its reason, before running.

## The sealed data

The sealed folder holds the Dataverse files and the three papers (in `raw.tar`, unpacked
beside it as `raw/`), `measured.json` (each slab's outcome and the measured peaks as the
protocol scores them), `measured-records.json` (peaks, arrivals and impulses processed from
the records by `seal_measured.py` before any prediction) and that script. `SEALED.sha256`
checks that nothing changed between sealing and the reveal:

```bash
cd /Volumes/StudioData/bombcad/blind/mendonca-sealed && shasum -a 256 -c "$OLDPWD/Samples/Mendonca2020/SEALED.sha256"
```
