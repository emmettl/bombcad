# WSL clock-adjustment actor identified — 21 October 2026

A bounded kernel trace identifies `chronyd` (kernel-global PID 239) making **22 accepted
ADJ_TICK | ADJ_FREQUENCY updates** to timekeeper 0, with tick values 10,044, 10,046 and
10,048 µs. Ubuntu's `systemd-timesyncd` also makes accepted updates to timekeeper 0. This
identifies the current coarse-tick setter and demonstrates two active controllers of the same
kernel clock. It does not yet prove the feedback mechanism or validate a normalization.
No clock, service, clocksource or VM setting was changed by this investigation.

## From hidden service to observed setter

The active experiment-owning distribution is Ubuntu-24.04. A marker-file check establishes
that identity before root reads; stopped distribution Ubuntu is not started. The supported
owner invocation of `wsl.exe --distribution Ubuntu-24.04 --user root --exec ...` permits
read-only time-service/kernel history that the earlier unprivileged journal query could not
see. Ubuntu has systemd/systemd-timesyncd 255.4-1ubuntu8.18, an active timesyncd service, and
no installed/active chrony, ntpsec or adjtimex service. Its journal shows timesyncd start,
contacts/timeouts and a restart around 06:08 CEST. This study did not perform that restart;
the other PC coordination session reports no clock ownership or changes.

An unprivileged modes=0 discipline query reads tick 10,045 µs and frequency −39.338 ppm.
Ubuntu's SNTP status reports a 32-second poll and about −145 ms offset. Merely listing Ubuntu
services therefore misses the observed tick setter.

The live host reports WSL 3.0.3.0 and kernel 6.18.54.1. The version-matched published
[WSL 3.0.3 init implementation](https://github.com/microsoft/WSL/blob/15ea3b3846c5f18318722d1381186b2ff6ed72eb/src/linux/init/main.cpp#L3706)
launches a VM-level chronyd agent using a Hyper-V PHC reference. System-distribution
`chronyc tracking/sources` reports PHC0 selected, an 8-second interval and about 4,576 ppm
slow frequency compensation. That is consistent with the traced process and enlarged tick.
It explains why an Ubuntu package/service inventory is insufficient to find the VM-level actor.

A direct `/proc/239` mapping is unavailable in the Ubuntu/system-command PID namespace;
we do not claim an executable-file hash for that global PID. Likewise the interactive system
shell's default `/etc/chrony.conf` is not treated as the agent's effective generated config:
its default server differs from the runtime selected PHC0. Version-matched init source and
runtime tracking establish the launch/reference context; the kernel trace establishes actual
accepted setter calls. These are distinct evidence layers.

## Bounded kernel observation

The matching [kernel NTP implementation](https://github.com/microsoft/WSL2-Linux-Kernel/blob/d504d40ab83839cb61942a812a99d183c42227b9/kernel/time/ntp.c#L759)
processes runtime coarse-tick changes when ADJ_TICK is set. Following the
[kprobe event interface](https://www.kernel.org/doc/html/latest/trace/kprobetrace.html), an
owned entry/return probe observes `ntp_adjtimex`: x86-64 first argument is timekeeper ID,
second is a kernel timex pointer. A separately compiled header ABI check confirms modes/freq/
tick offsets 0/16/88 and size 208. The probes capture those input fields and the return value.

The experiment uses a UUID-named tracing instance with its own event enables/buffer and raw
trace clock. It never truncates global probe definitions or changes the global tracer/on state.
A first attempt failed before registration because Python text append attempted an unsupported
SEEK_END on tracefs; cleanup verified empty definitions/state. Direct append writes correct it.
The successful observation lasts 90 raw seconds, after all GPU timing/diagnostic/audit jobs are
terminal and before repository checks. Its six discipline samples use the existing C helper
with modes=0; none is an adjustment request.

The retained 53 calls all pair with returns. The accepted tick-changing calls are from chronyd
and return 0; the three observed guest timesyncd update calls also return 0 on timekeeper 0.
Captured sample ticks include 10,046 → 10,048 → 10,046 µs. Chronyd's repeated accepted writes
therefore account for current coarse-tick changes; our sampler only queries them. No claim is
made that the capture exhausts every call outside its window. The probe-profile filter retained
no miss-counter rows, so no zero-miss statistic is inferred from that empty list.

Unused timex fields can contain uninitialized client values. The public trace redacts tick
unless ADJ_TICK is set and frequency unless ADJ_FREQUENCY is set; it never interprets those
unused values as updates. Actor/mode/used-value/return evidence is retained, with the original
private trace hash and the exact redaction/pairing script for audit.

All owned probes and the instance are removed. Original global tracer/on controls are unchanged,
prior definitions are preserved, and before/after global-definition SHA-256 values agree.
No packages or tracing mounts are installed. Normal time controllers continue operating.

## Interpretation and next experiment

Two controllers and the setter identity are now demonstrated. The approximately 4,600 ppm
coarse correction and guest's roughly 145 ms offset per 32-second poll are consistent in scale
with controller competition. That feedback explanation remains an inference until a controlled
single-owner test; this trace is not evidence that Hyper-V/tsc hardware is intrinsically wrong.
The earlier raw/QPC/Mac interval agreement remains the elapsed-time control.

#64 remains open for coordinated normalization and longer validation. The next concrete
experiment is a quiescent, bounded pause of Ubuntu's duplicate client while retaining WSL's
host-synchronized agent, recording active/enabled state for restoration, raw/adjusted/kernel
state and native-Windows/Mac paired intervals before/after. Observe rather than manually
forcing frequency/tick to look nominal. Restore the guest client for a reversible diagnostic
unless a persistent single-owner policy is deliberately chosen. No such pause, clock write or
persistent policy change has occurred here. Coordinate all PC sessions and use the shared
compute lock before time-sensitive experiments. Subsequent sustained/boot behavior needs its
own validation; historical receipts keep their original clock basis.

Application elapsed measurement stays on CLOCK_MONOTONIC_RAW with dual-clock audit. No solver
numerical logic, timestep, field gate or training admission is changed by this finding.

## Evidence

`history.json`, `discipline.json`, `system-actor.json`, `system-root-processes.txt` and
`wsl-version.json` retain runtime/service/reference observations. `trace.json` is the redacted
successful capture; `analysis.json` pairs returns and extracts accepted setters. ABI, exact
history/trace/pairing programs, source/version URLs/hashes and failed-setup cleanup evidence
are retained. Full privately retained unredacted data remains in this task's temporary workspace
and on the PC; it is not necessary to interpret unused input fields. Tools require the existing
WSL-owner/root access and tracing support; use a fresh owned instance and always verify cleanup.

Validation: `make check-affected` passed after experiments: strict build/lint/scripts/docs,
57 CUDA/queue/profiler tests (four local Torch skips), 7 selected Mac tests and 36 PC tests.
Final GPU snapshot: 0% utilization, 912 MiB, shared lock absent. All owned experiment,
diagnostic, audit and check commands are terminal; no compute reservation remains.
