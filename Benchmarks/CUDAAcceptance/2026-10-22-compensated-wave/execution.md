# Execution record — 22 October 2026

Tracking: emmettl/bombcad-work#81, parent emmettl/bombcad-work#80.

The predeclared 432 groups / 1296 exports started from implementation
`4ef88d4daa472f66c815351c947fd3189c1336e0`, with the uncommitted experiment
controller and auditors copied and hashed before execution. Raw results live at
`$BOMBCAD_DATA/experiments/2026-10-22-compensated-wave`. The controller records its
own PID/boot/birth identity and the current GPU process group in `run.json`.
Each numerical command independently acquires a shared 2 GB GPU slot. Timings
are shared-machine observations, not quiet performance measurements.

Tool controls passed (five), as did format, lint, warning-free strict build and
plain `make check-affected`, including 36 tests in four suites on the PC. These
tool checks supplement the published implementation checks in `final-checks.json`.

An early read-only audit of the first retained export exposed an auditor error:
it equated the host Double sum of Float32 timesteps with the diagnostic integer
clock. The latter truncates each positive timestep conversion into 2^-40 second
ticks. The final clocks differ by approximately 2.3e-13 seconds in that case.
The original failure remains in `early-contract-check/failure.txt`; no producer,
raw data, frozen helper or tolerance was changed and no numerical case rerun.

`audit-v2.py` is a separately versioned correction. It requires exact replay of
both clock definitions, preserves their difference as a readout, and records its
own SHA-256 in the final audit. The first case passed the observation and raw
operation replay gates with that correction. This is an audit-contract check,
not a completed scientific matrix or an adoption decision. The original frozen
auditor remains intact alongside the additional versioned file.

The complete matrix and analysis are terminal: 432 groups /1296 exports,
157 unique Float64 inputs serving all 432 groups, all observation/replay and
full/tiled gates passing, no floor events. The all-outcome archive is verified.
[summary.md](summary.md) records the bounded keep decision, remaining peak error,
stronger-pulse regressions and emmettl/bombcad-work#82. Defaults and dataset
admission are unchanged.

After the producer is terminal, analysis uses the frozen directory (the additional
v2 auditor is byte-pinned separately), a fresh output directory, and the same
recorded Python/NumPy runtime:

```sh
python "$raw/analysis/audit-v2.py" "$raw" "$raw/audit-v2"
python "$raw/analysis/oracles.py" "$raw" "$raw/audit-v2"
python "$raw/analysis/finalize.py" "$raw/audit-v2"
```

Here `$raw` is the raw root above. These are analysis commands, not instructions
to start another matrix. The oracle controller refuses an existing output
directory and retains input aliases, live process identities, failures and logs.
The descriptive summary compares every audited column with the preceding
ordinary acoustic-control matrix, including worse and unchanged outcomes.
