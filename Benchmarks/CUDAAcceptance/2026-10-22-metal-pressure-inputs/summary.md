# Metal/CUDA pressure-input comparison — 22 October 2026

Tracking: emmettl/bombcad-work#83; parent emmettl/bombcad-work#62;
related emmettl/bombcad-work#63 and emmettl/bombcad-work#80.

**The tested wider pressure evaluation does not remove the Beirut closure gap.**
All four declared models keep the nearby Metal pressure positive and CUDA pressure negative.
The two backends started from byte-identical complete coarse fluid-cell states. This bounds a reader-only
widening proposal; it does not identify a particular update instruction or establish continuum truth.

## Captures accepted as observations

The published opt-in diagnostic (emmettl/bombcad@4234c09d and emmettl/bombcad@950e48fb)
reads raw Cell words through a separate Metal library, after the native pressure producer.
Producer shader source and pipeline construction remain unchanged; encoder bindings are restored.

All nine declared Metal commands ran once under normal shared GPU leases, terminal0.
Flat has2646 samples, slope2712 and Beirut2418, including initialization.
Every mode reproduces every corrected-reference dataset array byte.
Plain, pressure-only and raw-input modes have identical coarse initial/final state hashes;
the complete initial state also matches the original physical CUDA job's state.bin hash.
The hash scope excludes refinement/structural state. Native pressure traces match bit for bit,
and Beirut's trace also matches the earlier accepted corrected-Beirut trace byte for byte.
Raw endpoint words match independent host reads from full state buffers; initial selected
Cells and descriptors match the original job. Column words/weights are constant and valid.

Before any conditional model, every Metal and reused CUDA native recorder value replayed
word for word from its real seed, including sample zero: Metal fused accumulation, CUDA separate.
CUDA pressure remains the earlier read-only recomputation diagnostic, not direct consumed-pressure
attestation. Reused CUDA inputs/traces retain their original endpoint/output parity proof and archive.
All model uniform parameters are identical between backends.

## Beirut result

Receiver187747, row366/column355, remains the sole corrected-reference target failure.
At CUDA's closing sample827 (1.5420506962259823s), nearest Metal sample827 is
1.5420496433080189s, earlier by1.05291796348439 microseconds. These are nearby discrete
states, not a same-time or same-state comparison; all10 captured Cell words differ.

| Pressure evaluator | CUDA inputs (Pa) | Nearby Metal inputs (Pa) |
| --- | ---: | ---: |
| Native trace | -0.0078125 | +0.03125 |
| source64, either declared weight policy | -0.0018087679636664689 | +0.03972687329223845 |
| root64, either declared weight policy | -0.0018090502708218992 | +0.039726590941427276 |

All four conditional recorders retain CUDA closure827 and Metal closure900.
At native Metal closure900, the nearest CUDA sample is1.086911237457855 microseconds later;
all declared models are negative there too. Full transitions and paired cell words are retained.

| Recorder evaluation | Metal impulse (Pa s) | CUDA impulse (Pa s) | Backend gap (Pa s) |
| --- | ---: | ---: | ---: |
| Actual native | 1696.1177978515625 | 1514.2877197265625 | 181.830078125 |
| Every declared wider-pressure model, native accumulator policy | 1696.127685546875 | 1514.297607421875 | 181.830078125 |

Against the original Metal reference, conditional CUDA still has error181.8201904296875
and allowance3.4422355957031248 under the unchanged0.05+0.002*abs(reference) gate: **FAIL**.
The same wider evaluator changes each backend's impulse by only0.0098876953125 Pa s.
There is no new actual CUDA output or pass. The earlier one-sample zero substitution was
sensitivity evidence, not a prediction of the wider evaluator.

## Controls and limits

All four models are retained: source64/root64 times native/column64 weights, with promoted
Float32 source parameters and thermally-perfect air. The two weight policies happen to agree
for the selected descriptors. Root64 independently bisects the rounded-parameter energy relation;
source64 retains the production rational guess and one Newton step. Neither emulates native
compiler instructions or supplies high-precision flow states.

For flat62902, conditional Metal/CUDA impulses are1107.3524169921875/1107.3505859375.
For slope134058 they are439.77642822265625/439.774658203125; for slope250097,
188.54281616210938/188.54249572753906. All four models give those respective results;
all selected control-point differences from the native Metal references fit the original allowance.
This is not a whole-field conditional admission test.

Every wider model opens at sample zero: source64 initial pressure is about+0.00671895 Pa
and root64 about+0.00671866 Pa on both backends. This unfavorable startup equilibrium result
is retained; no early samples were dropped. Wider reading of rounded native states does not
automatically preserve ambient equilibrium.

Implementation validation: broad affected check passed (selected Mac suites and128 PC tests
in36 suites). Final endpoint/binding revisions passed strict build without warnings and all8
first-phase tests. Release build passed with warnings as errors. Frozen postprocessing passed
four pressure-model and three replay controls. See [implementation scopes](implementation-checks.json),
[controls](controls.json), [capture receipt](run.json), [all comparisons](comparison-results.json)
and the [predeclared protocol](plan.md).

The next useful bounded experiment is native EOS cross-replay: feed each backend's captured
inputs through both native readers, first requiring native-word reproduction on each reader's
own inputs. Reject attribution if replay parity fails. This separates reader sensitivity from
represented-state differences without another full solve; it still cannot identify which earlier
flow update produced a state difference. Broader work remains on emmettl/bombcad-work#62,
emmettl/bombcad-work#63 and emmettl/bombcad-work#80.

Raw arrays, frozen runtime/sources and all outcomes remain under
`$BOMBCAD_DATA/experiments/2026-10-22-metal-pressure-inputs`.
No tolerance, mask, phase, default, training-index or admission change.
Bulk CUDA generation remains held under emmettl/bombcad-work#39 and emmettl/bombcad-work#47.

## Publication verification and archives

Final report checks passed: formatting/lint, warning-free strict build and plain
`make check-affected` (selected Mac suites plus62 PC tests in11 suites).
After those checks, every consumed/source/selected-runtime pin and all nine ordinary
output inventories were independently rehashed; native pressure parity was rechecked.
See [publication checks](publication-checks.json).

All834 raw files (153,614,465 bytes) are preserved in
`$BOMBCAD_DATA/experiments/2026-10-22-metal-pressure-inputs-archive/all-raw.tar.gz`
(65,310,289 bytes, SHA256
`b4f1ea2ba76a46bc1839539686bb7e634d5cd98be043c44d5b5f6ac538c7cd7a`).
The [public metadata archive](evidence/metadata.tar.gz) contains51 files
(524,863 bytes, SHA256
`12df2ee3e4d3c2052b0a3dc9513939fae8719055645013eb19df02a7c2957de5`).
Every decompressed member and every raw file was verified against the
[complete manifest](archive.json). Earlier CUDA/reference roots remain pinned to their
existing archives. This stage adds no fresh remote CUDA inventory or solve.

## Native reader cross-replay

The [native-reader study](../2026-10-22-native-pressure-cross-replay/summary.md) now reproduces
all own-input pressure and recorder words before swapping readers. Neither reader changes
the negative-pressure decision on any selected frozen history; both retain Beirut's early
CUDA-state closure. Reader choice alone does not repair the remaining case.
