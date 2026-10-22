# Next stage: actual stencil observations (not executed)

Tracking: emmettl/bombcad-work#82 remains open. Saved histories bound pressure
projection effects but cannot identify a primitive/reconstruction/flux mechanism:
the existing trace contains only selected centre states and final face fluxes.
At wall column 0, for example, the source cells 1 and 2 are not in the selected
index set; at the interior receiver its neighboring source cells are absent.
Do not manufacture an unobserved five-cell history from the centre's values.

Proposed implementation stays within the existing guarded compensated 1-D
diagnostic. Add a separate explicit stencil-capture option and versioned format;
the existing 24/33-field traces, ordinary shader source/ABI and default paths
remain unchanged. Generate diagnostic siblings rather than editing ordinary
`.metal` functions. Capture the variables actually consumed, with canonical
UInt32 words and executed/skipped flags:

- The current 33 update/residual words.
- Five underlying source conserved states (five words each), the four existing
  `from` offsets and four mirror signs used to map wall/copy ghosts.
- Five actual `Prim` stencil values, including rho, three velocity components,
  pressure and gamma (six words each).
- The three actual limited slope `Prim` values and all six actual reconstructed
  face `Prim` values from the MUSCL-Hancock path.

That is 150 words per selected executed opportunity. Keep the existing six
selected indices so original selected-operation, boundary and continuity controls
remain available. Bounded allocation/complete-history refusal and skipped zero
slots still apply. No state or arithmetic probe may be accepted without exact
plain/pressure/old-update/new-stencil parity and matching preceding wave outputs.
Added stores can perturb compiler behavior; failure of that gate rejects the
observation, rather than justifying a tolerance change.

First implement focused source/layout/scope/overflow, ghost-mapping and paired
GPU controls. Freeze the verified executable, resources, source, parser/model
helpers and exact matrix before scientific exports. The intended scientific
matrix retains all preceding 432 retain/no-carry × arithmetic × CFL × component
× amplitude × resolution × tiling groups, with all outcomes and full/tiled
comparisons. Exact observation-mode counts and execution budgets must be fixed
in the runner before launch; this document authorizes no duplicate old run.

Use independent Float64 component evaluations on the captured identical inputs,
and explicit Float32 models where defensible. Separate primitive conversion,
limited slopes, predicted faces, HLLC fluxes, rounded flux differences/products
and compensated storage. Report whole-stage compatible arithmetic policies;
never pick a different passing model for each scalar. A compatible model is not
instruction attestation, and a local counterfactual is not a new evolved PDE run.
Only propose alternative algebra after the actual-stage evidence warrants it.

No numerical default, phase target, acceptance tolerance, mask, training index,
service, CUDA admission or general geometry/refinement/checkpoint support change.
