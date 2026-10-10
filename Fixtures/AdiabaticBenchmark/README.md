# Independent adiabatic source adapter

Run `bash Scripts/check-adiabatic.sh OUTPUT_DIRECTORY [CASES_JSON]` from the repository
root. The script creates an optimized temporary SwiftPM consumer of the immutable
ContinuumKit revision in `core-revision.txt`, with no production dependency change.

The shared case/schema, complete-history errors, bounds, unsupported states and
observed orders are documented in [the core contract](https://github.com/emmettl/ContinuumKit/blob/codex/adiabatic-conformance/docs/benchmarks/ADIABATIC.md).
Metadata includes source/dependency revisions, source hashes, dirty status, toolchain,
hardware, precision and SI-labelled CSV histories. Output stays outside study baselines.

This is uniform, closed, reversible adiabatic reference conformance with prescribed
volume. It does not verify coupled support/geometry, venting, waves or empirical
material response. The 1 s sample clock is a case label, not an acoustic/piston speed.

The existing Check workflow runs this source benchmark on main pushes. Manual dispatch
with `suite=adiabatic` verifies only this bounded case; `suite=all` retains the application
checks as well. Trusted triggers and the repository-scoped Mac mini runner remain in use.

## Packet extraction checkpoint

The historical framework revision and original numerical operator are now frozen
inside this verification-only fixture. SourceTransport.swift is unmodified from
pre-adoption e5ead4b; packet-source.json and the source guard protect its bytes/blob.
It is no longer copied from the production alias. The same script additionally
runs SharedAdiabaticBenchmark at exact alpha.14 with the actual current alias,
using these same cases, and requires complete sample histories to match.
