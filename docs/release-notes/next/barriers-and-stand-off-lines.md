kind: added

**Barrier walls and stand-off lines.**
- `Scenario.addBarrier` puts a barrier wall along x or y on the lowest ground under it, as a fixed
  block the air sees.
- The façade load surrogate's quick estimate now sees the scene's fixed blocks as well as its
  buildings, a thin wall included. Its shielding terms are still those fitted on buildings.
- A layout can hold stand-off lines that keep charges back. The app warns when a charge stands
  inside one, and the protective-design search can move a charge to where a line stops it
  ([protective design](../../protective-design.md#changes-as-constructions-stage-3)).
