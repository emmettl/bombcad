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

**Standing: none yet.** Nothing here has trained on a PC, and no model is used by the app. The
code was tested on the Studio and the CI mini (below). The first real run waits for the PCs to be
reachable, and the full set of training runs waits for the user's go-ahead for its GPU time.

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
   python3 -I Scripts/ml/remote-train.py bombcad-pc /Volumes/StudioData/bombcad/ml/datasets/smoke Scripts/ml/train_field.py --job estimate-pc --args --estimate --grid 256,512
   ```

Keep the data in WSL's own file system (`~`), not under `/mnt/c`. The Windows file system is slow
from inside WSL. Don't let the laptop sleep or run on battery during a job. On long jobs it
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
   `/Volumes/StudioData/bombcad/ml/<job>/`, and writes `job.json` there. `job.json` records the
   host, the GPU as `nvidia-smi` names it, the Python, the dataset's hash and whether it was sent,
   the script's hash, the arguments, the start and end times, and the exit status.

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
example `--args --resume ~/bombcad-ml/jobs/<old job>/out/checkpoint.pt`.

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

`district-compare --export-field folder` writes the same files from a district-compare run. That
run is on the balloon start, as district-compare's runs are pinned, and `meta.json` says so.

The export is off unless asked for, and it only reads fields the solver already keeps. Other
targets are unchanged: `blastbench digest --recommended` was the same before and after, on release
builds (see [testing](#what-was-tested-where)).

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
python3 -I Scripts/ml/field-runs.py run --set main --dataset /Volumes/StudioData/bombcad/ml/datasets/fields-v1
```

The runs go one after another under gpu-slot, each declaring its memory and limited to 1.5 hours.
Runs already in the dataset are skipped, so a stopped list carries on where it left off. Each
run's output goes to `logs/<id>.txt`, and `dataset.json` indexes the finished runs.

`--on scrimply-ci-tb` sends the cases to the mini instead, through the runner. scenebench, its
bundles and the cases' inputs go as one dataset, and `field_job.py` runs them there under the
mini's lock. `--only`, `--limit` and `--dry-run` pick and preview. `fit <dataset>` refits the cost
constants from a dataset's runs.

The smoke set, six runs on 256 × 256 cells of 20–100 t (five made-up districts and Beirut 900 m
south of the port), is in `/Volumes/StudioData/bombcad/ml/datasets/smoke/`. Datasets and model
weights stay on StudioData and are never committed.

## Training: `Scripts/ml/train_field.py`

```bash
python train_field.py --data DATASET --out OUT --model unet|fno [--epochs 40] [--batch 8] [--crop 256] [--holdout 0.2] [--split-by run|layout] [--resume auto]
```

- **Inputs.** Six channels, each standardised over the training runs:
  - the buildings' heights;
  - their footprints;
  - the ground;
  - ln Z;
  - the logs of Kingery–Bulmash's peak and impulse.
- **Outputs.** The logs of the run's peak overpressure and impulse. By default the network
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
  test.
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

## Not done yet

- **The PCs' set-up**, by the user (above), then a first `--estimate` on each card to replace the
  estimated times.
- **The full run list.** It waits for the user's go-ahead for about 5 GPU hours on the Studio
  (or about 15 on the mini).
- **A first real training and its judgement.** Hold out whole layouts (`--split-by layout`) and
  Beirut, compare with the [façade load surrogate](surrogate-first-look.md) by band, and decide
  whether the field model helps the first look and the [hybrid far field](hybrid-far-field.md).
- **Other learned models** on the same runner, as they come:
  - emulators for the uncertainty work;
  - walls and roofs;
  - surrogates for the thermal and fragment hazards.
- **Fields at façades and roofs.** The targets are at street level only. A façade model needs the
  envelope histories (`district-compare --save-loads`) on the same grid.
- **Other cell sizes.** Every run is on 4 m cells, so the model learns the 4 m runs, artefacts and
  all: their peaks are about 0.7 of Kingery–Bulmash's even in the open. Finer runs would be needed
  to learn converged fields.
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
