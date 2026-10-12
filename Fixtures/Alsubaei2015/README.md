# Alsubaei's perimeter walls under field blasts

`walls.json` holds derived numbers from F. C. F. Alsubaei, *Performance of protective perimeter
walls subjected to explosions in reducing the blast resultants on buildings*, Master's thesis,
Western University, 2015
([hdl:20.500.14721/35930](https://hdl.handle.net/20.500.14721/35930)). The repository states no
terms, so only numbers are kept here: transcribed from the thesis's tables and text, with the
pressures behind the canopied walls read off its Figure 7.33 to about 2 kPa (the no-wall points
read back within 2 kPa of its Table 7.4). Nothing is copied from its figures or prose.

The tests, at the SSF range in Riyadh, are ANFO charges (0.82 of TNT) on a table in front of a
wall standing on a buried footing, wing walls either side, and gauges on steel pipe columns
behind it standing for a building:

| Chapter | Wall | Charges | Measured |
|---------|------|---------|----------|
| 4, 5 | Half-scale reinforced concrete, 2 × 1 × 0.2 m; charge 2 m in front at 0.5 m up | 0.45–14 kg, twelve on each wall | Column peaks with no wall (2.44, 6.46, 14 kg at 8.2 and 11.85 m); the ratio behind the wall (6.46, 10 kg at 4.2, 8.2, 11.85 m); damage seen |
| 6 | The same, charge 3 m in front, the street level or lowered | 0.45–15 kg | Column peaks with no wall at 9.2 and 12.85 m; the reduction at the lowest gauge; damage seen |
| 7 | Full-scale wall with a canopy, 4 × 2 × 0.4 m stem; charge 4 m in front at 1 m up | 125 kg, one on each wall | Column peaks with and without the wall at 16.4 m; mid-height deflection of foam-faced walls; damage seen |
| 8 | Full-scale double-leaf reinforced blockwork, 4 × 2 × 0.4 m; the same charge position | 25 kg (three walls), 125 kg (one) | Top deflection at 25 kg; collapse at 125 kg; damage seen |

Things to know before using them:

- The gauges are on narrow pipes, so the reflection clears within about a millisecond: peaks
  are usable, impulses are not a building face's (they are a quarter to a half of A.T.BLAST's).
- Deflections are double-integrated accelerometer records, without baseline correction stated;
  the canopied walls' velocities still climb at the end of the 4 ms plotted.
- The half-scale walls took twelve shots each, rising, so their damage is cumulative.
- Chapter 6's plotted no-wall histories peak at about a seventh of its tabled peaks for the
  same shots.
- The masonry's cells hold bars in polyurethane foam, though the text also calls the walls fully
  grouted; its base is not described. The wing walls' length and the columns' diameter are not
  stated anywhere.

The thesis is not in the repository; it was fetched with the user's agreement to
`/Volumes/StudioData/bombcad/data/Alsubaei2015/`. `blastbench perimeter` runs the model against
these data (see [Validation](../../docs/validation.md#perimeter-walls-under-field-blasts)).
