# First-phase raw pressure inputs — 22 October 2026

Tracking: emmettl/bombcad-work#62; related emmettl/bombcad-work#80.

The corrected Beirut receiver187747 closes in CUDA on−0.0078125Pa while nearby
Metal pressure remains positive. Its gas is thermally perfect (airModel1).
Capture actual pressure inputs to evaluate fixed wider-arithmetic counterfactuals;
do not infer an ideal-gas pressure or change phase semantics.

Freeze an artifact-only copy of the accepted CUDA worker and generated physical
source. Append one read-only diagnostic kernel, preserving the existing eight
trace fields, that records each column descriptor, native interpolation weights
and both physical Cells (16 Float32 words). No production source/worker changes.
Use immutable initial jobs and fresh remote output folders. Run once each:
fixed flat made-perimeter-s1-1 at62902, fixed slope made-perimeter-s3-1 at134058
and250097, fixed Beirut beirut-p0-1 at187747. All selected columns are valid in
the unchanged masks. Use the existing shared PC lock, preserve refusals/failures
and do not retry automatically or bypass another job. Bound commands to80min.

Require every original remote numeric file and dt byte-identical, with only
trace.npy and pressure-inputs.npy added. Verify complete worker/physical/diagnostic
source hashes. Require exact native recorder replay, constant column words and
weights, and initial/final captured-cell words equal the corresponding full
input/output states. Beirut's eight-field trace must also equal its preceding
accepted corrected-input diagnostic. Do not interpret raw inputs on any failed
gate; retain every case and failure. No quiet throughput claim.

Before scoring, test a scalar Double thermally perfect evaluator against an
independent monotone bisection of the same rounded-parameter energy relation,
covering1–60000K and multiple densities. Use the frozen source's Float32-rounded
constants, rational guess and one Newton step. Also retain the independent-root
evaluation. Two fixed interpolation policies: captured native Float32 weights
promoted toDouble, and exact Double weights from the represented column fraction.
Do not choose a policy per sample or fit thresholds to the rejected receiver.
Refuse unsupported gas models; ideal gas may be an analytic control only.

Evaluate all captured samples/columns under both temperature evaluators and both
weight policies. Report their pressures and conditional recorder outcomes with
unchanged Float32 accumulation/zero-crossing rules, starting from the actual
initial recorder/open buffers, including the initial sample. First require this
seeded replay reproduce every native recorder value using native pressures.
Wider evaluation of rounded CUDA inputs is a conditional numerical comparison,
not continuum truth, a Metal-state observation, a new CUDA pass or a physical
phase definition. No source-state, phase, label, tolerance, mask, training-index,
default, service or admission change. Bulk CUDA generation stays gated.

Archive every own raw file and verify every member. Arrays/runtime dependencies
remain external by kind, never by outcome. Preserve the original fixed-reference
and corrected-Beirut evidence. Existing issue scope covers the next work; no
duplicate tracking issue.

Fixed math-control limits before scoring: source-Double temperature versus the
independent bisection root must agree within1e-8K +2e-8*|T| over the declared
control temperatures. The root must recover generated temperatures within
1e-8K +2e-14*|T|. These are evaluator controls, not dataset admission tolerances.
Arithmetic is widened after promoting source Float32 literals (including the
rounded1/3000 factor); Double products are not claimed to emulate native compiler
constant folding. Both evaluators and both weight policies are retained.
