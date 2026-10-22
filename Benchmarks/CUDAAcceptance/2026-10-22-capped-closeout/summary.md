# CUDA acceptance capped closeout — 22 October 2026

User-directed cap: three additional experiments or four hours, whichever comes first.
Started 16:17:50 UTC; all three CPU-only experiments finished at the timestamp in
`results.json`, exhausting the count cap. **No further CUDA experiments.**
No new GPU solves or reservations were used. Return to Edgerton and emmettl/edgerton-work.

## Remaining gate and best explanation

The corrected mapped-terrain reference passes flat and slope under the unchanged complete
`0.05 + 0.002 * abs(reference)` target gate. Beirut has one first-phase impulse failure:
receiver 187747, row 366, column 355 (zero based). CUDA is 1514.2877197265625 Pa s;
Metal is 1696.1177978515625 Pa s, error 181.830078125 versus allowance 3.4422355957031248.
Bulk generation remains gated under emmettl/bombcad-work#39 and emmettl/bombcad-work#47.
No tolerance, phase definition, mask, reference choice or admission policy changes.

CUDA closes at native sample 827, time 1.5420506962259823 s, on −0.0078125 Pa.
Its immediately adjacent pressures are +0.859375 and +0.25 Pa: a single near-zero negative
sample terminates the retained phase, before another positive portion. Metal closes at 900,
time 1.6764549618392266 s, on −59.75 Pa. The archived native histories have their own
unmodified time axes; matching an index does not assert matching states.

Both baseline recurrences reproduce every archived recorder word exactly, with Metal fused
and CUDA separate Float32 accumulation. These are compatible arithmetic models, not emitted
instruction attestations. Three predeclared controls then ran once:

| Offline control | First-phase impulse (Pa s) | Closing sample | Change from own baseline |
|---|---:|---:|---:|
| CUDA pressure, Metal positive active-index dt weights | 1514.287353515625 | 827 | −0.0003662109375 |
| Metal pressure, CUDA positive active-index dt weights | 1696.1180419921875 | 900 | +0.000244140625 |
| CUDA, only sample 827 pressure changed from −0.0078125 to zero | 1696.1112060546875 | 900 | +181.823486328125 |

The one-sample sensitivity leaves a 0.006591796875 Pa s difference from Metal. It supports
an early phase-end decision near zero as the immediate source of the large impulse gap.
Weight swaps isolate recorder quadrature only; they do not evolve the PDE or align physical
times. The earlier [matched-clock full-solver control](../2026-10-22-matched-clock/summary.md)
removed the failure using the captured Metal dt history: 1696.1107177734375 Pa s, closure 900,
all three pilots passing the original full-field gate. Together these locate sensitivity in
the evolved pressure/closing decision rather than the integration weights alone. They do not
identify the exact upstream cell/instruction cause or establish which physical phase is right.

## Candidates and disposition

| Candidate/control | Evidence | Disposition |
|---|---|---|
| Rebuild after mapped-terrain fix | Flat/slope failures disappear; Beirut reduced to this one phase cell | Correct reference retained; does not reopen bulk |
| Native pressure-reader cross replay, emmettl/bombcad-work#84 | Exact own inputs; cross-reader arithmetic changes no negative predicates/closures | Reader substitution does not resolve failure |
| Captured Metal dt schedule in CUDA, emmettl/bombcad-work#85 | Full-field pilots pass; Beirut closes 900 | Useful diagnostic, reference-dependent; not a deployable native policy |
| Explicit selector arithmetic, emmettl/bombcad-work#88 and emmettl/bombcad-work#89 | Scalar replay exact, analytic controls pass, but candidate adds one slope phase and 61 Beirut peak failures; native CUDA Beirut phase still fails | Rejected for adoption; scalar parity is insufficient |
| Recorder dt-only swaps, experiments 1–2 here | Closure unchanged; impulse changes less than 0.0004 Pa s | Quadrature alone cannot explain gap |
| One pressure sample changed to zero, experiment 3 here | Removes early closure in offline replay | Sensitivity only; no deadband/phase-policy adoption |
| Weak-wave/compensated investigations, emmettl/bombcad-work#80–#82 | Recorded independent accuracy/observer limitations | Parked; no demonstrated fix or weak-label admission |

The [expanded histories](../2026-10-22-selector-failure-histories/summary.md) explain the
selector candidate's extra slope failure as a strict half-peak requalification boundary;
they leave Beirut accumulated-cell peak histories and upstream cause unobserved. Follow-ups
emmettl/bombcad-work#91 and emmettl/bombcad-work#92 are parked, not a new work queue.

## Retention and restart condition

Raw inputs, original axes, transformed recurrence inputs/outputs, source and failed import-only
preflight are retained under `$BOMBCAD_DATA/experiments/2026-10-22-capped-closeout`.
`archive.json` records member hashes and a verified complete archive. One dependency-path
preflight failed before any experiment; the original source/receipt remain, and the corrected
runner changes only dependency/output paths. No numerical retry or search for a passing policy.

emmettl/bombcad-work#62 and emmettl/bombcad-work#63 carry the canonical stop status.
Sub-issues emmettl/bombcad-work#82–#90 point there; completed issues stay completed, open work
is parked. emmettl/bombcad-work#39 remains a Big bet: CUDA worker, export/transfer pipeline,
static fixtures, flat/slope corrected-reference acceptance and PC training work; bulk native
CUDA data remains blocked by this Beirut cell and unchanged admission gate. Revisit only on
explicit reprioritization, such as emmettl/bombcad-work#33 needing substantially more data.
The user reports the corrected 200-run Studio dataset is already re-exported and PC training
takes about 35 minutes; no current product work requires CUDA data. Claude sessions retain
BombCAD product work. No further CUDA experiments under the exhausted cap.
