# The BlastModel split

These tools move BombCAD's plain model (scenarios, structures, materials and the calculations
that run on the CPU) out of `BlastCore` into `BlastModel`, a module that imports no Metal and so
also builds and is tested on Linux. They do the move by script, so that it can be redone on
whatever `main` is when the window opens, and they stop rather than guess when `main` has changed
under them. The findings and the numbers are in the cloud report of 19 October 2026
(`CLOUD-REPORT.md` on the branch `cloud/blastmodel-split`).

| File | What it is |
|---|---|
| `import-graph.py` | Maps `Sources/BlastCore` and `Tests/BlastCoreTests`: each file's imports, the types it declares and uses, and its class (`cpu`, `gpu` or `mixed`); `--write` records it in `classification.json`, `--check` fails when that record is stale |
| `blastcore_graph.py`, `swift_source.py` | The rules of that map and the reader of Swift source it uses (no compiler, so it runs anywhere) |
| `classification.json` | The map, for review: what moves, and for each mixed file what is cut out and why |
| `seams.json` | Behaviour-neutral edits beyond moving code; one, which moves a constant (`ShellSolver.fibresAcross`, 9) to `ShellMesh` |
| `overrides.json` | Declarations a Linux build showed must stay in BlastCore, each with its reason |
| `split-blastmodel.sh`, `split_blastmodel.py` | The split itself |
| `LinuxSIMD.swift` | The part of Apple's simd that BlastModel uses, for Linux only |
| `SIMDParity.swift`, `LinuxSIMDParityTests.swift` | Digests of those functions' results recorded on Linux, checked against Apple's simd on the Mac |
| `test-split.py` | The tools' own tests, on a made-up package |

## In the window

1. Branch from `main` and bring these tools in (the commit that adds `Scripts/split/`).
2. `python3 Scripts/split/import-graph.py --check`. If it fails, `main` has changed what moves:
   run it with `--write`, read the difference in `classification.json`, and commit it.
3. `Scripts/split/split-blastmodel.sh`. It stops before changing anything if a file it expects
   has moved or a seam no longer applies.
4. `swift package resolve`, to refresh `Package.resolved`'s origin hash for ContinuumKit
   0.1.0-alpha.29.
5. On the Mac: build every target, `make check-anywhere`, and compare the digests with `main`'s.
   `LinuxSIMDParityTests` there says whether Linux's simd results are Apple's bit for bit.
6. Commit, and push the branch for review.

Running the script again changes nothing. `--no-seams` leaves the seam out, and with it about
ninety declarations that depend on it stay in BlastCore (rewrite the map with
`import-graph.py --write --no-seams` first).
