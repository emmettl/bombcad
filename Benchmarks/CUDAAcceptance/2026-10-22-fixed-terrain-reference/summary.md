# Fixed terrain references remove the slope failures; one Beirut phase failure remains

22 October 2026. emmettl/bombcad-work#62 and emmettl/bombcad-work#63 remain open.
Bulk CUDA generation stays gated under emmettl/bombcad-work#39 and
emmettl/bombcad-work#47. No acceptance tolerance changed.

Release `scenebench` rebuilt from main `c78451c0` containing `aff21dff`.
Fresh production Metal references use the mapped start on slope and Beirut.
All three CUDA jobs run once from those exact captured initial physical buffers,
with the unchanged generated source and frozen workers. Every numerical worker
completes successfully; all three outcomes are retained.

| Pilot | Original failures: peak / total / first-phase | Fixed-reference failures: peak / total / first-phase | Existing gate |
| --- | --- | --- | --- |
| Flat `made-perimeter-s1-1` | 0 / 0 / 0 | 0 / 0 / 0 | pass |
| Slope `made-perimeter-s3-1` | 0 / 0 / 2 | 0 / 0 / 0 | pass |
| Beirut `beirut-p0-1` | 3 / 0 / 3 | 0 / 0 / 1 | fail |

Features and masks are byte-identical between each fresh reference and candidate.
Flat reference inputs/mask/targets are also byte-identical to the old reference;
slope/Beirut inputs/masks agree while their reference targets change. The new
results establish agreement with corrected-main Metal, not physical validation
or a causal isolation of every change since the original pilot.

The remaining Beirut failure is first-phase impulse at row366/column355,
row-major index187747 on the 512×512 output:

- Metal: 1696.1177978515625 Pa s.
- CUDA: 1514.2877197265625 Pa s.
- Absolute error: 181.830078125 Pa s.
- Original permitted error: 3.4422355957031248 Pa s.
- Excess above that gate: 178.38784252929688 Pa s.

[results.json](results.json) retains every failed value, location, comparison
statistic and consumed-file pin. The gate remains exact numeric features/masks
and `abs(error) <= 0.05 + 0.002 * abs(reference)` at every valid target. A reduced
failure count does not admit the remaining rejected value. These three cases do
not establish a new portability contract or waive gates on future cases.

## Packaging failure and controlled saved-output recovery

The initial-state diagnostic exports physical buffers but omits the dataset
metadata/templates added by `--cuda-job`. The runner incorrectly assumed that
`out/dataset` would therefore be written. All three numerical workers completed;
retrieval then failed before any comparison. [retrieval-failure.log](retrieval-failure.log)
and the original stale run receipt are preserved rather than rewritten. No Metal
or CUDA simulation was rerun to obtain an accepted result.

The existing worker also writes raw peak/total-impulse planes, first-phase plane,
native-valid mask, dt and result provenance. The separately predeclared
[recovery plan](recovery-plan.md) reconstructs the dataset using that same rule:
stack saved Float32 planes and zero only the original template-excluded pixels.
No valid candidate value is changed. Three earlier dataset-mode CUDA jobs are
controls of packaging only; their balloon-start targets are never the new reference.

Every control reconstruction is whole-array Float32-word-identical to the actual
worker-written dataset. Its original template features/mask match the fresh
Metal bytes, and its receiver columns match the new physical job byte for byte.
Every selected template pixel is native-valid. All three controls pass before
any current target is scored. Source/worker hashes, actual mapped start times,
all transferred input hashes and result provenance are checked.
[assembly-results.json](assembly-results.json) and [cuda-results.json](cuda-results.json)
retain the controls and actual worker reports. The versioned
[auditor](audit-targets-recovered.py) independently checks the recovery proof and
every per-value failure. Its [hand-calculated controls](recovered-auditor-controls.json)
retain exact/next-Float32 boundaries, masked errors, negative references and
changed-feature refusal. These synthetic checks are not numerical CUDA evidence.

All remote outputs, including full-state binaries, are inventoried by size/hash;
full-state files stay at their recorded PC job paths. Complete local raw data is
under `$BOMBCAD_DATA/experiments/2026-10-22-fixed-terrain-reference`. The first
80-minute lease-only timeout, its complete verified archive, the second queue,
failed retrieval and recovered outputs remain distinct records. The final archive
retains every outcome; numerical NPY/BIN arrays and runtime/input geodata stay
external by kind. See [checkpoint.md](checkpoint.md) for earlier checkpoints.

## Decision and next work

The fixed-reference prerequisite is complete. Slope and Beirut peak comparisons
improve, but Beirut's remaining first-phase failure prevents reopening bulk CUDA
generation. Record it on emmettl/bombcad-work#62; preserve the fixed-reference
peak pass on emmettl/bombcad-work#63 while its broader numerical/product contract
remains open. Diagnose the remaining receiver against these corrected inputs;
do not reuse the old balloon-start history or relax the target gate.

Under the user's explicit "if they persist" branch, resume the already paused
read-only CPU audit in emmettl/bombcad-work#80 / emmettl/bombcad-work#82. Its
idealized one-dimensional waves have no shaped-terrain charge initializer; keep
that scope separate from this production acceptance result. Resume its existing
owned process, rather than rerunning its completed 432-command producer. No
numerical default, label, tolerance, mask, training index, service or dataset
admission changes in this stage.

The forward runner now attaches the missing templates before deployment.
[CPU preflight controls](template-controls.json) validate all three copied real
physical jobs with the frozen job validator before and after attachment. Every
physical descriptor field and buffer hash remains unchanged, as do features and
masks; uncomputed templates remain marked unstable. An unstable reference is
refused before writes. No solver is run by these controls. Their raw data is at
`$BOMBCAD_DATA/experiments/2026-10-22-fixed-terrain-reference-template-controls`.

The complete final local archive retains **958 files /2,190,468,920 bytes**; every decompressed
member and original file was independently rehashed. Its compressed size is
168,171,775 bytes at `$BOMBCAD_DATA/experiments/2026-10-22-fixed-terrain-reference-archive/all-raw.tar.gz`.
All **822 metadata files /2,839,157 compressed bytes** are public in
[evidence/pilots-metadata.tar.gz](evidence/pilots-metadata.tar.gz), selected by
kind rather than outcome. [pilot-archive.json](pilot-archive.json) records every
local file and the separately retained remote full-state scope.

Required format/lint, warning-free Mac strict build and plain `make check-affected`
pass, including the selected Mac suites and 62 PC tests/11 suites, scripts,
reference tests and documentation checks. All 958 raw files, both final archive
hashes, consumed auditor inputs and tested packaging/auditor sources still match
after verification. [publication-checks.json](publication-checks.json) records the
scope; this is not an unchanged ordinary-digest claim for unrelated solver work.
