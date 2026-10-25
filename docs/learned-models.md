# Learned models: training on the PCs

BombCAD's learned models want a CUDA GPU, and on the Studio they would compete with simulations
for its GPU. The user's two Windows PCs each have a 12 GB NVIDIA card: an RTX 3080 Ti desktop
(912 GB/s) and a laptop with a mobile RTX 4080 (Ada, 432 GB/s). Both run PyTorch on CUDA inside
WSL2. The data are BombCAD's own runs, as plain files. No solver code moves to the PCs: the Studio
runs the simulations, the PCs train on what they produce, and the models and logs come back.

This page covers:

- the set-up the user does on each PC;
- the runner that sends a job to a PC;
- the first model's data and training script: [Horizons](roadmap.md#horizons) item 2's learned
  field model, which predicts a district's peak overpressure and impulse at street level from its
  plan;
- what is not done yet.

**Standing: judged, not used.** The field model has trained on the 200 runs and been judged against
the façade load surrogate at held-out runs' ground-floor façades
([below](#the-field-model-against-the-façade-surrogate-20-october-2026)). No model is used by the
app.

## Setting up a PC (the user)

Each step is done once on each PC. The user decides on, and makes, any firewall or system change.

1. **The NVIDIA driver.** Install the current Game Ready or Studio driver for Windows from NVIDIA.
   It also provides CUDA inside WSL2. Don't install a Linux NVIDIA driver inside WSL.
2. **WSL2 and Ubuntu.** In an administrator PowerShell, run `wsl --install -d Ubuntu-24.04`, then
   restart and make the Linux user. Check that the GPU shows up inside Ubuntu:

   ```bash
   nvidia-smi
   ```

3. **SSH inside Ubuntu.** Install the server and `rsync` (the runner uses both), and start the
   server:

   ```bash
   sudo apt update && sudo apt install -y openssh-server rsync python3-venv
   sudo systemctl enable --now ssh
   ```

4. **Reaching it from the Studio.** WSL2 sits behind Windows' own network, so the Studio can't
   reach it directly. Use one of these:
   - **Tailscale** inside Ubuntu (`tailscale up`). The Studio then reaches it by its tailnet name.
     No Windows port is opened.
   - **Windows' port forwarding** to WSL, plus a firewall rule for that one port, limited to the
     local network. Turning on WSL's mirrored networking (`networkingMode=mirrored` in
     `%UserProfile%\.wslconfig`) makes this simpler.

5. **Key-only SSH.** On the Studio, copy its public key to the PC:

   ```bash
   ssh-copy-id -i ~/.ssh/id_ed25519.pub <user>@<pc-address>
   ```

   On the PC, set `PasswordAuthentication no` in `/etc/ssh/sshd_config`, then
   `sudo systemctl restart ssh`.

6. **A Host entry on the Studio.** In `~/.ssh/config`, add one entry per PC, using the names the
   runner knows:

   ```
   Host bombcad-pc
       HostName <the desktop's address or tailnet name>
       User <user>
       IdentityFile ~/.ssh/id_ed25519
   Host bombcad-laptop
       HostName <the laptop's address or tailnet name>
       User <user>
       IdentityFile ~/.ssh/id_ed25519
   ```

   Check with `ssh bombcad-pc nvidia-smi`.

7. **The Python environment.** Inside Ubuntu, make `~/bombcad-ml/venv` with PyTorch for CUDA
   (PyTorch's site gives the current CUDA wheel's index URL):

   ```bash
   python3 -m venv ~/bombcad-ml/venv
   ~/bombcad-ml/venv/bin/pip install --upgrade pip
   ~/bombcad-ml/venv/bin/pip install torch numpy --index-url https://download.pytorch.org/whl/cu128
   ~/bombcad-ml/venv/bin/python -c "import torch; print(torch.cuda.is_available(), torch.cuda.get_device_name())"
   ```

   It should print `True` and the card's name. Then check the card from the Studio with the
   estimate (below):

   ```bash
   python3 -I Scripts/ml/remote-train.py bombcad-pc $BOMBCAD_DATA/ml/datasets/smoke Scripts/ml/train_field.py --job estimate-pc --args --estimate --grid 256,512
   ```

Keep the data in WSL's own file system (`~`), not under `/mnt/c`. The Windows file system is slow
from inside WSL. WSL's disk image lives on C: and only grows, so keep room on C:
([Disk space on the PCs](#disk-space-on-the-pcs)). Don't let the laptop sleep or run on battery during a job. On long jobs it
throttles, so give it short ones (its default timeout is 2 hours).

## The runner: `Scripts/ml/remote-train.py`

```bash
python3 -I Scripts/ml/remote-train.py <host> <dataset-dir> <train-script> [--job name] [--timeout 6h] [--wait 1h] [--venv path|none] [--dry-run] [--args ...]
```

From the Studio, it:

1. **Names the dataset by its content.** It hashes the dataset folder's files (hidden files left
   out; the hashes are cached in `~/.cache/bombcad-ml`) and sends it to
   `~/bombcad-ml/datasets/<name>-<hash>/` on the host, unless that folder is already there and
   complete. A dataset is sent once, however many jobs use it. A dataset that changes gets a new
   folder.
2. **Copies the script and the runner itself** to `~/bombcad-ml/jobs/<job>/`. The runner runs on
   the host as well, so both ends agree on the lock and the layout.
3. **Takes the host's lock** (`~/bombcad-ml/lock`): one job per GPU. The lock belongs to a process
   that is still alive on the same boot, so a crash or a reboot never leaves the host blocked. With
   `--wait` the runner waits for the lock; without it, it gives up at once (exit 75).
4. **Runs the script** in the host's environment (`~/bombcad-ml/venv` unless `--venv` says
   otherwise) as `python -u <script> --data <dataset> --out out [args…]`, streaming its output to
   the Studio. Everything after `--args` goes to the script. Stopping the runner on the Studio
   hangs up the host's end, which stops the script and lets the lock go. At `--timeout` (the
   host's default: 24 h on the desktop, 2 h on the laptop) the host stops the script, and the exit
   status is 124.
5. **Brings back the job's folder** (`out/`, `log.txt`, `status.json`, the script) to
   `$BOMBCAD_DATA/ml/<job>/`, and writes `job.json` there. `job.json` records the
   host, the GPU as `nvidia-smi` names it, the Python, the dataset's hash and whether it was sent,
   the script's hash, the arguments, the start and end times, the exit status, and the host's
   free space before and after (`hostSpace`).
6. **Tidies the host.** Once the results are back and checked (`job.json` says `resultsCopied`, and
   the host's `status.json` came with them), the host marks the job collected. Then, if no job
   holds its lock, it prunes (see [Disk space on the PCs](#disk-space-on-the-pcs)).

Before it sends anything, the runner checks the host's free space, and refuses with exit 73 if
the send would leave too little.

`--dry-run` reaches the host and says what would happen without sending or running anything: the
dataset's size, whether the host already has it, the environment, the lock and the command.

An unreachable host fails cleanly, before anything is sent (exit 69). A host without the
environment gets exit 78 and a pointer to this page.

The hosts are in one block at the top of the file, `HOSTS`:

| Host | What | Environment | Lock | Default timeout |
|---|---|---|---|---|
| `bombcad-pc` | the desktop, RTX 3080 Ti | `~/bombcad-ml/venv` | `~/bombcad-ml/lock` | 24 h |
| `bombcad-laptop` | the laptop, mobile RTX 4080 | `~/bombcad-ml/venv` | `~/bombcad-ml/lock` | 2 h |
| `scrimply-ci-tb` | the CI Mac mini, for testing the runner | its own `python3` | `~/bombcad-remote/lock` | 1.5 h |

On the mini, the runner takes the lock that BombCAD's checks and workers take there
(Scripts/remote.py), so a test job never runs beside a check. Nothing is installed on the mini.

A stopped training run carries on from where it stopped: pass the old job's checkpoint, for
example `--args --resume ~/bombcad-ml/jobs/<old job>/out/checkpoint.pt`. Only the newest few
jobs stay on the host (below); an older job's checkpoint is in its results on the Studio.

## Disk space on the PCs

On 23 October 2026 the desktop's C: drive filled up. WSL keeps its whole Linux file system in one
disk image on C: (`ext4.vhdx`), which grows as WSL writes and never shrinks by itself. With C: full,
WSL's file system gave I/O errors. Nothing had kept the runners' folders in bounds:
- every dataset version was a full copy in `~/bombcad-ml/datasets`;
- every job's folder stayed in `~/bombcad-ml/jobs`;
- every Linux-lane check and sweep left its own source snapshot in `~/bombcad-sweeps/staging`
  (106 of them, 18 GB).

The datasets and jobs were cleared that day, and the snapshots' sources too (18 GB, listed in
`~/bombcad-sweeps/cleanup-report-20261023.json` on the PC). Since then the runners keep themselves
in bounds and refuse to fill a disk.

**What stays on the host.**
- **Datasets:** the last 2 used (`--keep-datasets`), by last use. Older ones are removed only when
  no job holds `~/bombcad-ml/lock` and no live process names them. A dataset whose send was left
  half done goes after a day.
- **Jobs:** the newest 3 (`--keep-jobs`), for debugging. An older job's folder goes once its
  results are back on the Studio and checked; a job whose results never came back stays.
- **Sweep and lane stages** (`~/bombcad-sweeps/staging`): see
  [Linux](linux.md#retention-and-free-space-23-october-2026). The build checkout,
  `~/bombcad-sweeps/src`, is one folder, reused by every run.
- Nothing else is touched: not the environment, `~/bombcad-ml/experiments`, or Codex's CUDA
  folders (`~/bombcad-cuda`, `~/bombcad-*-<hash>`, `~/bombcad`).

To prune by hand, or see what would go:

```bash
python3 -I Scripts/ml/remote-train.py prune bombcad-pc --dry-run
python3 -I Scripts/remote-sweep.py prune bombcad-pc --dry-run
```

**Free space.** Before sending a dataset or a source, both runners ask the host for its free space
on two disks:
- the home's file system, which inside WSL is its virtual disk (WSL's `df` there shows the
  image's maximum size, about 1 TB, not what C: can hold);
- inside WSL, the Windows drive under `/mnt/c`, which holds the disk image. This is the one that
  filled.

A send that would leave less than 50 GB on either, or 15% of a disk smaller than 333 GB, is
refused: the training runner with exit 73, and the Linux lane is then "not there", so its suites run
on the Mac. `BOMBCAD_HOST_MIN_FREE_GB` and `BOMBCAD_HOST_MIN_FREE_PERCENT` move the floor.

**Deleting inside WSL does not give C: its space back.** The image stays as large as it ever grew.
Compacting it is a Windows-side job for the user:

1. Close everything using WSL, then in PowerShell run `wsl --shutdown`.
2. Compact the image. The runner's refusal message names the images it found. On the desktop the
   Ubuntu image is `C:\Users\<user>\AppData\Local\wsl\{19241bd4-…}\ext4.vhdx`.
   - With Hyper-V's PowerShell module (Windows Pro), in an administrator PowerShell:
     `Optimize-VHD -Path <ext4.vhdx> -Mode Full`.
   - Otherwise with diskpart, in an administrator prompt: `diskpart`, then
     `select vdisk file="<ext4.vhdx>"`, `attach vdisk readonly`, `compact vdisk`, `detach vdisk`,
     `exit`.

Recent WSL versions can also make the image sparse, so that it gives space back by itself
(`wsl --manage <distro> --set-sparse true`). That is a setting for the user to decide on.

**On 23 October, after the clean-up,** the desktop had:
- 867 GB free on WSL's virtual disk, with 160 GB used;
- 30 GB free of 998 GB on C:;
- a 175 GB Ubuntu image and a second, 30 GB image.

So C: is under the 50 GB floor, and both runners refuse to send to the desktop until the user
frees space on C: or compacts the image. Compacting would give back about 15 GB (the image is 175
GB, with 160 GB in use).

## The learned field model's data

### What one run gives

`scenebench field-export` makes one training pair from one run. It lays out a district from map
files, as `district-scene` does: a map's buildings, an optional elevation grid and building
heights, with the charge on the ground at `--centre`. It then runs the air on the recommended
configuration, on 4 m cells by default, with the top set by the open-face rule
(`DistrictLayout.top`). The run goes on until Kingery–Bulmash's arrival at the domain's corners
plus the positive phase there, and a tenth more. No envelope histories are recorded, so the run
costs only the air.

```bash
scenebench field-export --osm district.osm [--dem ground.asc] [--heights heights.tif] --centre lon,lat --radius 1024 --dx 4 --mass 200000 --ground saturated --id name --out folder
```

From the solver's peak overpressure and impulse fields, it writes into the folder:

- **`inputs.npy`**: channels × rows × columns, on the air's plan grid. Rows run from the south
  going north; columns from the west going east. The channels are:
  - the tallest block over each cell's centre, in metres above the ground (0 where there is none);
  - the ground, relative to the ground under the charge;
  - the distance from the charge in plan;
  - ln Z;
  - Kingery–Bulmash's incident peak and impulse at Z. Below Z = 0.2 they are held at their
    values there; beyond Z = 40 they are carried on in log-log.
- **`targets.npy`**: the run's peak overpressure (Pa) and positive impulse (Pa s) 2 m over the
  ground (`--above`). Each is read between the two cells whose centres span that height, or from
  the nearer open one.
- **`mask.npy`**: 1 where the target is air at that height, at least 4 cells (`--edge`) from the
  side faces.
- **`meta.json`**: the grid, the charge's mass and position, the cells, the solver's memory, the
  steps, the wall time, whether the run stayed stable, the channels' names and units, and the
  arguments.

The arrays are little-endian float32 `.npy` files (format 1.0), with the header written by
SceneBench itself. `numpy.load` reads them, and so does `standin_train.py` without NumPy.

`district-compare --export-field folder` writes the same files from a district-compare run. Its
runs have been on the mapped start since 20 October (`--balloon-start` for the balloon), and
`meta.json` says which.

The export is off unless asked for, and it only reads fields the solver already keeps. Other
targets are unchanged: `blastbench digest --recommended` was the same before and after, on release
builds (see [testing](#what-was-tested-where)).

`field-export --phase-timings` additionally writes a local phase receipt for preparation,
solver setup including compilation, recorder setup, solve and output. It leaves the numerical
arrays unchanged. The [resumable field queue](field-queue.md) uses these observations and
existing Metal references for bounded replay admission; it does not publish a training index.

**`--first-phase`** (to `field-export`, or to `district-compare --export-field`) adds a third
target, `firstPhaseImpulse`: the first positive phase's impulse, by the façade recorder's rule
(from the start until the overpressure first falls below nothing after reaching half its peak).
The solver keeps it only when asked: a small kernel (`FirstPhaseColumns`, `sampleFirstPhase`)
reads each plan cell's column between the same two cells the export reads, after every step. The
rule wants the history's whole peak, which a run knows only at its end. So a phase stands while its
peak is at least half the peak so far; a later sample more than twice its peak starts it again
there, counting the impulse before it, as the rule does. Within a mapped start's radius the
columns take the one-dimensional solution's peak and impulse, the phase still going. It only
observes: the run is the same to the bit with it or without
([below](#the-first-phase-target-and-glass-by-side-20-october-2026)).

### The run list: `Scripts/ml/field-runs.json`

`python3 -I Scripts/ml/field-runs.py plan` writes the list. It is seeded, so the same code always
gives the same list, and a script test checks that the committed file matches the plan. The list
has 200 runs:

- **150 over made-up districts.** `Scripts/ml/make_district.py` draws them; they are not real
  places. There are five styles: perimeter blocks round courtyards, detached houses on a grid,
  towers in plazas, industrial sheds, and a mix with a quarter turned 30°. Each style has six
  seeds, on flat ground, a slope, a hill or a valley. Each layout gets 5 runs, one yield from each
  fifth of the log range 0.05–2 kt, with the charge up to 150 m from the middle.
- **50 over Beirut.** These use the inputs of the [Beirut page](beirut-2020.md)'s runs (OSM
  buildings, Copernicus DEM, GHSL heights). The charge is at the port or at nine points in the city
  0.7–1.9 km from it, again with one yield from each fifth of the range.

Every run is on 4 m cells, with the fields read 2 m over the ground. Below 0.5 kt the domain is
2,048 m square (512 × 512 cells); from 0.5 kt it is 2,560 m (640 × 640). The top is 4 m/kg^(1/3)
over the charge: 148–504 m.

**Estimated cost: 5.2 GPU hours on the Studio, one run at a time.** That is 0.5 to 3.5 minutes a
run, with up to 7 GB declared to gpu-slot. On gpu-slot's slots it is about two hours of wall time.
The estimate scales the six smoke runs' measured cost:

- 1.0 ns a cell-step;
- 573 steps a simulated second on 4 m cells;
- 73 bytes a cell;
- 40 s more for each Beirut run, to read its 12,000 × 12,000 height grid.

Quiet, the smoke runs took 0.46–0.65 ns a cell-step, so the total could be as little as 3 hours.
The CI mini takes about 2.8 times as long (one smoke case: 5.8 s against 2.1 s, with identical
files). The dataset comes to about 2.3 GB. `python3 -I Scripts/ml/field-runs.py estimate` prints
the totals.

### Running the list

```bash
python3 -I Scripts/ml/field-runs.py run --set main --dataset $BOMBCAD_DATA/ml/datasets/fields-v1
```

The runs go one after another under gpu-slot, each declaring its memory and limited to 1.5 hours.
Runs already in the dataset are skipped, so a stopped list carries on where it left off. Each
run's output goes to `logs/<id>.txt`, and `dataset.json` indexes the finished runs.

`--on scrimply-ci-tb` sends the cases to the mini instead, through the runner. scenebench, its
bundles and the cases' inputs go as one dataset, and `field_job.py` runs them there under the
mini's lock. `--only`, `--limit` and `--dry-run` pick and preview. `fit <dataset>` refits the cost
constants from a dataset's runs.

The smoke set, six runs on 256 × 256 cells of 20–100 t (five made-up districts and Beirut 900 m
south of the port), is in `$BOMBCAD_DATA/ml/datasets/smoke/`. Datasets and model
weights stay on StudioData and are never committed.

## Training: `Scripts/ml/train_field.py`

```bash
python train_field.py --data DATASET --out OUT --model unet|fno [--epochs 40] [--batch 8] [--crop 256] [--holdout 0.2] [--split-by run|layout] [--holdout-layouts beirut,made-*-s6] [--impulse all|first] [--resume auto]
```

- **Inputs.** Six channels, each standardised over the training runs:
  - the buildings' heights;
  - their footprints;
  - the ground;
  - ln Z;
  - the logs of Kingery–Bulmash's peak and impulse.
- **Outputs.** The logs of the run's peak overpressure and impulse: every positive phase's
  (`--impulse all`, the default) or the first phase's (`--impulse first`, the `firstPhaseImpulse`
  target of `--first-phase` exports; a run without it stops the training). By default the network
  predicts corrections to Kingery–Bulmash's logs (`--no-residual` predicts the logs outright). The
  loss is the squared error of the logs over the mask, leaving out peaks under 10 Pa.
- **Models.**
  - `--model unet`: a 2-D U-Net with `--depth` halvings and `--width` channels at the top, doubling
    at each level, using GroupNorm and GELU.
  - `--model fno`: a Fourier neural operator with `--layers` Fourier layers of `--width` channels,
    each keeping the lowest `--modes` frequencies each way. The map is padded so that its edges
    don't wrap into each other, and the transforms run in float32.
- **Augmentation.** Random crops (`--crop`, no larger than the smallest run), each turned by one
  of the eight flips and rotations of the square. Nothing in a plan prefers a direction.
- **The split.** Whole runs are held out (`--holdout 0.2`, drawn with `--seed`, or named with
  `--holdout-runs`). `--split-by layout` holds out every run of a layout together, the stricter
  test. `--holdout-layouts beirut,made-*-s6` holds out every run of the layouts matching the shell
  patterns: here all of Beirut and each made-up style's sixth layout, 75 runs.
- **The judge.** After each epoch the held-out runs are judged on their full maps. By bands of
  scaled distance (Z 0–3, 3–5, 5–7, 7–10, 10–14, 14–20, 20–28, 28–40 and beyond), it gives the
  median of predicted over run, as a ratio, and the standard deviation of its log, for peak and
  impulse. This is how `scenebench surrogate-judge` judges the façade surrogate. Kingery–Bulmash
  alone is judged the same way beside it.
- **Precision.** Mixed precision on CUDA (bfloat16 where the card has it, as both PCs do; float16
  with a gradient scaler otherwise) and on MPS (float16). The CPU runs in float32. `--device` and
  `--amp` override the choice.
- **Checkpoints.** `OUT/checkpoint.pt` after every epoch (the model, the optimiser, the random
  states, the split and the history), `OUT/best.pt` by held-out loss, and `OUT/metrics.json`.
  `--resume auto`, the default, carries on from `OUT/checkpoint.pt`. A path resumes from another
  job's checkpoint. The learning rate is a warm-up and a cosine over the steps of `--epochs`, so a
  resumed run asked for more epochs stretches the curve rather than restarting it.

### Smoke training on the Studio

These ran on MPS, on the six smoke runs: five to train on, `smoke-perimeter-50t` held out.

| Model | Size | Train loss, first epoch to last | Held-out loss: untrained / trained | Kingery–Bulmash alone | Held-out peak ratio / log-SD | Impulse ratio / log-SD |
|---|---|---|---|---|---|---|
| U-Net, width 16, depth 3 | 0.49 M parameters | 0.085 → 0.027 (20 epochs, resumed at 12) | 0.355 / 0.088 | 0.203 | 0.87 / 0.29 (KB 1.44 / 0.29) | 0.84 / 0.20 (KB 0.70 / 0.21) |
| FNO, width 16, 12 modes, 4 layers | 0.59 M parameters | 0.121 → 0.037 (12 epochs) | 0.195 / 0.088 | 0.203 | 0.87 / 0.30 (KB 1.44 / 0.29) | 0.88 / 0.21 (KB 0.70 / 0.21) |

Each used 25 steps of 8 crops of 128 cells a side per epoch, 23–60 ms a step, under gpu-slot. The loss falls
and the metrics print. On five training runs the model has learned only the run's offset from
Kingery–Bulmash: on 4 m cells the run's peaks are about 0.7 of Kingery–Bulmash's. It has not
learned the shielding, so the log-SD stays at Kingery–Bulmash's. That needs the full list.

### Sizing for the 12 GB cards: `--estimate`

```bash
python train_field.py --estimate --model both --grid 256,512 --batch 8
```

For each model and grid, it prints:

- the parameters;
- the memory of a training step: what backward keeps, from forward hooks under autocast, plus the
  float32 weights, gradients and Adam's moments, plus 1 GB for CUDA's context and workspace;
- the step's arithmetic;
- a step's time, measured on the machine's own device, and estimated for each PC. The estimate
  assumes 35% of the card's float16 tensor peak (with float32 accumulation) and 60% of its memory
  bandwidth, whichever limits.

These are the defaults (width 32; U-Net depth 4; FNO 24 modes, 4 layers), at batch 8:

| Model, grid | Parameters | Memory, about | Batch that fits 12 GB | 3080 Ti, estimated | 4080 Laptop, estimated | Studio MPS, measured |
|---|---|---|---|---|---|---|
| U-Net, 256² | 7.9 M | 2.0 GB | 101 | 56 ms a step | 39 ms | 114 ms |
| U-Net, 512² | 7.9 M | 4.5 GB | 25 | 225 ms | 155 ms | 435 ms |
| FNO, 256² | 9.5 M | 2.2 GB | 86 | 25 ms | 52 ms | 364 ms |
| FNO, 512² | 9.5 M | 5.0 GB | 22 | 92 ms | 194 ms | 482 ms |

Both models fit either card at 512² with batch 8, with room to spare. The FNO's estimated times
are the less sure: its transforms are memory-bound in ways the simple model only approximates, and
on MPS its complex arithmetic is slow. The estimate measures on CUDA when it runs on a PC, and that
measurement replaces these figures.

## What was tested where

- **The runner, against the mini.** These were run on 20 October:
  - a dry run;
  - an end-to-end run of `standin_train.py` (pure Python) on the smoke dataset: the 14 MB sent,
    the loss printed, `out/` and `job.json` back;
  - a second job: the dataset found already there, and not sent;
  - a 5 s timeout: exit 124, and `timedOut` in `job.json`;
  - stopping the runner on the Studio mid-job: the mini's lock was let go and the script stopped;
  - `train_field.py` through the runner with `--dry-run` (the mini has no PyTorch);
  - `bombcad-pc`, which isn't set up yet: "unreachable", exit 69.

  The unit tests (`Scripts/ml/test-remote-train.py`, in `make ci-test`) cover:
  - the arguments;
  - the hosts' settings;
  - the lock: one holder, dead owners, earlier boots, Scripts/remote.py reading the same owner;
  - the dataset's hash and its cache;
  - `job.json`.

  `Scripts/ml/test-field-runs.py` checks the run list against its plan and its bounds.
- **The export.** It was tested on the Studio's six smoke runs. One case also ran on the mini
  through `field-runs.py run --on scrimply-ci-tb`, and its arrays were bit-identical to the
  Studio's. `blastbench digest --recommended` was the same on release builds before and after the
  change.
- **Training.** The smoke trainings above ran on MPS, with a CPU check of two epochs. Resuming was
  tested by carrying on a 12-epoch U-Net run to 20 epochs. `--estimate` ran on the Studio. Nothing
  has run on CUDA yet.

## The field model against the façade surrogate (20 October 2026)

Judged at held-out runs' ground-floor façades (emmettl/bombcad-work#33, emmettl/bombcad-work#47), with
`Scripts/ml/judge_field.py`. In short: on peak overpressure the field model beats the surrogate
at Beirut's façades 50–700 m from the charge in every split, even having never seen Beirut. On
impulse it predicts a different quantity from the one the surrogate and the damage use, so it
cannot replace the surrogate there yet.

### Where the two meet

The two predict different things:

- **The field model** gives the peak overpressure and positive impulse 2 m over the ground, on
  the run's plan cells.
- **The surrogate** gives each façade strip's load: a storey of one block's side, its peak and
  its first positive phase's impulse.

On 4 m cells the air 2 m over the ground is the first layer of cells, the layer the recorder
reads a ground-floor strip from. So each ground-floor strip (its storey spanning 2 m over the
ground) is matched to the air cells beside its face, along its width, in the run's mask:

- the truth is the run's own field there, the mean over those cells;
- the field model's value is the mean of its predictions over the same cells;
- the surrogate's is its strip's, from `scenebench field-surrogate`. That command lays the run's
  district out again from its own arguments and calls `FacadeLoadSurrogate.estimate`; it runs
  nothing.

Strips beyond 0.85 of the half side are left out, as `surrogate-judge` leaves them out. The
judgement is the same as the surrogate's: the median of predicted over run, then the standard
deviation of the log.

**Checked against the recorder.** Four held-out runs were run again with
`district-compare --save-loads --export-field`, at the dataset run's top (`--height`). Their
fields came out bit-identical to the dataset's, and they also give the recorder's own strips:
beirut-p2-4, beirut-p4-3, made-mixed-s6-1 and made-perimeter-s6-4, 65,934 ground-floor strips.
Against those strips:

- **Peak: the same quantity.** The run's field in front of a strip gives the strip's peak at
  1.00, log-SD 0.05.
- **Impulse: not the same.** The field's impulse is every positive phase. The strip's, and the
  surrogate's, is the first. The field's is 1.34 times the strip's (log-SD 0.11): 1.23 in sight
  of the charge, 1.33–1.36 behind buildings.

So peaks are judged fairly against the field, everywhere. Impulses are judged fairly only against
the recorder, and against the field the surrogate reads about 1/1.34 low.

### The three models

| Model | Trained on | Held out |
|---|---|---|
| Round 1, `field-unet-main-1` (bombcad-pc, 60 epochs) | 154 runs | 39, by run |
| Round 2, `field-unet-main-2` (bombcad-pc, 300 epochs) | 160 runs | 40, by run |
| `field-unet-studio-layouts` (Studio, MPS, float32, 60 epochs) | 125 runs | 75: all 50 of Beirut and each made-up style's sixth layout |

Rounds 1 and 2 hold out runs, not layouts: a held-out run's buildings were in training at other
yields or charge points, and Beirut's map at nine other points. The Studio model is the strict
test: it never saw Beirut. Its best held-out loss was 0.028, against Kingery–Bulmash's 0.098 (the
rounds by run: 0.019 and 0.0115).

### Beirut's façades 50–700 m, the first look's own ground

Against the run's field. The surrogate's and Kingery–Bulmash's numbers differ by row only
because each split holds out different runs.

| Split | Strips | Field model, peak | Impulse | Surrogate, peak | Impulse | KB incident, peak | Impulse |
|---|---|---|---|---|---|---|---|
| Round 1 (by run) | 113,677 | 0.97 / 0.23 | 0.98 / 0.15 | 1.11 / 0.46 | 0.72 / 0.35 | 1.29 / 0.42 | 0.75 / 0.27 |
| Round 2 (by run) | 130,957 | 0.99 / 0.17 | 0.99 / 0.13 | 1.10 / 0.45 | 0.73 / 0.34 | 1.25 / 0.43 | 0.77 / 0.27 |
| Beirut never seen | 598,743 | 1.07 / 0.28 | 1.21 / 0.18 | 1.08 / 0.44 | 0.72 / 0.32 | 1.25 / 0.42 | 0.74 / 0.25 |

By distance, with Beirut never seen:

| Distance | Strips | Field model, peak | Impulse | Surrogate, peak | Impulse | KB incident, peak | Impulse |
|---|---|---|---|---|---|---|---|
| 50–100 m | 10,013 | 1.25 / 0.66 | 1.19 / 0.36 | 2.09 / 0.94 | 1.09 / 0.63 | 3.40 / 0.90 | 0.83 / 0.51 |
| 100–200 m | 39,619 | 1.26 / 0.42 | 1.23 / 0.26 | 1.52 / 0.62 | 0.96 / 0.44 | 1.93 / 0.60 | 0.79 / 0.37 |
| 200–350 m | 91,761 | 1.14 / 0.30 | 1.25 / 0.19 | 1.33 / 0.46 | 0.83 / 0.36 | 1.50 / 0.41 | 0.77 / 0.26 |
| 350–500 m | 151,517 | 1.07 / 0.25 | 1.22 / 0.17 | 1.10 / 0.39 | 0.72 / 0.29 | 1.27 / 0.34 | 0.75 / 0.22 |
| 500–700 m | 305,833 | 1.04 / 0.22 | 1.20 / 0.16 | 0.99 / 0.33 | 0.68 / 0.24 | 1.15 / 0.31 | 0.73 / 0.21 |

By the strip's sight of the charge, with Beirut never seen. "Street" is a street the line from
the charge runs down (the surrogate's canyon terms); "facing away" is a negative cosine:

| Sight | Strips | Field model, peak | Impulse | Surrogate, peak | Impulse | KB incident, peak | Impulse |
|---|---|---|---|---|---|---|---|
| In sight, facing | 4,835 | 1.07 / 0.39 | 1.11 / 0.24 | 0.97 / 0.60 | 0.88 / 0.48 | 0.81 / 0.56 | 0.71 / 0.45 |
| Shielded, 1–3 crossed | 21,418 | 1.06 / 0.40 | 1.13 / 0.22 | 1.15 / 0.67 | 0.89 / 0.47 | 1.01 / 0.60 | 0.74 / 0.28 |
| Shielded, 4 or more | 156,192 | 1.08 / 0.25 | 1.21 / 0.16 | 1.24 / 0.43 | 0.81 / 0.33 | 1.17 / 0.36 | 0.73 / 0.22 |
| Street | 118,185 | 1.11 / 0.29 | 1.21 / 0.19 | 1.19 / 0.46 | 0.76 / 0.35 | 1.17 / 0.40 | 0.71 / 0.24 |
| Facing away | 298,113 | 1.06 / 0.27 | 1.22 / 0.18 | 0.97 / 0.37 | 0.67 / 0.24 | 1.35 / 0.41 | 0.77 / 0.25 |

### Against the recorder's strips

These are the two Beirut runs' 23,394 ground-floor strips at 50–700 m. The truth is the
recorder's peak and first-phase impulse, the surrogate's own quantities:

| | Peak | Impulse |
|---|---|---|
| The run's field at the strip | 1.00 / 0.05 | 1.32 / 0.12 |
| Round 2 (both runs held out) | 1.00 / 0.14 | 1.32 / 0.12 |
| Beirut never seen | 1.02 / 0.26 | 1.69 / 0.18 |
| Surrogate | 1.05 / 0.38 | 0.96 / 0.26 |
| Kingery–Bulmash incident | 1.31 / 0.37 | 0.99 / 0.18 |
| Kingery–Bulmash raised by the facing (the surrogate's base) | 1.59 / 0.43 | 1.12 / 0.29 |

Over all four runs (65,934 strips):

- Beirut never seen: 0.99 / 0.22 in peak, 1.55 / 0.18 in impulse;
- the surrogate: 0.99 / 0.35 and 0.95 / 0.22;
- Kingery–Bulmash incident: 1.16 / 0.38 and 1.02 / 0.17.

### By scaled distance and by layout, with Beirut never seen

All 75 held-out runs, 1,661,822 strips, against the run's field:

| Z, m/kg^(1/3) | Strips | Field model, peak | Impulse | Surrogate, peak | Impulse | KB incident, peak | Impulse |
|---|---|---|---|---|---|---|---|
| 0–3 | 74,362 | 1.20 / 0.49 | 1.17 / 0.30 | 1.55 / 0.73 | 1.00 / 0.51 | 1.89 / 0.76 | 0.86 / 0.47 |
| 3–5 | 131,117 | 1.09 / 0.28 | 1.18 / 0.18 | 1.34 / 0.42 | 0.84 / 0.33 | 1.24 / 0.40 | 0.83 / 0.23 |
| 5–7 | 202,686 | 1.04 / 0.23 | 1.16 / 0.16 | 0.99 / 0.35 | 0.73 / 0.25 | 1.07 / 0.34 | 0.82 / 0.20 |
| 7–10 | 416,791 | 1.02 / 0.21 | 1.13 / 0.15 | 0.89 / 0.30 | 0.73 / 0.19 | 1.01 / 0.30 | 0.80 / 0.18 |
| 10–14 | 457,667 | 1.02 / 0.19 | 1.11 / 0.15 | 0.93 / 0.28 | 0.70 / 0.19 | 1.06 / 0.28 | 0.75 / 0.18 |
| 14–20 | 284,765 | 1.02 / 0.19 | 1.11 / 0.17 | 0.97 / 0.28 | 0.63 / 0.20 | 1.20 / 0.28 | 0.66 / 0.20 |
| 20–28 | 90,375 | 0.98 / 0.19 | 1.03 / 0.18 | 0.96 / 0.27 | 0.54 / 0.22 | 1.34 / 0.26 | 0.60 / 0.21 |
| 28–40 | 4,059 | 0.91 / 0.25 | 0.92 / 0.21 | 0.87 / 0.37 | 0.50 / 0.28 | 1.38 / 0.35 | 0.59 / 0.28 |

| Layout | Strips | Field model, peak | Impulse | Surrogate, peak | Impulse | KB incident, peak | Impulse |
|---|---|---|---|---|---|---|---|
| Beirut | 1,446,015 | 1.04 / 0.24 | 1.15 / 0.17 | 0.97 / 0.38 | 0.69 / 0.27 | 1.12 / 0.37 | 0.75 / 0.22 |
| Grid | 89,723 | 0.99 / 0.12 | 0.99 / 0.08 | 0.90 / 0.25 | 0.92 / 0.18 | 1.02 / 0.22 | 0.97 / 0.12 |
| Industrial | 7,375 | 0.97 / 0.09 | 0.98 / 0.05 | 0.94 / 0.16 | 0.78 / 0.17 | 1.08 / 0.27 | 0.93 / 0.11 |
| Mixed | 55,326 | 0.97 / 0.17 | 0.98 / 0.10 | 0.93 / 0.28 | 0.68 / 0.20 | 1.05 / 0.33 | 0.76 / 0.18 |
| Perimeter | 50,686 | 0.98 / 0.17 | 1.04 / 0.14 | 0.95 / 0.35 | 0.66 / 0.26 | 1.06 / 0.41 | 0.70 / 0.25 |
| Towers | 12,697 | 0.98 / 0.18 | 1.03 / 0.12 | 1.11 / 0.28 | 0.57 / 0.21 | 1.23 / 0.39 | 0.67 / 0.21 |

The rounds by run, over all their held-out strips:

- round 1 (497,686 strips): 0.97 / 0.18 in peak and 0.99 / 0.13 in impulse;
- round 2 (544,677): 0.98 / 0.13 and 1.01 / 0.11;
- on the same strips, the surrogate gave 0.94 / 0.37 and 0.72–0.73 / 0.28–0.29.

### What it says

- **Peak: the field model wins where it matters.** Never having seen Beirut, it scatters by
  0.22–0.30 at Beirut's façades 200–700 m, where the surrogate scatters by 0.33–0.46. Its median
  is 1.04–1.14, against the surrogate's 0.99–1.33. Close in, at 50–200 m, both run high:
  1.25 / 0.42–0.66 against 1.52–2.09 / 0.62–0.94. Behind buildings and down streets it holds
  0.25–0.29 where the surrogate gives 0.43–0.46. Trained with Beirut's map, at other points and
  yields (round 2), it scatters by 0.17 against the field and 0.14 against the recorder.
- **Impulse: not yet comparable as a product.** Its scatter is lower than the surrogate's, both
  against the recorder (0.18 against 0.26, Beirut never seen) and against the field (0.18 against
  0.32). But it learned all the positive phases, 1.3 times the first phase the SDOF and the glass
  take. Never having seen Beirut, it also runs 1.2 times high there.
- **The surrogate on these runs is no better than Kingery–Bulmash's incident values.** Against
  the recorder it scatters by 0.35–0.38 in peak (Kingery–Bulmash 0.37–0.38) and 0.22–0.26 in
  impulse (0.17–0.18). It runs 1.3–2.1 times high within 350 m. Its terms were fitted to
  district-compare runs on the balloon start, and these runs are on the mapped start; that
  difference may be most of its close-in excess. This is for its next refit to check; nothing was
  changed.
- **Limits of this judgement:**
  - only ground-floor strips: the field model knows nothing above 2 m;
  - only 4 m runs, with their artefacts, as the truth for both;
  - Beirut's 50 runs share one map, so "never seen" means no Beirut run at all, not a new city.

### Gotcha: float16 on MPS does not train

The first Studio run used train_field.py's default for MPS, float16 autocast with no gradient
scaler. Its training loss stayed at 0.046–0.053 for 46 epochs. In float32 (`--amp off`) the same
run fell to 0.015. On MPS, use `--amp off` until the trainer scales float16's gradients there.
The default is unchanged.

### What it would take

- **A first-phase impulse target.** field-export would write the first positive phase's impulse
  per cell, by the recorder's rule (from the start until the overpressure first falls below
  nothing after reaching half its peak), beside the all-phases impulse. That needs a per-cell
  accumulator and flag in the solver, kept only when asked. Then the runs would be exported again
  and the model retrained.
- **Storeys above the ground floor.** These need fields at more heights (`--above`), or a façade
  head trained on `--save-loads` strips.
- **The decision.** A round on a PC with Beirut and whole layouts held out, then judging glass by
  building side through the SDOF, as `surrogate-judge` does: the product test, more than the
  load ratios.

The judgements, the strips and the four recorder runs are in
`$BOMBCAD_DATA/ml/judge/`. The Studio model is in `field-unet-studio-layouts/`.

```bash
python -I Scripts/ml/judge_field.py --data $BOMBCAD_DATA/ml/datasets/main \
    --model unet2=$BOMBCAD_DATA/ml/field-unet-main-2/out/best.pt --out judged.json
```

## The first-phase target and glass by side (20 October 2026)

emmettl/bombcad-work#33, emmettl/bombcad-work#47: the three steps the [judgement above](#what-it-would-take) asked
for.

### The first-phase impulse target

`field-export --first-phase` (and `district-compare --export-field … --first-phase`) writes a
third target, `firstPhaseImpulse`, by the recorder's rule ([above](#what-one-run-gives)). It was
checked on the four recorder runs of the judgement, run again with it into
`$BOMBCAD_DATA/ml/judge/compare-first/`:

- **Nothing else moved.** Each run's `inputs.npy`, `mask.npy` and its peak and all-phases impulse
  targets are bit-identical to the dataset's. `FirstPhaseColumnsTests` checks the same in the
  solver's state digest, and checks the columns against the rule applied afterwards to each
  column's whole history (within 0.1%).
- **It is the recorder's quantity.** The new target in front of each ground-floor strip, against
  the strip's own first-phase impulse, over the 65,934 strips: **1.00, log-SD 0.02** (the
  all-phases target: 1.34 / 0.11). By band:

| Z, m/kg^(1/3) | Strips | Peak | All phases | First phase |
|---|---|---|---|---|
| 0–3 | 2,556 | 1.02 / 0.12 | 1.36 / 0.18 | 1.00 / 0.05 |
| 3–5 | 6,200 | 1.01 / 0.06 | 1.35 / 0.13 | 1.00 / 0.02 |
| 5–7 | 7,811 | 1.00 / 0.05 | 1.34 / 0.12 | 1.00 / 0.02 |
| 7–10 | 17,926 | 1.00 / 0.04 | 1.36 / 0.11 | 1.00 / 0.02 |
| 10–14 | 18,694 | 1.00 / 0.04 | 1.34 / 0.11 | 1.00 / 0.01 |
| 14–20 | 11,325 | 1.00 / 0.03 | 1.33 / 0.09 | 1.01 / 0.01 |
| 20–28 | 1,422 | 1.00 / 0.05 | 1.32 / 0.10 | 1.01 / 0.01 |

  In sight 1.00 / 0.04, shielded 1.00 / 0.01, facing away 1.00 / 0.02; Beirut 50–700 m (23,394
  strips) 1.00 / 0.02. Over the mask, the first phase is a median 0.76–0.80 of all the phases.
- **Cost.** The kernel reads two cells a column a step: nothing measurable beside the air.

`train_field.py --impulse first` trains on it. **Update, 21 October:** the overnight job completed
all 200 stable cases in `$BOMBCAD_DATA/ml/datasets/main-fp`, then trained
`field-unet-fp-strict` (75 whole-layout holdouts, 2,360 s on the PC GPU) and
`field-unet-fp-byrun` (40 run holdouts, 2,042 s). Both jobs exited successfully. The retained
record is `ml/overnight-fp/summary.txt`, with each model's `job.json`, split and metrics under
StudioData. The strict round's all-cell first-phase impulse ratio / log-SD is 1.00 / 0.17;
the by-run round is 1.02 / 0.09. These are field-prediction checks, not wall/roof damage validation.

The original Metal regeneration command (about 5 GPU hours estimated) was:

```bash
python3 -I Scripts/ml/field-runs.py run --set main --first-phase --dataset $BOMBCAD_DATA/ml/datasets/main-first
```

### The strict round on the PC

`field-unet-strict-pc` (bombcad-pc, RTX 3080 Ti, bfloat16): the U-Net of round 2 (crop 256,
batch 16, 300 epochs), holding out all 50 Beirut runs and each made-up style's sixth layout
(`--holdout-layouts beirut,made-*-s6`, the Studio model's 75 runs to the run). It took 2,378 s, 4 s
an epoch. Its best held-out loss was **0.0223**, at epoch 91 (the Studio's float32 model: 0.028;
Kingery–Bulmash alone 0.098); by epoch 300 it had crept back to 0.025 as the training loss kept
falling, so `best.pt` is epoch 91's.

Judged with `judge_field.py` as above, Beirut never seen, against the run's field (median / log-SD):

| | Strips | PC strict, peak | Impulse | Studio, peak | Impulse | Surrogate, peak | Impulse |
|---|---|---|---|---|---|---|---|
| All 75 held-out runs | 1,661,822 | 0.98 / 0.22 | 1.07 / 0.16 | 1.03 / 0.23 | 1.12 / 0.17 | 0.96 / 0.37 | 0.70 / 0.27 |
| Beirut 50–700 m | 598,743 | **1.00 / 0.26** | 1.12 / 0.18 | 1.07 / 0.28 | 1.21 / 0.18 | 1.08 / 0.44 | 0.72 / 0.32 |
| Beirut 50–100 m | 10,013 | 1.05 / 0.61 | 0.99 / 0.35 | 1.25 / 0.66 | 1.19 / 0.36 | 2.09 / 0.94 | 1.09 / 0.63 |
| Beirut 100–200 m | 39,619 | 1.03 / 0.40 | 1.06 / 0.25 | 1.26 / 0.42 | 1.23 / 0.26 | 1.52 / 0.62 | 0.96 / 0.44 |
| Beirut 200–350 m | 91,761 | 1.01 / 0.28 | 1.12 / 0.18 | 1.14 / 0.30 | 1.25 / 0.19 | 1.33 / 0.46 | 0.83 / 0.36 |
| Beirut 350–500 m | 151,517 | 1.01 / 0.24 | 1.13 / 0.17 | 1.07 / 0.25 | 1.22 / 0.17 | 1.10 / 0.39 | 0.72 / 0.29 |
| Beirut 500–700 m | 305,833 | 0.99 / 0.21 | 1.13 / 0.16 | 1.04 / 0.22 | 1.20 / 0.16 | 0.99 / 0.33 | 0.68 / 0.24 |
| Made-up sixth layouts | 215,807 | 0.97–0.99 / 0.08–0.16 | 0.98–1.02 / 0.05–0.13 | 0.97–0.99 / 0.09–0.18 | 0.98–1.04 / 0.05–0.14 | 0.90–1.11 / 0.16–0.35 | 0.57–0.92 / 0.17–0.26 |

Against the recorder's strips of the four runs (Beirut's two at 50–700 m, 23,394 strips): peak
1.04 / 0.25 (Studio 1.02 / 0.26, surrogate 1.05 / 0.38); impulse 1.69 / 0.19, the all-phases
target's excess as before.

So the PC's round is a little better than the Studio's at the same split, mostly close in: it
takes out the Studio model's 1.25 times excess at 50–200 m, where its scatter is 0.40–0.61 against
the surrogate's 0.62–0.94.
### Glass by building side, the product test

All 50 Beirut runs were run again as `district-compare --save-loads --export-field --first-phase`
at the dataset run's top (2–4 minutes each under gpu-slot, about 2.7 hours in all, 26 GB in
`compare-first/`). Every one's field came out bit-identical to the dataset's. Over their
1,469,173 ground-floor strips (with the two made-up layouts), the first-phase target against the
recorder is 1.00 / 0.02 in every band of Z from 0 to 40 (all phases: 1.28–1.59).

`judge_field.py --peaks-out` then wrote each judged ground-floor strip's peaks, and
`scenebench field-glass` judged each strip's glass through the SDOF, as `surrogate-judge` does: the
building's mix, summed over the side's strips, and GEER's three states (none broken, some, blown
out). Only the ground floor is judged, since the field model knows nothing above 2 m; the run is
judged on the same strips. The loads:

- **Run**: the recorder's own history: the truth.
- **Surrogate**: its triangle (`FacadeLoadSurrogate.load`).
- **PC strict / Studio**: the surrogate's triangle with the field model's peak (the mean over the
  cells in front of the strip), the surrogate's impulse and rise kept. This is what the app could
  use now.
- **Run field's peak**: the same with the run's own field's peak there: the most a better peak
  alone could give.
- **Run field's peak and first phase**: with the new target's impulse as well: the most a field
  model trained on the first phase could give.

50 runs, 0.06–1.95 kt, 584,486 sides. Within one state is 1.000 for every load (with three states
only none-against-blown-out misses, and there were at most 127 such sides), so the measures are
the share exactly right, Heidke's skill score on the 3 × 3 table, and the mean error of the share
of panes broken:

| Load | Exact | Skill | Share broken, mean error |
|---|---|---|---|
| Surrogate | 0.916 | 0.62 | 0.043 |
| PC strict's peak, surrogate's impulse | **0.937** | **0.70** | **0.035** |
| Studio's peak, surrogate's impulse | 0.938 | 0.70 | 0.034 |
| Run field's peak, surrogate's impulse | 0.946 | 0.75 | 0.031 |
| Run field's peak and first phase | 0.946 | 0.76 | 0.031 |

By the building's distance (exact / skill):

| Distance | Sides | Surrogate | PC strict's peak | Run field's peak | Peak and first phase |
|---|---|---|---|---|---|
| 0–350 m | 56,076 | 1.000 / – | 1.000 / – | 0.999 / 0.21 | 0.999 / 0.23 |
| 350–500 m | 60,193 | 0.991 / 0.15 | 0.991 / 0.36 | 0.987 / 0.53 | 0.987 / 0.54 |
| 500–700 m | 118,343 | 0.930 / 0.47 | 0.952 / 0.64 | 0.956 / 0.71 | 0.956 / 0.71 |
| 700–1000 m | 232,397 | 0.874 / 0.62 | 0.899 / 0.69 | 0.915 / 0.74 | 0.915 / 0.75 |
| 1000–1500 m | 117,089 | 0.908 / 0.62 | 0.939 / 0.72 | 0.949 / 0.77 | 0.950 / 0.77 |

By yield (exact / skill):

| Yield | Sides | Surrogate | PC strict's peak | Run field's peak | Peak and first phase |
|---|---|---|---|---|---|
| 0.05–0.1 kt | 88,755 | 0.737 / 0.50 | 0.776 / 0.57 | 0.812 / 0.64 | 0.814 / 0.65 |
| 0.1–0.3 kt | 156,342 | 0.855 / 0.50 | 0.899 / 0.63 | 0.913 / 0.70 | 0.913 / 0.70 |
| 0.3–0.7 kt | 139,260 | 0.978 / 0.20 | 0.991 / 0.35 | 0.991 / 0.49 | 0.991 / 0.50 |
| 0.7–2 kt | 200,129 | 0.999 / 0.08 | 0.999 / 0.15 | 0.999 / 0.36 | 0.999 / 0.37 |

Against the run, the surrogate calls 17,009 sides blown out that had only some glass broken and
27,861 the other way; with the PC model's peak those fall to 14,028 and 19,035. Every triangle,
the run field's own included, calls about 3,200–3,600 sides unbroken where the run broke a few
panes: the triangle's single phase misses the later reflections that break them, which no peak
mends.

Against the recorder's strips over all 50 Beirut runs (1,446,015 strips), the PC model's peak is
0.98 / 0.23 and the surrogate's 0.98 / 0.38; at 50–700 m, 1.01 / 0.26 against 1.09 / 0.44.

### What the glass says

- **The field model's peak makes the glass answer better.** With it, glass by side is exactly
  right on 0.937 of the sides against the surrogate's 0.916, with skill 0.70 against 0.62. That
  is about two thirds of the way to the best a better peak could give (0.946, 0.75), on a city
  the model never saw. The gain is largest where glass is in doubt: low yields (0.737 → 0.776 at
  0.05–0.1 kt, 0.855 → 0.899 at 0.1–0.3 kt) and 500–1,500 m.
- **A first-phase impulse would add nothing to glass.** With the run's own peak, its first-phase
  impulse gives 0.946 / 0.76 against the surrogate's impulse's 0.946 / 0.75: glass here is
  decided by the peak. A first-phase model would matter for walls and roofs, whose SDOFs are
  impulse-sensitive, not for glass. That is a reason to re-export with `--first-phase` before
  the field model drives structural damage, not before it drives glass.
- **The PC round and the Studio round agree on glass** (0.937 / 0.70 and 0.938 / 0.70), though
  the PC model's peaks are better close in. Close in, every side's glass is gone either way.
- **Limits:** the ground floor only (upper storeys would need the surrogate's terms, or a field
  model at more heights); one city's 50 runs on one map; 4 m runs as the truth.

The judgements are in `$BOMBCAD_DATA/ml/judge/fp47/` (`judge-all.txt`,
`glass/summary.json`, `glass-all.txt`); the strict model is in `field-unet-strict-pc/`.

### The recommendation (for the user to decide)

Put the field model's **peak** into the quick estimate's ground-floor façade glass, keeping the
surrogate's impulse and rise. On Beirut's held-out runs it lifts glass by side from 0.916 to 0.937
exactly right (skill 0.62 to 0.70). Its peaks within 350 m are within 5% of the run's, where the
surrogate's run 1.3–2.1 times high. Nothing changes by default until the user says so. What it
would take, and what it would leave out:

- **the model in the app**: a 7.9 M-parameter U-Net over the district's plan, its inputs from the
  scene the quick estimate already lays out. On the Studio's CPU, `judge_field.py`'s prediction
  over a 512² run takes a few seconds; on the GPU it would take less;
- **storeys above the ground floor** stay on the surrogate unless the model learns more heights;
- **walls and roofs** stay on the surrogate's impulse until a model is trained on the first
  phase. That needs the re-export above: about 5 GPU hours, and the user's go-ahead.

## The first-phase models at walls and roofs (21 October 2026)

emmettl/bombcad-work#33, emmettl/bombcad-work#47: the two models trained overnight on the first-phase target
(`--impulse first`, `datasets/main-fp`), judged where the first phase was meant to matter.

- **`field-unet-fp-strict`** never saw Beirut: it holds out all 50 Beirut runs and each made-up
  style's sixth layout.
- **`field-unet-fp-byrun`** holds out 40 runs, 10 of them Beirut's. It saw Beirut's map at the
  other 40 points and yields, so it is judged on those 10 only.

In short: the models' first-phase impulse is better than the surrogate's at the façades, but it
changes nothing for walls. Ground-floor concrete walls are decided by the peak, and there the
model's peak lifts the walls' chances as it lifted the glass's. The model knows nothing of roofs,
and a proxy from its ground-floor loads does not help them.

### Façades against the recorder

Beirut's ground-floor strips at 50–700 m. The truth is each strip's recorded peak and first-phase
impulse (`compare-first/`, all 50 runs). The ratio is the median of predicted over recorded, then
the log-SD:

| Beirut runs | Strips | Predictor | Peak | First-phase impulse |
|---|---|---|---|---|
| All 50 | 598,743 | Strict model | 1.07 / 0.27 | 0.94 / 0.18 |
| | | Surrogate | 1.09 / 0.44 | 0.95 / 0.31 |
| | | Kingery–Bulmash incident | 1.26 / 0.42 | 0.98 / 0.23 |
| | | Kingery–Bulmash raised by the facing | 1.56 / 0.49 | 1.14 / 0.34 |
| | | The run's own field at the strip | 1.00 / 0.05 | 1.00 / 0.02 |
| By-run's 10 | 130,957 | By-run model | 1.00 / 0.18 | 1.01 / 0.11 |
| | | Strict model | 1.04 / 0.29 | 0.93 / 0.19 |
| | | Surrogate | 1.11 / 0.45 | 0.96 / 0.32 |
| | | Kingery–Bulmash incident | 1.26 / 0.43 | 1.01 / 0.24 |

By distance, all 50 runs:

| Distance | Strips | Strict, peak | Impulse | Surrogate, peak | Impulse | KB incident, peak | Impulse |
|---|---|---|---|---|---|---|---|
| 50–100 m | 10,013 | 1.14 / 0.62 | 0.87 / 0.46 | 2.18 / 0.94 | 1.58 / 0.70 | 3.57 / 0.90 | 1.19 / 0.64 |
| 100–200 m | 39,619 | 1.14 / 0.42 | 0.90 / 0.31 | 1.56 / 0.62 | 1.32 / 0.46 | 1.98 / 0.60 | 1.08 / 0.41 |
| 200–350 m | 91,761 | 1.15 / 0.31 | 0.94 / 0.19 | 1.35 / 0.46 | 1.08 / 0.34 | 1.52 / 0.41 | 1.01 / 0.25 |
| 350–500 m | 151,517 | 1.09 / 0.25 | 0.94 / 0.15 | 1.11 / 0.39 | 0.95 / 0.26 | 1.28 / 0.34 | 0.98 / 0.18 |
| 500–700 m | 305,833 | 1.03 / 0.22 | 0.94 / 0.14 | 0.99 / 0.33 | 0.91 / 0.20 | 1.16 / 0.31 | 0.98 / 0.17 |

What the table shows:

- **The first-phase target did its job at the façades.** The models' impulse is now the
  recorder's quantity. Never having seen Beirut, the strict model's impulse runs 0.94 times the
  recorder's, with a log-SD of 0.18. The surrogate's is 0.95 / 0.31, and Kingery–Bulmash's incident
  impulse 0.98 / 0.23. The all-phases model had run 1.69 times high.
- **The strict model's peak is a little higher than the all-phases round's.** It runs 1.07 / 0.27,
  against 1.01 / 0.26 for `field-unet-strict-pc` on the same strips. Within 350 m it runs
  1.11–1.13 against the field, where that round ran 1.01–1.05.

### Walls and roofs through the envelope SDOF

`scenebench field-walls` draws emmettl/bombcad-work#19's chances on each held-out run's buildings, as
`FacadeLoadSurrogate.structureProbabilities` draws them at a known yield:

- a load scatter for each building side, shared by its strips, and one for each roof;
- the surrogate's leave-one-out scatter by scaled distance, with its correlation;
- no strength scatter, since the runs have none.

The truth is the run's own histories through the same SDOF, at the constructions' nominal
strength, as `wall-calibrate` judges them. The field model knows nothing above 2 m, so:

- **Walls** are each building's worst wall over its judged ground-floor strips (the strips of the
  façade judgement above).
- **Roofs** are each building's worst roof inside 0.85 of the half side. Each variant gives a roof
  only a proxy: the roof's own surrogate pulse (on the roofs' terms), scaled by the building's
  geometric mean of the variant's peak and impulse over the surrogate's at its ground-floor strips.

The loads are triangles with the surrogate's rise. Each one takes:

- **Surrogate**: the surrogate's peak and impulse.
- **Model peak, surrogate impulse**: what glass uses (emmettl/bombcad-work#47, 20 October).
- **Model peak and first phase**: the model's peak and its first-phase impulse.
- **Run field's peak** and **run field's peak and first phase**: the run's own field at the strip.
  This is the best a field model could give.

The pairs judged are load factors 0.8, 1, 1.3 and 1.6, times scatter scales 0, ½ and 1, with 50
draws. `judge_field.py walls` holds out each of the ten charge points in turn. It takes the pair
with the least Brier score on the other nine and judges the held-out point's buildings with it.

The test is the protective-design report's, as emmettl/bombcad-work#19's: the Brier score, its skill against giving
each the mean, and the tenths test. To pass it, every tenth of chance holding 50 or more
building-runs must be within 0.1 of the share damaged.

All 50 Beirut runs (the strict model never saw Beirut). Each cell is the Brier score / skill /
tenths test:

| Load | Concrete walls, moderate+ (156,492; 19,492 damaged) | Concrete walls, heavy+ (14,303) | Roofs, moderate+ (155,532; 34,605) |
|---|---|---|---|
| Surrogate | 0.0338 / 0.69 / fail | 0.0264 / 0.68 / fail | 0.0480 / 0.72 / fail |
| Strict peak, surrogate impulse | **0.0236 / 0.78 / pass** | 0.0162 / 0.81 / pass | 0.0465 / 0.73 / fail (proxy) |
| Strict peak and first phase | 0.0236 / 0.78 / pass | 0.0166 / 0.80 / fail | 0.0453 / 0.74 / fail (proxy) |
| Run field's peak, surrogate impulse | 0.0078 / 0.93 / pass | 0.0059 / 0.93 / fail | 0.0425 / 0.75 / fail (proxy) |
| Run field's peak and first phase | 0.0076 / 0.93 / pass | 0.0055 / 0.93 / fail | 0.0405 / 0.77 / fail (proxy) |

By-run's 10 held-out Beirut runs, the same measures:

| Load | Concrete walls, moderate+ (34,745; 6,082) | Heavy+ (4,470) | Roofs, moderate+ (34,556; 10,759) |
|---|---|---|---|
| Surrogate | 0.0456 / 0.68 / fail | 0.0351 / 0.69 / fail | 0.0559 / 0.74 / fail |
| Strict peak, surrogate impulse | 0.0337 / 0.77 / pass | 0.0246 / 0.78 / fail | 0.0656 / 0.69 / fail |
| Strict peak and first phase | 0.0338 / 0.77 / pass | 0.0239 / 0.79 / fail | 0.0637 / 0.70 / fail |
| By-run peak, surrogate impulse | 0.0213 / 0.85 / fail | 0.0147 / 0.87 / pass | 0.0528 / 0.75 / fail |
| By-run peak and first phase | 0.0213 / 0.85 / fail | 0.0141 / 0.87 / pass | 0.0518 / 0.76 / fail |
| Run field's peak and first phase | 0.0106 / 0.93 / pass | 0.0079 / 0.93 / fail | 0.0521 / 0.76 / fail |

**How the surrogate fails the tenths test.** On walls moderate+ it calls too many: its tenths from
0.4 to 0.9 hold 0.29–0.54 damaged. **How the field-model roofs fail.** Their tenths from 0.3 to 0.5
run low by 0.10–0.11; with the run field's proxy, low by up to 0.2.

**What the pairs chose.** The surrogate's and the strict model's walls took load ×0.8 with the
whole scatter in every fold, against the app's ×1.0. The run field's walls took ×1.0 with no
scatter. The field-model roofs took ×1.0 with half the scatter, against the app's ×1.3.

**With the app's own pairs** (walls ×1.0 with the whole scatter, roofs ×1.3 with half), on all 50
runs:

| Load | Walls moderate+ | Roofs moderate+ |
|---|---|---|
| Surrogate | 0.0441 / 0.60 | 0.0438 / 0.75 |
| Strict peak, surrogate impulse | 0.0344 / 0.68 | 0.0634 / 0.63 |
| Strict peak and first phase | 0.0344 / 0.68 | 0.0627 / 0.64 |

All fail the tenths test.

**How rarely the impulse matters.** With no scatter and at ×1.0, the first-phase impulse in place
of the surrogate's changes 640 of the 156,492 building-runs' moderate+ wall answers: 306 made
right, 334 made wrong. The model's peak in place of the surrogate's changes 6,777: 4,953 made
right, 1,824 made wrong. Even the run's own first phase changes only 731 (386 right, 345 wrong).

### Glass rechecked

`field-glass` as in [glass by side](#glass-by-building-side-the-product-test), all 50 Beirut runs
and 584,486 sides:

| Load | Exact | Skill | Share broken, mean error |
|---|---|---|---|
| Surrogate | 0.916 | 0.62 | 0.043 |
| All-phases strict peak (`field-unet-strict-pc`, 20 October) | 0.937 | 0.70 | 0.035 |
| First-phase strict peak, surrogate impulse | **0.942** | **0.72** | **0.034** |
| First-phase strict peak and first phase | 0.943 | 0.73 | 0.034 |
| Run field's peak, surrogate impulse | 0.946 | 0.75 | 0.031 |
| Run field's peak and first phase | 0.946 | 0.76 | 0.031 |

On by-run's 10 runs (128,295 sides), exact / skill:

- surrogate: 0.934 / 0.72;
- strict peak: 0.943 / 0.76 (0.944 / 0.77 with its first phase);
- by-run peak: 0.945 / 0.78 (0.944 / 0.78 with its first phase);
- run field's peak and first phase: 0.962 / 0.84.

Nothing regressed. By yield, the strict peak takes the surrogate's 0.737 to 0.776 at 0.05–0.1 kt
and its 0.855 to 0.917 at 0.1–0.3 kt.

### What it says

- **The first-phase impulse does not improve walls, on a city the model never saw.** With the
  strict model's peak, its first phase gives the same Brier score as the surrogate's impulse for
  concrete walls moderate+ (0.0236 against 0.0236), and slightly worse for heavy+ (0.0166 against
  0.0162). The run's own first phase gains no more (0.0076 against 0.0078). Ground-floor concrete
  walls here respond to the peak, not the impulse.
- **The field model's peak does improve walls**, as it did glass:
  - concrete walls moderate+ go from skill 0.69 to 0.78, and the chances pass the tenths test,
    which the surrogate's fail;
  - heavy+ goes from 0.68 to 0.81;
  - the by-run model, having seen the map, reaches 0.85–0.87;
  - the run's own field reaches 0.93.
- **Roofs gain nothing.** The models know nothing above 2 m. A proxy from the ground-floor ratio
  moves the roofs' skill by at most 0.02, and the run's own field gives 0.75–0.77 against the
  surrogate's 0.72–0.74. With the app's ×1.3, the proxy loses (0.63 against 0.75).
- **The walls' load factor.** Both the surrogate's and the model's walls chose ×0.8 against the
  app's ×1.0, and at ×1.0 neither passes the tenths test. This is for the user: the walls'
  calibration is emmettl/bombcad-work#19's and was not changed.
- **Limits of this judgement:**
  - ground-floor walls only;
  - one city's 50 runs on one map;
  - 4 m runs as the truth;
  - the runs' own strength is nominal, so these check the loads' scatter, not the strength's.

### The recommendation (for the user to decide)

Take the field model's **peak only**, and at the **ground floor only**, for glass and for walls,
keeping the surrogate's impulse and rise:

- **Glass by side**: exact 0.916 → 0.942, skill 0.62 → 0.72, never having seen the city.
- **Concrete walls moderate+**: skill 0.69 → 0.78, and the chances pass the tenths test.

Its first-phase impulse adds nothing to either, so carrying it would be cost without gain. Leave
on the surrogate:

- roofs;
- storeys above the ground floor;
- any wall above 2 m.

The model could only reach these with fields at more heights. Nothing changes by default until the
user says so; the walls' ×0.8 factor is a separate decision.

Everything is in `$BOMBCAD_DATA/ml/judge/fpw/`:

- the façade judgement: `judge-strict.txt`, and `facades.txt` for the recorder tables;
- the walls: `walls/`, `walls-summary.txt` and `walls/summary.json`;
- the glass: `glass/`, `glass-all.txt` and `glass-byrun.txt`.

```bash
python -I Scripts/ml/judge_field.py --data $BOMBCAD_DATA/ml/datasets/main-fp \
    --model strict=$BOMBCAD_DATA/ml/field-unet-fp-strict/out/best.pt \
    --model byrun=$BOMBCAD_DATA/ml/field-unet-fp-byrun/out/best.pt --impulse first \
    --recorded $BOMBCAD_DATA/ml/judge/compare-first --peaks-out fpw/peaks --out fpw/judge-strict.json
python -I Scripts/ml/judge_field.py walls --peaks fpw/peaks --out-dir fpw/walls \
    --variants surrogate,strict:surrogate,strict:strict,byrun:surrogate,byrun:byrun,runField:surrogate,runField:runFieldFirst \
    --only byrun=$BOMBCAD_DATA/ml/field-unet-fp-byrun/out/split.json
```

## In the app's quick estimate (21 October 2026)

emmettl/bombcad-work#67. On 21 October the user decided to build the
[recommendation above](#the-recommendation-for-the-user-to-decide-1) as an option, and to decide
the default afterwards. The option is now in the app: **Learned field model for ground-floor
peaks**, under the envelope damage. It is **off by default**, and off it changes nothing.

### What it does

- **Where the model's peak goes.** It goes to every ground-floor façade strip: a storey spanning
  2 m over the ground under its face's middle, within a centimetre. There the strict model's peak
  (`field-unet-fp-strict`, peak channel only) replaces the surrogate's, as the judge used it:
  - the peak is the mean of the network's peak over the strip's front cells, the plan cells of
    air beside its face along its width (judge_field.py's `front_cells`);
  - a cell counts only with no building over its centre, at least 4 cells from the plan's sides,
    and a peak above 10 Pa;
  - the surrogate's impulse and rise are kept.

  A strip with no such cell keeps the surrogate's peak. So do roofs, upper storeys and every
  other component.
- **Everything downstream follows.** The peak is carried as a factor on the strip's features
  (`Features.learnedPeakFactor`, the model's peak over the surrogate's at the scene's yield). The
  quick estimate's damage, the glass's chances and the walls' chances all take it. At a yield drawn
  away from the scene's, the same ratio is kept, since the network is run once, at the scene's
  yield. Off, or for a strip it does not reach, the factor is 1, and a peak multiplied by 1 is
  the same to the bit.
- **The inputs.** `LearnedField.Plan` lays out the network's inputs from the scene on the 4 m plan
  over its domain, as `field-export` does: the buildings' heights over the ground and the ground,
  laid out once per district; the distances, ln Z and Kingery–Bulmash's values, again for each
  place of the charge. On all 50 Beirut runs these came out the same as the runs' own
  `inputs.npy` to the bit: 0 values differing of 1,572,864 or 2,457,600 a run. The model always
  works on 4 m cells, whatever cells the estimate is on.
- **The network** is `LearnedFieldNetwork` in BlastCore, the U-Net on MPSGraph, in float32. It
  needs no new dependency. It is built once for each plan size and kept, so a drag reuses it.
- **The weights** come from `Scripts/ml/export_field_weights.py`, as one `.bcfw` file of float16
  weights, 15.7 MB. The file holds a JSON header with the architecture, the input standardisation
  and the source checkpoint's SHA-256, then the tensors. The weights are not committed. The app
  reads them from `BOMBCAD_FIELD_MODEL`, else the `quickEstimate.learnedFieldWeights` setting, else
  `~/Library/Application Support/BombCAD/LearnedModels/field-unet-fp-strict.bcfw`. Without them,
  the sidebar says so and the estimate is the surrogate's alone. The file is on StudioData at
  `ml/field-unet-fp-strict/app/field-unet-fp-strict.bcfw`.

```bash
python -I Scripts/ml/export_field_weights.py --model $BOMBCAD_DATA/ml/field-unet-fp-strict/out/best.pt \
    --out field-unet-fp-strict.bcfw --data $BOMBCAD_DATA/ml/datasets/main-fp \
    --reference beirut-p0-1,beirut-p0-3,beirut-p4-1,made-towers-s6-2 --reference-out reference
```

### Against PyTorch

The test is on four held-out runs, three of Beirut's and a made-up sixth layout, 512² and 640²
(`scenebench field-predict`; `LearnedFieldNetworkTests`, which skips without the weights). The
reference is PyTorch on the CPU in float32, with the same float16 weights:

- **The log peak agrees within 2.9–3.8 × 10⁻⁶** on every cell (mean 1.1 × 10⁻⁷), which is float
  rounding.
- **The float16 weights** against the checkpoint's own float32 move the log peak by at most
  0.8–2.1 × 10⁻³ (mean 7 × 10⁻⁵).
- **Over all 50 Beirut runs' 1,446,015 judged strips**, the app's peaks lie within 0.28% of the
  judge's (judge_field.py, float32 weights), with a median of 0.009%. With float32 weights
  exported for the check, beirut-p0-1's 10,013 strips agree within 10⁻⁵.

### The app's estimate path against the judge

`Scripts/ml/app_peaks.py run` lays out each of Beirut's 50 held-out runs again and runs
`scenebench field-app` on it: the app's own `Prepared.estimate(learned:)`, the network on the GPU.
`app_peaks.py merge` adds those peaks to the [judge's strip files](#glass-rechecked), and
`field-glass` and `judge_field.py walls` judge them as they judged the Python model's. Every one of
the 1,446,015 judged strips took the model's peak in the app. Everything else was the surrogate's
to the bit.

**Glass by side**, 584,486 sides (exact / Heidke skill / mean error of the share broken):

| Load | All | 500–700 m | 700–1000 m | 1000–1500 m | 0.05–0.1 kt | 0.1–0.3 kt |
|---|---|---|---|---|---|---|
| Surrogate | 0.916 / 0.62 / 0.043 | 0.930 / 0.47 | 0.874 / 0.62 | 0.908 / 0.62 | 0.737 / 0.50 | 0.855 / 0.50 |
| Judge's strict peak (8701c269) | 0.942 / 0.72 / 0.034 | 0.948 / 0.63 | 0.911 / 0.72 | 0.947 / 0.75 | 0.776 / 0.58 | 0.917 / 0.67 |
| **The app's, option on** | **0.942 / 0.72 / 0.034** | 0.948 / 0.63 | 0.911 / 0.72 | 0.947 / 0.75 | 0.776 / 0.58 | 0.917 / 0.67 |

In all: glass by side exactly right on 0.916 of sides with the surrogate's peak and 0.942 with the
model's, Heidke skill 0.62 and 0.72. Between the app and the judge, at most 8 sides of the 584,486
changed state. (The surrogate here is its terms before the refit of 23 October 2026,
emmettl/bombcad-work#56; this judge was not run again.)

**Walls**, ground-floor walls of Beirut's 156,492 concrete building-runs. Each cell is the Brier
score / skill / tenths test, each charge point held out with the load factor and scatter chosen on
the other nine (the app's own pair, ×1.0 with the whole scatter, beside it):

| Load | Moderate+ (19,492 damaged) | At the app's ×1.0 | Heavy+ (14,303) | At the app's ×1.0 |
|---|---|---|---|---|
| Surrogate | 0.0338 / 0.69 / fail | 0.0441 / 0.60 / fail | 0.0264 / 0.68 / fail | 0.0376 / 0.55 / fail |
| Judge's strict peak | 0.0236 / 0.78 / pass | 0.0344 / 0.68 / fail | 0.0162 / 0.81 / pass | 0.0209 / 0.75 / fail |
| **The app's, option on** | **0.0236 / 0.78 / pass** | 0.0344 / 0.68 / fail | 0.0162 / 0.81 / pass | 0.0209 / 0.75 / fail |

So for concrete walls moderate or worse, Brier skill 0.69 and 0.78 with the factor the judge chose
(×0.8 in every fold), and at the app's own load factor of 1.0, 0.60 and 0.68. The tenths test
passes only at ×0.8. That factor is the user's to judge again (emmettl/bombcad-work#19's calibration, not changed
here). The app gives roofs the surrogate's loads, so the judge's roof proxy does not apply.

The judgements are in `$BOMBCAD_DATA/ml/app67/`: `app/` holds the in-app strips and
logs, `merged/` the merged strip files, and `glass/`, `glass-summary.txt`, `walls/` and `walls.txt`
the judgements.

```bash
python3 -I Scripts/ml/app_peaks.py run --data $BOMBCAD_DATA/ml/datasets/main-fp \
    --weights field-unet-fp-strict.bcfw --out-dir app67/app
python3 -I Scripts/ml/app_peaks.py merge --app app67/app --peaks judge/fpw/peaks --out-dir app67/merged
python3 -I Scripts/ml/app_peaks.py glass --peaks app67/merged --out-dir app67/glass
python3 -I Scripts/ml/app_peaks.py summary --glass app67/glass
python -I Scripts/ml/judge_field.py walls --peaks app67/merged --out-dir app67/walls \
    --variants surrogate,strict:surrogate,app:surrogate
```

### Time

The test is Beirut's district as the [drag was timed](surrogate-first-look.md#dragging-the-charge-20-october-2026):
14,169 buildings, 724,512 components, 0.5 kt, the plan 1,250 × 1,250 cells of 4 m. It ran with
`scenebench drag-time --drag 0,5,…,100 --weights …`, ten frames and then the full look, on the
Studio shared with other sessions (load 10–27). The network needs no raster of its own beyond its
plan: `LearnedField.Plan` holds the heights and the ground for every place of the charge, as
emmettl/bombcad-work#34's `Prepared` holds the sight lines' raster. The plan takes 0.02 s to lay out, and the weights
0.05 s to load.

| Colouring | Later frames, off | Later frames, on | The model's share | First frame, on |
|---|---|---|---|---|
| Damage | 0.62–0.72 s | 0.86–1.18 s | 0.17–0.27 s | 3.1 s |
| Glass's chances (10 draws) | 0.40–0.41 s | 0.59–0.63 s | 0.18–0.20 s | 2.3 s |
| Walls' and roofs' chances (20 draws) | 0.55–0.60 s | 0.70–0.77 s | 0.17–0.20 s | 2.1 s |

- **Each frame runs the network again,** since the charge moves: its inputs and the network take
  0.17–0.20 s. The first frame also builds the graph for the plan's size, 1.3–1.7 s, kept after.
- **emmettl/bombcad-work#34's bar of a second a frame is still met** with the option on, except the damage's frames
  at 0.86–1.18 s, on a loaded Mac.
- **The full estimate once let go took 63–78 s either way**, with or without the model. The model
  added 0.18–0.19 s, and 129,772 of the strips took its peak; the glass's 100 draws are most of
  the time.
- **On the 512² and 640² runs**, the network alone takes 14–23 ms after its first run (0.7–1.2 s
  to build the graph).

### How the weights ship (21 October 2026)

The user decided that the weights ship as a release asset, downloaded on first use. The release
is prepared and handed over. The user publishes it; no session does.

- **The release:** `field-model-1` on emmettl/bombcad, kept off "latest" so that it never stands
  in for the app's own releases. It has two assets, `field-unet-fp-strict.bcfw`
  (15,716,144 bytes) and `MODEL-NOTES.md`, which is also the release's text. Both are on
  StudioData in `release-field-model-1/`. The header no longer carries a local path: the export
  writes only the round's last path parts (`field-unet-fp-strict/out/best.pt`).
- **Pinned in the app:** `LearnedField.Release` holds the tag, the file, its size and its SHA-256,
  `d544d80f…370440`.
- **The download asks first.** Turning the option on without the file asks "Download the learned
  field model?", with its size, the URL
  (`https://github.com/emmettl/bombcad/releases/download/field-model-1/field-unet-fp-strict.bcfw`)
  and what it is for. Nothing is fetched until the user clicks Download.
  `LearnedFieldDownload.install` then fetches it to a temporary file, checks the SHA-256, reads it
  as weights, and only then moves it into Application Support. Only after that is the option
  turned on.
- **Failure and cancel.** A failed, cancelled or mismatched download keeps nothing, and the option
  stays off with a message saying why. A path set by hand (the setting, or `BOMBCAD_FIELD_MODEL`)
  that holds nothing is reported, never filled.
- **Tests.** `LearnedFieldDownloadTests` and `LearnedFieldOptionTests` use `file://` stand-ins and
  fetch nothing real.
- **A retrained model** is a new file name, a new tag (`field-model-2`) and a new pin.

**Attribution.** The weights were trained only on BombCAD's own runs of made-up districts:
125 runs of 25 layouts invented by `Scripts/ml/make_district.py`, with Kingery–Bulmash's
published fits as inputs. No map data went into their values, nor into the input standardisation.
Real data did play a part in two ways:

- **The checkpoint.** It is epoch 59 of 300, kept because it had the least loss on the 75
  held-out runs. 50 of those are Beirut's: OpenStreetMap buildings (ODbL 1.0), GHS-BUILT-H heights
  (CC BY 4.0) and Copernicus DEM GLO-30 ground.
- **The standing.** It was judged on those same runs.

Our reading is that the weights are not a derived database of those sources. `MODEL-NOTES.md`
credits all three anyway, in their own required wording, and says this is not legal advice. It
also records the training round, the held-out standing and that the model is illustrative.

The command for the user, run from a checkout once the commit is on main:

```bash
gh release create field-model-1 --repo emmettl/bombcad --target main --latest=false \
    --title "Learned field model 1 (field-unet-fp-strict)" \
    --notes-file $BOMBCAD_DATA/release-field-model-1/MODEL-NOTES.md \
    $BOMBCAD_DATA/release-field-model-1/field-unet-fp-strict.bcfw \
    $BOMBCAD_DATA/release-field-model-1/MODEL-NOTES.md
```

### The decision for the user

Whether to make the option the default. For it:

- In the app's own path, it reproduces the judge to the side: glass 0.916 → 0.942 exactly right,
  skill 0.62 → 0.72, on a city the model never saw. Concrete walls moderate+ go 0.69 → 0.78 in
  skill (×0.8) and 0.60 → 0.68 at the app's ×1.0.
- It costs about 0.2 s a drag frame and nothing measurable in a full estimate.

Against it, or what to settle first:

- **The weights are a download.** Until the release is published, the download fails, and the
  option stays off. As a default it would have to ask for the download before the first
  estimate.
- **Its reach is one city and made-up districts, on 4 m cells.** Ground-floor façades only, a
  charge on the ground.
- **The walls' tenths test passes only at ×0.8.** At the app's ×1.0 it fails, with the model or
  without. That is the factor the user is to judge again now that this is in.

The recommendation: keep it off until the release is published and the download has been tried.
Then make it the default for glass and walls together, and settle the walls' factor (×0.8 against ×1.0) on its own numbers above.
Nothing has been changed by default.

**The walls' factor, settled on 22 October 2026** (emmettl/bombcad-work#19). Against Beirut's ten
near boxes rerun on air refined to 2 m, the model's walls take the peak ×1.15 and the impulse
×0.95. That is the one choice there that passes the tenths test: concrete walls moderate or worse
at skill 0.66, against the surrogate's 0.59 at its own ×1.3. The ×0.8 above was chosen against the
4 m runs, which read the walls' peaks 13–19% low
([the first look](surrogate-first-look.md#the-walls-chances-re-judged-on-2-m-references-22-october-2026)).
The option itself stays off by default.

## Round 3: the 4 m runs' resolution bias (21 October 2026)

emmettl/bombcad-work#69, stage 1. Every training run is on 4 m cells. 3afdd0c9 found that 4 m runs
read walls' reflected peaks 13–27% low at 400–600 m of 0.5 kt (emmettl/bombcad-work#19). The
question here is whether that bias is also in the exported fields the model learns, and what to do
about it.

**How it was measured.** `Scripts/ml/field_bias.py run` exports six of the dataset's runs again,
on 4 m and on uniform 2 m cells, with the fields at more heights (`--levels 6,10,14,20 --roof`,
[below](#fields-at-more-heights)). The six are 54–355 t: Beirut
p2-5, p0-1 and p4-3, and the made-up perimeter-s6-2, mixed-s6-4 and towers-s6-1. All six are in
the strict split's held-out set. Two made-up runs were also run at 1 m on smaller squares about
the same charge (half sides 512 m and 384 m), at 4, 2 and 1 m. Uniform cells were used, not
corridors or ceilings, so that nothing but the cell size differs. 3afdd0c9 saw a refined level of
its own over terrain read impulse 12–17% low.

The 4 m runs agree to the bit with the dataset's. Beirut's three started as the balloon, as every run on terrain did before aff21dff ([below](#round-3-fields-at-more-heights-22-october-2026)), at both sizes alike; the three made-up layouts are flat and had the mapped start. The 2 m runs took 3–9 minutes each on a shared
Studio, the 1 m runs 6–7 minutes. `field_bias.py analyse` compares each coarse cell with the
mean of the finer cells it holds, at each level, wherever all of them are in the mask. It also
compares each façade strip's front cells, as judge_field.py reads them: each storey at the level
it spans, and on the fine cells the first cell in the mask going out from the face. Each figure
below is the median of fine over coarse, then the log-SD.

**4 m against 2 m, all six runs** (1.1 M cells at 2 m over the ground, 72,000 ground-floor strips):

| Where | Peak | First-phase impulse |
|---|---|---|
| Cells 2 m over the ground | 1.09 / 0.07 | 0.97 / 0.06 |
| Z 0–3 / 3–7 / 7–14 / 14–20 / 20–40 | 1.13 / 1.09 / 1.09–1.10 / 1.08 / 1.10–1.14 | 0.95–0.99 |
| In sight, open | 1.09 / 0.05 | 0.92 / 0.07 |
| Shielded (4+ buildings crossed), open | 1.09 / 0.07 | 0.97 / 0.05 |
| Shielded, beside a building | 1.11 / 0.10 | 0.98 / 0.07 |
| Cells at 10 m, 20 m | 1.09, 1.08 | 0.97 |
| Over the roofs (2 m over the top) | 1.08 / 0.08 | 0.97 / 0.05 |
| Ground-floor façade strips | **1.11 / 0.13** | 0.97 / 0.08 |
| … Z 0–3 / 3–5 / 5–7 / 7–14 / 14–40 | 1.24 / 1.19 / 1.15 / 1.11–1.13 / 1.09–1.15 | 0.96–1.00 |
| … in sight and facing (cos > 0.7) | 1.17 / 0.21 | 0.94 / 0.14 |
| … facing away, down a street | 1.11 / 0.12–0.14 | 0.96–0.97 |
| Façade strips at 10 m, 20 m | 1.09, 1.07 | 0.96 |

By run, the cells at 2 m are 1.08–1.12 in peak, and the ground-floor strips 1.10–1.12. Beirut's
runs lie in the made-up runs' range. The runs with the fewest cells per charge length run highest:
1.11–1.12 at W^(1/3)/dx = 9.5 on 4 m cells, and 1.08–1.09 at 13–18.

**4 m, 2 m and 1 m** (the two smaller squares, made-up and flat):

| | Perimeter s6-2, 54 t: cells | Façade strips | Towers s6-1, 194 t: cells | Façade strips |
|---|---|---|---|---|
| 2 m over 4 m, peak | 1.08 | 1.12 | 1.09 | 1.12 |
| 1 m over 2 m, peak | 1.05 | 1.08 (facing: 1.15) | 1.07 | 1.10 (facing: 1.14) |
| **1 m over 4 m, peak** | **1.14** | **1.20** (facing: 1.29) | **1.16** | **1.23** (facing: 1.28) |
| 1 m over 4 m, first-phase impulse | 0.93 | 0.93 | 0.93 | 0.92 |
| Open, in sight, Z 3–14, over Kingery–Bulmash's incident peak: 4 m / 2 m / 1 m | 0.73 / 0.81 / 0.88 | | 0.76 / 0.83 / 0.87 | |

**What it says:**

- **The bias is general, not only at reflecting faces.** The field 2 m over open ground reads about
  9% low on 4 m cells against 2 m, and 14–16% against 1 m. Façade strips read 11% low against 2 m,
  and 20–23% against 1 m. Strips facing the charge read 15–17% and 28–29% low, as 3afdd0c9's block
  in the open did. Roofs and upper levels have about the same bias, a little less with height:
  1.08 at 20 m against 1.09 at 2 m.
- **The impulse is 3–7% high on 4 m cells**: 0.97 against 2 m and 0.93 against 1 m. It is
  highest close in and in sight, at 0.92.
- **It is not converged at 2 m.** From 2 m to 1 m the peak still rises by 5–7% in the open and
  8–10% at façades (14–15% for those facing). In the open, in sight, 1 m reads 0.87–0.88 of
  Kingery–Bulmash's incident peak, against 0.73–0.76 for 4 m.
- **It hardly depends on the district.** Shielded and in-sight cells, Beirut and made-up layouts,
  ground and roofs: all lie within a few per cent. The bias's own scatter from cell to cell, a
  log-SD of 0.05–0.13, is well under the model's scatter against the runs (0.22–0.26 at Beirut's
  façades). What it depends on is the scaled distance, whether the face is struck head on, and,
  weakly, the cells per charge length.

**The verdict: a correction, not finer training data.**

- **Finer training data cost too much for what they buy.** On 2 m cells the 200 runs would take
  about 16 times the 4 m list's GPU time: 50–80 GPU hours, against the 5 approved. They would
  still be 5–10% low against 1 m. A refined export would also need the refined levels' fields
  read on the plan, and 3afdd0c9 found a refined level over terrain reading impulse low.
- **A factor fixes most of it,** because the bias is close to a function of scaled distance and
  facing alone, with little scatter. Against 1 m, as the best this study has:
  - the peak ×1.15 in the open, at roofs and at upper levels (×1.2 within Z 7, ×1.06 beyond
    Z 14);
  - ×1.20 at façades, and up to ×1.29 for faces struck head on;
  - the first-phase impulse ×0.93.
  This matches 3afdd0c9's interim wall factor (peak ×1.15, impulse ×0.95), measured on Beirut's
  walls in the refined runs.
- **Nothing was changed.** The factor is not applied in the model, the trainer or the app. The
  glass's and walls' calibrations were fitted against 4 m runs (#19, #47). A factor on the
  model's peak alone would move their chances without recalibrating them. f5d0fd97 is re-running
  #19's wall references on 2 m air. The factor belongs with that recalibration, as one decision
  for the user. It would apply to the surrogate and the model alike.

The runs and tables are in `/Volumes/StudioData/bombcad/ml/bias/`: `analyse-4-2.txt` and
`summary-*.json`, with the 4/2/1 m tables in `summary-r512-*` and `summary-r384-*`.

```bash
python3 -I Scripts/ml/field_bias.py run --only beirut-p2-5,beirut-p0-1,beirut-p4-3,made-perimeter-s6-2,made-towers-s6-1,made-mixed-s6-4 \
    --dx 4,2 --out /Volumes/StudioData/bombcad/ml/bias
python3 -I Scripts/ml/field_bias.py run --only made-perimeter-s6-2 --dx 4,2,1 --radius 512 --tag r512 --out /Volumes/StudioData/bombcad/ml/bias
python -I Scripts/ml/field_bias.py analyse --out /Volumes/StudioData/bombcad/ml/bias [--tag r512 --coarse 4 --fine 1]
```

### Fields at more heights

`field-export --levels 6,10,14,18,22,26,30 --roof` (and `field-runs.py run --levels … --roof`)
writes the same targets at more levels as well:

- **Each height**, so many metres over the ground under the cell, read between the two cells
  whose centres span it, as the 2 m field is read.
- **The roof**, `--above` (2 m) over the top of the cell's building.
- **The first phase** at every level. The first-phase recorder takes a layer of columns for each
  level, and the same kernel sweeps each layer at its offset in the buffers. No shader changed,
  and one layer is as before.

They go to `levels-targets.npy` (levels × targets × rows × columns) and `levels-mask.npy`
(levels × rows × columns), named in `meta.json`'s `levels`. A height level's mask is the air
there over a cell whose building, if any, is no taller. The roof's mask is the air over a cell
with a building. The 2 m files are as they were: on the dataset's runs they are bit-identical to
`main-fp`'s. Without either flag nothing else is written. `FirstPhaseColumnsTests` checks that
two layers each record as that layer alone would, and leave the run as it was to the bit.

`train_field.py --levels all` learns every level: a log peak and a log impulse for each, as
corrections to Kingery–Bulmash's incident logs at the cell's distance, each over its own mask.

## Round 3: fields at more heights (22 October 2026)

emmettl/bombcad-work#69, stages 2 and 3. The first models knew only the 2 m field, so roofs and
upper storeys stayed on the façade surrogate. This round trains the model on nine levels and
judges it at every storey and over the roofs.

**These data are from before the terrain fix.** f5d0fd97 found that a charge on shaped terrain
never got the mapped start: it started as the balloon (aff21dff, emmettl/bombcad-work#78). That
covers every Beirut run and every made-up layout with terrain, in `main-fp` and in `main-levels`
alike. At 4 m those runs read impulse about 9% low and peaks a little low. The judgement below
compares models trained and judged on the same pre-fix runs, so it says how the heights and the
validation split behave. Its absolute numbers will move. Round 4 re-exports the dataset from the
fixed main and retrains, and that is the round for the app to ship.

### The dataset: `main-levels`

`field-runs.py run --set main --first-phase --levels 6,10,14,18,22,26,30 --roof` exported the 200
runs again, into `/Volumes/StudioData/bombcad/ml/datasets/main-levels`, 10.7 GB. The levels are 4 m
apart, so that every storey of 4 m up to 32 m spans one. Each level has the peak, the all-phases
impulse and the first phase's impulse, and there is the roof level, 2 m over each building's top.

- **Stable:** all 200 runs.
- **The 2 m targets** are bit-identical to `main-fp`'s on all 200, so the recorder runs of
  `compare-first` still match them.
- **Cost:** 3.1 GPU hours of solving on the shared Studio (`main-fp`: 2.7), 4.5 hours of wall
  time.

### Training

Three models on bombcad-pc, the U-Net of round 2 (crop 256, batch 16, 300 epochs, first-phase
impulse, `--levels all`): 18 outputs, a log peak and a log impulse for each of the nine levels.

| Model | Trained on | Held out | Chooses its epoch on | Time |
|---|---|---|---|---|
| `field-unet-l3-strict` | 100 runs | 75 (Beirut, made-*-s6) | 25 validation runs: made-perimeter-s1, grid-s2, towers-s3, industrial-s4 and mixed-s5 (`--validate-layouts`) | 2.5 h, after 40 min sending the dataset |
| `field-unet-l3-strict-125` | 125 runs | the same 75 | the held-out runs, as rounds 1 and 2 did | 2.3 h |
| `field-unet-l3-byrun` | 160 runs | 40, by run (10 of Beirut's) | the held-out runs | 1.6 h |

**Choosing the epoch on a validation set** (the orchestrator's request): `train_field.py
--validate-layouts` sets those layouts' runs apart. They are not trained on, and the epoch kept in
`best.pt` is the one with the least validation loss. `best-heldout.pt` keeps the epoch the old
picking would have chosen. The held-out runs are then only judged, never chosen by. Without the
option nothing changes. For the strict model:

- **Validation chose epoch 227.** Its held-out loss was 0.0253 (validation 0.0169).
- **The held-out runs would have chosen epoch 146,** at 0.0244 (validation 0.0187).
- **Between the two, the held-out numbers hardly move.** Per level against the run's field, the
  ratio and log-SD agree within 0.02. Against the recorder at Beirut's façades, 0.98 / 0.25
  against 0.98 / 0.24. Glass by side at every storey: 0.932 / 0.72 for both. The old picking
  flattered the held-out judge by about 0.001 in loss, and by nothing a judgement shows.
- **What the validation set costs is its 25 runs.** Trained on all 125 runs and picked on the
  held-out runs, the same model reached a held-out loss of 0.0228. At Beirut's ground floor its
  glass is 0.939 / 0.71, against 0.928 / 0.68 with 100 runs. Round 2's single-level model reached
  0.942 / 0.72. So the ground floor's loss is the training runs', not the heights'.

Held out, against the run's field over every judged cell (the validation-picked strict model):

| Level | Cells | Peak | First-phase impulse | Kingery–Bulmash's peak |
|---|---|---|---|---|
| 2 m | 18.0 M | 1.01 / 0.16 | 1.00 / 0.16 | 1.21 / 0.27 |
| 6, 10, 14 m | 18.0–19.6 M | 0.99–1.01 / 0.15–0.16 | 1.00 / 0.16 | 1.22–1.25 / 0.26–0.27 |
| 18–30 m | 20.3–23.0 M | 0.99 / 0.15 | 0.99–1.00 / 0.16 | 1.27–1.36 / 0.26 |
| Roofs (2 m over the top) | 5.3 M | 1.00 / 0.17 | 0.97 / 0.19 | 1.40 / 0.29 |

### Façades at every storey, against the recorder

`judge_field.py --storeys all` matches each façade strip to the level its storey spans: 7.6 M
strips of the 50 Beirut recorder runs (`compare-first`) and two made-up ones. The run's own field
at the strip reads the recorder's peak at 1.00 / 0.04–0.11 at every level. So the levels are the
recorder's quantity, as the 2 m field was. Beirut never seen, 50–700 m, the recorder's peak and
first-phase impulse:

| Level | Strips | Strict model, peak | Impulse | Surrogate, peak | Impulse | KB incident, peak |
|---|---|---|---|---|---|---|
| Ground floor (2 m) | 598,743 | 1.02 / 0.28 | 0.98 / 0.18 | 1.09 / 0.44 | 0.95 / 0.31 | 1.26 / 0.42 |
| 6 m | 608,022 | 1.01 / 0.29 | 0.98 / 0.18 | 1.10 / 0.46 | 0.95 / 0.31 | 1.30 / 0.43 |
| 10 m | 600,537 | 1.01 / 0.28 | 0.98 / 0.18 | 1.14 / 0.46 | 0.96 / 0.32 | 1.36 / 0.43 |
| 14 m | 534,886 | 1.01 / 0.29 | 0.98 / 0.18 | 1.22 / 0.47 | 0.97 / 0.34 | 1.48 / 0.44 |
| 18 m | 433,047 | 1.02 / 0.29 | 0.98 / 0.18 | 1.30 / 0.46 | 0.98 / 0.35 | 1.60 / 0.42 |
| 22 m | 257,231 | 1.03 / 0.29 | 0.98 / 0.18 | 1.36 / 0.46 | 0.97 / 0.34 | 1.70 / 0.41 |
| 26 m | 92,773 | 1.03 / 0.34 | 0.98 / 0.22 | 1.45 / 0.48 | 0.98 / 0.40 | 1.81 / 0.45 |
| 30 m | 22,766 | 1.05 / 0.36 | 0.98 / 0.25 | 1.45 / 0.49 | 0.98 / 0.44 | 1.81 / 0.50 |

- **At every storey the model holds the ground floor's standing:** 1.01–1.05 / 0.28–0.36 in
  peak and 0.98 / 0.18–0.25 in impulse. The surrogate runs higher with every storey, from 1.09 at
  the ground floor to 1.45 at 26–30 m, with 0.44–0.49 of scatter.
- **Over all 7.6 M strips** the model gives 0.98 / 0.25 and 0.96 / 0.19, and the surrogate 1.04 /
  0.40 and 0.92 / 0.26.
- **By-run** (`field-unet-l3-byrun`, its 10 Beirut runs and its made-up ones, 1.6 M strips):
  0.97–0.99 / 0.17–0.22 in peak and 1.02–1.03 / 0.11–0.19 in impulse at every level, against
  the surrogate's 0.95–1.24 / 0.39–0.43.
- **Close in it runs high,** as the ground floor did: over every storey, against the run's field,
  1.27 at 50–200 m (the surrogate 1.84–2.31).

**Roofs against the recorder.** The roof level's mean over each recorded roof's cells, 494,442
roofs:

| | All | Z 3–5 | Z 5–7 | Z 7–14 | Z 14–20 | Z 20–28 |
|---|---|---|---|---|---|---|
| The run's roof level | 1.00 / 0.05, impulse 1.00 / 0.02 | 1.01 | 1.01 | 1.00 | 1.00 | 1.00 |
| Strict model, peak | 1.03 / 0.19 | 1.19 / 0.19 | 1.10 / 0.16 | 1.01–1.03 / 0.14–0.15 | 0.99 / 0.14 | 0.90 / 0.18 |
| Strict model, impulse | 0.95 / 0.17 | 0.99 | 0.99 | 0.95–0.98 | 0.85 | 0.63 |

The roof level is the recorder's roof load: a roof model is possible. The network's roof impulse
falls away beyond Z 14, to 0.63 at Z 20–28.

### Glass and walls through the SDOF

As the [first-phase judgement](#walls-and-roofs-through-the-envelope-sdof) did: `field-glass` and
`judge_field.py walls` on the recorder runs. The loads are the surrogate's triangle with each
predictor's peak (its impulse and rise kept). The roofs, where a variant has them, take the model's
roof level (`field-walls --roof-peaks`). The predictors:

- **Surrogate:** the surrogate everywhere.
- **Model at the ground floor:** the strict model's peak at ground-floor strips, the surrogate's
  above. This is what #67's option does today, called `l3g` in the files.
- **Model at every storey:** the strict model's peak at every strip it spans.
- **Run's field:** the run's own field at every storey, the best a field model could give.

**Glass by side** (52 runs, 616,754 sides when every storey is judged; exact / Heidke skill /
mean error of the share broken):

| Strips judged | Surrogate | Model at the ground floor | Model at every storey | 125-run model, every storey | Run's field |
|---|---|---|---|---|---|
| Every storey | 0.924 / 0.68 / 0.044 | 0.931 / 0.71 / 0.040 | **0.932 / 0.72 / 0.045** | not run | 0.950 / 0.79 / 0.033 |
| Upper storeys only | 0.923 / 0.68 / 0.044 | (the surrogate's) | 0.929 / 0.72 / 0.047 | **0.942 / 0.76 / 0.037** | 0.949 / 0.79 / 0.034 |
| Ground floor, Beirut's 50 runs | 0.916 / 0.62 / 0.043 | 0.928 / 0.68 / 0.040 | (the same) | 0.939 / 0.71 / 0.033 | 0.946 / 0.75 / 0.031 |

Round 2's ground-floor model (`field-unet-fp-strict`) on the same ground-floor strips: 0.942 /
0.72 / 0.034, as in 8701c269.

- **Upper storeys' glass gains with the model, most with the 125-run one.** That model takes
  exactly right from 0.923 to 0.942, skill from 0.68 to 0.76, and the mean error of the share
  broken from 0.044 to 0.037. That is three quarters of the way to the run's own field (0.949,
  0.79). The 100-run model gains less: 0.929, 0.72, and no fall in the share's error.
- **The gain is at the low yields and far out.** With the 125-run model, at 1,000–1,500 m exactly
  right is 0.944 against the surrogate's 0.919. At 0.05–0.1 kt it is 0.826 against 0.787.

**Walls** (concrete, moderate or worse, each building's worst wall over every judged storey;
156,569 building-runs, 19,627 damaged; each charge point held out with the factor and scatter
chosen on the other nine; 20 draws):

| Load | Moderate+: Brier / skill / tenths | At ×1.0 (the app's until 87ea4c9c) | Heavy+ (14,374) | At ×1.0 |
|---|---|---|---|---|
| Surrogate | 0.0344 / 0.69 / fail | 0.0449 / 0.59 | 0.0270 / 0.68 / fail | 0.0383 / 0.54 |
| Model at the ground floor | 0.0332 / 0.70 / fail | 0.0512 / 0.53 | 0.0267 / 0.68 / fail | 0.0404 / 0.52 |
| **Model at every storey** | **0.0236 / 0.78 / pass** | 0.0344 / 0.69 | 0.0165 / 0.80 / pass | 0.0217 / 0.74 |
| 125-run model, every storey | 0.0245 / 0.78 / pass | 0.0351 / 0.68 | 0.0172 / 0.79 / pass | 0.0223 / 0.73 |
| Run's field | 0.0079 / 0.93 / pass | 0.0263 / 0.76 | 0.0062 / 0.93 / fail | 0.0145 / 0.83 |

These walls are judged against the 4 m runs, as 8701c269's were. Since 87ea4c9c the app's walls take ×1.3, and ×1.15 in peak with ×0.95 in impulse where the model gives the peak, from #19's 2 m references; round 4 should judge against those.

**Roofs** (moderate or worse, 155,588, 34,612 damaged): the surrogate 0.0448 / 0.74; the model's
roof level 0.0444 / 0.74; the run's roof level 0.0322 / 0.81. All fail the tenths test.

- **The 125-run model's peaks run a little higher** against the recorder at Beirut's façades,
  1.05–1.10 / 0.27–0.34 by level, against the 100-run model's 1.01–1.05.
- **Walls need the upper storeys.** When a building's walls are judged at every storey, the
  ground floor alone no longer decides them. The model at the ground floor only gives 0.70, the
  surrogate's 0.69. The model at every storey gives 0.78 and passes the tenths test, which is what
  the ground floor alone gave in 8701c269. At the ground floor alone, with 50 draws, the new
  model gives 0.79 against round 2's 0.78.
- **Roofs gain nothing from the model.** The run's own roof level would take the roofs from 0.74
  to 0.81. The network's roof peak, at a log-SD of 0.19, is not good enough to show it.

### In the app (the option stays off)

The quick estimate's code reads a weights file with levels (`LearnedField.Weights.Header.levels`):

- **The network** gives each level's log peak, the head's outputs 0, 2, 4…
  (`LearnedFieldNetwork.peakChannels`). On two held-out runs it matches PyTorch within 6 × 10⁻⁶
  in the log peak at every level (`scenebench field-predict`).
- **`PeakMap`** reads each façade strip at the level its storey spans, and each roof at the roof
  level, as far as its `reach`.
- **The estimator's default reach** for a levels model is what the judge supports: every
  storey's façade strips, not the roofs (`Reach.judged`). The first model's weights reach the
  ground floor alone, read as before to the bit (`LearnedFieldTests`).
- **The weights** are exported as `field-unet-l3-strict.bcfw` and `field-unet-l3-strict-125.bcfw`,
  15.7 MB each, on StudioData in `ml/field-unet-l3-strict*/app/`. It is a new file name, not the release's, and it is used only
  when `BOMBCAD_FIELD_MODEL` or the setting names it. The download and its pin
  (`field-model-1`) are unchanged.

The option's name and standing in the sidebar still speak of the ground floor. They are for
round 4, once its weights are judged.

### The shape with height against Alsubaei's columns

Alsubaei 2015's pipe columns ([perimeter walls](validation.md#perimeter-walls-under-field-blasts),
`Fixtures/Alsubaei2015`) are the measured peak-against-height profiles in the repository: four
gauges up each column, 8.2–16.4 m from 2–102 kg of TNT, with and without a wall in front. Their
gauges span 0.32–4.2 m/kg^(1/3) of scaled height. The levels the network learns span 0.05–0.8 at
50 t and 0.02–0.24 at 2 kt. So the network's own profile can be set against only the lowest gauge
of each column, which gives the ratio its denominator and nothing more.

What can be tested is the solver's profile at the training runs' resolution: the targets the
network learns. `field_bias.py profile` runs 50 t of TNT on flat rigid ground with nothing near it,
with a level at each gauge's height scaled by Hopkinson's rule (12–153 m). At each shot's scaled
distance, the ring of cells gives each level's incident peak, reflected square-on as the gauges
face the charge. Each gauge's peak over the lowest's, gauges from the second up:

| Shot (ANFO) | Measured | 4 m cells | 2 m cells |
|---|---|---|---|
| 2.44, 6.46, 14 kg at 8.2 m | 0.86–0.98, 0.79–0.93, 0.83–1.05 | 0.93–0.95, 0.81–0.87, 0.69–0.77 | 0.93–0.95, 0.84–0.87, 0.72–0.78 |
| 2.44, 6.46, 14 kg at 11.85 m | 1.02–1.09, 0.59–0.80, 0.92–1.09 | 0.97–0.98, 0.92–0.95, 0.85–0.91 | 0.98, 0.93–0.94, 0.87–0.89 |
| 7.25, 15.05 kg at 9.2 m | 0.93, 0.89–0.93, 0.93–0.96 | 0.94–0.95, 0.85–0.87, 0.74–0.77 | 0.96, 0.88–0.89, 0.78–0.80 |
| 7.25, 15.05 kg at 12.85 m | 0.95–0.96, 0.80–0.88, 1.08–1.09 | 0.98, 0.93–0.95, 0.73–0.90 | 0.98, 0.94–0.95, 0.89–0.90 |
| 125 kg at 16.4 m | 0.64, 0.61, 0.68 | 0.93, 0.81, 0.68 | 0.92, 0.81, 0.69 |

- **The shape hardly depends on the cells.** 4 m and 2 m give each ratio within 0.01–0.04. The
  exception is one top gauge, at 0.73 against 0.89. So the ratios carry little of the 4 m
  under-read, as expected.
- **The second gauge agrees.** It is 0.93–0.98, measured 0.86–1.09.
- **The upper gauges fall more with height than measured.** The model's top gauge is at 0.69–0.91.
  The measured top gauge reads 0.83–1.09, often higher than the gauge below it. The 125 kg shot,
  whose lower records were interrupted, is the other way. [The validation page](validation.md#perimeter-walls-under-field-blasts)
  saw the same at 50 mm cells and put it down to the narrow pipes.
- **Behind the walls,** and above all the canopied wall's 1.5–10.5 m profile, the comparison is not
  made. A district layout cannot hold the canopy's overhang, and the wing walls' length, which
  decides the low gauges, is unknown.

For the 4 m under-read itself, the open measured references are the Sheffield clearing tests:
Rigby's 2014 thesis, and Rigby and Sielicki 2014, listed in data-wanted.md. They are not in the
repository yet. A factor fitted on them would stand on measurements rather than on 1 m runs.

### What it says

- **Fields at more heights work.** The model holds 1.01–1.05 / 0.28–0.36 against the recorder at
  every storey to 30 m, where the surrogate drifts to 1.45 high. Walls judged over every storey go
  from skill 0.69 to 0.78 and pass the tenths test. Upper storeys' glass goes from 0.923 to 0.942
  exactly right, skill 0.68 to 0.76, with the 125-run model.
- **Roofs:** a roof level that is right would help (0.74 → 0.81), but this network's is not good
  enough yet. Its impulse falls away far out.
- **The validation split:** choosing the epoch on it moves the held-out judgement by nothing a
  judgement shows. Its 25 runs cost glass 0.011–0.013 in exactness, at the ground floor and above.
  For round 4: train on all 125 runs and pick on the held-out runs, the picking this round found
  harmless. Or keep a smaller validation set.
- **The data are pre-fix.** Round 4 re-exports from the fixed main (about 5 GPU hours), retrains,
  and judges again. That is the round the app's option should ship.

Everything is in `/Volumes/StudioData/bombcad/ml/judge/l3/`:

- `judge-all.txt`, `judge-byrun.txt` and `judge-125.txt` for the façades;
- `glass-*.txt` and `walls-*-d20.txt` for glass and walls;
- `walls-ground-fp.txt` for the regression against round 2.

The models are in `ml/field-unet-l3-*`.

```bash
python3 -I Scripts/ml/field-runs.py run --set main --first-phase --levels 6,10,14,18,22,26,30 --roof \
    --dataset /Volumes/StudioData/bombcad/ml/datasets/main-levels
python3 -I Scripts/ml/remote-train.py bombcad-pc /Volumes/StudioData/bombcad/ml/datasets/main-levels Scripts/ml/train_field.py \
    --job field-unet-l3-strict --wait 8h --args --model unet --crop 256 --batch 16 --epochs 300 --impulse first \
    --levels all --holdout-layouts 'beirut,made-*-s6' \
    --validate-layouts made-perimeter-s1,made-grid-s2,made-towers-s3,made-industrial-s4,made-mixed-s5 < /dev/null
python -I Scripts/ml/judge_field.py --data …/main-levels --model l3=…/best.pt --model l3h=…/best-heldout.pt --impulse first \
    --storeys all --recorded …/judge/compare-first --peaks-out l3/peaks --roofs-out l3/roofs --out l3/judge-all.json
python -I Scripts/ml/judge_field.py walls --peaks l3/mixed/all --roofs l3/roofs --out-dir l3/walls-all-d20 --draws 20 \
    --variants surrogate,l3g:surrogate,l3:surrogate,runField:surrogate
```

## Round 4: fields at more heights on the fixed terrain start (23 October 2026)

emmettl/bombcad-work#69. This is round 3 again, on data from after aff21dff, which gives a charge on
terrain the mapped start. The strict model trains on all 125 runs and keeps the best epoch on the
held-out runs, as rounds 1 and 2 did. The walls are also judged on #19's fixed 2 m references.
The proposed resolution factor is shown beside each result, applied nowhere.

### Data and training

- **`datasets/main-levels-fixed`**: the 200 runs from 5a9bff94, with the same levels as round 3.
  All 200 are stable. 3.3 GPU hours of solving, on the Studio shared with other work.
- **What the fix moved:** 77 runs. These are the 25 Beirut runs at charge points 0, 1, 4, 7 and
  9, where the ground under the charge slopes, and the 52 made-up runs on slopes, hills and
  valleys. The flat runs are unchanged to the bit. On 4 m cells the fix moves each changed run's
  peak and impulse by a median of −2% to +2.5%.
- **The recorder's truth**, `judge/compare-fixed`: the 52 recorder runs of `compare-first` run
  again on the fixed main (`Scripts/ml/recorder_runs.py`), about 2.0 GPU hours of air. Each
  run's field is bit-identical to the new dataset's.
- **The models** (bombcad-pc, as round 3's):
  - `field-unet-l4-strict`: 125 runs, 75 held out, best epoch 130 (held-out loss 0.0237); 3.8
    hours, 1.2 of them sending the dataset;
  - `field-unet-l4-byrun`: 160 runs, 40 held out; 1.6 hours.
- **The weights:** `ml/field-unet-l4-strict/app/field-unet-l4-strict.bcfw`, 15,718,128 bytes,
  SHA-256 `bc8f9f76…a219ca8`. It is a new file name. The release's pin and the download are
  unchanged. On two held-out runs the Swift network matches PyTorch within 4 × 10⁻⁶ in the log
  peak at every level.

### Façades and roofs against the recorder

Beirut never seen, 50–700 m (median / log-SD of predicted over recorded):

| Level | Strict, peak | Impulse | Surrogate, peak | Impulse |
|---|---|---|---|---|
| Ground floor | 1.02 / 0.28 | 0.97 / 0.18 | 1.09 / 0.44 | 0.95 / 0.31 |
| 6–14 m | 1.00 / 0.27–0.28 | 0.95–0.96 / 0.18 | 1.10–1.21 / 0.46–0.47 | 0.95–0.97 / 0.32–0.34 |
| 18–22 m | 1.02–1.03 / 0.28 | 0.94–0.95 / 0.19 | 1.29–1.35 / 0.46–0.47 | 0.96–0.97 / 0.34–0.35 |
| 26–30 m | 1.06–1.07 / 0.32–0.34 | 0.93–0.94 / 0.23–0.26 | 1.44–1.45 / 0.48–0.49 | 0.97–0.98 / 0.40–0.44 |

- **Over all 7.6 M strips** of every storey, the strict model gives 0.99 / 0.25 and 0.96 / 0.19.
  The surrogate gives 1.04 / 0.39 and 0.92 / 0.26.
- **The by-run model** (its 10 Beirut runs and the made-up ones, 1.6 M strips) gives
  0.97–1.00 / 0.16–0.21 and 1.01–1.02 / 0.11–0.18 at every level.
- **Roofs:** the roof level reads the recorded roofs at 1.09 / 0.19, impulse 0.98 / 0.17. It runs
  1.12–1.22 at Z 3–10. Its impulse falls to 0.65 at Z 20–28.

### Glass by side

Against the 4 m recorder runs (exact / Heidke skill / mean error of the share broken):

| Strips judged | Surrogate | Strict model | Model with the factor (peak ×1.2) | Round 2 (ground) | Run's own field |
|---|---|---|---|---|---|
| Ground floor, Beirut's 50 | 0.917 / 0.62 / 0.043 | 0.927 / 0.67 / 0.040 | 0.941 / 0.67 / 0.029 | **0.943 / 0.73 / 0.034** | 0.946 / 0.76 / 0.031 |
| Upper storeys, 52 runs | 0.924 / 0.68 / 0.044 | 0.934 / 0.73 / 0.044 | **0.948 / 0.75 / 0.030** | – | 0.949 / 0.79 / 0.034 |
| Every storey, 52 runs | 0.926 / 0.68 / 0.043 | 0.936 / 0.73 / 0.043 | 0.948 / 0.75 / 0.030 | – | 0.950 / 0.79 / 0.033 |
| Every storey, Beirut: round 2 at the ground, round 4 above | 0.923 / 0.68 / 0.045 | 0.933 / 0.73 / 0.045 | | 0.936 / 0.74 / 0.043 combined | 0.949 / 0.79 / 0.034 |

- **Round 4 at the ground floor only**, the surrogate above, gives every storey 0.932 / 0.71 / 0.039. The storeys above add 0.004 and 0.02 of skill.
- **The ground floor is round 4's weak point.** At Beirut's ground floor the strict model is
  unbiased but scatters more than round 2 beyond 500 m: log-SD 0.22–0.24 against 0.18–0.19.
  Round 2 also read 1–4% high there, which the glass's triangle rewards. Round 3's 125-run model
  reached 0.939, so how much of the gap is the epoch is uncertain. This round's best epoch came
  early, at 130 of 300.
- **The factor helps glass against the 4 m runs, for the wrong reason.** A peak ×1.2 against 4 m
  truth is 20% high. It gains because the glass's single triangle misses the later reflections
  that break panes ([glass by side](#glass-by-building-side-the-product-test)). That is a
  calibration effect, not the resolution's. No 2 m glass reference exists to tell them apart.

### Walls and roofs

**Against the 4 m recorder runs** (concrete, moderate or worse, worst over every storey; 156,569
building-runs, 19,652 damaged; 20 draws; each charge point held out):

| Load | Moderate+ | Heavy+ | Roofs, moderate+ |
|---|---|---|---|
| Surrogate | 0.0344 / 0.69 / fail | 0.0270 / 0.68 / fail | 0.0447 / 0.74 / fail |
| Model at the ground floor only | 0.0327 / 0.70 / fail | 0.0264 / 0.68 / fail | 0.0447 / 0.74 / fail |
| **Model at every storey and the roofs** | **0.0229 / 0.79 / pass** | 0.0161 / 0.81 / fail | **0.0394 / 0.77 / pass** |
| The same with the factor | 0.0228 / 0.79 / fail (it picks ×0.8) | 0.0170 / 0.80 / pass | 0.0449 / 0.74 / fail |
| Round 2 at the ground, round 4 above | 0.0247 / 0.77 / fail | 0.0158 / 0.81 / pass | 0.0481 / 0.72 / fail |
| Run's own field | 0.0079 / 0.93 / pass | 0.0062 / 0.93 / fail | 0.0322 / 0.81 / fail |

On the fixed data the roof level helps for the first time: roofs 0.74 → 0.77, passing the tenths
test. Round 3's gave nothing.

**Against #19's fixed 2 m references** (14707293: Beirut's ten near boxes refined to 2 m on the
mapped start, 20,530 building-yields; through the app's own estimate, `wall-calibrate
--learned`, 50 draws; roofs at the app's ×1.3, ×0.5):

| Concrete walls, moderate or worse | Round 4, every storey's façades | Round 2, ground floor |
|---|---|---|
| ×1.0 | 0.020 / 0.63 / fail | 0.021 / 0.62 / fail |
| The app's adopted (peak ×1.15, impulse ×0.95) | 0.023 / 0.58 / fail | **0.018 / 0.66 / pass** |
| The proposed factor (peak ×1.2, impulse ×0.93) | 0.026 / 0.52 / fail | 0.019 / 0.65 / fail |
| Refit, each yield held out | 0.020 / 0.63 / fail (×1.0, impulse ×0.78) | 0.019 / 0.66 / pass (×1.3) |

The surrogate alone at its adopted ×1.3 gives 0.023 / 0.59, tenths pass
([the first look](surrogate-first-look.md#the-walls-chances-re-judged-on-2-m-references-22-october-2026)).
Roofs give 0.74 with every model.

- **On the 2 m references, round 4 does not beat round 2 for walls.** Raw they are level (0.63
  against 0.62). Round 2 gains from the adopted ×1.15 (0.66, pass), and round 4 loses (0.58). Its
  refit wants no peak factor. In round 2's estimate the storeys above the ground floor are the
  surrogate's, which runs 1.1–1.45 high there. That excess seems to be part of what the 2 m
  references reward, and round 4's accurate upper storeys take it away. The factor at ×1.2 makes
  round 4 worse still (0.52).
- **Against the 4 m runs the order is the other way:** round 4 at every storey scores 0.79 and
  passes, round 2's estimate 0.70. The two truths disagree on what a correct upper storey is worth.
  The 2 m references are the user's adopted standard.

### The resolution factor

Shown, applied nowhere:

- **Against the 4 m runs** it helps glass (0.934 → 0.948 at upper storeys), through the
  triangle's calibration, not through resolution. It changes walls little once their factor is
  refit (0.79 either way), and it hurts at the app's pairs.
- **Against the 2 m references** it hurts round 4's walls (0.63 → 0.52) and leaves round 2's
  level (0.66 → 0.65).
- **It is not the correction the 2 m references want for these models.** Do not adopt it as
  measured here.

### What it says, and the decision for the user

- **The heights work against the 4 m truth.** Every storey to 30 m holds 1.00–1.07 / 0.27–0.34
  against the recorder, where the surrogate drifts to 1.45 high. Upper storeys' glass goes from
  0.924 to 0.934 (skill 0.68 → 0.73), walls over every storey from 0.69 to 0.79, and the roofs
  from 0.74 to 0.77.
- **But round 4 is not ready to replace round 2 as the shipped model:**
  - at the ground floor its glass is 0.927 against round 2's 0.943;
  - on the 2 m wall references, the user's adopted walls truth, it scores 0.58–0.63 against
    round 2's 0.66.
- **The recommendation: do not publish round 4 as field-model-2 yet.** Keep `field-model-1`.
  Round 4's weights are on StudioData for testing (`BOMBCAD_FIELD_MODEL`), with the option off.
  What would settle it:
  - a 2 m reference for the storeys above the ground floor, and for glass, so that the two truths
    stop disagreeing;
  - a ground-floor head as sharp as round 2's: a seed or epoch study, or a loss weighted toward
    the ground floor.
- **If the user wants upper storeys now,** combining round 2 at the ground floor with round 4
  above scores glass 0.936 / 0.74 and walls 0.77 against the 4 m runs. It would need two networks
  in the app, which is not built.

Everything is in `/Volumes/StudioData/bombcad/ml/judge/l4/`:

- `judge-all.txt` and `judge-byrun.txt`;
- `glass-*.txt`;
- `walls-all-d20.txt` and `walls-comb-d20.txt`;
- `walls-2m-x/` for the 2 m references.

```bash
python3 -I Scripts/ml/field-runs.py run --set main --first-phase --levels 6,10,14,18,22,26,30 --roof \
    --dataset /Volumes/StudioData/bombcad/ml/datasets/main-levels-fixed
python3 -I Scripts/ml/recorder_runs.py --like /Volumes/StudioData/bombcad/ml/judge/compare-first \
    --out /Volumes/StudioData/bombcad/ml/judge/compare-fixed
python3 -I Scripts/ml/remote-train.py bombcad-pc …/main-levels-fixed Scripts/ml/train_field.py --job field-unet-l4-strict \
    --wait 8h --args --model unet --crop 256 --batch 16 --epochs 300 --impulse first --levels all \
    --holdout-layouts 'beirut,made-*-s6' < /dev/null
scenebench wall-calibrate <Beirut's inputs> --dx 4 --height 320 --radius 1320 --runs <the ten 2 m near boxes> \
    --factors 0.8,1,1.15,1.2,1.3,1.5 --scales 0.5,1 --impulse-ratios 0.775,0.826,1 --draws 50 \
    --learned field-unet-l4-strict.bcfw --held-out \
    --fixed raw=1:1:1/1.3:0.5:1,adopted=1.15:1:0.826/1.3:0.5:1,factor=1.2:1:0.775/1.3:0.5:1
```

## Round 4 on the 2 m references: glass and every storey (23 October 2026)

emmettl/bombcad-work#69. Round 4 left two truths disagreeing about the storeys above the ground
floor, and no 2 m reference for glass. This judges three ways of using the networks, through the
app's own estimate, on the same 2 m references as #19's walls. The question was whether to ship new
weights as `field-model-2` for 0.7.1.

**The references.** These are Beirut's ten near boxes, 0.15–1.5 kt, refined to 2 m below the
buildings' tops on the mapped start (14707293). Their saved loads already hold every storey's
façade strips: 152,604 strips over 3,012 buildings, 95,000 of them recorded. Rerun on main at
744b5236, the 150 t and 200 t boxes are bit-identical to the 22 October runs, façades, walls and
roofs alike, so the other eight were not rerun.

**The judge.** `scenebench field-refs` takes each yield in turn and lets it go before the next. At
each it makes the app's estimate (`FacadeLoadSurrogate.Prepared.estimate` with each variant's
`LearnedField.Estimator`). It judges glass by side as `field-glass` does: each strip's breakage on
the run's 2 m history and on the estimate's triangle, summed over the side's strips, each side's
state GEER's. Ground-floor strips and those above form their sides apart. The walls go through
`wall-calibrate`, as before. Its new `--learned-ground` gives the combination.

The variants:
- **(a)** round 2 (`field-unet-fp-strict`, field-model-1) at the ground floor, the surrogate above:
  today's option;
- **(b)** round 4 (`field-unet-l4-strict`) at every storey;
- **(c)** round 2 at the ground floor and round 4 above
  (`LearnedField.Estimator(groundNetwork:)`).

**Glass by side against the 2 m runs** (10 yields, sides inside 0.85 of the box; exact / Heidke
skill / mean error of the share broken):

| Sides | Surrogate | (a) Round 2, ground | (b) Round 4, every storey | (c) Combined |
|---|---|---|---|---|
| Ground floor (63,951) | 0.911 / 0.51 / 0.043 | **0.939 / 0.57 / 0.034** | 0.929 / 0.41 / 0.037 | **0.939 / 0.57 / 0.034** |
| … 700–1000 m | 0.946 / 0.39 | 0.977 / 0.60 | 0.979 / 0.55 | 0.977 / 0.60 |
| … beyond 1000 m | 0.851 / 0.51 | 0.882 / 0.54 | 0.855 / 0.36 | 0.882 / 0.54 |
| Upper storeys (64,914) | 0.903 / 0.54 / 0.051 | 0.903 / 0.54 / 0.051 (the surrogate's) | **0.925 / 0.59 / 0.043** | **0.925 / 0.59 / 0.043** |
| Every storey (65,263) | 0.904 / 0.54 / 0.051 | 0.910 / 0.56 / 0.048 | 0.926 / 0.58 / 0.043 | **0.928 / 0.60 / 0.042** |

**Peaks by storey against the 2 m runs** (predicted over recorded, median / log-SD; all strips,
then 50–700 m):

| Level | Strips | Surrogate | Round 2 | Round 4 |
|---|---|---|---|---|
| Ground floor | 162,366 | 0.90 / 0.37; 0.77 / 0.36 | 1.01 / 0.32; 0.89 / 0.25 | 1.10 / 0.35; 0.92 / 0.25 |
| 6–14 m | 141,000–162,000 | 0.90–0.94 / 0.37; 0.79–0.82 / 0.34–0.35 | (the surrogate's) | 1.02–1.08 / 0.33–0.34; 0.90–0.91 / 0.24 |
| 18–22 m | 56,000–112,000 | 0.97–1.02 / 0.37; 0.87–0.92 / 0.35–0.44 | | 1.03–1.04 / 0.34; 0.93 / 0.25–0.32 |
| 26–30 m | 6,000–19,000 | 0.98–1.08 / 0.36–0.40; 0.86–0.90 / 0.30–0.53 | | 1.00–1.09 / 0.34–0.37; 0.90–0.93 / 0.25–0.42 |

**Concrete walls, moderate or worse, the worst storey** (2,053 buildings × 10 yields, 50 draws;
Brier / skill / the tenths test):

| Walls' load | Surrogate | (a) Round 2, ground | (b) Round 4, every storey | (c) Combined |
|---|---|---|---|---|
| ×1.0 | 0.028 / 0.48 / fail | 0.021 / 0.62 / fail | 0.020 / 0.63 / fail | 0.020 / 0.64 / fail |
| **The app's adopted** (×1.3; with a model, peak ×1.15, impulse ×0.95) | 0.023 / 0.59 / pass | **0.018 / 0.66 / pass** | 0.023 / 0.58 / fail | 0.020 / 0.63 / fail |
| Refit, each yield held out | 0.023 / 0.59 / fail | 0.019 / 0.66 / pass | 0.020 / 0.63 / fail | 0.021 / 0.62 / fail |
| Best pair of the grid over all ten (not held out) | | 0.0183 (×1.3, scatter ×½, impulse ×0.83) | | 0.0195 (×1.3, scatter ×½) |

Roofs are 0.74 in every variant. The surrogate's and (b)'s rows are from 14707293 and round 4, on
these same references. (a) was judged again here and gave the same figures to the digit.

**What it says:**

- **At the upper storeys round 4 is better on the 2 m truth too.** Its peaks there read 0.90–0.93
  of the 2 m runs at 50–700 m with a log-SD of 0.24–0.25. The surrogate's read 0.79–0.92 with
  0.34–0.44. Upper storeys' glass goes from 0.903 to 0.925, skill 0.54 to 0.59. So the two truths
  agree about the upper storeys' peaks. Round 4's guess, that the 2 m references reward the
  surrogate running high above the ground floor, was wrong: against 2 m cells the surrogate reads
  low there, not high.
- **At the ground floor round 2 stays the better network.** Its glass is 0.939 / 0.57 against
  round 4's 0.929 / 0.41, and round 4 loses most beyond 1 km (skill 0.36 against 0.54).
- **The walls still prefer (a).** At the adopted factors (a) scores 0.66 and passes the tenths
  test. (c) scores 0.63 and (b) 0.58, and both fail. No factor of the grid brings (c) to (a): its
  best pair over all ten yields gives a Brier of 0.0195, against (a)'s 0.0183. More accurate peaks
  above the ground floor do not make better wall chances. A likely reason is that the chances draw
  the surrogate's own scatter (log-SD 0.35–0.45) about whichever peak they are given, and the
  model's 0.25 is never used. The factors were also fitted to (a). That is for a next round, not
  tried here.

**The verdict: field-model-1 stays.** Neither (b) nor (c) is clearly better than (a) on the 2 m
references. (b) loses at the ground floor's glass and at the walls. (c) matches (a) at the ground
floor's glass and gains at the upper storeys' glass (0.925 against 0.903), but it loses at the
walls (0.63 and failing the tenths test, against 0.66 and passing). No weights are published,
and the app's pin, file and option are unchanged.

What would let (c) ship:
- the walls' chances given the model's own scatter where its peak is used, and their factors
  refit for the combination on these references;
- a decision by the user on whether a gain in upper storeys' glass is worth a loss in the walls.

The app can already run (c) for testing. `LearnedField.Estimator(groundNetwork:)` takes a second
network for the ground floor, and `wall-calibrate --learned l4.bcfw --learned-ground fp.bcfw`
judges it. Only the bench uses it so far. The setting and the download still take one file.

Everything is in `/Volumes/StudioData/bombcad/ml/judge/l4-2m/`:
- `glass-2f.txt` for glass and peaks;
- `walls-2f-fp.txt` and `walls-2f-comb.txt` for the walls;
- `near2g-*` for the two reruns on 744b5236;
- `glass.sh`, `walls.sh` and `refs.sh` for the commands.

```bash
scenebench field-refs <Beirut's inputs> --dx 4 --height 320 --radius 1320 --runs <the ten 2 m near boxes> \
    --variants surrogate,fp=field-unet-fp-strict.bcfw,l4=field-unet-l4-strict.bcfw,comb=field-unet-l4-strict.bcfw+field-unet-fp-strict.bcfw
scenebench wall-calibrate <the same> --factors 0.8,1,1.15,1.3,1.5 --scales 0.5,1 --impulse-ratios 0.826,1 \
    --draws 50 --learned field-unet-l4-strict.bcfw --learned-ground field-unet-fp-strict.bcfw --held-out \
    --fixed raw=1:1:1/1.3:0.5:1,learned-adopted=1.15:1:0.826/1.3:0.5:1
```

## The models' own scatter in the chances (23 October 2026)

emmettl/bombcad-work#69. The round above left one likely reason why (c) loses at the walls. The
chances draw the surrogate's scatter (`Uncertainty.leaveOneOut`, log-SD 0.30–0.41 at Beirut's
scaled distances) about whichever peak they are given, and never the model's own. This round
draws the model's own where its peak is used, refits the walls for (c), and judges (a) and (c)
again on the same 2 m references, each with its own scatter.

**What was built.** It is opt-in, and off everywhere, the app included. With it off, nothing
changes to the bit.

- `LearnedField.Scatter`: each network's peak scatter by level (ground floor or above), facing
  (front, cos > 1/3; side; back, cos < −1/3) and scaled distance (bands to Z 7, 10, 14, 20, 28
  and beyond).
- `LearnedField.Estimator(scatter:)` hands it on through the `PeakMap`. Each façade strip the
  network reads carries its bands (`Features.learnedPeakScatter`).
- `glassProbabilities` and `structureProbabilities` draw each side's same standard normal as
  before. They scale it by the strip's own band at that draw's yield. The impulse's error is
  still the surrogate's, and so is every strip the network does not read.
- Bench: `wall-calibrate --own-scatter`, and `field-refs`' variants with `@own`. `field-refs` now
  also judges the glass's chances by side (`--draws`), by Brier, skill and the deciles' test.

**The model's scatter, measured.** It is measured against the 4 m recorder runs, which neither
strict model saw. These are Beirut's charge points and two made-up layouts, from
`judge_field.py`'s strips (`fpw/` for round 2, `l4/` for round 4). It is not measured on the 2 m
references it is judged on. Each figure is the root mean square of the log of the model's peak
over the recorded strip's, bias and spread together, as `leaveOneOut` is.

| Z, m/kg^(1/3) | ≤ 7 | 7–10 | 10–14 | 14–20 | 20–28 | > 28 |
|---|---|---|---|---|---|---|
| Round 2, ground floor (1.47 M strips) | 0.32–0.33 | 0.21 | 0.19–0.20 | 0.19–0.20 | 0.19–0.22 | 0.29–0.33 |
| Round 4, storeys above (6.15 M) | 0.32–0.34 | 0.20–0.21 | 0.19–0.20 | 0.21 | 0.22–0.23 | 0.37–0.39 |
| Round 4, ground floor | 0.32–0.34 | 0.22–0.23 | 0.21–0.22 | 0.22–0.24 | 0.22–0.25 | 0.38–0.40 |
| The surrogate on the same strips, ground floor | 0.56 | 0.33 | 0.29 | 0.28 | 0.27 | 0.37 |
| `leaveOneOut`, as drawn | 0.41 | 0.30 | 0.25 | 0.24 | 0.23 | 0.30 |

- The ranges are over the facings. Facing moves the model's scatter by 0.02 at most. It moves the
  surrogate's bias by ±0.15–0.4 in the log.
- Height moves it little: round 4 reads 0.24–0.25 from 6 to 22 m, and 0.27–0.29 at 26–30 m.
- **The 4 m recorder understates the model's scatter about the 2 m runs.** On the 2 m references,
  round 2's ground floor scatters by 0.32 over all strips (`field-refs`). On the 4 m recorder it
  scatters by 0.24. The surrogate's is about the same on both, 0.37 and 0.38. The model learned
  the 4 m runs, and the 2 m runs do not share their errors. The grid's scatter scale (×½, ×1,
  ×1.5) leaves room for that.

**Glass's chances by side** against the 2 m runs. These are 10 yields, sides inside 0.85 of the
box, 50 draws at each run's yield, the load scatter only (Brier / skill / every decile of 200+
sides within 0.1). The outcome judged is blown out. "Some broken" is near 1 for nearly every side
in these boxes: its Brier is 0.011–0.012 for every variant, skill 0.01–0.07, and every variant
passes.

| Sides | Surrogate | (a) | (a), own scatter | (c) | (c), own scatter |
|---|---|---|---|---|---|
| Ground floor (63,951) | 0.0609 / 0.24 / fail | 0.0469 / 0.41 / fail | 0.0462 / 0.42 / **pass** | 0.0469 / 0.41 / fail | 0.0462 / 0.42 / **pass** |
| Upper storeys (64,914) | 0.0663 / 0.32 / fail | 0.0663 / 0.32 / fail | 0.0663 / 0.32 / fail | 0.0559 / 0.42 / fail | **0.0553 / 0.43** / fail |
| Every storey, the app's sides (65,263) | 0.0662 / 0.31 / fail | 0.0631 / 0.34 / fail | 0.0629 / 0.35 / fail | 0.0546 / 0.43 / fail | **0.0539 / 0.44** / fail |

The exact states by side are as the round above gave them, since the scatter does not enter them:
(c) 0.939 at the ground floor, 0.925 above and 0.928 over every storey, against (a)'s 0.939,
0.903 and 0.910.

**Concrete walls, moderate or worse, the worst storey** (2,053 buildings × 10 yields, 50 draws;
Brier / skill / the tenths test; grid ×0.8–1.5, scatter ×½, ×1 or ×1.5, impulse ×0.826 or ×1):

| Walls' load | (a) | (a), own scatter | (c) | (c), own scatter |
|---|---|---|---|---|
| ×1.0 | 0.0207 / 0.622 / fail | 0.0233 / 0.575 / fail | 0.0199 / 0.636 / fail | 0.0223 / 0.593 / fail |
| The app's adopted (peak ×1.15, impulse ×0.95) | **0.0184 / 0.664 / pass** | 0.0190 / 0.653 / fail | 0.0204 / 0.628 / fail | 0.0188 / 0.656 / fail |
| Refit, each yield held out | 0.0186 / 0.661 / pass | 0.0203 / 0.630 / pass | 0.0206 / 0.624 / fail | 0.0188 / 0.656 / fail |
| Best pair over all ten (not held out) | 0.0183 (×1.3, scatter ×½, impulse ×0.83) | 0.0190 (adopted) | 0.0195 (×1.3, scatter ×½) | 0.0188 (adopted) |

- For (c) with its own scatter, every held-out yield picks the adopted pair, so the refit is the
  adopted factors.
- (c)'s failing tenth is 0.80–0.90: 176 building-yields, predicted 0.84 and seen 0.95. That is on
  the unsafe side, and 0.01 beyond the test.
- Scatter ×1.5 is never chosen.
- Roofs are 0.74 in every variant, as before.
- (a) and (c) without their own scatter reproduce the round above to the digit.

**What it says:**

- **For glass, the model's own scatter helps a little.** Blown-out skill rises by 0.01 in every
  group. At the ground floor it lets the deciles pass, at 0.0462 against 0.0469. (c) stays far
  ahead of (a) above the ground floor: 0.43 against 0.32, and 0.44 against 0.35 over the app's
  whole sides.
- **For walls, it helps (c) and hurts (a).**
  - (c) goes from 0.624 to 0.656 held out, nearly closing its gap to (a)'s 0.661–0.664. It still
    fails the tenths test, by one tenth.
  - (a) loses: 0.664 → 0.653 at its adopted factors, and that pair no longer passes.
  - The likely reason is the table above: the drawn 0.19–0.21 is narrower than the model's
    scatter about the 2 m runs, about 0.32. The chances become too sure. In (a) every
    ground-floor wall is drawn narrow. In (c) the narrower draw also takes the place of the
    surrogate's wide one above, where the network had been given the surrogate's 0.30–0.41.
- **The walls' factors don't move for (c).** With its own scatter, (c)'s refit lands on the
  adopted ×1.15, impulse ×0.95 at every yield.

**The verdict: field-model-1 stays.** With each variant given its own scatter:

- (c) beats (a) at glass: blown-out skill 0.44 against 0.35 over the app's sides, ties at the
  ground floor, and wins above it.
- At walls (c) does not beat (a) as it ships: Brier 0.0188 against 0.0184, skill 0.656 against
  0.664, and it fails the tenths test that (a) passes.
- Against (a) given its own scatter, (c) scores better at walls (0.656 against 0.630), but that
  (a) is worse than today's, so it is not the bar.

No weights are published, and no `field-model-2` is prepared. The app's pin, file and option are
unchanged, and the scatter stays off. What would settle it:

- the model's scatter measured against 2 m runs rather than 4 m ones. That needs 2 m references
  apart from Beirut's ten near boxes, so that measuring it does not fit it to the judge. A scale
  on the measured 4 m scatter (×1.5 was not chosen) is not that;
- or the user's decision that (c)'s glass gain, about +0.09 of blown-out skill over the app's
  sides, is worth a wall score level within 0.01 of skill that misses the tenths test by one
  tenth.

The user decided the second the same day: (c) with its own scatter ships as `field-model-2`
([field model 2 in the app](#field-model-2-in-the-app-23-october-2026)).

Everything is in `/Volumes/StudioData/bombcad/ml/judge/scatter/`:

- `scatter_stats.py`, with `fp-strict.json` and `l4-strict.json` for the measured scatter;
- `glass.sh` and `glass.txt` for glass and peaks;
- `walls.sh` and `walls-{a,c,a-own,c-own}.txt` for the walls;
- `run1/` for the first own-scatter runs, at 3 decimals, which give the same Brier sums.

```bash
python3 -I scatter_stats.py ../fpw/judge-strict-strips.json strict fp-strict.json
python3 -I scatter_stats.py ../l4/judge-all-strips.json l4 l4-strict.json
scenebench field-refs <Beirut's inputs> --dx 4 --height 320 --radius 1320 --runs <the ten 2 m near boxes> --draws 50 \
    --variants surrogate,a=fp.bcfw,a-own=fp.bcfw@own,c=l4.bcfw+fp.bcfw,c-own=l4.bcfw+fp.bcfw@own
scenebench wall-calibrate <the same> --factors 0.8,1,1.15,1.3,1.5 --scales 0.5,1,1.5 --impulse-ratios 0.826,1 \
    --draws 50 --learned l4.bcfw --learned-ground fp.bcfw --own-scatter --held-out \
    --fixed raw=1:1:1/1.3:0.5:1,learned-adopted=1.15:1:0.826/1.3:0.5:1
```

## Field model 2 in the app (23 October 2026)

emmettl/bombcad-work#69. On 23 October the user decided, in chat, to ship the model: variant (c)
above, given its own scatter. With both files the app's option is now **field model 2**:

- round 2's strict network (`field-unet-fp-strict`, field model 1's very file) gives the ground
  floor's façade strips their peak;
- round 4's strict levels network (`field-unet-l4-strict`) gives the storeys above theirs;
- each strip the networks read draws its own network's measured scatter in the chances
  (`Scatter.fieldModel1` at the ground floor, `Scatter.round4` above);
- roofs and the impulse stay on the surrogate (`Reach.judged`).

`LearnedField.optionEstimator` builds it as `scenebench field-refs` judged it (`c-own`). With the
option off nothing is reached, so nothing changes to the bit. With field model 1's file alone the
estimator is field model 1's as it shipped: its peak at the ground floor, the surrogate's scatter.

**Its standing**, judged through the app's own estimate against Beirut's ten near boxes refined to
2 m, 50–700 m, ten yields (the two rounds above):

| | Field model 1 | Field model 2 |
|---|---|---|
| Glass blown out by side, over the app's sides (Brier / skill) | 0.0631 / 0.34 | **0.0539 / 0.44** |
| … above the ground floor | 0.0663 / 0.32 | **0.0553 / 0.43** |
| … at the ground floor (and its deciles' test) | 0.0469 / 0.41, fails | 0.0462 / 0.42, passes |
| Glass by side exactly right, every storey | 0.910 | 0.928 |
| Concrete walls moderate or worse, worst storey, adopted factors (Brier / skill / tenths test) | **0.0184 / 0.664 / passes** | 0.0188 / 0.656 / fails |
| Roofs | 0.74 | 0.74 |

In words, on the façade terms of the time: glass blown out, Brier skill 0.44 against field model
1's 0.34, and the walls 0.656 against 0.664, missing the tenths test by one tenth on the unsafe side
(in the 0.80–0.90 tenth, 176 building-yields, they predicted 0.84 and 0.95 were damaged so).

**Judged again on the façade terms refitted on 23 October 2026** (emmettl/bombcad-work#56; the
surrogate gives the impulse everywhere and the peak where no network reads, and the concrete walls'
own factor went from ×1.3 to ×1.15). The field path's factors, peak ×1.15 and impulse ×0.95, were
judged again with the refit's grid, each yield held out:

| | Field model 1 | Field model 2 |
|---|---|---|
| Glass blown out by side, over the app's sides (Brier / skill) | 0.0628 / 0.35 | **0.0540 / 0.44** |
| … above the ground floor | 0.0659 / 0.32 | **0.0553 / 0.43** |
| Glass by side exactly right, every storey | 0.908 | 0.927 |
| Concrete walls moderate or worse, peak ×1.15, impulse ×0.95 | 0.0190 / 0.654 / passes | **0.0188 / 0.656 / passes** |
| The refit's choice, each yield held out | ×1.15 with the impulse ×1.15 in 9 folds (0.651) | **×1.15, impulse ×0.95, in every fold** (0.656) |
| Roofs | 0.74 | 0.74 |

So the field path keeps ×1.15 and ×0.95: field model 2's refit chooses them in every fold, and
field model 1's own choice scores lower than they do. In words: glass blown out over the app's
sides, Brier skill 0.44 against field model 1's 0.35, and above the ground floor 0.43 against
0.32; for concrete walls moderate or worse, Brier skill 0.656 against field model 1's 0.654, and
both pass the tenths test. The option's standing in the app says the same (`LearnedField.standing`).
With field model 1's file alone it shows field model 1's standing, as before (`standingModel1`).
The judgements are in `$BOMBCAD_DATA/refit56/takeover/judge-adopt` (`glass.txt`, `walls-a.txt`,
`walls-c-own.txt`). On the references run to their judged corners rather than to 3 s, the same
day, the walls held to the digit, and the glass gains grew: blown out over the app's sides, 0.69
against 0.43 ([below](#the-near-boxes-run-to-their-corners-23-october-2026)).

**The weights.** The release `field-model-2` on emmettl/bombcad holds both files, kept off
"latest" like `field-model-1`:

| File | Bytes | SHA-256 |
|---|---|---|
| `field-unet-fp-strict.bcfw` (round 2, epoch 59) | 15,716,144 | `d544d80f5a3985c56e0035475b4ebf95f8b16ffc2057619a7f7b621935370440` |
| `field-unet-l4-strict.bcfw` (round 4, epoch 130) | 15,718,128 | `bc8f9f76db52cdd34b451f7f8e27473d0ef7ca99d333e1905a5573603a219ca8` |

`LearnedField.Release` pins the tag and each file's name, size and hash.

- **A first download fetches both, 31.4 MB.** It checks each file's hash and reads each as weights.
  Only when both have passed does it move them into
  `~/Library/Application Support/BombCAD/LearnedModels/` (`LearnedFieldDownload.install`). A
  failure or a cancel keeps neither.
- **An install with field model 1's file keeps working.** Its file is the release's first, to the
  byte. Under the option it says "A newer model is available", with the size, 15.7 MB, and a
  **Download Update** button. Nothing is fetched until that is clicked. The update fetches only
  the second file. If the update fails, field model 1 carries on and the app says so.
- **Set by hand.** `BOMBCAD_FIELD_MODEL` or the setting names the ground floor's file, as before.
  The levels network is read from `BOMBCAD_FIELD_MODEL_LEVELS`, else beside it under its own name.
  A path set by hand is never filled and never offered the update.
- **Tests** use `file://` stand-ins only (`LearnedFieldDownloadTests`, `LearnedFieldOptionTests`).

The release's assets are in `/Volumes/StudioData/bombcad/release-field-model-2/`: both `.bcfw`
files and `MODEL-NOTES.md`, which is also the release's text. Their hashes match the pin. The
command for the user, from a checkout once the commit is on main:

```bash
gh release create field-model-2 --repo emmettl/bombcad --target main --latest=false \
    --title "Learned field model 2 (field-unet-fp-strict + field-unet-l4-strict)" \
    --notes-file $BOMBCAD_DATA/release-field-model-2/MODEL-NOTES.md \
    $BOMBCAD_DATA/release-field-model-2/field-unet-fp-strict.bcfw \
    $BOMBCAD_DATA/release-field-model-2/field-unet-l4-strict.bcfw \
    $BOMBCAD_DATA/release-field-model-2/MODEL-NOTES.md
```

**Check on this Mac.** The user asked whether the model runs on a small laptop. The button **Check
on this Mac**, under the option, runs `BombCAD field-model check` from the app's own executable,
in a process of its own (`LearnedFieldCheck`). It loads the downloaded weights and runs each
network twice on a built-in district of 1,250 × 1,250 cells of 4 m, 5 km square, larger than
Beirut's judged boxes (2.6 km across). It reports:

- the GPU and its recommended working set;
- the load time and the first and second run's times;
- the process's peak memory;
- whether it fits, and the largest square plan the option will run there.

On the Studio (M4 Max, 30.2 GB recommended working set), each network loaded in 0.7 s and ran
in 0.6–0.7 s the first time (building the graph) and 0.3 s after that. The check's process peaked
at 3.2 GB for both networks, 3.0 GB for one alone, and 1.1 GB for one on a 688² plan.
MPSGraph holds about 1.7–1.8 KB a cell at once, over about 0.2 GB.

**When memory is short.** Before each run, `LearnedFieldNetwork` checks the plan's need, taken as
2 KB a cell over 0.25 GB, against what the GPU is recommended to use less what it already holds.
A plan that would not fit is refused before it runs, with a message giving both figures, and the
estimate is then the surrogate's alone. It never crashes. The plan is not cut into tiles. Each
group norm takes its mean and variance over the whole plan, so tiles normalised on their own give
other peaks. Exact tiling would need each norm's statistics gathered over every tile before the
next layer, one pass per norm (18 of them), at many times the cost. The need at 1,250², about
3.5 GB by that rule, is within what an 8 GB Mac's GPU is usually recommended (around two thirds of
its memory), but not with much else open. The check says what it is on the Mac itself.

## The models' scatter measured on 2 m runs (23 October 2026)

emmettl/bombcad-work#69. Field model 2's chances draw each network's own peak scatter
(`Scatter.fieldModel1` and `round4`). Those tables were measured against the 4 m recorder runs,
about 0.2 in the log at most distances. Against the 2 m references the model reads with about 0.32.
The [round above](#the-models-own-scatter-in-the-chances-23-october-2026) took that gap as the
likely reason why the walls missed the tenths test on the unsafe side. This round measures the
scatter on new 2 m runs, apart from the judge's, and judges field model 2 again with it.

**The runs.** These are 28 new 2 m references, all at places neither strict network was trained on
(both held out Beirut and the made-up layouts of seed 6):

- Beirut, with the charge at the 4 m dataset's nine other points (p1–p9, 0.6–1.9 km from the
  port), two yields each from 0.1 to 1.3 kt;
- the five made-up layouts of seed 6 (perimeter, grid, towers, industrial, mixed; flat), two yields
  each from 0.11 to 1.6 kt, the charge at their 4 m runs' first point.

They were run as the judge's near boxes were (14707293): 4 m air refined to 2 m below the buildings'
tops, the mapped start, `--radius 1280 --height 320`, every storey's façade strips saved. Each ran
until Kingery–Bulmash's arrival at the judged part's corners plus the positive phase, ×1.1
(4.6–4.8 s). Each took 130–320 s on the solver, about 1.9 GPU-hours in all. The judged part is
inside 0.85 of the box, as `field-refs` judges it.

**The measure.** `field-refs` now adds up, for each run, the log of the network's peak over the
2 m run's. It does this only at strips where the network's peak is used, banded as
`LearnedField.Scatter` is: level, facing, and scaled distance. `scatter2m.py` adds the sums over
the runs. Each figure is the root mean square, bias and spread together, as the 4 m tables were
measured. There were 0.80 M ground-floor strips for each network, and 3.1 M above the ground floor
for round 4.

| Z, m/kg^(1/3) | ≤ 7 | 7–10 | 10–14 | 14–20 | 20–28 | > 28 |
|---|---|---|---|---|---|---|
| Round 2, ground floor, 2 m | 0.36–0.39 | 0.23–0.24 | 0.22–0.23 | 0.20–0.24 | 0.20–0.21 | 0.17–0.19 (3,735 strips) |
| … on the 4 m recorder (`fieldModel1`) | 0.32–0.33 | 0.21 | 0.19–0.20 | 0.19–0.20 | 0.19–0.22 | 0.29–0.33 |
| Round 4, ground floor, 2 m | 0.35–0.38 | 0.23–0.25 | 0.22–0.25 | 0.22–0.27 | 0.24–0.27 | 0.25–0.27 (3,735) |
| … on the 4 m recorder | 0.32–0.34 | 0.22–0.23 | 0.21–0.22 | 0.22–0.24 | 0.22–0.25 | 0.38–0.40 |
| Round 4, storeys above, 2 m | 0.36–0.37 | 0.22 | 0.22–0.23 | 0.20–0.25 | 0.19–0.23 | 0.24–0.26 (15,390) |
| … on the 4 m recorder (`round4`) | 0.32–0.34 | 0.20–0.21 | 0.19–0.20 | 0.21 | 0.22–0.23 | 0.37–0.39 |

The ranges are over the three facings.

- **The 2 m scatter is wider close in, and little wider beyond.** It is +0.03–0.06 at Z ≤ 7,
  +0.02–0.03 to Z 14, and +0.00–0.04 to Z 28. It is not the 0.32 the near boxes suggested. Most
  of that figure is the boxes' outer ring, whose runs stopped too soon (below).
- **Part of it is bias, and the bias differs by place.** Round 2 reads these places high, by
  +0.04 to +0.12 in the log beyond Z 7. On the judge's boxes it reads them 11% low at 50–700 m.
  Taking the bias out (the spread alone) leaves 0.37 at Z ≤ 7, 0.23 at 7–10, and 0.18–0.21
  beyond: about the 4 m tables, but for the closest band.
- **The places differ a lot.** Round 2's ground floor at Z ≤ 7 ranges from 0.26 (made-up mixed) to
  0.43 (Beirut p5), and at Z 10–14 from 0.16 to 0.32.
- **Beyond Z 28** only the corners of two places reach, 3,735 ground-floor strips. The tables
  judged below keep the 4 m figures where a band has under 10,000 strips over every facing. That
  is the ground floor beyond Z 28. Facing bands under 1,000 strips take every facing's figure.

**Field model 2 judged again** on the judge's ten near boxes, through the app's estimate as before
(`field-refs`, `wall-calibrate --own-scatter`). This time the tables come from a file
(`--scatter-tables`). Read back, the code's 4 m tables give the code's chances to the digit. The
2 m figures are not fitted to the judge: none of its boxes is among the runs. The figures quoted
are on the **façade terms adopted the same day** (327497ee, emmettl/bombcad-work#56). On those
terms the field path keeps peak ×1.15 and impulse ×0.95. The same judges on the terms before
#56 are given after the table.

| (c) round 2 + round 4, own scatter, on the #56 terms | 4 m tables (as shipped) | 2 m tables | 2 m, spread only |
|---|---|---|---|
| Walls moderate+, adopted factors (Brier / skill / tenths) | **0.0188 / 0.656 / pass** | 0.0189 / 0.655 / pass | 0.0188 / 0.656 / pass |
| … each yield held out | **0.0188 / 0.656 / pass** | 0.0190 / 0.654 / pass | 0.0189 / 0.655 / fail |
| … the largest tenth's miss | 0.09 unsafe (0.80–0.90: 0.84, seen 0.93) | 0.08 safe (0.50–0.60: 0.54, seen 0.46); 0.07 unsafe at 0.80–0.90 | 0.09 safe (0.50–0.60: 0.54, seen 0.45); 0.08 unsafe at 0.80–0.90 |
| Walls heavy+, adopted factors | **0.0068 / 0.616** / fail | 0.0069 / 0.607 / fail | 0.0069 / 0.609 / pass |
| Glass blown out, the app's sides (Brier / skill) | **0.0540 / 0.44** | 0.0542 / 0.44 | as the 4 m tables (before #56) |
| … at the ground floor (deciles' test) | **0.0462** / 0.42 / fail | 0.0465 / 0.42 / fail | – |
| … above the ground floor | **0.0553 / 0.43** | 0.0555 / 0.43 | – |
| Roofs | 0.74 | 0.74 | 0.74 |

The 4 m tables' column is the #56 judge's (`refit56/takeover/judge-adopt`). Glass under them was
judged again here and gave the same figures to the digit.

On the façade terms before #56 (3ceb8de0), walls moderate+ at the adopted factors read:

- 4 m tables: 0.0188 / 0.656, failing (0.84 against 0.95 seen);
- 2 m tables: 0.0189 / 0.656, passing by a hair (0.84 against 0.90, and 0.54 against 0.44), but
  failing held out (0.0189 / 0.655) and failing at heavy+ (0.608, against 0.618 passing);
- spread only: 0.0188 / 0.656, failing (0.54 against 0.43, on the safe side).

Field model 1's network (a) with the 2 m tables scored 0.0187 / 0.658 and failed (0.84 against
0.94). Glass was as in the table above, to 0.0003.

**What it says:**

- **The scatter was not why field model 2's walls missed the tenths test.** With the 2 m tables
  the top tenths move toward what was seen (0.84 against 0.91 rather than 0.93–0.95). The middle
  tenths then move the other way (0.54 against 0.44–0.46), and Brier and skill do not improve.
  The walls' chances are close to calibrated either way. A tenth 0.01 beyond the test is within
  what about 200 building-yields can give, when they share buildings across the yields.
- **On the #56 terms the shipped tables already pass.** The walls pass the tenths test at the
  adopted factors and held out. The miss the round above recorded is gone.
- **Glass prefers the narrower tables.** Its mid deciles already read low, and the wider draw
  makes every group's Brier 0.0002–0.0003 worse. The ground floor's deciles fail on both.

**The judge's near boxes stop before the blast reaches their outer ring.** They were run to 3 s
(`--until 3`, 14707293). The judged part runs to the corners of 0.85 of the box, up to 1.59 km
from the charge, and at Beirut's yields the blast reaches 1.1–1.3 km at about 3 s. Measured on
the boxes themselves, for comparison only, the networks' scatter is 0.15–0.22 beyond Z 7
(0.29–0.41 closer in), but for the farthest band each yield reaches. In that band it is 0.38–1.9,
with the model reading high by +0.09 to +1.8 in the log. For example, round 2 at the ground floor,
Z 10–14 at 1.5 kt, reads 0.57, and +0.17 high. The saved histories show why (`cutshort.py`):

- At 1.5 kt the strips at 1.2 km have windows cut short by the run's end, but they hold a peak,
  median 12.9 kPa. Those at 1.3 km read 3.5 kPa: the front had only begun. Beyond that nothing was
  recorded at all.
- At 150 t the cut begins at 0.9 km, and 1.1 km reads 3.6 kPa against 4.8 kPa at 1.0 km.

The strips never reached are left out of every judge, since their histories are empty. Those cut
short are judged on what was recorded: an impulse missing its tail, and at the edge a peak too low.
They are a large share of the far bands:

- at 150 t, 28,900 of the 81,200 strips that were reached;
- at 1.5 kt, 37,500 of the 112,200.

This weighs on every judgement made on these boxes, glass beyond 1 km most of all. The surrogate's
#56 refit fitted its peak terms on five of them; whether that fit kept these strips was not
checked here. Rerunning the ten boxes to the corners, as
the 28 runs above were run (4.6–4.8 s, about 5 minutes each), would remove it. It was done the
same day ([below](#the-near-boxes-run-to-their-corners-23-october-2026)).

**The verdict: the tables stay.** The 2 m tables are neither better calibrated nor kept glass's
skill. `Scatter.fieldModel1` and `round4` are unchanged, so field model 2's chances are as
shipped. What landed is the bench:

- `field-refs` keeps the scatter's sums for each run (`@own` variants, in its out file);
- `--scatter-tables` in `field-refs` and `wall-calibrate` judges tables from a file;
- `field-refs --coefficients` judges the network variants under other façade terms.

**Round 5** (a ground-floor-weighted loss) was not trained: the PC lane refuses the send.
`remote-train.py --dry-run` to `bombcad-pc` found 30.4 GB free on the Windows drive that holds WSL's
disk image, and sending the 10.7 GB `main-levels-fixed` dataset would leave 19.8 GB, under the
50 GB floor. Compacting the image is the user's job on Windows (`wsl --shutdown`, then
`Optimize-VHD`; [disk space on the PCs](#disk-space-on-the-pcs)). The floor was not lowered.

Everything is in `/Volumes/StudioData/bombcad/ml/judge/scatter2m/`:

- `runs.py` for the 28 runs (`run`) and their measurement (`refs`), with `loads-*`, `run-*.txt`
  and `measure-*.json`;
- `scatter2m.py`, with `scatter-rms.txt` and `scatter-sd.txt`;
- `tables-2m.json`, `tables-2m-sd.json` and `tables-4m.json` (the code's, for the check);
- `judge.sh` (`COEF=terms-56-adopted.json` for the #56 terms), with `glass-*.txt` and
  `walls-{a,c}-*.txt` (`-56` on the #56 terms);
- `judge-boxes-scatter.sh` and `judge-boxes/` for the boxes' own scatter, and `cutshort.py` with
  `cutshort.txt` for their cut-short histories.

```bash
python3 -I runs.py run && python3 -I runs.py refs
python3 -I scatter2m.py --tables tables-2m.json            # --measure sd for the spread alone
COEF=terms-56-adopted.json zsh judge.sh tables-2m.json 2m-56 glass walls-c
```

## The near boxes run to their corners (23 October 2026)

emmettl/bombcad-work#69, #19. The round above found the ten 2 m near boxes cut short: run to 3 s,
their outer ring had not seen the front pass. They were run again on main ec61b6a8, as before
(14707293), but each until Kingery–Bulmash's arrival at the judged part's corners plus the positive
phase, ×1.1: 4.8–5.0 s, 182–272 s each on the solver. The new loads are
`wall-recal/near2full-loads-*`, beside the old `near2f-loads-*`, which are kept. Within 0.8 km the
two sets are the same to the digit. Beyond that the new runs reach strips the old never recorded,
and the judged sides go from 65,263 to 78,020. Everything here is on main's façade terms, adopted
the same day (emmettl/bombcad-work#56).

**Glass by side**, every storey, through the app's estimate (exact / Heidke skill; then blown out
by Brier / skill):

| Sides | Surrogate | Field model 1 | Field model 2 |
|---|---|---|---|
| Every storey, full length (78,020) | 0.901 / 0.65 | 0.911 / 0.68 | **0.957 / 0.81** |
| … on the 3 s boxes (65,263) | 0.903 / 0.55 | 0.908 / 0.57 | 0.927 / 0.60 |
| Ground floor, full length | 0.891 / 0.58 | 0.963 / 0.81 | 0.963 / 0.81 |
| Upper storeys, full length | 0.901 / 0.66 | 0.901 / 0.66 (the surrogate's) | **0.954 / 0.81** |
| Blown out, the app's sides, full length | 0.0666 / 0.39 | 0.0621 / 0.43 | **0.0333 / 0.69** |
| … on the 3 s boxes | 0.0657 / 0.32 | 0.0628 / 0.35 | 0.0540 / 0.44 |
| Blown out above the ground floor, full length | 0.0661 / 0.41 | 0.0661 / 0.41 | **0.0352 / 0.68** |
| Blown out at the ground floor, full length | 0.0691 / 0.26 | 0.0311 / 0.66 | 0.0285 / 0.69 |

So on the full-length references the field models' glass gains are much larger than on the cut
boxes: glass blown out over the app's sides, Brier skill 0.69 against field model 1's 0.43, and
above the ground floor 0.68 against 0.41. Their peaks read the runs at the ground floor with a
log-SD of 0.19 (1.02 on the median), against the surrogate's 0.24. The blown-out chances still fail
the deciles' test: they are underconfident in the middle (where they say 0.54, 0.73 of sides blew
out).

**Concrete walls and roofs** (`wall-calibrate`, the grids and fixed pairs of the rounds above)
gave every figure to the digit, every tenth's count included. Concrete walls are damaged well
inside the cut ring, so neither their chances nor what was seen changed:

- the surrogate's concrete walls at ×1.15: Brier skill 0.611, passing the tenths test; the refit
  picks ×1.15 in every fold, as before;
- concrete walls moderate or worse, Brier skill 0.656 against field model 1's 0.654, both passing
  the tenths test at peak ×1.15 and impulse ×0.95, and both picking them in every fold;
- concrete heavy or worse 0.616 with field model 2 (illustrative, failing), and roofs 0.74 with
  their middle chances low by up to 0.18.

Stone (each building as 0.5 m stone, heavy or worse) moved a little: it is weaker, so it is
damaged farther out. Its skill went from 0.724 to 0.719 at its factors, and from 0.715 to 0.709
held out. Its middle chances are still high by up to 0.19, and its refit still picks ×0.8 in seven
folds of ten.

**The scatter tables hold.** Measured on the full-length boxes themselves, for comparison only, the
networks' scatter is 0.15–0.23 beyond Z 7: round 2 at the ground floor reads 0.20, 0.15, 0.17 and
0.22 to Z 28, and round 4 above 0.19, 0.18, 0.20 and 0.23. That is the 4 m tables' 0.19–0.22, and
the 0.32 that started this was the cut ring. With the 2 m tables in their place field model 2's
glass blown out scores 0.0350 / 0.68 against 0.0333 / 0.69, and its walls are as above.
`Scatter.fieldModel1` and `round4` stay.

**The hybrid far field** was judged again too. Its near runs (`beirut/hybrid/near-loads-*`, 4 m)
had also been run to 3 s, so they were rerun until the blast passes their judged corners (4.8–5.0 s,
`refs-full/hybrid-near-loads-*`), on main 3058da57, which holds a rising trend at nothing. Its
seeds move by 0.5% (×1.063 → ×1.069 at 0.2 kt), its slopes by 0.01 or less, and its arrivals'
factor from 0.98 to 1.00. Every band's peak, impulse and glass against the full runs is the same
within 0.01, so `hybridFarPeak` holds. The seed band, 800–1,000 m, is mostly inside the cut, and
the hybrid is judged against the full 4 m runs, which were never cut.

**The surrogate's peak terms refitted on the full-length boxes** were judged and not adopted. They
gain on the near boxes but lose the full runs' glass chances and the hybrid far field
([the first look](surrogate-first-look.md#the-peak-terms-on-the-full-length-boxes-23-october-2026)).

The standing's figures for field model 2's glass (`learnedModel2Glass`, `learnedModel2GlassUpper`)
now quote this section. Its walls' figures and those of the walls' and roofs' chances
(`structureChances*`, `learnedWallsRefined`) held, so they are unchanged. So do the adopted
choices: concrete walls ×1.15; the field model's walls at peak ×1.15 and impulse ×0.95; and the 4 m
scatter tables.

Everything is in `/Volumes/StudioData/bombcad/ml/judge/refs-full/`:

- `runs.py` and `hybrid.sh` (`runs`) for the reruns;
- `judge.sh`, `judge2.sh` and `hybrid.sh` (`judge`) for the judges, with `glass-*.txt`,
  `walls-*.txt` and `hybrid-*.txt`, and `walls_summary.py` and `glass_split.py` to sum them up;
- `fitcut.py`, `refit.py` and `terms-refit-full.json` for the peak terms;
- the full-length boxes' own scatter in `../scatter2m/judge-boxes-full/`.

## Round 5: one levels network weighted toward the ground floor (24 October 2026)

emmettl/bombcad-work#69. Field model 2 needs two networks: round 2's at the ground floor and
round 4's above. Round 4 alone trails round 2 at the ground floor. This round tried to train one
levels network that matches round 2 there, so that the app needs one file again.

**What changed in training.** `train_field.py` has new opt-in flags. With them off, training is as
before, to the bit.

- `--level-weights ground=4` weights each named level's cells in the loss.
- `--far-weight 2 --far-z 14` weights every cell beyond scaled distance 14 as well. The two
  multiply.
- The epoch is chosen by the same weighted loss on the validation runs (`--validate-layouts`).
  The held-out runs are only judged.
- `--judge-every 5` records the held-out runs every fifth epoch only, which saves most of an
  epoch's time.

**Training.** Each of the three settings below:

- trained on `main-levels-fixed`, round 4's dataset, with round 4's other arguments;
- held out Beirut and the seed-6 layouts, as before;
- set apart the 25 seed-5 runs (`made-*-s5`) to choose the epoch, leaving 100 runs to train on
  against round 4's 125.

The PC's link went to a Tailscale relay on 23 October (no direct connection, about 0.2 MB/s), and
its send stopped at 3.4 of 10.7 GB. So all three trained on the Studio's GPU in float32 (MPS,
`--amp off`), one at a time under gpu-slot. Each took 1.9–2.7 hours and about 18 GB.

| Setting | Loss weights | Epoch chosen | Held-out loss at the nearest judged epoch (every level) |
|---|---|---|---|
| `field-unet-l5-g4` | ground ×4 | 158 | 0.0299 |
| `field-unet-l5-g4f2` | ground ×4, ×2 beyond Z 14 | 122 | 0.0272 |
| `field-unet-l5-g8f2` | ground ×8, ×2 beyond Z 14 | 123 | 0.0321 |
| Round 4 (`field-unet-l4-strict`), for comparison | none | 130, chosen on the held-out runs | 0.0237 |

Each was exported (`ml/field-unet-l5-*/app/*.bcfw`). Each was judged with its own scatter, measured
on the 4 m recorder runs as round 4's was. The 2 m references are the full-length near boxes
([above](#the-near-boxes-run-to-their-corners-23-october-2026)). The façade terms are main's.

**Peaks against the 4 m recorder runs** (median / log-SD of predicted over recorded; the 52 recorder
runs of `compare-fixed`):

| | Round 2 | Round 4 | g4 | g4f2 | g8f2 |
|---|---|---|---|---|---|
| Beirut's ground floor, 50–700 m | 1.06 / 0.27 | 1.02 / 0.28 | 1.06 / 0.29 | 1.02 / 0.30 | 0.99 / 0.29 |
| Beirut's 6–22 m, 50–700 m | | 1.00–1.03 / 0.27–0.28 | 1.03–1.08 / 0.29–0.30 | 0.99–1.05 / 0.30–0.33 | 0.94–0.98 / 0.28–0.31 |
| Every strip, Z 0–3 | | 1.09 / 0.55 | 1.38 / 0.53 | 1.51 / 0.57 | 1.18 / 0.56 |
| … Z 7–14 | | 0.99–1.00 / 0.20–0.21 | 0.96–0.97 / 0.20–0.21 | 0.93 / 0.19–0.20 | 0.93–0.94 / 0.21–0.22 |
| … Z 20–28 | | 0.92 / 0.22 | 0.87 / 0.22 | 0.88 / 0.21 | 0.85 / 0.23 |

**Glass by side on the full-length 2 m boxes** (exact / Heidke skill; then blown out, Brier / skill):

| Sides | (c), field model 2 | Round 4 alone | g4 | g4f2 | g8f2 |
|---|---|---|---|---|---|
| Ground floor | **0.963 / 0.81** | 0.942 / 0.64 | 0.914 / 0.65 | 0.916 / 0.66 | 0.932 / 0.67 |
| … beyond 1 km | **0.946 / 0.82** | 0.904 / 0.63 | 0.871 / 0.65 | 0.878 / 0.67 | 0.904 / 0.70 |
| Upper storeys | **0.954 / 0.81** | 0.954 / 0.81 | 0.895 / 0.65 | 0.885 / 0.62 | 0.909 / 0.68 |
| Every storey | **0.957 / 0.81** | 0.955 / 0.80 | 0.901 / 0.65 | 0.890 / 0.63 | 0.915 / 0.69 |
| Blown out, ground floor | **0.0285 / 0.69** | 0.0399 / 0.57 | 0.0543 / 0.41 | 0.0551 / 0.41 | 0.0464 / 0.50 |
| Blown out, upper storeys | **0.0352 / 0.68** | 0.0352 / 0.68 | 0.0703 / 0.37 | 0.0769 / 0.31 | 0.0623 / 0.44 |

**Peaks by storey on the same boxes** (median / log-SD, every strip):

| Level | (c) | Round 4 | g4 | g4f2 | g8f2 |
|---|---|---|---|---|---|
| Ground floor | 1.02 / 0.19 | 1.12 / 0.23 | 0.95 / 0.20 | 0.93 / 0.19 | 0.99 / 0.26 |
| 6–30 m | 1.00–1.09 / 0.18–0.23 | (as (c)) | 0.87–0.92 / 0.17–0.23 | 0.86–0.91 / 0.16–0.24 | 0.88–0.95 / 0.19–0.25 |

**Concrete walls, moderate or worse** (2,053 buildings × 10 yields, own scatter, 50 draws; Brier /
skill / the tenths test):

| | (c) | Round 4 alone | g4 | g4f2 | g8f2 |
|---|---|---|---|---|---|
| Peak ×1.15, impulse ×0.95 | **0.0188 / 0.656 / pass** | 0.0206 / 0.625 / fail | 0.0189 / 0.656 / fail | 0.0197 / 0.641 / fail | 0.0183 / 0.667 / fail |
| Each yield held out | **0.0188 / 0.656 / pass** | 0.0212 / 0.614 / fail | 0.0198 / 0.639 / pass | 0.0210 / 0.617 / pass | 0.0192 / 0.650 / pass |

Roofs are 0.74 in every variant.

**What it says:**

- **No round-5 network matches (c).** At the ground floor the best, g8f2, reaches glass 0.932 /
  0.67, against (c)'s 0.963 / 0.81. Above it, g8f2 reaches 0.909 / 0.68 against 0.954 / 0.81, so it
  is also worse than round 4 there.
- **On walls, g8f2 is level with (c) at best.** Its Brier is 0.0183 at the adopted factors, against
  0.0188, but it fails the tenths test there. Held out, it scores 0.0192 against 0.0188.
- **The weighting did not sharpen the ground floor.** Against the 4 m recorder, Beirut's ground
  floor at 50–700 m scatters by 0.29–0.30 in every setting. That is round 4's 0.28, and wider than
  round 2's 0.27.
- **What all three share is a tilt with distance:**
  - they read high close in (×1.18–1.51 at Z under 3, against round 4's 1.09);
  - they read low far out (0.85–0.88 at Z 20–28, against 0.92);
  - on the 2 m boxes, which are mostly beyond 700 m, every storey reads 0.86–0.99 of the runs,
    against (c)'s 1.00–1.09.
  - The glass's far sides miss on that low bias: "some broken" loses all its skill.
- **The far weighting did not undo the tilt.** g4f2 and g8f2 read Z 20–28 at 0.85–0.88, as g4
  does.
- **The tilt appears at every storey, not only the ground floor where the weight is.** So the
  weighting is not its only cause. Two other things changed from round 4, and this round does not
  separate them:
  - 25 fewer runs to train on, the seed-5 layouts being set apart for validation;
  - the Studio's float32 MPS training in place of the PC's bfloat16 CUDA.
- **Round 3 measured the first of these.** Setting the same 25 runs apart cost it 0.011–0.013 of
  glass exactness, with its peaks 4–5% lower at Beirut's façades
  ([round 3](#round-3-fields-at-more-heights-22-october-2026)). Against round 4 on the same boxes,
  round 5 loses 0.010–0.028 at the ground floor, about that, but 0.045–0.069 above it, four to six
  times that. So above the ground floor the weighting, which takes weight from the upper storeys,
  or the device, adds to it.

**The verdict: no field-model-3.** Field model 2 stays as shipped, and nothing was published. The
pin, the files and the option are unchanged.

What would settle the cause, if one levels network is still wanted:
- round 4's own settings trained on the Studio, to see what the device does;
- the same with `--validate-layouts`, to see what 25 fewer runs do;
- then a weighting on whichever of those matches round 4.

Each run is about 2–2.5 Studio GPU-hours, or 1–1.5 on the PC once its link is direct again.

Everything is in `/Volumes/StudioData/bombcad/ml/r5/`:

- `train-studio.sh` for the training (the networks in `ml/field-unet-l5-*/`);
- `train.sh` for the PC's attempt, and `epochs.py`;
- `judge.sh` (export, recorder, scatter tables, glass, walls) and `judge-chain.sh`;
- `judge-*/` for each network's judgements, and `judge-field-unet-l4-strict/` for round 4's on the
  same full-length boxes;
- `judge-fp-ground/` for round 2's ground floor against the fixed recorder runs;
- `tables.py`, and `summary.py` with `summary.txt` for the tables above.

```bash
python train_field.py --data …/main-levels-fixed --out OUT --model unet --crop 256 --batch 16 --epochs 300 \
    --impulse first --seed 0 --levels all --holdout-layouts 'beirut,made-*-s6' --validate-layouts 'made-*-s5' \
    --judge-every 5 --device mps --amp off --level-weights ground=8 --far-weight 2 --far-z 14
zsh /Volumes/StudioData/bombcad/ml/r5/judge.sh field-unet-l5-g8f2 export rec tables glass walls
```

## On the clear-top terms (25 October 2026)

emmettl/bombcad-work#99. The surrogate's façade terms refitted on runs with their top clear were
adopted on 25 October 2026
([the first look](surrogate-first-look.md#adopted-25-october-2026)). The field models give the peak
at the strips they read (`learnedPeakFactor` is taken over whichever terms are given), so their
peaks do not move. Their impulses, their rise and every strip they do not read are the surrogate's,
and the chances there draw its new scatter. The judges of [the near boxes run to their
corners](#the-near-boxes-run-to-their-corners-23-october-2026) were run again on the new defaults,
against the same ten 2 m references (`wall-recal/near2full-loads-*`, 320 m top), on main 45b1ddce
with the change (`$BOMBCAD_DATA/scratch/issue99`, `judges.sh walls-a walls-c glass`; each 12–30
minutes, at most 10 GB):

| | Terms of 23 October | Clear-top terms |
|---|---|---|
| Concrete walls moderate+, field model 1, peak ×1.15, impulse ×0.95 (Brier / skill / tenths) | 0.0190 / 0.654 / pass | 0.0190 / 0.653 / pass |
| … each yield held out | ×1.15, ×0.95 in every fold | ×1.15, ×0.95 in every fold (0.653) |
| Concrete walls moderate+, field model 2, own scatter, peak ×1.15, impulse ×0.95 | 0.0188 / 0.656 / pass | 0.0190 / 0.653 / pass |
| … each yield held out | ×1.15, ×0.95 in every fold (0.656) | ×1.15 in every fold, the impulse ×1.15 in 8 and ×0.95 in 2 (0.652, pass) |
| … the largest tenth's miss | 0.09 unsafe (0.80–0.90: 0.84, seen 0.93) | 0.10 unsafe (0.80–0.90: 0.84, seen 0.94) |
| Concrete walls heavy+, field model 2 | 0.0068 / 0.616 / fail | 0.0069 / 0.611 / pass |
| Glass blown out, the app's sides: surrogate / field model 1 / field model 2 (Brier / skill) | 0.0666 / 0.39; 0.0621 / 0.43; 0.0333 / 0.69 | 0.0397 / 0.64; 0.0365 / 0.66; 0.0307 / 0.72 |
| … above the ground floor: field model 1 (the surrogate's) / field model 2 | 0.0661 / 0.41; 0.0352 / 0.68 | 0.0393 / 0.65; 0.0323 / 0.71 |
| … at the ground floor | 0.0691 / 0.26; 0.0311 / 0.66; 0.0285 / 0.69 | 0.0411 / 0.56; 0.0286 / 0.69; 0.0279 / 0.70 |
| Glass by side, every storey, exact / Heidke | 0.901 / 0.65; 0.911 / 0.68; 0.957 / 0.81 | 0.946 / 0.77; 0.951 / 0.79; 0.961 / 0.81 |
| Ground-floor peaks over the runs', median / log-SD: surrogate; field models | 0.97 / 0.24 (as before); 1.02 / 0.19 | 0.97 / 0.24; 1.02 / 0.19 |

What it says:
- **The field-model walls hold their factors.** At peak ×1.15 and impulse ×0.95 both pass the
  tenths test on the new terms, at skill 0.653 (0.654 and 0.656 before). The impulses the walls
  see rise 2–14% close in, and the skill gives back 0.001–0.003. Held out, field model 1's refit
  still picks ×1.15 and ×0.95 every time. Field model 2's picks the impulse ×1.15 in eight folds
  of ten and passes at 0.652, no better than the fixed pair. So the factors stay. A change to the
  impulse's factor would be the user's decision, and nothing here asks for one.
- **The glass gains, mostly where the network is not.** Above the ground floor and in the strips the
  networks do not read, the new terms carry the far loads higher. The surrogate's blown-out skill
  goes from 0.39 to 0.64, and field model 1's (the surrogate above the ground floor) from 0.43 to
  0.66. Field model 2's goes from 0.69 to 0.72. The blown-out chances still fail the deciles' test,
  underconfident in the middle.
- These references keep the 320 m top, which drains the strips beyond about 1.1 km (a fifth of the
  judged sides). The glass there is judged against the clear-top runs on [the first
  look](surrogate-first-look.md#refitted-on-clear-top-runs-25-october-2026); the walls are damaged
  well inside it.

The standing's figures (`learnedModel2Glass`, `learnedModel2GlassUpper`, `learnedModel2Walls`) quote
this section since 25 October 2026.

Later that day the surrogate's own concrete walls took the same pair, peak ×1.15 and impulse ×0.95,
on the user's decision (emmettl/bombcad-work#102), and pass their tenths test with it. Judged again
then, both field models' walls gave the figures above to the digit
([the walls' impulse](surrogate-first-look.md#the-walls-impulse-095-25-october-2026)).

## Not done yet

- **The laptop's measured training times**, if it is to join the desktop. The desktop is set up
  and has completed the first-phase training rounds above.
- **One levels network for every storey.** Round 5 did not match field model 2
  ([round 5](#round-5-one-levels-network-weighted-toward-the-ground-floor-24-october-2026)). Next
  would be round 4's settings on the Studio, with and without the validation runs set apart, to
  find what tilts round 5's peaks with distance.
- **Field model 2 on the small laptop**: the user's `BombCAD field-model check` there.
- **Measured heights** to judge the levels on (emmettl/bombcad-work#69; routes, not readings, from
  the search of 21 October in [data wanted](data-wanted.md#to-fetch)). Alsubaei 2015's columns are
  [done](#the-shape-with-height-against-alsubaeis-columns), as far as their scaled heights overlap.
  Still to fetch:
  - Ma Long et al. 2026 (*Explosion and Shock Waves* 46(4)): front and rear faces against height
    from a surface burst, if it proves measured, not numerical;
  - Sheffield's clearing tests (Rigby's 2014 thesis, Rigby and Sielicki 2014, Bogosian, Rigby and
    Powell 2016), for how much of the 4 m cells' wall under-read is clearing smeared;
  - Cranfield's open 1:50 city (Burrows, Forth and Sheldon 2021, CC BY dataset): 11 gauges'
    histories among buildings, peaks and arrivals clean.
- **The user's decision** on making the quick estimate's learned field option the default, and
  on how its weights ship ([above](#the-decision-for-the-user)); then the same peak in the
  [hybrid far field](hybrid-far-field.md).
- **Other learned models** on the same runner, as they come:
  - emulators for the uncertainty work;
  - walls and roofs;
  - surrogates for the thermal and fragment hazards.
- **Fields at façades and roofs.** The targets are at street level only. A façade model needs the
  envelope histories (`district-compare --save-loads`) on the same grid.
- **Other cell sizes.** Every run is on 4 m cells, so the model learns the 4 m runs, artefacts and
  all. Their peaks are about 9% low against 2 m and 15–20% against 1 m, and their impulses 3–7%
  high ([round 3](#round-3-the-4-m-runs-resolution-bias-21-october-2026)). The proposed
  correction is a factor, decided with #19's recalibration.
- **Times on the PCs.** `job.json` records each job's time and GPU. The training time for each
  machine is to be added here after the first runs.

## Sources

- O. Ronneberger, P. Fischer and T. Brox, *U-Net: convolutional networks for biomedical image
  segmentation*, MICCAI 2015 (the U-Net's form).
- Z. Li, N. Kovachki, K. Azizzadenesheli, B. Liu, K. Bhattacharya, A. Stuart and A. Anandkumar,
  *Fourier neural operator for parametric partial differential equations*, ICLR 2021 (the FNO's
  form).
- C. N. Kingery and G. Bulmash, ARBRL-TR-02555, 1984, through Swisdak's fits (`KingeryBulmash`):
  the base the network corrects.
- The Beirut inputs and their licences: [Beirut, 2020](beirut-2020.md).
