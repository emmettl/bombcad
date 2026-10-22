# Remaining peaks: pressure projection is a small part of the discrepancy

22 October 2026. Tracking: emmettl/bombcad-work#82 remains open and claimed;
parent emmettl/bombcad-work#80. This completes saved-history analysis, not the
proposed actual-stencil experiment.

All 432 preceding case groups /864 receiver histories were analyzed, including
every component, retention/no-carry, amplitude, resolution, CFL, arithmetic and
tiling outcome. All 1,023 consumed files match the preceding published archive
inventory before/after analysis. No GPU export or Float64 reference was rerun.
The 537 parent producing-source, 33 runtime and 15 original analysis pins also
still match. Three analytical controls cover signed decomposition/tied maxima,
interpolation without extrapolation, and malformed axes/nonfinite inputs.

Keep compensated storage as a bounded candidate, but reject pressure projection
alone as a complete explanation for the remaining discrepancies bounded below.
Proceed to actual-stencil observations before attributing them to a primitive,
limiter, predictor or Riemann-flux mechanism. No numerical or acceptance default
changes follow from this analysis.

## What is compared

At each native integer-tick time within Float64 dt-sum coverage, the pressure
difference is decomposed as:

`native − reference = (native − storedDouble) + (storedDouble − pairDouble) + (pairDouble − reference)`.

The first term compares native pressure evaluation with a Double projection of
the same stored conserved state. The second is the represented-pair projection
counterfactual; the GPU does not consume it. The last compares that represented
state with an independently evolved Float64 numerical solution. It includes
operator/discretization differences and cannot identify a local cause by itself.

Every native global maximum is retained, including all ties. At each such sample
a fourth term, aligned-reference-at-that-time minus raw-reference global peak,
separates reference shape/peak selection from same-time pressure differences.
The four terms sum to native peak minus raw Float64 peak. Ranges across tied
maxima and a reproducible earliest tuple are both saved; separate range extrema
must not be combined as if they came from one sample.

All native samples and maxima have reference coverage. No endpoint is
extrapolated. Raw and interpolated Float64 maxima are separate readouts. The
largest three-term closure residual is 1.11e−16 Pa, a reported floating-point
reduction residual rather than an acceptance tolerance. Existing global peak
and first-phase definitions are unchanged.

## Fine-grid wall example

For A1 Pa/nx2048/CFL0.225/default/full with both residuals retained:

| Readout | Peak pressure | Maximum sample(s) |
|---|---:|---|
| Native | 1.906250000 Pa | 4316–4319 |
| Double stored-state projection | 1.906460445 Pa | 4316–4317 |
| Double represented-pair projection | 1.907103811 Pa | 4318 |
| Independent Float64 | 1.991678906 Pa | 4282 |

The native maximum interval is 0.0222814950–0.0222969916 s; Float64 peaks at
0.0221058675 s, about 176–191 microseconds earlier. The saved dt-sum versus tick
clock lag is at most 1.47 nanoseconds here. Interpolating the reference onto tick
times lowers its peak by only 4.08e−9 Pa. The clock representation does not
explain this observed maximum interval.

At the earliest native maximum, the complete signed tuple is:

| Term | Pressure difference |
|---|---:|
| Native − stored Double | −0.000210445 Pa |
| Stored Double − represented-pair Double | +0.001914700 Pa |
| Represented-pair Double − same-time Float64 | −0.033692522 Pa |
| Same-time Float64 − Float64 global peak | −0.053440639 Pa |
| Total native peak − Float64 peak | **−0.085428906 Pa** |

Across all four tied native maxima, the third term ranges −0.03369 to
−0.02285 Pa and the fourth −0.06331 to −0.05344 Pa. Most of this peak gap
is not the native/Double pressure projection. A reference-at-native-maximum
shortfall describes the saved curves; it is not proof of one phase-speed defect.
In multi-event histories, global maximum sets can belong to different pulses,
so their time differences are not universal arrival-time errors.

## All A1 outcomes, with stronger amplitudes retained

Each row below contains all 48 receiver/case combinations for that selector,
including full/tiled duplicates. Projection bound is the maximum over a history
of `|native−storedDouble|`, plus the maximum of `|storedDouble−pairDouble|`.
The raw/interpolated-reference peak difference is accounted for separately.

| Method | Largest absolute native/Float64 peak gap | Largest projection bound | Histories with a positive remaining mismatch lower bound |
|---|---:|---:|---:|
| Retain density | 0.226054 Pa | 0.003336 Pa | 44/48 |
| Retain energy | 0.163554 Pa | 0.006461 Pa | 42/48 |
| Retain both | 0.147929 Pa | 0.006461 Pa | 40/48 |
| No carry, each selector | 0.335429 Pa | 0.003336 Pa | 46/48 |

These are descriptive triangle bounds on the remaining same-time
represented-pair/reference discrepancy, not physical-error certificates or new
admission gates. For the eight combined A1 histories without a positive bound,
this inequality does not exclude a projection-sized explanation; it does not
prove one either. The largest combined A1 remaining lower bound is 0.141469 Pa.

For combined retention, A10/A100 maximum absolute native/Float64 peak gaps are
0.164776/0.285994 Pa, with projection bounds at most 0.006462/0.009589 Pa and
positive remaining bounds in 48/48 and 46/48 histories. Every stronger-pulse
and no-carry result remains in [results.json](results.json); no passing subset
was selected. Agreement with Float64 is numerical comparison, not exact
finite-amplitude PDE truth or a replacement for the original analytic targets.

## Evidence and next action

All 443 output files /71,907,694 bytes were archived and every decompressed
member independently verified: 62,026,410 compressed bytes at
`$BOMBCAD_DATA/experiments/2026-10-22-compensated-peaks-archive/all-raw.tar.gz`.
The public [metadata archive](evidence/metadata.tar.gz) contains all 11 metadata,
source and control files (523,292 compressed bytes); 432 derived NPZ arrays remain
external by file kind. Inputs remain pinned in the preceding
[compensated-wave archive](../2026-10-22-compensated-wave/archive.json).
[archive.json](archive.json) and [integrity.json](integrity.json) retain hashes
and verification scope. Runtime identities are selected Python/NumPy-core pins,
not a hermetic operating-system/dependency environment.

Final publication checks pass: format/lint, warning-free strict build and plain
`make check-affected`, including 33 selected Mac tests and 62 PC tests/11 suites.
All consumed-input, frozen-helper, raw-output and archive hashes still match
after checks. [publication-checks.json](publication-checks.json) records scope
and log hashes. No scientific producer or reference job was restarted.

The existing traces lack the neighbors and intermediate quantities necessary
to isolate a cause. [next-stencil-plan.md](next-stencil-plan.md) proposes a
separate bounded 150-word actual-state/primitive/slope/reconstructed-face trace,
keeping the current 24/33-word diagnostics and ordinary shaders intact. It must
pass complete plain/observer/prior-wave and full/tiled controls before any local
counterfactual is interpreted. That instrumentation and its scientific exports
have **not run**. emmettl/bombcad-work#82 remains open and claimed for this stage;
emmettl/bombcad-work#80, emmettl/bombcad-work#62, emmettl/bombcad-work#63,
emmettl/bombcad-work#59 and emmettl/bombcad-work#47 remain separately gated.
