# High-strength slabs in a blast load simulator: blind-test inputs

Inputs for the record's third held-out test, run under [the blind-test protocol](../../docs/blind-tests.md#test-3-high-strength-slabs-in-the-blast-load-simulator-reynolds-2015).
Six one-third-scale reinforced concrete panels, 64 in. long and 4 in. thick, of 15 ksi
concrete with one layer of No. 3 vanadium bars, each loaded once by a shock wave in the blast
load simulator at ERDC, Vicksburg. This is the same rig, fixture and span as the contest's
normal-strength slab in the validation record; these are its high-strength companions, with
two bar spacings. From K. A. Reynolds's MS thesis (University of Missouri-Kansas City, 2015,
hdl:10355/48353; no rights statement in the record, so only numbers are given here).

| File | Contents |
|---|---|
| `inputs/slabs.json` | Geometry, concrete, bars, supports, instruments and each slab's load, with page references |
| `inputs/loads.csv` | Each slab's average reflected pressure history, digitised from the thesis's Figs 9 and 10 |
| `inputs/digitise/` | How the histories were digitised |
| `SEALED.sha256` | SHA-256 of the sealed folder's files, which hold the measurements |
| `FROZEN` | The frozen commit: `b524a9d`, v0.3.0 build 7 |

| Slab | Bars along the span | Average peak / impulse (Table 1) |
|---|---|---|
| HSCV1 | No. 3 at 4 in. (0.69%) | 342.7 kPa / 6,987 kPa ms |
| HSCV2 | No. 3 at 4 in. | 339.2 kPa / 6,878 kPa ms |
| HSCV3 | No. 3 at 4 in. | 275.1 kPa / 5,336 kPa ms |
| HSCV4 | No. 3 at 8 in. (0.35%) | 283.4 kPa / 5,198 kPa ms |
| HSCV5 | No. 3 at 8 in. | 213.7 kPa / 3,527 kPa ms |
| HSCV6 | No. 3 at 8 in. | 244.1 kPa / 3,972 kPa ms |

## What was left out, and why

- **Every measured response:** deflection and strain histories, peak and residual
  deflections, times, damage photographs and descriptions, and whether any slab failed. They
  are in `$BOMBCAD_DATA/blind/reynolds-sealed/`, off the repository, with the
  thesis.
- **The thesis's account of the series' order** and why each load was chosen, which refers to
  results.
- **The thesis's SDOF (SBEDS) analyses and their comparison with the tests**, and its
  comparison with the normal-strength slabs.
- **The regular-strength (RSCR) slabs' figures**, which the thesis tabulates beside these;
  the record's contest slab is one of them.
- **A. K. Vasudevan's thesis** (UMKC, 2012), on the contest's slab series, stays sealed and
  unread beside this one.

## Assumptions the predictor must make

The sources leave open, or contradict each other on:

- **The slab's width:** 36 in. in the text, 33.75 in. in the drawings, 37.75 in. in Schwer.
- **The span:** 58 in. centre to centre in the text, 52 in. clear between the back supports in
  the drawings, as the record found for the contest slab.
- **The bearings:** their width and the honeycomb material.
- **The bars:** how many there are across the width and which way lies nearer the face.
- **The steel:** its ultimate strength and elongation.
- **The concrete:** its strength on the day of the test, its tensile strength and modulus.
- **The load:** which history to apply (the digitised curves, the tabulated points, or a shape
  scaled to Table 1's impulse).

The predictor records each choice, with its reason, before running.

## The sealed data

The sealed folder holds the thesis and its source note (in `raw.tar`, unpacked beside it as
`raw/`), `measured.json` (each slab's measured responses as the protocol scores them) and
`seal_measured.py`, which wrote it from the thesis's tables and figures before any prediction.
`SEALED.sha256` checks that nothing changed between sealing and the reveal:

```bash
cd $BOMBCAD_DATA/blind/reynolds-sealed && shasum -a 256 -c "$OLDPWD/Samples/Reynolds2015/SEALED.sha256"
```
