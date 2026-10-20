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

`district-compare --export-field folder` writes the same files from a district-compare run. Its
runs have been on the mapped start since 20 October (`--balloon-start` for the balloon), and
`meta.json` says which.

The export is off unless asked for, and it only reads fields the solver already keeps. Other
targets are unchanged: `blastbench digest --recommended` was the same before and after, on release
builds (see [testing](#what-was-tested-where)).

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

Judged at held-out runs' ground-floor façades (emmettl/bombcad-work#33, #47), with
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
`/Volumes/StudioData/bombcad/ml/judge/`. The Studio model is in `field-unet-studio-layouts/`.

```bash
python -I Scripts/ml/judge_field.py --data /Volumes/StudioData/bombcad/ml/datasets/main \
    --model unet2=/Volumes/StudioData/bombcad/ml/field-unet-main-2/out/best.pt --out judged.json
```

## The first-phase target and glass by side (20 October 2026)

emmettl/bombcad-work#33, #47: the three steps the [judgement above](#what-it-would-take) asked
for.

### The first-phase impulse target

`field-export --first-phase` (and `district-compare --export-field … --first-phase`) writes a
third target, `firstPhaseImpulse`, by the recorder's rule ([above](#what-one-run-gives)). It was
checked on the four recorder runs of the judgement, run again with it into
`/Volumes/StudioData/bombcad/ml/judge/compare-first/`:

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

`train_field.py --impulse first` trains on it. The 200-run dataset has not been exported again
with it: that waits for the user's go-ahead. The command, about 5 GPU hours on the Studio as the
first export took (5.3 h measured, partly on the mini):

```bash
python3 -I Scripts/ml/field-runs.py run --set main --first-phase --dataset /Volumes/StudioData/bombcad/ml/datasets/main-first
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

The judgements are in `/Volumes/StudioData/bombcad/ml/judge/fp47/` (`judge-all.txt`,
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

## Not done yet

- **The PCs' set-up**, by the user (above), then a first `--estimate` on each card to replace the
  estimated times.
- **The full run list.** It waits for the user's go-ahead for about 5 GPU hours on the Studio
  (or about 15 on the mini).
- **The 200 runs exported again with `--first-phase`** (about 5 GPU hours, the user's go-ahead)
  and a model trained on it, before the field model drives walls and roofs
  ([above](#the-first-phase-target-and-glass-by-side-20-october-2026)).
- **The user's decision** on the field model's peak in the quick estimate's ground-floor glass,
  and then in the [hybrid far field](hybrid-far-field.md)
  ([above](#the-recommendation-for-the-user-to-decide)).
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
