# Hupfauf's slabs under contact charges

`slabs.json` holds the fifteen reinforced concrete slabs without steel fibres from M. A.
Hupfauf's PhD thesis, *Secondary debris resulting from concrete slabs subjected to contact
detonations*, Universität der Bundeswehr München, 2024
([athene 149703](https://athene-forschung.unibw.de/149703)), with the first results in M. Hupfauf
and N. Gebbeken, *Advances in Structural Engineering* 25(7) (2022) 1373–1385,
doi:10.1177/13694332221080614 ([athene 141205](https://athene-forschung.unibw.de/141205)).
Both are licensed CC BY 4.0; this file is derived from them and carries the same licence.

The slabs, charges and the equivalence factors are transcribed from the thesis's tables 4.1 to
4.4. The measurements are read off its figures, to about the width of a marker:

| Quantity | Figure | Reading |
|----------|--------|---------|
| Crushing crater diameter and depth | 4.11 | ±0.3 cm; depths measured to 5 mm |
| Spall crater diameter (area-equivalent circle on the protective face) | 4.13 | ±0.5 cm |
| Debris mass (spall crater's scanned volume times the density) | 4.17 | ±0.5 kg |
| Maximum x-velocity of the debris (tip of the cloud) | 4.20, 4.18 | ±1 m/s; four quoted |
| Width σ of the debris's velocity profile | 4.22 | ±3 mm |
| Spall crater radius and radius of maximum curvature | 4.21 | quoted |

Within a group of identical shots the values are in the order the figure shows them; they are
assigned to shots only where the thesis names them. The slabs with steel fibres or a retrofitted
layer (SN81, SN148–SN155, SN161–SN164, SN171–SN173) are left out.

The original PDFs are not in the repository; they were fetched with the user's agreement to
`/Volumes/StudioData/bombcad/data/Hupfauf/`. `blastbench contact` runs the model against these
data (see [Validation](../../docs/validation.md#slabs-under-contact-charges)).
