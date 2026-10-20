kind: changed

**Refined runs of a structure standing on terrain cut the terrain through the cells.** Until
now, refined air under a structure on a slope kept the ground as a staircase of whole cells.
Refined levels now shut in the thin cut cells under a structure, as the unrefined grid does, and
the closed air keeps its gas to 2–5e-8. On "Two-storey frame on a hillside" the frame's largest
displacement comes within 2–9% of fine uniform cut cells, where the staircase gave 1.6–2.7 times
as much. Such runs take 26% more GPU time refined once and 8% twice, the cost of cut cells over
the staircase; the cap itself is 0.6% of it ([terrain](../../terrain.md#cut-cells)). Saved runs
keep the setting they were recorded with.
