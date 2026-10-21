# WSL clock ownership: controlled service experiment

Date: 2026-10-21. RTX 3080 Ti PC, Ubuntu-24.04 under WSL 3.0.3.
Follow-up to the [clock actor trace](../2026-10-21-clock-actor/summary.md)
and private tracking issue [#64](https://github.com/emmettl/bombcad-work/issues/64).

A phase-acknowledged baseline / pause / restore experiment supports competing
clock controllers as the current source of clock-rate instability. The WSL VM's
PHC0-backed chronyd remained active throughout. Only Ubuntu's systemd-timesyncd
was temporarily stopped; no manual tick, frequency, clocksource, or Windows
configuration writes were made.

| Confirmed phase | Five-second observations | Median absolute MONOTONIC/RAW error | Maximum absolute error |
| --- | ---: | ---: | ---: |
| Both clients active | 6 | 743.0 ppm | 7717.5 ppm |
| Guest client paused, after settling | 6 | 29.9 ppm | 53.8 ppm |
| Guest client restored | 6 | 1854.2 ppm | 9518.7 ppm |

The direction and recurrence support a present feedback mechanism; they do not
prove when or why the historical configuration first changed. Native Windows
QPC, Windows UTC, WSL clocks and Mac intervals were recorded independently.
RAW/native differences include request bracketing and are not direct clock-offset
measurements. Continue using CLOCK_MONOTONIC_RAW for worker durations; do not
rescale historical benchmark results.

The first exploratory cycle used fixed windows. Its manually launched paired
batches crossed phase boundaries and failed their guards. Retain those records
as excluded exploratory evidence. The confirmed cycle used token-matched before
and after phase acknowledgements and completed all three batches successfully.
Both cycles verified restoration to active/enabled/tsc, removal of their own
restore timer, and release of the shared compute lock.

A separate longer validation holds the same shared compute reservation and uses
an independent rollback timer. It requires PHC0 health, at least 120 seconds of
settling, paired 0/1/5/15-second measurements, then paired 60-second measurements.
Acceptance limits are 500 ppm MONOTONIC/RAW, 20 ms RAW/native bracketing, and
50 ms Windows UTC/QPC difference. A successful acknowledgement applies the
reversible policy `systemctl mask --now systemd-timesyncd.service` in
Ubuntu-24.04 only. Rollback is `systemctl unmask systemd-timesyncd.service` then
`systemctl enable --now systemd-timesyncd.service`. Final transaction results
are recorded in `policy/experiment.json` and `policy/controller.json`.

Reboot persistence, longer operational stability, and any other WSL distro remain
unverified. Do not shut down WSL through its own sole SSH path without a tested
native recovery path. This experiment changes clock ownership, not CUDA numerical
admission, backend selection, or training data eligibility.

## Reproduction records

`exploratory/`, `confirmed/`, and `policy/` retain the exact scratch controllers,
root experiment programs, phase receipts and probe output. These are evidence,
not unattended host-management tools: their original paths, ownership assumptions,
nonces and deadlines are specific to these runs. Service mutations were guarded
by a live PID/boot compute reservation and unique transient restoration units.
The local policy controller was briefly suspended during a host-policy instruction
review, so its first probe's outer phase window includes that pause. The paired
probe's own intervals remain independently recorded. No acceptance threshold was
relaxed. Public records exclude private handover contents.

## Final receipt

The policy transaction completed in 477.02 RAW seconds. Both paired
checks passed. Ubuntu-24.04's client is now inactive/masked; clocksource remains
`tsc`. The PHC0 agent remained healthy, the owned rollback timer is unloaded and
inactive, and the shared lock is absent. GPU utilisation at handover was 0%.
The 5/15-second checks had maximum absolute adjusted/RAW error 19.3 ppm;
the 60-second check results and independent bracketing values are in
`policy/controller.json`. Repository checks overlapped the final long check;
this is clock validation, not a compute throughput benchmark.

Validation: evidence JSON parses, reproduction scripts compile, and
`make check-affected` passes (strict build, lint, script checks, docs checks,
selected Mac suites and PC suites).
