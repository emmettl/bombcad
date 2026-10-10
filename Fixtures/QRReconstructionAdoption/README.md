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

## Actual source-bound capture

`bash Scripts/check-qr-reconstruction-adoption.sh OUTPUT` runs from a clean
committed candidate. It prepares complete original production source with exact
alpha.16 and current shared source with exact alpha.19, compiles both optimized
standalone CPU captures, retains their exact pins/compiled source/passive binding
recipes and verifies all complete native data. No app target or UI is linked.
Reversing the hooks restores byte-identical arithmetic and control flow.

The 191-case cohort contains 143 conserved reconstruction cases and 48 scalar
reuse cases: dense/translated/rotated inputs, two boosts, neighbour reversal,
volume-aware/point and quadratic/linear requests, sparse/rank fallback, a near-rank
ring, extreme scales, constant/far-control/positivity cases and seven invalid inputs.
Each scalar case solves five distinct actual RHS using one Stencil and then repeats
the primary. Conserved cases exercise the real five-component path, including
constant-component skips. Complete original/shared captures each retain 178 actual
stencils, 734 solves, 680 component results, 3,390 limiter updates, every short-circuit
admissibility probe and 192 actual backoff steps from four 48-step reductions.
Both preliminary variants pass independent full policy replay; that is not yet a
completed two-host adoption gate.

References independently reconstruct rotated native volume nodes/moments/averages,
distance multipliers, weighted basis and exact-native least squares, mean restoration,
frame transforms, original-data constant thresholds, component/sample factors,
all backoff intervals/branches, inverse lab states/EOS and volume inventories.
The exact QR reference helpers are retained from immutable Core alpha.19 with hashes.
Chosen coefficient bounds depend on exact-native conditioning; they are not a
blanket arbitrary-input forward-error guarantee. Original solve conformance to its
actual stored factors is checked separately from exact least-squares accuracy.

The ring at `delta=1e-10` is a recorded cutoff boundary: its exact final pivot ratio
is `1.0000000000000002e-10`, only about `1.3e-26` above the floor, while the floating
factor may reject. The verifier retains exact pivot ratios, actual acceptance and
a selected absolute pivot-norm roundoff envelope `64 eps max(m,n) ||A||F / initialNorm`.
This does not change the production `1e-10` floor or certify mathematical rank.
It separates boundary ambiguity from rejected ordinary supported inputs, then
verifies the actual chosen fallback and full downstream policy. All such findings
remain visible. Reported internal-energy decisions are checked against exact native
inputs and their recorded rounded energy; a near-boundary floating predicate is
not silently substituted with an ideal-arithmetic comparison.

Deliberate coherent corruption must reject for inputs, factors, RHS reuse,
coefficients with every prediction, means, frame/threshold/limiter/backoff/EOS,
source bindings and dependency pins. The bounded physical-mini suite is
`qr-reconstruction-adoption`; full application/coupled history and packaging gates
remain separate required work before this draft can merge.
