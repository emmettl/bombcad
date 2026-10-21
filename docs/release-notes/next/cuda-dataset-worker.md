kind: added

**Generate uniform-grid training targets on an NVIDIA PC.** `scenebench field-export
--cuda-job --cuda-source generated.cu` exports the actual initial air, fixed obstacles,
species and receiver histories. `Scripts/cuda/remote.py` deploys the production-derived
CUDA kernels over SSH and returns compatible training arrays. Hot air, afterburning and
recommended radiative cooling are retained. Unsupported physics is refused, including
refinement, terrain and moving structures. This is an optional data-generation worker;
the app's Metal solver and defaults are unchanged. See [the CUDA backend](../../cuda-backend.md)
for the measured comparisons and limits.
