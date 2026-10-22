# Transparent host-source observer: implementation gate passed

22 October 2026. Tracking: emmettl/bombcad-work#82 remains open and claimed;
parent emmettl/bombcad-work#80. Scientific component attribution remains pending.

The host-side alternative passes focused and optimized transparency controls.
It observes actual conserved source-cell and residual words without changing the
existing GPU update-observer program. This succeeds where the rejected
full-intermediate observer changed outputs. It does not observe GPU primitives,
slopes or predicted faces, and is not yet the planned scientific matrix.

## Capture and safety contract

`configureSweepUpdateDiagnostics(..., captureHostSources: true)` requires an
existing compensated bare unmasked 1-D ideal-gas experiment, copied open faces
and no periodic sides. The configured x-wall mapping must remain fixed. Existing
physical/source/charge/reaction/geometry restrictions are rechecked before reads.

The host read occurs only inside blocking advance, after the preceding command
buffer has completed and before the next part is encoded. Positive blocking
advances require no preexisting in-flight batch; zero-step calls retain their
previous no-op behavior. The public withState API is not used mid-batch. Source
words are read from host-visible current state/residual buffers; no new encoder,
shader store, GPU binding, uniform or logical batch is introduced.

Each selected index retains M2/M1/C/P1/P2 physical indices and ghost velocity
signs as mapping metadata, plus five conserved UInt32 words and four residual
UInt32 words per physical source cell. Arrays contain untransformed physical
state, not fabricated ghost primitives. Source-centre state and residual words
must equal the actual old-state/residual GPU update words on every executed
sample. The getter refuses incomplete/asynchronous, overflowing or misaligned
histories. Restart discards capture. Tiled skips retain real host source reads
but keep the GPU's executed=false/zero update slots; host reads are not evidence
that a skipped GPU operation ran.

Source arrays are **before** the update; their shared step/time/dt keys identify
that update's completion. Component models must not compare pre-step pressure
with the post-step native receiver value. Existing 24/33-word traces are unchanged.
[gpu-source-identity.json](gpu-source-identity.json) verifies byte identity of
shader assembly, the entire update-shader generator and ordinary .metal files
against baseline d2ebdf4e. This is source/program-selection evidence, not emitted
machine-code or continuous runtime attestation.

## Verification

All 24 default/unfused × density/energy/both × retain/no-carry × full/tiled
focused combinations preserve four-mode complete state/residual/recorder hashes,
steps/clocks, native pressure histories and every existing GPU trace word.
All paired full/tiled outcomes match. Physical neighbor words and reflected/copy
ghost maps pass with either high-wall setting. Skip, overflow, unsupported scope,
asynchronous-history refusal and zero-step behavior controls pass.

The final optimized-release run passes all nine test methods across the new
host-source, compensated-update and existing update-diagnostic suites. The
initial optimized run is retained separately; final source adds the explicit
zero-step compatibility check before repeating optimized verification.

A frozen one-case CLI integration control runs **A100 Pa/nx128/full/default/
CFL0.45/both-retained**, outside the planned fine-grid matrix. All four modes
complete in 252 steps. All physical snapshot/hash/record/time fields agree,
all three pressure-trace files are byte-identical, every 33-word GPU update row
matches, and all serialized source centres match actual old-state/residual words.
Source shape is [252,6,5,5], residual shape [252,6,5,4]. Three invalid flag
combinations exit 1 before creating output directories. All four controller
children are terminal with no owned descendant group left alive.

`--trace-source-stencils` requires `--trace-updates` and `--compensated`. It adds
a fourth `sources` snapshot, `source-pressure-trace.json` and separately versioned
`source-stencil.json`, preserving the original three output names and headers.
The source file declares canonical UInt32 field order, physical indices, ghost
signs and retained configuration. [cli-control-results.json](cli-control-results.json)
records every control command and parity outcome. These are serialization and
transparency checks, not a weak-wave accuracy assessment or a model calibration.

The control froze 529 selected source/helper files and 31 executable/resource
files before execution. Every original/snapshot/runtime hash still matched
afterward. All 578 raw files /39,497,810 bytes are archived and every decompressed
member independently verified (12,119,055 compressed bytes) at
`$BOMBCAD_DATA/experiments/2026-10-22-host-source-cli-control-archive/all-raw.tar.gz`.
All 547 non-runtime files are public in [evidence/cli-control.tar.gz](evidence/cli-control.tar.gz)
(2,332,720 bytes), including complete output arrays and frozen source. Runtime
binaries/resources remain external by kind, not passing status.
[archive.json](archive.json) retains all hashes. This selected source/executable/
resource freeze is not a hermetic operating-system/driver/Python environment.

Reported held GPU buffers are 13,952 plain, 14,592 pressure-only and 15,896 bytes
for either existing updates or host-source mode in this control. The new source
words add 272,160 nominal CPU data bytes, excluding array/JSON/allocator overhead.
This is not total process memory or a quiet throughput result; host reads and
serialization add work. See [memory-observation.json](memory-observation.json).

Final required format/lint, warning-free strict build and plain make
check-affected pass: 280 selected Mac tests/59 suites and 128 PC tests/36 suites.
All 42 ordinary digest variants in six sets are bit-identical to baseline
d2ebdf4e. [publication-checks.json](publication-checks.json) records log hashes
and scope. All 529 source originals, 31 runtime files, 578 raw control files and
archive hashes still match afterward; GPU source identity is rechecked.
Implementation tests alone do not establish scientific coverage.

## Remaining work

[component-plan.md](component-plan.md) specifies the parser and independently
checked local operator models needed before freezing a 432-group/1728-export
scientific matrix. All original amplitudes, policies, selectors, retention,
resolutions and tilings remain in scope, including adverse outcomes and exact
prior-wave gates. Those scientific exports and component analyses have **not run**.
Recomputed primitive/limiter/predictor/flux values must be labeled counterfactuals,
not observed GPU intermediates or independently evolved PDE solutions.

The remaining peak mechanism is unresolved. No numerical default, phase target,
label, acceptance tolerance, mask, training index, service, general geometry/
refinement/checkpoint support or CUDA admission change. emmettl/bombcad-work#82,
emmettl/bombcad-work#80, emmettl/bombcad-work#62, emmettl/bombcad-work#63,
emmettl/bombcad-work#59 and emmettl/bombcad-work#47 remain separately gated.
