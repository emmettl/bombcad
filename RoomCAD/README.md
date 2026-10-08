# RoomCAD has moved

RoomCAD is now an independent repository: [emmettl/RoomCAD](https://github.com/emmettl/RoomCAD).
Its app, acoustic backend, auditioning, fixtures, documentation and release tools live there.
CAD foundations and response interchange are exact tagged dependencies in
[ContinuumKit](https://github.com/emmettl/ContinuumKit).

Clone the standalone repository and run `make check` or `make app` from its root.
The former `make roomcad-*` targets are retired here. RoomCAD has its own physical
Mac mini CI runner; BombCAD's checks cover BombCAD.

History is preserved in both repositories; the standalone repository records the
source hashes and rewritten commit map. The previous signed RoomCAD 0.1.0 download
remains at [the original release](https://github.com/emmettl/bombcad/releases/tag/roomcad-v0.1.0).
