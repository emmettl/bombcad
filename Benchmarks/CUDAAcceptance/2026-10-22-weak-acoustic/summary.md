# Weak acoustic phase diagnostic — 2026-10-22

Tracking: emmettl/bombcad-work#62, supporting emmettl/bombcad-work#63.

## Result

All 36 predeclared GPU runs complete stably. The 18 plain/observed pairs match exactly on
initial/final complete coarse state and recorder hashes, selected records, step counts and
times. All nine full-grid/tiled pairs also match exactly on those observables. Every recorded
history has a single compatible fused Float32 replay. All 36 receiver histories close and
have the same closing sample and Double impulse under the offline and streaming definitions.
The prior three-phase analytical counterexample remains; this two-pulse case does not rule
out that limitation.

There is no new phase rule or CUDA admission. The 1 Pa impulse errors are nonmonotonic under
refinement, and the finest wall-cell peak remains 6.14% below the linear reference. At 10 and
100 Pa, impulse errors decrease much more consistently. No gate is fitted to these results.

## Fixed setup and reference

[The plan](plan.md) was posted before any numerical run. A compact bipolar pulse starts at
x=8 m and travels toward a rigid wall at x=0 in ideal gas: p0=101325 Pa, rho0=1.225 kg/m³,
gamma=1.4. The 16 m domain has open x-max and reflecting transverse faces, with ny=nz=1.
A=1/10/100 Pa and nx=128/256/512. The diagnostic uses the bare numerical core, with no
charge, afterburning, cooling, gravity or mapped start. Tiling is an explicit per-case choice;
no application default changes.

For c=sqrt(gamma p0/rho0), let f(s)=-A sin(pi s) on |s|<1 m and zero elsewhere.
The independent linear-acoustic solution is p'(x,t)=f(x+ct-8)+f(ct-x-8), with velocity
[-f(x+ct-8)+f(ct-x-8)]/(rho0 c). It satisfies zero normal velocity at the rigid wall.
Initial density is rho0+p'/c². The run ends at 14/c s, after both pulses pass the far gauge.
The direct positive impulse is 2A/(pi c). At the wall-cell centre x=dx/2, the overlapping
reflection has peak 2A cos(pi x) and first positive impulse 2A[1+cos(pi x)]/(pi c).
The closed-form implementation deliberately exposes only the separation/overlap regimes
used by the diagnostic; CPU tests independently check travel, wall velocity and impulse
by midpoint quadrature.

These are exact **linear** acoustics, not an exact finite-amplitude compressible Euler
solution, experimental blast data or a validation of local 3-D reflections. Finite amplitude,
Float32 primitive-to-conserved initialization, background-pressure subtraction and spatial/time
error all remain possible contributions. The initial host-projected pressure differs from the
analytic initialization by up to 0.00387 Pa across the fixed matrix; that alone does not explain
the later error. The report does not assign a cause without another controlled experiment.

## All full-grid results

The tiled numbers are identical. Peak means the whole-window maximum at each gauge; first
impulse uses the current recorder. The far gauge is the cell centre just above 4 m; the wall
gauge is the first cell centre, whose exact x changes with resolution. Each comparison uses
its own physical centre in the analytic reference. Signed percentages are (measured/reference−1).

| A (Pa) | nx | x≈4 peak error | x≈4 impulse error | wall-cell peak error | wall-cell impulse error |
|---:|---:|---:|---:|---:|---:|
| 1 | 128 | -18.750% | -3.222% | -25.920% | -10.124% |
| 1 | 256 | -6.250% | 0.333% | -8.151% | -0.099% |
| 1 | 512 | -3.125% | -0.685% | -6.137% | -0.962% |
| 10 | 128 | -20.391% | -3.483% | -27.952% | -10.000% |
| 10 | 256 | -6.797% | -0.136% | -9.251% | -0.351% |
| 10 | 512 | -2.578% | -0.051% | -3.165% | -0.108% |
| 100 | 128 | -20.273% | -3.345% | -27.816% | -9.549% |
| 100 | 256 | -7.063% | -0.124% | -9.494% | -0.132% |
| 100 | 512 | -2.508% | -0.050% | -3.258% | -0.011% |

This is three resolutions, not a demonstrated asymptotic error bound. The 1 Pa impulse error
changes sign at the middle resolution and worsens again on the finest grid. Agreement between
tiling paths cannot turn common numerical error into physical validation. CUDA has not run
this diagnostic; it is Metal ideal-gas evidence only. The recommended hot-air/terrain product
regime, three or more qualifying phases, larger geometry and the existing failed acceptance
receivers remain outside this experiment.

## Evidence and reproduction

- [Frozen producing source/runtime receipt](pinned-runtime-and-sources.json): 547 files / 34,847,058 bytes
  copied and rehashed on StudioData after the runs, before another build could replace them.
- [Source/executable/raw receipts and all per-receiver metrics](results.json).
- [Controller](run.py), [read-only audit](audit.py), [audit log](audit.log), [controller log](controller.log).
- [Archive receipts](archive.json): all 57 raw files, 4,765,696 bytes, reproduced exactly from
  gzip copies under `evidence/` (497,864 compressed bytes). Every raw input/output is retained;
  no selected passing subset or rerun replaces an outcome.
- [CPU reference tests](cpu-tests.log), [release build](release-build.log).

Raw results are also at `$BOMBCAD_DATA/experiments/2026-10-22-weak-acoustic`. To run a fresh
matrix, build `blastbench` in release, reserve the GPU, and choose a nonexistent output:

```sh
~/.local/bin/gpu-slot --mem 2 .build/release/blastbench acoustic-phase --rounding default --out NEW-DIRECTORY
```

The controller uses the fixed dated scratch path and refuses an existing directory. Replaying
an archived outcome requires no GPU: decompress the archive copies into the same raw layout
and use the audit with the corresponding source checkout and frozen executable/resources.
The audit verifies the raw receipts and frozen original source/executable hashes rather than silently
using another binary. Producing revision is the recorded dirty candidate on f6554fd1;
the public commit will contain that candidate. Compatible arithmetic is not emitted-instruction
attestation. Hash parity is an observable control, not proof of every unobserved intermediate.

No solver/shader/default, label, mask, tolerance or training-index change. The experiment is
not a quiet throughput benchmark. The one owned GPU controller and its process group are
terminal; the cooperative slot is released.

Validation: format/lint pass; [strict build](strict-build.log) has no warnings.
Plain [make check-affected](check-affected.log) passes the covered selection, including
62 PC Linux tests in 11 suites (both acoustic reference tests), selected Mac suites,
script checks and documentation checks. Both expected destination [refusals](refusals.json)
exit 1; a fresh raw-file audit after them confirms the original matrix is unchanged.
The first Python syntax check hit the sandbox's default bytecode cache location; it passed
with a scratch cache prefix. No scientific run failed or was replaced.
