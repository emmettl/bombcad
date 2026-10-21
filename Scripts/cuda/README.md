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
  --dataset /Volumes/StudioData/bombcad/ml/datasets/main-fp-cuda \
  --scratch /Volumes/StudioData/bombcad/cuda-dataset-backend/field-batch \
  --reference /Volumes/StudioData/bombcad/ml/datasets/main-fp \
  --scenebench .build/release/scenebench
```

Use `--only id,id` or `--limit N` for pilots. Initial states use compressed SSH transfers.
`remote.py --dataset-only` retrieves training arrays and provenance while retaining raw fields
on the PC. The batch keeps a per-case comparison and deployment receipt beside `dataset.json`.
Its comparison requires exact features and masks and the existing per-value target gate
(`0.05 + 0.002 * abs(reference)`); it does not establish agreement with physical measurements.
