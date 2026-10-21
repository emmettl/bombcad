# Prepare-uniform reuse proposal — CPU feasibility only

Tracked by emmettl/bombcad-work#75 under emmettl/bombcad-work#60. This proposal is separate from
emmettl/bombcad-work#72's launch-size measurements and has not executed on the GPU or changed
the production worker. There is no performance or GPU-correctness claim.

The current worker computes and uploads a 276-byte prepare struct each iteration. The retained
emmettl/bombcad-work#71 blast64 trace records 590 pageable host-to-device transfers for both
baseline and graph labels, including setup/control traffic; that is not asserted to be 590
prepare uploads. The graph candidate intentionally kept per-iteration prepare allocation.

The proposed one-entry cache still computes every prepared struct with the original ramp math.
It compares the entire prepared byte sequence with the previous payload, reuses the immutable
GPU tensor only on exact equality, and otherwise allocates/uploads as before. Startup changes,
control copies and all kernels remain. The first allocation is lazy; trajectories with no
repeated payload do not get an eager extra prepare upload. The candidate is retained as a
patch for GPU validation, not installed as an optimization.

The CPU script checks repeated steady-state bytes for all six retained configurations and
1005 additional valid positive CFL bit patterns with NumPy 2.0.2. This establishes the byte
feasibility observed on this Mac, not buffer lifetime, device behavior, saved transfers or
complete worker speed. A full-byte cache also avoids assuming that CFL is the only possible
changed field. Device immutability/lifetime, actual cache miss/hit behavior, no-repeat/startup
and failure controls, full numerical/dt parity and quiet paired whole-worker/null comparisons
remain acceptance requirements in emmettl/bombcad-work#75.

Static source inspection also retains the const SolverUniforms pointer/reference in cudaPrepare and portablePrepare, whose body reads uniform fields while writing control/speed. This supports the read-only design; actual device/cache lifetime and full-output checks remain future GPU requirements.
