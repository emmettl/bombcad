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
| `receiver-fixtures` | Declared peak/first-phase pairs on hypothetical uniform panel/pane loads ([portability study](cuda-backend.md#receiver-fixture-sensitivity)) | CPU-only diagnostic |

Each takes the same options as the bench beside it. Both run the same code, which lives in
`Sources/BlastModel/Studies/`: on this Mac `blastmodel protect` gives the same plans as `scenebench
protect`, byte for byte.

`receiver-fixtures --input declared.json --out NEW.json` instead reads explicit fixtures and
positive peak/impulse pairs, with format `bombcad-receiver-fixtures-1`. The request specifies
`binS`, `riseShare`, `loads` (`id`, `peakPa`, `impulsePaS`) and `fixtures` (`id`, `kind`,
`material`, `widthM`, `heightM`, `thicknessM`). Kinds are wall, roof or pane; structural material
uses `EnvelopeConstruction.Kind`. Panes use the declared glass thickness and ordinary glass
assumptions, regardless of the structural material field. All four edges are supported; other
construction assumptions retain their defaults. Results retain both raw-pair binned triangles
and the existing 3% product pulses, integrated impulse, response ranges and damage levels.
They do not infer area loads from point receivers or admit datasets. Existing outputs, invalid
dimensions/IDs/steps and oversized pulses are refused.

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
  - each invocation's verified source, inputs and tools under `staging/<id>`;
  - the reusable `src` build checkout, updated from that snapshot only under host ownership;
  - results and completion records private to that invocation, including when names repeat.
- **One sweep at a time,** under the host's own lock, as `Scripts/ml/remote-train.py` locks
  (`--wait` waits for it). It never touches the training runner's `~/bombcad-ml` or its lock.
- **Each case is held** to `--cores` of the host's cores, 16 of the PC's 24 by default, so that a
  sweep can share the box with a training job on the GPU.
- **No command consumes interactive input.** Request/manifest uploads receive explicit JSON bytes.

Both the run and test lanes stage before acquiring the lock, but staging cannot modify an
active owner's checkout, inputs or tools. The worker verifies the transferred snapshot before
activating it under the lock. Source inputs and regular file modes, internal links, request and
tool identity are checked; build/Git/bytecode/cache metadata is excluded only from source/tools.
Declared input and result payloads retain every entry, including names such as `dist`, `.build`
and `__pycache__`. Input basenames and
case names must be distinct, simple paths; external input/source links are refused. A live
orphaned worker group continues to hold the lock after its parent dies. On TERM/HUP/INT the
worker drains its own group before releasing ownership. Older clients that still write the
shared checkout before locking must be updated; they cannot be made safe by a new receiver alone.
Stale-lease cleanup, acquisition and release are serialized by a short filesystem mutex.
Waiting uses a monotonic deadline; it does not rely on wall-clock corrections.

Fresh source stages reuse identical files from a verified, completed source stage through a
private hard-link basis view (emmettl/bombcad-work#70). Files enter that view only when SHA-256
and permissions match the requested manifest. Changed bytes or modes transfer into separate
inodes; directories, links, declared inputs and tools transfer normally. Checksummed rsync and
the final manifest check remain mandatory. The mutable build checkout is never a link basis,
so builds cannot write through to retained snapshots. A missing/corrupt basis falls back to a
full transfer; removal during transfer either yields a verified complete source or refuses
before execution. Source transfer statistics and elapsed transfer time are printed. These
measure staging work, not solver speed. Retained stages/views share unchanged file storage;
there is no automatic garbage collector, and active/recoverable snapshots must be preserved.

The log prints the invocation ID. To recover a retained invocation without sending changed
local sources or inputs:

```bash
python3 -I Scripts/remote-sweep.py resume bombcad-pc INVOCATION --wait 30m --results NEW-BASE
```

A staged invocation that never started can run its original snapshot. A verified completion
is retrieved without repeating work; interrupted partial work is preserved and refused for
automatic replay. Start a fresh invocation for an explicit retry of that work. Existing local
results are never merged; retrieval failure returns failure. Stages are retained for recovery
and consume storage; cleanup must preserve any active or still-needed invocation.
Run completion receipts bind every result file's bytes and mode. Cached recovery verifies them
on the host and after retrieval; a worker's explicit refusal is never replaced by an older
success receipt. A lost SSH connection can recover a completed result only when its receipted
files verify. Source/input/result tampering therefore refuses recovery rather than returning
an apparent pass.

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

## The Linux lane of the pre-push check

When `make check-affected` (and so `make ship`) chooses suites defined in `Tests/BlastModelTests`,
and bombcad-pc answers with its sweep lock free, those suites run there (`remote-sweep.py test`:
this worktree sent, the tests built, the suites run on 16 cores). Meanwhile the strict build, the
other suites and the digests run here or on the mini, as before.
- **A lane that is not there costs nothing.** The PC is asked first, and if it doesn't answer or
  its lock is held, every suite runs here.
- **A lane lost on the way** (the connection dropped, the lock taken meanwhile) has its suites run
  here after the rest.
- **A test that fails there fails the check,** as it would here: Linux CI runs the same suites.
- `BOMBCAD_LINUX_HOST` names another host; set it empty, or pass `--no-linux`, to keep every suite
  here.

The first `make ship` through it (a86e4618, 21 October) sent 9 of its 16 suites. The PC ran them
in 35 s, sending and building included, while the Mac's build and other suites took 50 s.

**What it saves** is BlastModel's share of the suites. For a change that runs all 182 of them:
- the PC takes 192 s, sending and building included (20 s, then 173 s of tests);
- this Mac takes 279 s for the same suites alone (load about 50);
- the mini takes 470–680 s.

Off the critical path, while the GPU suites and the digests run, a change to BlastModel's widely
used code lands up to about ten minutes sooner on the mini.

**Not yet:** teaching `BombCAD sweep` and `BombCAD ensemble` to hand their CPU-only cases to a
Linux host (emmettl/bombcad-work#48).
