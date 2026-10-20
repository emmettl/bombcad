kind: fixed

**A concrete or masonry shell keeps its own rule through the thickness beside timber.** (Also in 0.5.1.) Any
timber in a model, a glulam beam or a timber floor, put every shell on the timber's
Gauss–Lobatto points, so a concrete slab's cracking moved when a timber beam was added beside it.
Each shell now integrates by its own material's rule ([shell model](../../shell-model.md)): models
without timber shells are unchanged to the bit, and mixed ones, as the terraced row's brick walls
beside its timber floors, move a little. A joint's friction exponent must also now be below 1,
where its friction force still grows with pressure (the neoprene pad's is 0.20).
