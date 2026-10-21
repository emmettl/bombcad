# Actual thermal replay, 21 October 2026

Decision for #61: defer a live RTX thermal consumer on this route for the street workload.
Complete compressed input transport alone exceeds complete local replay, even assuming zero
PC compute cost. This is a workload/route result, not a rejection of offline replay or all RTX
thermal use. Revisit after a substantially faster route, much heavier receivers/ray budgets,
or measured Mac contention makes local work expensive. No CUDA/OptiX thermal port was attempted.

The archive contains actual consumer inputs from a street-canyon blast, dx 0.25 m, thermally
perfect air, afterburning, 60 ms, default thermal spec (128 samples), no radiative cooling.
61 frames, 10,456 receivers. Static scene and receiver setup: 715,469 bytes; frame JSON:
4,082,313 bytes; cells: 53,487,328 bytes, maximum 1,626,272. Capture extraction cost 0.097 s,
encoding/write 0.301 s, local thermal consumption 0.626 s. Recording perturbs elapsed run time.

A separate Mac replay exactly matched all final receiver fluence/peak floats. Read/decode:
0.064 s, consumption: 0.647 s, total reported replay: 0.746 s (setup JSON decode precedes this
timer). One local replay, not a median or a cross-backend scientific validation. Whole-process
command wall time was not measured; this distinction does not establish remote speedup.

Persistent SSH to bombcad-pc, three repetitions per variant, all decoded SHA256 checks passed:

| Input | Raw bytes | Encoding | Wire bytes | Median send/ack | Local encoding |
|---|---:|---|---:|---:|---:|
| Frame 30 | 976,784 | raw | 976,784 | 617 ms | — |
| Frame 30 | 976,784 | zlib 1 | 177,443 | 102 ms | 8.7 ms |
| Frame 60 | 1,626,272 | raw | 1,626,272 | 901 ms | — |
| Frame 60 | 1,626,272 | zlib 1 | 354,145 | 182 ms | 15.3 ms |
| Complete inputs | 58,295,589 | zlib 1 | 10,680,795 | 5.612 s | 0.180 s |
| Complete inputs | 58,295,589 | zlib 6 | 9,958,949 | 5.184 s | 0.393 s |

Frame 30/60 local consumer costs were 10.8/13.2 ms. Complete inputs include setup, manifest,
all shape JSON and binary cells, each preceded by an eight-byte little-endian length, in the
script's declared order. They exclude final reference outputs. The remote probe decompresses
and hashes, but does not reconstruct Swift objects or compute thermal exposure. Send/ack includes
pipes, SSH, remote decode/hash and acknowledgement RTT; it is not raw one-way link bandwidth.
Cold SSH setup, extraction, CPU/GPU reconstruction and returned receiver outcomes are extra.
Compression times are single observations; network order is fixed, so do not treat small level
1/6 differences as statistically established. Before/after GPU snapshots were 0%, 876 MiB.
Other PC session confirmed no active benchmarks/transfers; background CPU/network use is not
excluded. A later check-affected run also used the PC CPU lane, so absolute network isolation
is not claimed.

Reproduce: unpack street.tar.gz into a new directory, run `blastbench thermal --replay street`,
then `python3 Scripts/cuda/thermal-link-probe.py bombcad-pc street --sequence --out NEW.json
--context 'current load and coordination'`. Acquire a Mac gpu-slot for replay and coordinate
shared host use. This probe does no PC GPU work and creates no remote files. Full receipts,
per-frame timings, archive/file hashes and capture command are alongside this note. The archive
is 9.6 MiB; the source file hashes and executable hash pin the diagnostic build.

Validation: release build; exact local replay; deliberately corrupted payload length rejected
with exit 1; `make check-affected` passed (strict build/lint/script/doc checks, seven Mac tests
and 36 tests in the PC CPU lane). No production shader or thermal model changed.
