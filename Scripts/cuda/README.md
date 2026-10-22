# CUDA worker tools

See [the backend documentation](../../docs/cuda-backend.md) for supported physics, deployment,
accuracy measurements and limits.

- `generate.py`: generate CUDA and optional matched Metal reference source from production.
- `compile.py`: compile with the current Python environment's existing NVRTC library.
- `run.py`: execute a validated exported job and write raw states plus training targets.
- `remote.py`: deploy, run under the PC's shared training lock, and retrieve results over SSH.
- `field-runs.py`: resume the 200-case first-phase plan on a PC, checking every case against a
  Metal dataset. Stops on a failed comparison; only accepted cases enter the dataset index.
- `job.py`: CPU-only job validation, scalar ABI and checksums.
- `fixtures.py`: synthetic acceptance jobs; no NumPy/GPU needed to generate them.
- `terrain-fixtures.py`: reproducible made-up sloped/hilly DEMs for the sample neighbourhood.
- `metal-reference.swift`: standalone matched Metal acceptance runner.
- `compare.py`: complete-field comparison with explicit per-value tolerances.
- `compare_dataset.py`: end-to-end production training-array comparison, checking masks/features.
- `test_backend.py`: contract and negative-control tests, included in `make ci-test`.
- `smoke.py`: initial still-air kernel-launch smoke test, not an acceptance gate.

The Mac and PC test the same generated source hash and input buffers. Reference files and large
outputs belong in external scratch storage and are not committed. A returned `dataset/meta.json`
marks completed training data; a job template's `stable: false` does not.

For the planned first-phase dataset, with a built `scenebench` on the Mac:

```sh
python3 Scripts/cuda/field-runs.py bombcad-pc \
  --dataset $BOMBCAD_DATA/ml/datasets/main-fp-cuda \
  --scratch $BOMBCAD_DATA/cuda-dataset-backend/field-batch \
  --reference $BOMBCAD_DATA/ml/datasets/main-fp \
  --scenebench .build/release/scenebench
```

Use `--only id,id` or `--limit N` for pilots. Initial states use compressed SSH transfers.
`remote.py --dataset-only` retrieves training arrays and provenance while retaining raw fields
on the PC. The batch keeps a per-case comparison and deployment receipt beside `dataset.json`.
Its comparison requires exact features and masks and the existing per-value target gate
(`0.05 + 0.002 * abs(reference)`); it does not establish agreement with physical measurements.

For coordinated performance work, `profile-worker.py` compares two isolated worker files under
the shared GPU lock, alternates order, requires at least three repetitions and rejects any
change in full output arrays or timestep histories. `--fresh-process` includes Python startup.
`--candidate-cache-dir` enables a PTX cache only for the candidate. See
[heterogeneous compute](../../docs/heterogeneous-compute.md) for measurements and limits.

`remote.py --cache-dir bombcad-cuda/ptx-cache` optionally reuses compiled PTX. Cache keys include
the generated source, architecture, all compiler flags and the installed NVRTC/compiler-builtins
binaries. A missing, corrupt or mismatched entry is rebuilt and atomically replaced. The default
remains uncached. Worker reports now separate validation/imports, compilation, GPU setup/upload,
solve and validation/output wall time; deployment and retrieval remain outside those timings.

Numerical diagnostics: `trace_columns.py` derives a read-only pressure/recorder trace kernel;
`run.py --trace-columns i,j` enables it, and `remote.py --diagnostics-only --trace-columns i,j`
retrieves only histories and provenance. `diagnose-phase.py TRACE-DIR... --out NEW.json` reports
phase transitions, float32 replay and clearly labelled offline sensitivity experiments.
The standalone Metal reference takes the column list as its optional fourth argument and uses
source augmented by `trace_columns.py`. See the backend documentation for the controlled math
variants and the diagnosed near-zero label sensitivity. No acceptance tolerance changed.

Production observation uses `scenebench field-export --first-phase --trace-columns i,j`, without
new shaders or changed logical batches. Its `production-trace` format has recorder states and
accumulated fields, not recomputed pressure. `diagnose-production.py` compares exported arrays
and summarizes the actual production transitions; archived gzip traces require `--arrays` for
a fresh gate computation. `--full-grid-diagnostic` and `--all-tiles-diagnostic` on field-export
provide mutually exclusive controlled paths. No product defaults or acceptance rules change.

`field-export --initial-state-diagnostic NEW-FOLDER --cuda-source GENERATED.cu --first-phase`
also snapshots the actual portable physical state before stepping, then completes the ordinary
production export. The snapshot uses the existing CUDA job capability checks and format;
work-selection buffers are omitted. Its `initial-diagnostic.json` records the selected execution
path and requested math/contraction policies, which do not prove particular emitted instructions.
The folder must be new and outside `--out` (neither may contain the other); `--cuda-job` cannot
be combined with this option. Snapshot copying is included in the optional timing receipt's total,
outside its component phase intervals. These snapshots establish initial-state identity for
numerical controls; they do not provide final targets or dataset admission.

`math-matrix.py` runs explicit fast/safe × contraction-on/off × tiled/full production controls
from prepared field-run inputs. `--dry-run` plans without creating outputs; `--modes
 default-off,fast-default` runs bridge controls in a fresh root. Status completion is separate
from acceptance. Hashes and runner snapshots are retained; interruption terminates the owned
process group. See the backend documentation for the result and scope.

`reference-spread.py` describes whole-field variation across named reference outcomes while
reporting the original candidate gate unchanged. `phase-conditioning.py` performs offline
threshold sensitivity on archived pressure histories and includes analytic counterexamples.
Neither chooses a policy, changes targets or admits a dataset.

Cooling ray traversal/application now uses the positive-opacity box by default and skips empty
evaluations, while retaining the original clock/reset and numerical equations.
`--full-grid-cooling` on run.py/remote.py selects the old work for diagnostics.
`test_cooling_bounds.py` exercises CPU tensors in the PC PyTorch environment (no GPU needed);
the ordinary contract suite includes these tests and marks them skipped if PyTorch is absent.
Full-field/timestep paired evidence and scope are in the backend documentation.

Production Metal raw-cell observation adds `--trace-pressure --trace-pressure-inputs` to
`field-export --first-phase --trace-columns i,j`. It writes `pressure-inputs.npy` with
shape [samples, selected columns, 16]: column descriptor (4), interpolation weights (2),
then low/high cells (density, three momenta, energy). The matching JSON records column indices,
steps and physical times, including initialization. Independent host endpoint reads are written
to `pressure-input-endpoints.npy` ([initial/final, selected columns, 16]) for trace validation.
Indices flatten all export layers.
A separate read-only Metal library reads these words after the existing pressure producer;
its source and pipeline are unchanged. The paired pressure trace supplies the original recorder
seed and native pressure. `--trace-pressure-max-samples` bounds both traces; overflow refuses
complete readback. Verify ordinary arrays, state hashes and native trace parity on each new
control before interpreting raw inputs. These diagnostics do not change dataset admission.
