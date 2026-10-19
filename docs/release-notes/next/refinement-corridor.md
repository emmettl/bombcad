kind: added

**Refinement confined to chosen regions, and a corridor to one building.**
`SolverConfiguration.refinementConfinedTo` refines the air only inside the boxes it lists. On
Beirut's 1 km box, `scenebench district-compare --corridor x,y` refines a corridor from the charge
to one building. That gives the fully refined run's answer for the building at 2–9% of its refined
work, and about a third of its GPU time. Steering a whole district by the buildings whose outcome
the coarse cells leave in doubt (`--steer`) saved nothing, because those buildings fill a domain
drawn to the damage's reach. Refining only beside a building read its façade lower than coarse
cells ([refinement steering](../../refinement-steering.md)).
