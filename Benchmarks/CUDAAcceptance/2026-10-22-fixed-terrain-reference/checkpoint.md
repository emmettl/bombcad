# Fixed-main Metal references complete; CUDA comparison queued

22 October 2026. Tracking: emmettl/bombcad-work#39, emmettl/bombcad-work#47,
emmettl/bombcad-work#62, emmettl/bombcad-work#63 and emmettl/bombcad-work#80.

Release `scenebench` rebuilt successfully from main
`c78451c099a5899ca2e95b4e375280e56f6f486a`, containing `aff21dff`.
The producer freezes 709 selected source files and 784 executable/resource/input/
helper files before execution. It runs ordinary production Metal while capturing
its actual portable initial buffers, then stages unchanged CUDA workers against
those buffers. These selected pins do not make the OS/compiler/driver hermetic.

| Pilot | Metal steps | Captured initial time (s) | Old inputs/mask | Old targets |
| --- | ---: | ---: | --- | --- |
| Flat `made-perimeter-s1-1` | 2645 | 0.003934389986701742 | byte-identical | byte-identical |
| Slope `made-perimeter-s3-1` | 2711 | 0.007832608726021408 | byte-identical | changed |
| Beirut `beirut-p0-1` | 2417 | 0.025454009796289062 | byte-identical | changed |

All three fresh Metal exports are stable. Positive initial times on slope and
Beirut confirm these exports begin at the mapped start. Their changed targets
must be the reference for the new CUDA comparisons; old balloon-start acceptance
outcomes remain historical evidence. Byte comparisons are against the original
`main-fp` files, with original hashes rechecked after reading.
[metal-checkpoint.json](metal-checkpoint.json) retains producing revision,
executable/generated-source hashes, initial receipts and all compared array pins.
Raw root: `$BOMBCAD_DATA/experiments/2026-10-22-fixed-terrain-reference`.

All three initial CUDA invocations refused the existing PC GPU lock before a
numerical solve or output creation. Those logs and staged inputs are preserved.
The owner is `field-unet-l3-strict-125` training (emmettl/bombcad-work#69).
A separately frozen queued wrapper verifies the unchanged worker/source hashes
and no prior numerical output, waits up to80 minutes using the existing lock
helper, then runs all three workers once while holding that lease. It does not
interrupt training or bypass the lock. Original exec53160 is terminal; queued
exec62933/controllerPID86947 is live at this checkpoint. Its `queued-cuda/run.json`
and `remote.log` are authoritative for subsequent progress; do not duplicate it
on an observation timeout. No quiet throughput claim.

CUDA acceptance is **pending**. Preserve exact features/masks and
`abs(error) <= 0.05 + 0.002 * abs(reference)` for every valid target. No tolerance,
phase policy, mask, label, default, training index or bulk admission changed.
Record all fixed-reference outcomes on emmettl/bombcad-work#62 and
emmettl/bombcad-work#63 before deciding whether the existing bulk gate can reopen.

Weak-wave precision work and follow-ons remain paused by explicit user direction.
Its completed 432-command/1728-export producer and partial full audit are retained.
The owned auditor PID83120 is stopped with SIGSTOP, not terminal; do not restart
or resume it before this prerequisite is complete. The previously published
weak-wave experiments use their own idealized inputs; no result from them is
used to waive the corrected terrain-reference gate.

Publication validation: required format/lint and strict build pass without
compiler warnings. Plain `make check-affected` passes scripts/reference/docs,
seven selected Mac tests/one suite and 36 PC tests/four suites. This is a tooling
and reference checkpoint; it does not replace the pending CUDA numerical gate.

The [target auditor](audit-targets.py) independently enumerates every failed valid
value and verifies its counts against the frozen existing comparator. It retains
location, reference/candidate values, permitted error and excess, alongside every
planned pilot outcome. It verifies source/worker provenance and consumed-file
hashes; descriptive old-reference counts never replace the new gate.
[Hand-calculated controls](auditor-controls.json) pass for exact and next-Float32
tolerance boundaries, negative references, masked large errors, complete failure
retention and exact-feature mismatch refusal. These are synthetic audit controls,
not CUDA/Metal acceptance evidence. Raw controls remain under
`$BOMBCAD_DATA/experiments/2026-10-22-fixed-terrain-auditor-controls`.
All 37 synthetic-control fixture/output/source files are retained in the
[verified control archive](evidence/auditor-controls.tar.gz) (8,554 bytes), with
[per-file receipts](auditor-controls-archive.json). Every decompressed member was
independently checked and original files rehashed afterward, including the
explicit feature-mutation negative control.
