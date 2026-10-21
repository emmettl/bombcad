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

`train_field.py --impulse first` trains on it. **Update, 21 October:** the overnight job completed
all 200 stable cases in `/Volumes/StudioData/bombcad/ml/datasets/main-fp`, then trained
`field-unet-fp-strict` (75 whole-layout holdouts, 2,360 s on the PC GPU) and
`field-unet-fp-byrun` (40 run holdouts, 2,042 s). Both jobs exited successfully. The retained
record is `ml/overnight-fp/summary.txt`, with each model's `job.json`, split and metrics under
StudioData. The strict round's all-cell first-phase impulse ratio / log-SD is 1.00 / 0.17;
the by-run round is 1.02 / 0.09. These are field-prediction checks, not wall/roof damage validation.

The original Metal regeneration command (about 5 GPU hours estimated) was:

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

## The first-phase models at walls and roofs (21 October 2026)

emmettl/bombcad-work#33, #47: the two models trained overnight on the first-phase target
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

`scenebench field-walls` draws #19's chances on each held-out run's buildings, as
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
- **Model peak, surrogate impulse**: what glass uses (#47, 20 October).
- **Model peak and first phase**: the model's peak and its first-phase impulse.
- **Run field's peak** and **run field's peak and first phase**: the run's own field at the strip.
  This is the best a field model could give.

The pairs judged are load factors 0.8, 1, 1.3 and 1.6, times scatter scales 0, ½ and 1, with 50
draws. `judge_field.py walls` holds out each of the ten charge points in turn. It takes the pair
with the least Brier score on the other nine and judges the held-out point's buildings with it.

The test is the protective-design report's, as #19's: the Brier score, its skill against giving
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
  calibration is #19's and was not changed.
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

Everything is in `/Volumes/StudioData/bombcad/ml/judge/fpw/`:

- the façade judgement: `judge-strict.txt`, and `facades.txt` for the recorder tables;
- the walls: `walls/`, `walls-summary.txt` and `walls/summary.json`;
- the glass: `glass/`, `glass-all.txt` and `glass-byrun.txt`.

```bash
python -I Scripts/ml/judge_field.py --data /Volumes/StudioData/bombcad/ml/datasets/main-fp \
    --model strict=/Volumes/StudioData/bombcad/ml/field-unet-fp-strict/out/best.pt \
    --model byrun=/Volumes/StudioData/bombcad/ml/field-unet-fp-byrun/out/best.pt --impulse first \
    --recorded /Volumes/StudioData/bombcad/ml/judge/compare-first --peaks-out fpw/peaks --out fpw/judge-strict.json
python -I Scripts/ml/judge_field.py walls --peaks fpw/peaks --out-dir fpw/walls \
    --variants surrogate,strict:surrogate,strict:strict,byrun:surrogate,byrun:byrun,runField:surrogate,runField:runFieldFirst \
    --only byrun=/Volumes/StudioData/bombcad/ml/field-unet-fp-byrun/out/split.json
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
python -I Scripts/ml/export_field_weights.py --model /Volumes/StudioData/bombcad/ml/field-unet-fp-strict/out/best.pt \
    --out field-unet-fp-strict.bcfw --data /Volumes/StudioData/bombcad/ml/datasets/main-fp \
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
changed state.

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
passes only at ×0.8. That factor is the user's to judge again (#19's calibration, not changed
here). The app gives roofs the surrogate's loads, so the judge's roof proxy does not apply.

The judgements are in `/Volumes/StudioData/bombcad/ml/app67/`: `app/` holds the in-app strips and
logs, `merged/` the merged strip files, and `glass/`, `glass-summary.txt`, `walls/` and `walls.txt`
the judgements.

```bash
python3 -I Scripts/ml/app_peaks.py run --data /Volumes/StudioData/bombcad/ml/datasets/main-fp \
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
#34's `Prepared` holds the sight lines' raster. The plan takes 0.02 s to lay out, and the weights
0.05 s to load.

| Colouring | Later frames, off | Later frames, on | The model's share | First frame, on |
|---|---|---|---|---|
| Damage | 0.62–0.72 s | 0.86–1.18 s | 0.17–0.27 s | 3.1 s |
| Glass's chances (10 draws) | 0.40–0.41 s | 0.59–0.63 s | 0.18–0.20 s | 2.3 s |
| Walls' and roofs' chances (20 draws) | 0.55–0.60 s | 0.70–0.77 s | 0.17–0.20 s | 2.1 s |

- **Each frame runs the network again,** since the charge moves: its inputs and the network take
  0.17–0.20 s. The first frame also builds the graph for the plan's size, 1.3–1.7 s, kept after.
- **#34's bar of a second a frame is still met** with the option on, except the damage's frames
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
    --notes-file /Volumes/StudioData/bombcad/release-field-model-1/MODEL-NOTES.md \
    /Volumes/StudioData/bombcad/release-field-model-1/field-unet-fp-strict.bcfw \
    /Volumes/StudioData/bombcad/release-field-model-1/MODEL-NOTES.md
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

## Not done yet

- **The laptop's measured training times**, if it is to join the desktop. The desktop is set up
  and has completed the first-phase training rounds above.
- **Fields at more heights**, for roofs and upper storeys: the first-phase models leave both on
  the surrogate ([above](#the-first-phase-models-at-walls-and-roofs-21-october-2026)).
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
