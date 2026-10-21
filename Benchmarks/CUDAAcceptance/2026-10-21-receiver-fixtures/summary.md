# Rejected receiver pairs on declared component fixtures

For emmettl/bombcad-work#62 and emmettl/bombcad-work#63, this study covers the receivers missing
from the prior product sample: three Beirut peak failures, three Beirut phase failures and two
terrain phase failures. Each point's peak and first-phase impulse is hypothetically applied
uniformly to a fixture. This does not turn point data into a credible area-averaged building load,
recover its pressure history, validate the physics or resolve the failed dataset gate.

## Declared experiment

Fixtures were fixed before observing responses, using ordinary existing panel/test dimensions:

| Fixture | Dimensions | Construction |
|---|---|---|
| RC wall | 6 × 4 m, 0.2 m thick | Ordinary concrete/default central reinforcement |
| RC roof | 6 × 4 m, 0.2 m thick | Same ordinary construction |
| Masonry wall | 6 × 3 m, 0.215 m thick | Unreinforced masonry, no requested arching |
| Glass pane | 1.5 × 1.25 m, 6 mm thick | Ordinary annealed glass assumptions |

All four edges are supported; the model's fixed/simple response ranges are retained where
applicable. Other construction defaults remain, including reinforcement ratio 0.003. These
fixtures are not tuned capacities or inferred structures at the receiver locations.

Each receiver has ten load pairs: default, duplicate default control, default full-grid,
four explicit fast/safe × contraction-on/off outcomes, CUDA, CUDA peak only and CUDA impulse
only. Eight points × ten pairs × four fixtures × two pulse policies = 640 assessments per
bin width. The bins are 0.2, 0.1 and 0.05 ms: 1,920 assessments per host. Rise share is fixed
at 0.2; arrival is zero. Raw-pair triangles use existing exact impulse-in-bin integration;
the product policy uses existing 3% peak/impulse rounding and rounded rise. No uncertainty
scatter, fitted load factor or strength adjustment is introduced.

`blastmodel receiver-fixtures` is CPU-only. Both Mac and Linux run the same declared JSON via
the existing sweep runner; the PC uses eight cores and its sweep lock, with no GPU reservation.
The three diagnostic tests verify raw impulse conservation (including limiting rise shares),
invalid/oversized-input refusal and existing-output preservation.

## Results and interpretation

Every requested assessment returns a damage result. Duplicate controls are identical. Raw
pulses conserve the declared impulse within the audit's `1e-9` relative threshold. No arithmetic
or CUDA substitution changes a fixture's damage-level range at any of the three bin widths.
The host results agree within the existing sweep comparison's `1e-9` numeric tolerance; this
is numerical CPU agreement, not physical validation or a measured throughput result.

Continuous response differences matter even without category changes:

- At Beirut column 255969, default versus full-grid product pulses move the masonry response
  from 0.40742° to 0.48703° at 0.05 ms: 0.07961°, or 19.54%. Both remain heavy, below failed.
- The largest rotation difference is 4.025° for Beirut column 164452 on the masonry product
  pulse at 0.2 ms (default 27.961° versus safe/on or CUDA 23.936°). Both are already failed.
  These post-failure rotations must not be interpreted as reliable collapse deformation.
- The largest failure-time shift is 3.6 ms in an already-failed masonry fixture (Beirut 159777,
  fast/on versus default raw pair at 0.2 ms). It is not a category flip.

Changing bin width produces no category changes here. Relative to the finest bin, maximum
rotation differences over all declarations are 0.01595° at 0.2 ms and 0.005251° at 0.1 ms.
These are observed bin-width sensitivities of assumed triangles, not a convergence proof,
time-step error bound or resolution study of the underlying fluid solution.

The original numerical failures remain. Declared healthy/failed fixtures away from a damage
threshold cannot establish safety for other capacities or constructions. The substantial
continuous masonry sensitivity means categorical agreement cannot justify treating all phase
labels as interchangeable. Independent weak/reflected/multiphase histories, justified label
semantics and a portability contract remain outstanding.

## Evidence and operational scope

`prepare.py` declares fixtures and extracts exact source pairs, masks and file hashes from the
previously retained Beirut/terrain fields. The archive includes every request, response,
source-pair mapping, sweep receipt and analysis. Full source fields remain in the preceding
product-portability and independent-portability archives. `analyse.py` checks source identity,
conservation, duplicate controls and all response comparisons. Actual local source pins and a
read-only post-run audit of 286 PC source files, three inputs and its producing binary are
retained. A post-run source snapshot is not continuous source observation.

Source transfer in the existing sweep runner occurs before acquisition of its host lock.
The study checked that the sweep was unowned before sending and coordinated the CPU work,
but this advisory check does not close the race. emmettl/bombcad-work#68 tracks isolated or
reserved staging and safe concurrent-controller tests. No concurrent mutation was deliberately
attempted against live work. The sweep lock was absent after completion; original run handles
completed successfully. There are no model-default, mask, phase-rule, tolerance, training-index,
GPU-runtime or host-service changes in this experiment.

Archive audit: all 23 retained file instances hash-verified, 243,124 bytes. Producing builds
include the new diagnostic on the recorded base; source/binary hashes identify that state,
not a clean-base executable. `make check-affected` passed: strict build without warnings,
lint/scripts/docs, 71 CUDA/queue tests (four local Torch skips), 18 selected Mac tests and
57 PC tests. Three diagnostic tests also passed separately on Mac.
