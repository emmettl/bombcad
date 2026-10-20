kind: added

**Protective design: the cheapest changes that meet a glass hazard target, in the app and
headless.** Simulation ▸ Protective Design… (and `scenebench protect`) takes a threat (a charge,
weighted places, or an inferred charge's samples), a target for each side (no pane worse than a
GSA condition except with an accepted chance), and your costs for the changes allowed: security
film, toughened or laminated glass, filling a window in, the scene's stand-off lines and barrier
walls. It ranks the plans that meet the target, cheapest first, from the façade load surrogate's
draws. Choosing a plan colours each side by its residual chance, and Apply Plan writes its glazing
into the project as each side's own glazing mix. Glazing mixes now carry a glass type, so a plan
is an ordinary envelope construction that the envelope damage assessment judges and a run can
confirm (`scenebench protect --confirm`). On the design prototype's own problems
(`Scripts/protective/`) the search finds the same plans, and stand-off comes first in every
cheapest one. `Scenario.addBarrier` builds a barrier wall on the ground as a fixed block the air
sees; the app warns when a charge stands inside a stand-off line. *Plans are illustrative until a
run confirms them*, and the surrogate, fitted on buildings only, takes little off for a barrier
(about 2% of the peak behind a 10 m wall), so a barrier rarely earns its cost until the refit
with barrier runs ([protective design](../../protective-design.md),
[using the app](../../using-the-app.md#protective-design)).
