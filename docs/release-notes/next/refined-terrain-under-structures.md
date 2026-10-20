kind: changed

**Refined runs of a structure standing on terrain cut the terrain through the cells.** Until
now, refined air under a structure on a slope kept the ground as a staircase of whole cells.
Refined levels now shut in the thin cut cells under a structure, as the unrefined grid does, and
the closed air keeps its gas to 2–5e-8. On "Two-storey frame on a hillside" the frame's largest
displacement comes within 6% of fine uniform cut cells refined once and 9% twice, where the staircase gave 2.7 and 1.6 times
as much. Such runs take 26% more GPU time refined once and 8% twice, the cost of cut cells over
the staircase; the cap itself is 2% of it ([terrain](../../terrain.md#cut-cells)). Saved runs
keep the setting they were recorded with.
