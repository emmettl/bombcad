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

## Sweeps on a Linux host

`Scripts/remote-sweep.py` sends a sweep of `blastmodel` cases from the Studio to a Linux host,
runs them there and brings the results back. `compare` then sets them beside the same sweep run
on the Mac:

```bash
python3 -I Scripts/remote-sweep.py run bombcad-pc sweep.json --cores 16 --wait 30m
python3 -I Scripts/remote-sweep.py run --here sweep.json
python3 -I Scripts/remote-sweep.py compare /Volumes/StudioData/bombcad/sweeps/<name>-here /Volumes/StudioData/bombcad/sweeps/<name>-bombcad-pc
```

- **The sweep** is a JSON list of cases, each one `blastmodel` command's arguments, and the files
  they read. `{repo}` and `{out}` stand for the repository's copy and the case's folder, and the
  inputs are sent and their paths rewritten (the script's own help says how).
- **On the host** it keeps to `~/bombcad-sweeps`:
  - this worktree in `src`, its release build kept between sweeps;
  - the inputs, and each sweep's results.
- **One sweep at a time,** under the host's own lock, as `Scripts/ml/remote-train.py` locks
  (`--wait` waits for it). It never touches the training runner's `~/bombcad-ml` or its lock.
- **Each case is held** to `--cores` of the host's cores, 16 of the PC's 24 by default, so that a
  sweep can share the box with a training job on the GPU.
- **Every SSH and rsync** reads nothing from standard input.

**The first sweep, 21 October 2026** (`cpu-studies-1`), on `bombcad-pc`: WSL2 Ubuntu 24.04 on 24
cores and 30 GB, Swift 6.4.1 as CI's. BlastModel's 817 tests pass there in 170 s. The sweep has
eleven cases:
- protective design on the made-up district at 1, 2, 5, 10 and 20 t, the 20 t plans confirmed on
  its saved run;
- the soil column;
- the half-space's calibration;
- charge inference from Rigby et al.'s Beirut arrivals at four seeds.

Against the same sweep on the Mac:
- **The same answers in ten of the eleven.**
  - Every protective plan agrees within 10⁻⁹, and the plans' tables print alike.
  - The soil column's stresses and the half-space's velocities print alike.
  - Three of the four inference seeds give the same posterior: two byte for byte, one within 10⁻⁹.
- **The fourth seed's chain went another way.** Its yield is 0.540 kt here (90%: 0.392–0.852)
  against 0.543 kt on the PC (0.396–0.830), within the sampler's own scatter.
  - Linux's and Apple's maths libraries round some functions differently in the last bit (as the
    other seeds' 10⁻⁹ show).
  - In a Monte Carlo chain one such bit can flip an acceptance, and the chain then follows another
    path to the same posterior.
  - So a sampled result run on Linux is a draw from the same posterior, not the Mac's draw: mark
    it Linux-run, and compare its summaries, not its bytes.
- **Time:** 111 s on the PC's 16 cores, the release build 137 s on top. The Mac took 261 s,
  shared with other sessions' runs at a load of 60–90.

**Not yet** (emmettl/bombcad-work#48's later stages):
- teaching `BombCAD sweep` and `BombCAD ensemble` to hand their CPU-only cases to a Linux host;
- the PC as a lane for `check-affected`'s BlastModel tests.
