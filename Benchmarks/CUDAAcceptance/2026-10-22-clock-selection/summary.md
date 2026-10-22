# Native initial timestep selection — 22 October 2026

Tracking: emmettl/bombcad-work#86 under emmettl/bombcad-work#62; related
emmettl/bombcad-work#63 and emmettl/bombcad-work#80. Later-state follow-up:
emmettl/bombcad-work#87.

The slope's first native timestep difference is reproduced by the original selectors on
identical measured maximum-speed and relevant scalar inputs. Metal returns one ULP more than
CUDA. The CUDA result matches correctly rounded Float32 evaluation of the written expression.
This locates an initial selector-expression evaluation difference; it does not identify a
machine instruction or explain every later divergence.

| Pilot | First different active dt | Different native dt words | Initial maximum speed, Metal / CUDA (m/s) | Initial dt words, Metal / CUDA |
| --- | ---: | ---: | --- | --- |
| Flat | 3 | 2587 / 2645 | 3512.27001953125 / same | 951263423 / same |
| Slope | 1 | 2498 / 2711 | 2900.248779296875 / same | 953740701 / 953740700 |
| Beirut | 2 | 2388 / 2417 | 1911.6304931640625 / 1911.630615234375 | 958697133 / same |

The Metal and CUDA selector bodies are exact after normalizing bit-cast spelling. The actual
host startup CFL expressions produce identical Float32 words at every active step in all
three histories. There is no additional timestep-growth limiter in these selector bodies.
Inactive zero-dt rows and the separately defined absolute/relative clock epochs are retained;
neither is counted as a different active timestep.

Each backend measures the complete original initial coarse Cell state and mask through its
original native measurement entry point. Those physical input bytes are identical locally
and on the PC and pinned to the corrected-reference archive. Each original native selector
then reproduces its immutable first dt word on all three cases: six end-to-end gates pass.
Only after those gates pass are both measured maximum-speed banks fed to both selectors.
All own-bank cross-selection controls match the corresponding own-replay controls byte for
byte. Both CUDA PTX variants match the archived native producer PTX exactly; Metal own/cross
use identical full source and harness binary.

For slope, both selectors consume fastest-word 1161118715, CFL 0.07500000298023224 and dx 4,
with no forced step, maximum-step clamp, clipping or stop. On either speed bank Metal produces
0.00010343941539758816 s (word 953740701), while CUDA produces
0.00010343940812163055 s (word 953740700). An exact rational nearest-even Float32 reference,
rounding the written multiplication before division, gives word 953740700. This bounds the
whole selector expression; compiler regrouping, reciprocal/division implementation and other
instruction details are not individually identified.

For Beirut the initial measured fastest words differ by one ULP (1156510765 / 1156510766),
but both native selectors produce word 958697133 on both banks. Flat's initial measurement
and selection agree. Their first evolving-state differences therefore need inputs that the
current histories do not contain. emmettl/bombcad-work#87 tracks a parity-gated capture of
actual pre-prepare maxima, uniforms and complete controls before later selector attribution.
No exhaustive contributing-cell/argmax/tie capture is claimed here.

The prior emmettl/bombcad-work#85 experiment passed all corrected flat/slope/Beirut target
values using captured Metal timestep histories, including Beirut closure900 rather than827.
That remains a reference-dependent diagnostic. This initial replay does not establish a
deployable common-clock policy, continuum accuracy or the cause of Beirut's later closure.
Default CUDA generation stays held under emmettl/bombcad-work#39 and emmettl/bombcad-work#47.
No default, tolerance, mask, phase rule or training-admission change.

The original full Metal producer source (including the already archived pressure observer)
is reused with nil options, empty function constants and the original `measureWaveSpeed` /
`prepareStep` entry points. CUDA reuses its original full diagnostic compilation unit,
`cudaMeasure` / `cudaPrepare`, precise division/sqrt and unfused flags. No PDE or new GPU kernel
is run. Unused gauge/tile/refinement context is disabled. Relevant selector input words match;
Metal retains its source-defined absolute epoch and CUDA its relative zero epoch. The original
run did not capture its initial maximum/control words, so the six native first-dt matches are
end-to-end gates, not a claim of full original consumed-control parity.

One failed Metal compilation attempt is retained before the first numerical dispatch. Direct
`swiftc` linked SDK14 despite the `-sdk` argument, whereas the archived harness linked SDK27.
The original `xcrun --sdk macosx swiftc` invocation restored SDK27 and compiled the unchanged
full source with unchanged nil Metal options. Its successful numerical own and cross stages
each ran once; no numerical failure was retried. Failed binary, log, process receipt and the
linked-SDK evidence are retained.

Raw evidence: `$BOMBCAD_DATA/experiments/2026-10-22-clock-selection`. All local replay inputs,
measured speeds, controls, full source/PTX, failed-attempt evidence and outcomes are archived
with member verification. Complete initial states/masks remain in the pinned parent archive
and original PC jobs. Fresh local and remote hashes, selected runtime pins and terminal remote
controllers verify. Selected runtime pins are not a hermetic environment or a global idle claim.

Three exact-division controls pass, including nearest-even ties. Standalone Swift compilation
treats warnings as errors; repository format/lint and host strict build pass without warnings.
Plain affected checks and final archival verification are recorded in the publication receipts.
