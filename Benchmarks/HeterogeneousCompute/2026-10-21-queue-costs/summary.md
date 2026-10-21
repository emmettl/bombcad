# Repeated small queue overhead study — 21 October 2026

Four exact passing replay cases from the preceding [recovery experiment](../2026-10-21-field-queue/summary.md)
are run three times per policy, on both the baseline queue controller and the demand-probe
controller. This is an overhead measurement for small jobs, not a general heterogeneous
throughput benchmark. No numerical code, thresholds, locks or dataset admission changes.

## Method and observations

The jobs are masses 5, 10 and 20 kg on the uniform synthetic neighbourhood, plus 10 kg on
static cut-cell terrain. Every domain is 48 × 48 × 16 cells, dx 2 m, until 0.08 s, with
first-phase output. All references and input identities are frozen by the queue contract.
Policies are Metal-only; automatic Metal/CUDA choice; and a forced split putting the uniform
10 kg and terrain cases on CUDA and the other two on Metal. Policy order rotates each round.
There are three baseline rounds followed by three candidate rounds, not randomized A/B pairs.

The existing PC session confirmed no reservation. Before every trial, Mac declared GPU memory
and waiting jobs are zero, memory pressure is normal, and the PC reports available. The normal
Mac slot and PC shared lock still protect actual work. All accepted objects and source pins
were verified by the study while each controller version was current. All attempts accepted
once with the existing comparison gate, and all owned groups were confirmed terminal. Snapshot
checks cannot rule out every unrelated process during the trial.

Each trial initializes a new queue; every CUDA run has fresh Mac preparation and a persistent
PTX cache already primed by earlier calibration. It still uploads inputs and workers and starts
a fresh PC worker. No cached-preparation retry or failure is mixed into the accepted timings.
Mac `time.perf_counter` measures controller subprocess entry through completion, including
startup, probes, polling and publication. PC nested worker timings use raw elapsed clocks;
they are not added to the outer Mac times.

| Policy | Baseline median (range), s | Demand-probe median (range), s |
| --- | --- | --- |
| Metal only | 3.475 (3.465–3.544) | 1.360 (1.348–1.376) |
| Automatic | 3.517 (3.501–3.539) | 3.518 (3.440–3.562) |
| Forced split | 21.711 (21.377–22.138) | 21.142 (21.094–21.164) |

Automatic selection chooses Metal for every case in every trial. Individual Metal worker
bodies are about 0.17–0.19 s; CUDA bodies about 9–10.5 s. Forcing CUDA here adds transfer and
process overhead far exceeding the solve. The split timing difference is not presented as a
CUDA optimization. Metal-only completion falls about 61% because it no longer waits for
irrelevant synchronous SSH probes. Automatic selection still checks the PC and its observed
completion time is unchanged at this precision. These numbers do not establish a CUDA win for
larger, contended or differently shaped jobs.

## Implementation and validation

`run_queue` now probes resources only when a pending case is past retry backoff. It queries
the PC only if at least one such case still has CUDA among its eligible backends. Running-only
or backoff-only queues skip resource probes, while publication/recovery/process checks continue.
A CUDA-capable runnable case still gets normal availability and memory observations. The
last dispatch receipt retains its observation timestamp when no new dispatch is possible.
Tests cover Metal-only dispatch without SSH, running/backoff without either probe, and retained
PC probing for a runnable CUDA alternative, alongside existing recovery and gate tests.

Candidate round 0 overlapped a lint/CPU validation command and is excluded in full. A fresh
three-policy round replaces it; the two later candidate rounds were uncontended by that
command. The initial validation failed because sandboxed `ps` was denied; the required check
was retried with host visibility after timing trials. The retained excluded data is labelled
and is not silently pooled into the comparison. A rejected invalid-poll initialization launched
no workers and is not a trial.

## Retained evidence and limits

- `study.json`: the nine baseline and nine included candidate trial records, snapshots,
  full accepted receipts, summaries and exclusion rule.
- `observed-costs.json`: per-exact-case/backend worker-body medians, ranges, sample counts
  and receipt identities from included candidate runs. Metal has six or nine samples per case;
  CUDA has three for each forced CUDA case. Other CUDA cases have no new observation.
- `baseline-state.tar.gz`, `candidate-state.tar.gz`, `repeat-state.tar.gz`: full plans,
  contracts, datasets, attempts and logs, including explicitly excluded candidate round 0.
- The three `*-study.py.txt` scripts are the exact trial drivers; `baseline-field-queue.py.txt`
  preserves the controller before the change. Paths and pinned identities are historical;
  create new queues and references to reproduce rather than assuming archived queues resume
  after changing source or host.

Observed worker-body costs include preparation, deployment and comparison, but exclude controller
probes/polling, Python startup before the body and publication. They can be referenced as named
JSON cost terms for these exact jobs, with those omissions understood. They are not an automatic
calibration model or a substitute for measuring complete queue cost. No cached-preparation cost
model is inferred from fresh-preparation runs.

#59 remains open for complete queue-cost modelling, cached-preparation resource/cost policy,
finer Metal compile/setup accounting, and larger representative queue evaluation. A useful next
controller experiment is to reduce synchronous PC observation overhead without weakening busy,
memory or lock checks. #60 retains CUDA per-step launch/control profiling; #47/#62/#63 broader
numerical gates and #64 clock-discipline remediation remain unchanged.
