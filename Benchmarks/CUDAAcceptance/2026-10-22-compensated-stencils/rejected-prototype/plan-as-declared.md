# Actual stencil diagnostic — implementation plan, 22 October 2026

Tracking: emmettl/bombcad-work#82 remains open and claimed by session
01a15d45-56b9-75e2-b7fa-3136c2ed5405.

This supersedes the preceding saved-history stage's proposed 150-word layout.
Source inspection shows slope() initializes rho, three velocity components and
pressure only. Its gamma member is neither initialized nor consumed by the
predictor. Never capture that undefined value or fabricate it as an actual
quantity. The actual initialized-state layout therefore has 147 words:

- Existing 33 update/residual words, unchanged as a prefix.
- 25 underlying source conserved-state words (M2/M1/C/P1/P2).
- Four actual from offsets and four mirror signs for ghost mapping.
- 30 actual primitive words (five × rho/vx/vy/vz/pressure/gamma).
- 15 actual limited-slope words (three × rho/vx/vy/vz/pressure).
- 36 actual predicted face words (six × rho/vx/vy/vz/pressure/gamma).

Generate opt-in sibling functions from the actual production sweep and stencil
operator. Added locals are the same values consumed by reconstruction and flux
calls, not a separately recomputed observation. Preserve ordinary .metal source,
Cell/uniform ABI, 24/33-field formats and defaults. Added stores can perturb the
compiler; require exact plain/pressure/old-update/stencil state/residual/recorder
and trace-prefix parity before interpreting results. Keep the six prior selected
indices and bounded complete/overflow/skipped-zero controls. Test physical-source
ghost maps and mirrored/copied primitive relationships.

The CLI adds explicit --trace-stencils only with --trace-updates and
--compensated. It exports four distinct observation modes and filenames. The
intended scientific matrix retains all 432 preceding component/retention/math/
CFL/amplitude/resolution/tiling groups, 1728 exports total, with all adverse
outcomes. No scientific export until verified sources, runtime/resources,
parser/component models, exact matrix and execution budgets are frozen. Compare
all four modes with prior wave outputs; no rerun or tolerance change to replace
a failed observation. Focused implementation controls are not scientific wave
accuracy evidence.

Independent Float64 and explicit Float32 component models must consume captured
identical inputs. Compare primitive conversion, limited slopes, predicted faces,
HLLC fluxes and rounded update/storage stages separately. Retain whole-stage
arithmetic compatibility policies and all failures; no per-scalar passing-model
selection or emitted-instruction claim. Local counterfactuals are not evolved
PDE solutions. No alternative algorithm, default, target, label, tolerance, mask,
training-index, service, geometry/refinement/checkpoint support or CUDA admission
change is part of this diagnostic implementation.
