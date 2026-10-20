# BombCAD's CPU studies on Linux

BlastModel holds the model without Metal: the façade load surrogate, single-degree-of-freedom
envelope damage, the glass, ground shock, the fireball's rise and the cloud, protective design and
charge inference. It builds and tests on Linux. `blastmodel` is its command-line tool, which runs
the studies that `scenebench` and `blastbench` run on the CPU, headless, on this Mac or on Linux.
It is stage 1 of emmettl/bombcad-work#48: running those studies' sweeps on the PCs (WSL2) instead
of the Studio.

```bash
swift build -c release --product blastmodel
.build/release/blastmodel
```

| Command | What it runs | Also |
|---|---|---|
| `surrogate-judge` | The façade load surrogate against a district run's saved loads ([validation](validation.md#the-quick-estimate-against-beiruts-runs)) | `scenebench surrogate-judge` |
| `surrogate-extract` | The surrogate's features beside a run's loads, for fitting | `scenebench surrogate-extract` |
| `district-glass` | A district run's saved strips' glass against GEER's survey | `scenebench district-glass` |
| `glass-calibrate` | The glass chances' reliability against runs and GEER ([glass by chance](glass-probability.md)) | `scenebench glass-calibrate` |
| `protect` | Protective design on the surrogate, confirmed on a run's saved loads ([protective design](protective-design.md#in-bombcad-scenebench-protect)) | `scenebench protect` |
| `infer-charge` | The charge's yield and place from arrivals, and glass ([charge inference](charge-inference.md)) | `scenebench infer-charge` |
| `soil-column` | The layered soil column against its closed form, and its cost | `blastbench soilcolumn` |
| `halfspace-calibrate` | The half-space's direct source against UFC's peak particle velocity | `blastbench groundmotion --calibrate` |

Each takes the same options as the bench beside it. Both run the same code, which lives in
`Sources/BlastModel/Studies/`: on this Mac `blastmodel protect` gives the same plans as `scenebench
protect`, byte for byte.

**What it needs.**
- A district run's saved loads (`district-compare --save-loads`) for the judges.
- The map, the elevations and the heights for the scene. Elevations come as an ESRI ASCII grid or
  a GeoTIFF. A Deflate-compressed GeoTIFF, such as Copernicus's, is read through Apple's
  Compression framework on a Mac, and on Linux through `Inflate`, a decoder of Deflate written in
  Swift. The two decode zlib's streams alike (`InflateTests`).
- Nothing that needs a GPU: the runs themselves, and studies whose models are on the GPU, stay with
  `scenebench` and `blastbench`.

**On Linux.**
- Build with Swift 6.4.1, as CI's `swift:6.4.1-noble` container does. The manifest keeps only
  RadialBlast, BlastModel, the tool and BlastModel's tests there.
- CI's Linux workflow (`.github/workflows/linux-blastmodel.yml`) builds the tool on every push,
  lists its commands, and runs the soil column.
- Linux's stand-in for `simd` differs from Apple's for a 3 × 3 inverse and a quaternion's
  trigonometry. A case run on Linux should be checked against the Mac's before its numbers are
  relied on (stage 2's parity check).

**Not yet** (emmettl/bombcad-work#48's later stages):
- sending a sweep's cases to a Linux host from the Studio (`Scripts/remote.py`'s way to the mini);
- the PC as a lane for `check-affected`'s BlastModel tests.
