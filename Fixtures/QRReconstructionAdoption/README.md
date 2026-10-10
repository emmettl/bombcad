# Protected original reconstruction source for alpha.19 adoption

These complete snapshots come from BombCAD remote checkpoint
`b7d86c445d7aa40ed63bab1562e9c956b1c5c31e`, before replacing its private QR.
`source.json` records exact Git blob and SHA-256 identities. The pressure fit,
conserved reconstruction and pressure-fit tests match Core's original weighted
QR audit; the conserved tests and actual packet alias are additionally retained.
These original arithmetic/policy identities must remain immutable.

The application candidate adopts exact Core alpha.19 and replaces only the private
three/nine-column factors and solve calls with `Numerics.PivotedQR`. The existing
mean-free basis, distance multipliers, means, quadratic/linear/constant fallback,
component/frame/limiter/EOS policies remain application-owned. The relative pivot
floor is still explicitly `1e-10`; safe factorization can intentionally change
coefficients and cutoff decisions near degeneracy.

The first local focused run passes eleven existing pressure/reconstruction tests.
That checks compilation and their declared contracts; it does not complete the
adoption gate. Complete original/shared native source-bound captures of actual
Stencil reuse, all five conserved components, bounds, frame/threshold decisions,
backoff and lab-frame EOS are still required, with independent references,
coherent corruption controls, affected coupled histories, both physical-host
application/package checks and durable full portable replay.

The [bounded adoption plan](https://github.com/emmettl/ContinuumKit/blob/main/docs/extraction/BOMBCAD_QR_ADOPTION_PLAN.md)
defines that scope. Do not replace it with an old/new coefficient match, a narrow
test pass, or a global positivity/empirical pressure claim.
