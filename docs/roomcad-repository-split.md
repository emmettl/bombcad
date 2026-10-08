# RoomCAD repository split — 8 October 2026

The independent application is at https://github.com/emmettl/RoomCAD. ContinuumKit
`0.1.0-alpha.2` owns its response interchange implementation and standalone verification,
while RoomCAD owns acoustic, audition, document and application integration tests.
BombCAD's CAD foundations remain pinned to the already adopted `0.1.0-alpha.1` release.

The split starts from `285b620806418f39e4bc7a66be20191f2d366612`, including the committed
gas-study work. Response extraction/adoption changes no model algorithms. Relevant
RoomCAD history, its old release tag, four documentation histories, source hashes and
a commit map are preserved in the new repository. The original BombCAD history and
historical signed application release remain unchanged.

The new root includes its own licence, third-party notices, recordings, measured
fixtures, formatter configuration, build commands and release scripts. It has a
dedicated `mac-mini-roomcad` CI runner. The [standalone verification](https://github.com/emmettl/RoomCAD/actions/runs/37831881121)
passed all 143 application tests, eight release-script tests, actual Metal access,
release packaging, signing and a packaged headless snapshot before source retirement.

A follow-up [test-fixture PR](https://github.com/emmettl/RoomCAD/pull/1) makes receiver
UUID inputs reproducible without changing acoustic code or tolerances; random receiver
identities had altered the diffuse-tail seed in an earlier full-suite failure.

The nested tracked implementation and old Makefile targets are retired, with package
and documentation redirects retained. Existing ignored local caches are not source
and need not be deleted. No BombCAD gas or structural implementation changes.
