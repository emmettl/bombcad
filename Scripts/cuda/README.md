# CUDA worker tools

See [the backend documentation](../../docs/cuda-backend.md) for supported physics, deployment,
accuracy measurements and limits.

- `generate.py`: generate CUDA and optional matched Metal reference source from production.
- `compile.py`: compile with the current Python environment's existing NVRTC library.
- `run.py`: execute a validated exported job and write raw states plus training targets.
- `remote.py`: deploy, run under the PC's shared training lock, and retrieve results over SSH.
- `job.py`: CPU-only job validation, scalar ABI and checksums.
- `fixtures.py`: synthetic acceptance jobs; no NumPy/GPU needed to generate them.
- `metal-reference.swift`: standalone matched Metal acceptance runner.
- `compare.py`: complete-field comparison with explicit per-value tolerances.
- `compare_dataset.py`: end-to-end production training-array comparison, checking masks/features.
- `test_backend.py`: contract and negative-control tests, included in `make ci-test`.
- `smoke.py`: initial still-air kernel-launch smoke test, not an acceptance gate.

The Mac and PC test the same generated source hash and input buffers. Reference files and large
outputs belong in external scratch storage and are not committed. A returned `dataset/meta.json`
marks completed training data; a job template's `stable: false` does not.
