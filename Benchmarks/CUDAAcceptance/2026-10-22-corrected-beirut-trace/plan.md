# Corrected Beirut receiver diagnostic — 22 October 2026

Tracking: emmettl/bombcad-work#62; related emmettl/bombcad-work#63.

The corrected-reference pilot retains one first-phase failure at index187747,
row366/column355. Metal1696.1177978515625 versus CUDA1514.2877197265625 Pa s
exceeds the unchanged allowance3.4422355957031248. Trace this receiver only,
with the exact frozen c78451c0 runtime and physical inputs already used in
[acceptance](../2026-10-22-fixed-terrain-reference/summary.md). Do not use old
balloon-start histories as the reference.

Predeclare two Metal commands: plain plus state hashes; consumed-pressure
recorder plus state hashes. Both use shared gpu-slot, unchanged ordinary
arithmetic/tiling, the original field arguments, fresh output folders and no
initial-state re-export. Require all dataset array bytes identical to the
accepted baseline, and paired complete coarse initial/final diagnostic state
hashes identical before interpreting the recorder. Report the actual hash scope,
which excludes refinement and structural state. Verify every frozen runtime and
input file before/after. A failure stops interpretation; retain the failed run.

Predeclare one CUDA command from the same captured physical initial buffers,
unchanged source/worker and normal shared PC lock, adding only the existing
receiver trace. No automatic retry or lock bypass. Require every original remote
numeric output and dt file byte-identical, with trace.npy the only extra numeric
file. CUDA pressure is recomputed by its existing read-only diagnostic kernel;
it is not a direct attestation of the pressure consumed by the production
kernel. Preserve this distinction from Metal's consumed-pressure recorder.

Reuse the frozen phase replay auditor. Report seeded recorder state, physical
start/time axes, closure/open transitions, first divergent phase decision and
final values. Do not align unrelated step indices across backends. Any offline
pressure substitution is a conditional replay, never an actual CUDA pass or
proof of an instruction-level cause. Retain every numerical/refusal outcome.
Raw files go under `$BOMBCAD_DATA/experiments/2026-10-22-corrected-beirut-trace`;
all existing baseline evidence remains immutable. No benchmark claim, tolerance,
phase rule, mask, label, training-index, default, service or admission change.
