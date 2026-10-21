# Mac / Windows / WSL elapsed-clock audit, 21 October 2026

The disagreement is isolated to WSL's adjusted elapsed clock in these observations.
`CLOCK_MONOTONIC_RAW` agrees with native Windows Stopwatch/QPC, while Linux monotonic and
boottime advance about 2.5% faster during the paired probe. This does not justify blaming
or switching the selected `tsc` clocksource. No clock, synchronization service, or OS setting
was changed. #64 remains open for the origin and safe normalization of the kernel discipline.

## Paired observations

The PC session confirmed no active workload; GPU lock was free and utilization 0% before the
audit. One persistent SSH connection to WSL runs a native Windows PowerShell child without a
user profile. For Windows sleeps, native Stopwatch/UTC intervals are inside WSL clock reads,
which are inside the Mac request/ack interval. For WSL sleeps, Windows timestamps bracket the
Linux sleep and IPC. Zero-duration observations retain pipe/network overhead; none is silently
subtracted. Three repetitions at 0, 1, 5 and 15 seconds for each target yield 24 observations.

Median 15-second observations:

| Sleep requested on | Mac request/ack | WSL monotonic | WSL raw | Windows QPC |
|---|---:|---:|---:|---:|
| Windows | 15.037254 s | 15.378633 s | 15.005926 s | 15.005178 s |
| WSL | 14.674718 s | 15.010410 s | 14.645293 s | 14.644716 s |

Across the six long samples, raw/QPC outer-versus-inner intervals differ by at most 0.75 ms,
consistent with their IPC bracketing. Adjusted monotonic/raw ratios are about 1.0249. Mac wall
and perf-counter intervals agree, with expected network overhead. WSL realtime also experiences
steps. These are measured interval agreements on this host, not an absolute UTC calibration or
a promise about other hardware, suspend/migration, or hours-long stability.

Linux documents that monotonic is affected by frequency adjustment, while raw omits it
([clock_gettime semantics](https://man7.org/linux/man-pages/man2/clock_gettime.2.html)). Microsoft
states that .NET Stopwatch uses QPC for elapsed timing
([Windows timing guidance](https://learn.microsoft.com/en-us/windows/win32/sysinfo/acquiring-high-resolution-time-stamps)).
Hyper-V's Linux documentation describes `tsc` as a normal supported selection on applicable
hosts; seeing that name alone is not a defect
([Hyper-V clocks](https://www.kernel.org/doc/html/latest/virt/hyperv/clocks.html)).

## Read-only discipline query

`read-clock-state.c` calls `adjtimex` with a zero-initialized structure and modes=0. It was
compiled with the existing PC compiler using `-Wall -Wextra -Werror` in a new temporary directory,
run unprivileged, and removed with its own temporary directory. It never requests an update.
The [API](https://man7.org/linux/man-pages/man2/adjtimex.2.html) defines the tick and scaled frequency
fields. USER_HZ is 100 (nominal 10,000 microseconds per tick). Snapshots show:

| Snapshot | Tick | Frequency offset |
|---|---:|---:|
| During/after paired probe | 10,248 µs | −47.758 ppm |
| After worker validation | 10,212 µs | +35.981 ppm |

The enlarged, changing tick is consistent with the adjusted-versus-raw rate difference.
The raw counter's agreement with Windows narrows the issue to clock discipline; it does not
identify the process or event that set those parameters. systemd-timesyncd is active and WSL's
boot arguments enable implicit Hyper-V time synchronization. Their interaction is a candidate
for investigation, not an established cause. The unprivileged journal cannot see system history;
a noninteractive privileged journal query required a password, so no service history was inferred.
No privilege, service, kernel, clocksource, or time setting was changed.

## Application correction and validation

The Linux CUDA worker and worker profiler now measure elapsed durations with
`clock_gettime(CLOCK_MONOTONIC_RAW)` and explicitly record `timingClock`. They fail clearly if
the required raw clock is unavailable. `clockAudit` records nearby raw and adjusted-monotonic
worker intervals for diagnosis. GPU timesteps, stopping rules, equations, precisions and accepted
array formats are unchanged. Dataset CUDA provenance includes the clock identity. Host-level
sleeps, lock leases and service configuration were not rewritten by this reporting correction.

The timing-only integration reruns 32³/64³ cooling fixtures and the real flat district under the
shared PC GPU lock. Every Metal gate passes; all raw numerical outputs and timesteps exactly
match the earlier worker's hashes. The flat district also passes fresh production Metal, and
its dataset provenance records the raw clock. Its audit observes 46.676 raw seconds versus
47.665 adjusted-monotonic seconds. A smaller reported duration is a measurement correction,
not faster computation. Kernel discipline changed during the study: do not retrospectively
rescale old receipts by one fixed percentage.

The actual worker profiling harness also completes three fresh-process pairs with the same
current worker as both controls: all six outputs/timesteps match, and raw clock/provenance
plumbing is verified. This is a plumbing control, not an optimization benchmark. Unit coverage
checks both elapsed helpers ignore adjusted monotonic and fail when raw is unavailable.

Reproduce paired observations with `python3 Scripts/cuda/clock-probe.py bombcad-pc --out NEW.json
--context 'current load/coordination'`. Native PowerShell interop must already be available;
no package is installed. Compile the read-only C helper on Linux into a new executable path to
query discipline independently. Raw observations, analysis, read snapshots, integration/profile
receipts, and the exact pilot script are retained alongside this note. #60/#59 can use the new
explicit measurement contract; #47/#62/#63 numerical admission remains unchanged.

Validation: `make check-affected` passes strict build/lint, scripts/docs, 35 Mac tests in
seven suites and 54 PC tests in 12 suites. CUDA contract tests pass 25 tests (four local
Torch-dependent skips); real PC cooling/timing integration and the six-process profiler
control pass. Artifact JSON/source hashes and final document links/whitespace are checked.
