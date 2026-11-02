# The blast wave, live

As you place or drag a charge on a district, the app draws the blast front sweeping through the
streets: when it arrives, how strong it is, and the shadows behind buildings. You can scrub it or
replay it at once, without a solver run. This is item 2 of emmettl/bombcad-work#112, "Interactive
first": the solver's runs are the referee and the data, not the experience. Like the
[quick estimate](surrogate-first-look.md), it is an estimate, never a run.

**Standing: illustrative.** It was judged cell by cell, 2 m over the ground, against BombCAD's own
4 m district runs, not against measurement. On Beirut, which it was not fitted to:

- **Peaks.** 91% of cells in sight of the charge came within ×1.25 of the run, and 68% of shielded
  cells did. Within ×1.5 the shares were 97% and 90%. Kingery–Bulmash along the straight line
  managed 54% and 51% within ×1.25.
- **Arrivals.** Beyond 200 m, the mean error was 0.4–1.4% in sight and 1.3–5.4% behind
  buildings.
- **Close in.** Within 200 m behind buildings it reads high, up to ×1.7, which is the safe side.
  Its arrivals there run up to 10% early.

The full tables are [below](#judged-against-the-solver-1-november-2026). An optional learned
refinement, on by default since 2 November within about 1 km of the charge, corrects it towards
the runs: close in behind buildings and in sight, and in its arrivals and pulse
([below](#the-learned-refinement-2-november-2026),
[adopted](#adopted-as-the-default-2-november-2026)).

![The live wave over Beirut at 0.5 kt, a third of the way through: the front a bright line, each
place keeping the colour of its peak, the front lagging into the city behind the port's
buildings](live-wave-beirut.png)

## What the model already knew about arrival (1 November 2026)

Before this page, the arrival was known only in these places:

- **The quick estimate and the façade surrogate** (`FacadeLoadSurrogate`, `Prepared`). They give
  each envelope component a peak and an impulse as a triangular pulse. The pulse's time is
  Kingery–Bulmash's arrival along the straight line, and the surrogate has no arrival field of its
  own. Its sight lines (crossings, the length inside buildings, the ridge, the canyon) are worked
  out per component, in 0.2–0.3 s a frame on Beirut. The surrogate's own page says its far-edge
  shortfall is "the pulse's front, not the loads".
- **Charge inference** (`ChargeInference`, [charge inference](charge-inference.md)). It runs the
  other way: Kingery–Bulmash's arrival at each observer, times a run's own ratio of arrival over
  Kingery–Bulmash (0.93–1.02 over Beirut's observers) where a run is given.
- **The hybrid far field** (`HybridFarField`). Beyond the hand-over it uses Kingery–Bulmash's
  arrival scaled by the near run's median ratio over its gauges from 500 m. That came 1–4% before
  the full run's.
- **The learned field datasets** (`scenebench field-export`;
  [learned models](learned-models.md#the-learned-field-models-data)). Each cell holds the peak, the
  impulse and the first phase's impulse at 2 m. There is no arrival and no waveform, and the
  existing outputs cannot give one: the fields hold maxima and sums, not times.
- **Saved runs that do hold times.** The arrivals at Rigby's 31 observers (`beirut/arrivals`, one
  per observer). Each façade strip's net history in `district-compare --save-loads`
  (`beirut/mix/loads-*`, 0.7 ms bins), on building faces, not the street. In the app, a run's
  exposure plane at 1.5 m (`ExposurePlane`, arrival over 1 kPa), which is kept for the injury
  field but not saved.

So the arrival per cell had to be recorded. `field-export --arrival` now writes it from the
solver's exposure plane, without touching the run: the peaks of the 24 runs below matched the
dataset's to the bit.

## How it works

`LiveWave` (Sources/BlastModel/LiveWave.swift), on the CPU:

1. **The plan.** Each cell has the tallest block over its centre and the ground under it, as the
   learned field's plan does (`LiveWave.Plan`, to the bit with `LearnedField.Plan` on 4 m cells).
   It is laid out once per scene: 7–54 ms on Beirut's 5 km.
2. **The paths.** Each cell gets the shortest path from the charge over the surface, round a
   building or over its roof, whichever is shorter. It is found by Dijkstra's method, with each
   cell joined to its 32 neighbours within 3 × 3 cells. A path is never more than 1.3% longer
   than the straight line in the open, and the lattice adds a cell or so near the charge. The
   queue is a bucket per cell width, which is exact because every step is at least a cell long,
   and each bucket's cells are taken in the plan's order. A step that would cross a cell standing
   above both its ends is barred, and so is one through the corner between two such cells. So a
   front never passes through a building or squeezes between two that meet at a corner.
3. **Strength and time.** These are Kingery–Bulmash's hemispherical surface burst at the path's
   scaled length L/W^(1/3), tabulated in ln Z: the arrival, the incident peak, the positive phase,
   and the Friedlander decay b that gives Kingery–Bulmash's impulse. Two corrections are fitted
   to BombCAD's 4 m runs (`LiveWave.Coefficients.fitted`):
   - the peak, by x = ln Z of the path and s = ln(L/R), the path's excess over the straight line:
     `c0 + c1 x + c2 x² + c3 s + c4 s x`;
   - the arrival, as `a0 + a1 x + a2 s`.

   Each is held at the ends of its fitted range.
4. **Drawing it.** `SceneRenderer` keeps the field as a texture: arrival, peak, duration and
   decay, one texel to a cell. After the composite, a fullscreen pass (`liveWaveFragment` in
   Render.metal) finds each pixel's surface again from the scene's depth. It reads the field there
   at the bar's time and draws:
   - nothing before the front;
   - a line a pixel or two wide at the front;
   - behind it, the overpressure now as the Friedlander pulse decays, over the colour of the peak
     it left.

   The colour is on a log scale from 1 kPa to the surfaces' top. The shadows are the lower peaks
   and later arrivals behind buildings, nothing drawn on top.

**The paths hug the surface.** Over a roof, the path climbs the near wall and comes down the far
one. A front through the air is more like a string stretched over the roof's edges, so behind a
building the path is a little too long: over a 10 m wall 80 m out, about 8 m long against the
string's 2 m. The fitted terms take this back on average: the arrival's s term is −0.17, and the
peak's s terms are positive. A path through the air is listed under [next](#next).

### The fit

Scripts/fit-live-wave.py fitted the terms on cells sampled by
`blastmodel live-wave-judge --coefficients none --samples`. Every run weighed alike. Cells under
200 Pa and cells within 50 m of the charge were left out.

- **The peak.** 1.41 million cells from the 150 made-up runs of the learned field's dataset
  `main-levels-fixed` (4 m cells, 2 m over the ground, after the terrain-start fix). The log
  scatter fell from 0.317 to 0.260. In the uncorrected wave, in-sight cells read ×1.3 high on
  4 m air.
- **The arrival.** 0.68 million cells from 16 of those runs, run again with `--arrival` (500 Pa
  on the exposure plane). The log scatter fell from 0.080 to 0.065. The 4 m air's smeared shock
  reaches 500 Pa a little ahead of its middle, so the runs' arrivals come about 4% before
  Kingery–Bulmash's.

Beirut's 50 dataset runs and its eight runs again with `--arrival` were held out.

## Judged against the solver (1 November 2026)

`blastmodel live-wave-judge` lays out each run's own plan and works out the live wave there, then
sets it against the run cell by cell. A cell counts as in sight when the straight line from the
charge to 2 m over it clears every building on the plan. Each table gives the live wave's median
over the run, the share of cells within ×1.25, and in brackets the same for Kingery–Bulmash on the
straight line.

**Beirut's 50 dataset runs** (0.06–1.9 kt, the port and nine places 0.7–1.9 km into the city),
held out. Peaks:

| Distance | In sight: median, within ×1.25 (KB) | Shielded: median, within ×1.25 (KB) |
|---|---|---|
| 0–100 m | ×0.91, 60% (×1.41, 22%) | ×1.71, 23% (×3.20, 7%) |
| 100–200 m | ×0.88, 75% (×1.32, 26%) | ×1.25, 37% (×1.93, 11%) |
| 200–400 m | ×1.00, 93% (×1.25, 52%) | ×1.16, 51% (×1.46, 25%) |
| 400–700 m | ×1.04, 91% (×1.19, 66%) | ×1.10, 60% (×1.27, 43%) |
| 700–1,000 m | ×1.05, 97% (×1.24, 53%) | ×1.04, 69% (×1.24, 48%) |
| 1,000–1,500 m | ×1.01, 100% (×1.24, 56%) | ×0.96, 75% (×1.15, 62%) |
| 1,500–2,000 m | ×0.97, 100% (×1.22, 98%) | ×0.88, 68% (×1.07, 81%) |
| All | ×1.02, 91%, 97% within ×1.5 (×1.24, 54%) | ×1.02, 68%, 90% within ×1.5 (×1.22, 51%) |

**Beirut's eight runs with arrivals** (0.06–1.0 kt), held out. Arrivals: the median over the run,
the mean error, and in brackets Kingery–Bulmash on the straight line.

| Distance | In sight | Shielded |
|---|---|---|
| 100–200 m | ×1.035, 4.2% (×1.109, 11.7%) | ×0.935, 10.5% (×0.949, 13.2%) |
| 200–400 m | ×0.992, 1.4% (×1.048, 5.0%) | ×0.954, 5.4% (×0.985, 5.9%) |
| 400–700 m | ×0.992, 0.8% (×1.021, 2.3%) | ×0.989, 2.7% (×1.012, 3.3%) |
| 700–1,000 m | ×0.997, 0.4% (×1.010, 1.1%) | ×0.998, 1.3% (×1.010, 1.9%) |
| 1,000–1,500 m | ×1.005, 0.5% (×1.007, 0.7%) | ×1.003, 1.3% (×1.006, 1.4%) |
| All | ×0.999, 7.2%, 92% within 5% | ×0.995, 2.6%, 81% within 5% |

Within 100 m, the runs' arrivals are milliseconds, read off the mapped start's own front. There
the mean errors are 18% shielded and close to 100% in sight, little better than Kingery–Bulmash
(25% and 104%).

On the **made-up runs** (in the fit), all 150 of them, the peaks came within ×1.25 on 67% of cells
in sight and 67% shielded (Kingery–Bulmash on the straight line: 31% and 56%). On the 16 run
again, the shielded arrivals' mean error was 2.9%. The cells in sight beyond 400 m are few, open
squares and parks, and there the runs read ×1.2–1.3 under the wave's peak. That is the 4 m air's
weak far field over open ground in a dense district, which the shielded cells dominate in the fit.

**On 8 m cells,** as the app works on Beirut while dragging (each 8 m cell the tallest of its
four), the same eight Beirut runs gave the same shares to within a point: peaks 93% and 71% within
×1.25, arrivals 2.7% shielded. The narrow streets closed at 8 m cost nothing that the 4 m runs can
see.

### Time

These were measured on the Studio while it was shared with other sessions' dust runs and the
live-drag work; the load average is given each time.

- **A recompute** on Beirut's 5 km district, 0.5 kt (`blastmodel live-wave-time`, the charge
  moved 5 m at a time over 100 m), at a load average of 26–28. The plan takes 7–11 ms, once per
  scene.
  - On 8 m cells (0.39 million): 64–69 ms median, 63–76 ms in all.
  - On 4 m cells (1.56 million): 261–264 ms median, 249–294 ms in all.

  So while you drag, a district over 500,000 cells works on cells twice as large, and on its own
  cells once you let go. On the dataset's 2–2.5 km plans (0.26–0.41 million 4 m cells) a recompute
  took 42–56 ms median over the runs (34–264 ms in all, at a load of 12–30).
- **In the app, offscreen** (`InterfaceReviewLiveWaveTests`, release build, load average about 28):
  - **Beirut by File ▸ New District**, 0.5 kt within 2.5 km: 9,708 buildings on a 5.64 km box,
    1.99 million 4 m cells, so the plan is on 8 m cells from the start (705 × 705; 1.7 million at
    most on the finest).
    - It was first shown in 92 ms: the plan in 9 ms and the field in 82 ms.
    - A drag in 5 m steps took 80 ms median for the field (75–180), and 213 ms median (158–388)
      from the charge moved to the field shown. The rest is the hops between the main actor and
      the worker on a loaded Studio.
    - A frame at 1800 × 1200 took 19.3 ms of GPU with the wave and 19.1 ms without it (13–28 ms
      in all), so the pass costs nothing that can be measured against the scene's own ray march.
  - **The made-up New District fixture** (20 buildings, 145 × 145 cells): the field took 3 ms and
    a drag step 6 ms median from placed to shown. A frame took 12.2 ms with the wave and 12.6 ms
    without.

  A play updates the time every 15 ms and the view draws each one, so the front moves at the
  display's rate. The frame's GPU time allows about 50 frames a second at that size on Beirut,
  most of it the scene's.

## The learned refinement (2 November 2026)

emmettl/bombcad-work#115, stage 2 of the [next steps](#next) below. On 1 November the user decided
to keep the live wave illustrative, to leave large districts on 8 m cells while dragging, and to
build the learned version. This is that version: a network that corrects the live wave cell by
cell, towards BombCAD's own 4 m runs. It is an option, **Learned Refinement** in the wave's bar,
**off by default**. Off, nothing changes. Its standing is **illustrative**. (On 2 November it was
made the default within about 1 km of the charge:
[adopted as the default](#adopted-as-the-default-2-november-2026).)

On Beirut's 50 runs, which it never saw, the refinement:

- **close in** brings the peaks behind buildings within 100 m from ×1.7 high to about right. 38%
  of those cells are within ×1.25 instead of 23%, and 59% are within ×1.5 instead of 36%.
- **in sight** brings 94% of cells within ×1.25 instead of 91%.
- **arrivals** come out a tenth to two fifths closer behind buildings beyond 200 m, and closer
  still in sight.
- **impulse** gives the pulse the runs' positive impulse: 77% of cells behind buildings are within
  ×1.25 instead of 26%.
- **shielded peaks over the whole plan** are no better: 67% within ×1.25 against 68%. It gains
  from 100 m to 700 m and gives that back beyond 1 km, where it reads 5–15% low.

### The data

`scenebench field-export --arrival` was run again for the whole 200-run list
(`Scripts/ml/field-runs.json`, the learned field's runs) into `$BOMBCAD_DATA/live-wave/dataset`.
The 24 runs of the first stage were kept.

| Where | Runs | Run time |
|---|---|---|
| The CI mini (`field-runs.py run --on scrimply-ci-lan --arrival`) | 67 | 2.2 h |
| The Studio, one run at a time under gpu-slot (5–6 GB declared, 4–5 GB used) | 108 | 1.8 h |
| The first stage's runs, on the Studio (1 November) | 25 | 0.35 h |

The mini took most runs under 0.5 kt, and the eight largest, which declare 7 GB. Its
Thunderbolt link was down, so it was reached over the local network (`scrimply-ci-lan`, a host of
its own in remote-train.py, with the mini's same lock). The Studio crashed at 00:16 on 2 November
when it ran out of memory. One run there was lost and done again. The mini's job in hand was hung
up, and its 18 finished runs were copied back. `field-runs.py run` now takes `--arrival`, and
`--wait` for a host's lock.

`blastmodel live-wave-features --runs … --out pairs` makes each run's training pair. It works the
live wave out on the run's own plan and on that plan coarsened twice (8 m, as the app works while
dragging), and writes three things on each:

- the network's inputs;
- its targets: the logs of the run's peak, arrival and positive impulse over the wave's, NaN where
  the run has none;
- the cells in sight, as the judge counts them.

`train_live_wave.py pack` packs the 150 made-up runs, float16 and compressed, 0.45 GB. Beirut's
runs are left out of the pack, so they never left the Studio.

### The network

`LiveWave.Refinement` (Sources/BlastModel/LiveWave+Refinement.swift) is a U-Net of train_field.py's
form without its group norms. Without them a cell's correction depends only on the plan around it,
so crops in training and the whole plan in the app agree. It has nine inputs:

- what `LearnedField.Plan` holds: the height, the footprint and the ground;
- the live wave's own fields: ln Z of the path and of the straight line, the path's excess ln(L/R),
  the logs of the wave's peak and scaled arrival;
- the cell's size, 4 or 8 m.

It has three outputs, each a log correction: to the peak, to the arrival and to the impulse. Each
is held within ±1.5 (±0.5 for the arrival). The head starts at zero, so an untrained network is the
live wave itself. The impulse goes into the Friedlander decay at the same positive phase. Where
even a pulse with no decay would hold too little, the phase is stretched instead. A correction of
nothing gives the wave as it was, to the bit (`LiveWaveRefinementTests`).

**Training**, on bombcad-pc's RTX 3080 Ti through `Scripts/ml/remote-train.py`:

- 125 made-up runs, at both cell sizes;
- 80 epochs of 120 steps, each step 16 random crops of 192 cells, turned by the square's symmetries;
- a Huber loss on each target's residual over its scale, with cells within 200 m weighing up to
  four times more;
- each made-up style's sixth layout (`made-*-s6`, 25 runs) set apart for validation. The epoch kept
  is the one with the least validation loss, so Beirut chose nothing.

Three widths were tried, and the widest was kept, on validation alone:

| Width | Parameters | Validation loss | Made-up shielded peaks within ×1.25, 4 m (the wave: 69%) | Time on the PC |
|---|---|---|---|---|
| 16 | 1.96 M | 0.659 | 69% | 9.6 min |
| 24 | 4.42 M | 0.420 | 82% | 11.4 min |
| **32** | 7.85 M | **0.404** | **84%** (epoch 73) | 12.3 min |

`Scripts/ml/export_live_wave_weights.py` writes the weights as the field models' `.bcfw`, float16,
15.7 MB. BlastCore's `LearnedFieldNetwork` runs them on MPSGraph, now with any number of inputs and
without the norms. `scenebench live-wave-predict` matches PyTorch on the CPU:

- within 5.8 × 10⁻⁶ in every log correction (mean 1.4 × 10⁻⁷), on three Beirut plans and a made-up
  one, 4 m and 8 m;
- the float16 weights move the corrections by at most 5.6 × 10⁻³ against the checkpoint's float32.

### Judged on Beirut

The judge was `scenebench live-wave-judge --learned live-wave-unet-1.bcfw`, the same judge as
`blastmodel live-wave-judge` with each run's wave refined first. It was run on Beirut's 50 runs
(0.06–1.9 kt), all now with arrivals, on their 4 m cells. In each cell: the median of the wave over
the run, then the share within ×1.25 and within ×1.5. The live wave alone is on the left of each
arrow, refined on the right.

**Peaks:**

| Distance | In sight | Shielded |
|---|---|---|
| 0–100 m | ×0.91, 60%, 77% → ×1.01, 71%, 85% | ×1.71, 23%, 36% → ×1.02, 38%, 59% |
| 100–200 m | ×0.88, 75%, 91% → ×1.01, 90%, 97% | ×1.25, 37%, 61% → ×1.07, 49%, 74% |
| 200–400 m | ×1.00, 93%, 99% → ×0.97, 98%, 100% | ×1.16, 51%, 76% → ×1.08, 62%, 84% |
| 400–700 m | ×1.04, 91%, 98% → ×0.93, 96%, 99% | ×1.10, 60%, 85% → ×1.06, 65%, 87% |
| 700–1,000 m | ×1.05, 97%, 100% → ×0.90, 100%, 100% | ×1.04, 69%, 92% → ×1.03, 67%, 91% |
| 1,000–1,500 m | ×1.01, 100%, 100% → ×0.86, 93%, 100% | ×0.96, 75%, 94% → ×0.95, 69%, 95% |
| 1,500–2,000 m | ×0.97, 100%, 100% → ×0.81, 64%, 100% | ×0.88, 68%, 93% → ×0.85, 65%, 96% |
| All | ×1.02, 91%, 97% within ×1.5 → ×0.92, 94%, 99% within ×1.5 | ×1.02, 68%, 90% within ×1.5 → ×1.00, 67%, 91% within ×1.5 |

**Arrivals,** the mean error:

| Distance | In sight | Shielded |
|---|---|---|
| 0–100 m | 102.5% → 58.9% | 21.1% → 16.0% |
| 100–200 m | 4.2% → 1.6% | 11.4% → 9.1% |
| 200–400 m | 1.7% → 1.0% | 6.4% → 4.2% |
| 400–700 m | 1.4% → 0.8% | 3.2% → 1.9% |
| 700–1,000 m | 1.1% → 0.6% | 1.8% → 1.5% |
| 1,000–1,500 m | 1.0% → 0.4% | 1.9% → 1.5% |
| 1,500–2,000 m | 0.6% → 0.3% | 0.9% → 0.8% |
| All, within 5% | 92% → 97% | 80% → 87% |

**The pulse.** The impulse is the wave's Friedlander pulse against the runs' positive impulse at
2 m, every positive phase's. In sight 38% → 94% of cells come within ×1.25, behind buildings 26% →
77%. Without the refinement the pulse holds ×0.71–0.77 of the runs' impulse. With it the pulse
holds ×1.09–1.10, and up to ×1.3 beyond 1.5 km.

**On 8 m cells,** as while dragging (`--coarsen 2`):

- peaks: 91% → 95% in sight, 67% → 68% shielded;
- shielded peaks within 100 m: 25% → 35% within ×1.25;
- arrivals: 3.1% → 2.5% mean error shielded;
- impulse: 26% → 76% shielded.

**Why not the shielded peaks far out.** On the made-up runs set apart, shielded peaks went 69% →
84% within ×1.25. On Beirut they went 68% → 67%. The gain holds to 700 m. Beyond 1 km the network
reads low, as the made-up districts' 4 m runs do over their far streets ([the
fit](#the-fit)): it has learned their far field, which Beirut's sea front and long city do not
share. More kinds of real place in the training runs would be the cure. A rule for where to apply
it, chosen on Beirut, would leave nothing held out.

The tables are in `$BOMBCAD_DATA/live-wave/learned-judge/`:

- `beirut-stage1-c1` and `-c2`, the live wave alone;
- `beirut-w32-c1` and `-c2`, the refinement kept;
- `beirut-w16-*` and `beirut-w24-*`, the narrower networks, for reference.

### Time

`scenebench live-wave-time --learned …` on Beirut's 5 km district at 0.5 kt (the charge moved 5 m at
a time), interleaved with `blastmodel live-wave-time`. The Studio's load average was 5–7.

| Plan | The live wave | Refined | The network's part |
|---|---|---|---|
| 8 m cells, 625 × 625 (0.39 M), while dragging | 60–62 ms median | 81–82 ms median (78–84) | 21–22 ms |
| 4 m cells, 1,250 × 1,250 (1.56 M), let go | 234 ms | 325 ms (316–340) | 89 ms |

The first recompute on a plan's size also builds the network's graph, 0.2–1 s, which is kept after.
At a load average of 83, just after the crash, the 8 m recompute was 81 ms with the width-16
network. So the refinement runs while dragging as well as on let-go
(`SimulationModel.liveWaveRefinesWhileDragging`), and the whole recompute stays under 100 ms. The
app's own drag was not timed offscreen this time. `InterfaceReviewLiveWaveTests` takes
`BOMBCAD_LIVE_WAVE_MODEL` to time it, and in stage 1 the hops in the app added about 130 ms on a
loaded Studio.

### In the app

**Learned Refinement**, the checkbox in the live wave's bar, was off by default at first (on since
the [adoption](#adopted-as-the-default-2-november-2026)) and is remembered
(`liveWave.learnedRefinement`). It reads the weights from:

1. `BOMBCAD_LIVE_WAVE_MODEL`;
2. else the `liveWave.learnedRefinementWeights` setting;
3. else `~/Library/Application Support/BombCAD/LearnedModels/live-wave-unet-1.bcfw`.

Turned on without the file, it asks first, as the field model's option does. "Download the live
wave's learned refinement?" gives the file's size and URL. Nothing is fetched until Download is
clicked. The file is checked against its pinned SHA-256 (`LiveWave.Refinement.Release`) and read as
weights before it is kept.

Refined, the bar's help gives the refinement's standing (`LiveWave.Refinement.standing`), and the
status says how long it took. If the network cannot run (no file, too little GPU memory), the wave
is shown without it and the bar says why.

**The weights ship as the field models' do**, as a release asset, `live-wave-model-1` on
emmettl/bombcad. It is kept off "latest", and the user publishes it. The file is
`live-wave-unet-1.bcfw`, 15,702,546 bytes, SHA-256
`4041d39729910a40190ccd50408a1699cde4d08fa9c4739038f95785167e4f26`. It and `MODEL-NOTES.md` are
in `$BOMBCAD_DATA/release-live-wave-model-1/`. The weights were trained on BombCAD's own runs of
made-up districts alone; Beirut's runs only judged them. The command, from a checkout once this is
on main:

```bash
gh release create live-wave-model-1 --repo emmettl/bombcad --target main --latest=false \
    --title "Live wave learned refinement 1 (live-wave-unet-1)" \
    --notes-file $BOMBCAD_DATA/release-live-wave-model-1/MODEL-NOTES.md \
    $BOMBCAD_DATA/release-live-wave-model-1/live-wave-unet-1.bcfw \
    $BOMBCAD_DATA/release-live-wave-model-1/MODEL-NOTES.md
```

### For the user to decide

- **Whether to make it the default.** For it:
  - close in it is much better: shielded peaks within 100 m ×1.7 → ×1.02, and 23% → 38% within
    ×1.25;
  - in sight 91% → 94%;
  - arrivals a tenth to two fifths closer behind buildings;
  - the pulse carries the runs' impulse;
  - it costs about 20 ms a drag step.

  Against it:
  - shielded peaks over the whole plan are no better (68% → 67%), and it reads 5–15% low beyond
    1 km;
  - the weights are a 15.7 MB download until the release is published;
  - close in it gives up reading high, which was the safe side.

  The recommendation: keep it off until the release is published. Then make it the default for
  districts within about 1 km of the charge, or wait for training runs over more kinds of place.
- **Its standing** stays illustrative, as asked.

## Adopted as the default (2 November 2026)

On 2 November the user decided to publish the weights and make the refinement the default, applied
within about 1 km of the charge and blended to the plain live wave beyond. The release
`live-wave-model-1` was published that morning, kept off "latest". `curl` of its asset gave
15,702,546 bytes with the pinned SHA-256. The app's own download (`LearnedFieldDownload.install`
with `LiveWave.Refinement.Release.asset`) fetched it, checked it and read it as the refinement's
weights (`LiveWaveLearnedTests`, run against the release with `BOMBCAD_REAL_DOWNLOAD`).

**The blend.** Each correction is taken whole within a first distance from the charge and eased to
nothing at a second, by a smoothstep on the straight-line distance (`LiveWave.Refinement.blend`).
Three blends were judged on Beirut's 50 runs, `scenebench live-wave-judge --learned … --blend
near,far`. Each cell gives peaks within ×1.25 in sight and shielded, the shielded arrivals' mean
error, and impulse within ×1.25 shielded:

| Blend | 4 m cells | 8 m cells (while dragging) |
|---|---|---|
| None (the live wave alone) | 91%, 68%, 3.1%, 26% | 91%, 67%, 3.1%, 26% |
| 500 → 1,000 m | 96%, 70%, 2.4%, 47% | 95%, 70%, 2.8%, 46% |
| **700 → 1,200 m (adopted)** | **96%, 70%, 2.3%, 59%** | **96%, 71%, 2.7%, 58%** |
| 1,000 → 1,500 m | 96%, 68%, 2.2%, 76% | 96%, 69%, 2.6%, 74% |
| Everywhere | 94%, 67%, 2.2%, 77% | 95%, 68%, 2.5%, 76% |

700 → 1,200 m was adopted: it gives the most shielded peaks within ×1.25. A wider blend keeps
more of the pulse's gain, but gives back shielded peaks beyond 1 km. The choice was made on
Beirut's runs, so on these figures Beirut is no longer wholly held out. The network itself was
still trained and chosen on made-up districts alone.

With the blend adopted, on Beirut's runs at 4 m, the live wave alone to the left of each arrow:

| Distance | In sight | Shielded | Shielded arrivals' mean error |
|---|---|---|---|
| 0–100 m | ×0.91, 60%, 77% → ×1.01, 71%, 85% | ×1.71, 23%, 36% → ×1.02, 38%, 59% | 21.1% → 16.0% |
| 100–200 m | ×0.88, 75%, 91% → ×1.01, 90%, 97% | ×1.25, 37%, 61% → ×1.07, 49%, 74% | 11.4% → 9.1% |
| 200–400 m | ×1.00, 93%, 99% → ×0.97, 98%, 100% | ×1.16, 51%, 76% → ×1.08, 62%, 84% | 6.4% → 4.2% |
| 400–700 m | ×1.04, 91%, 98% → ×0.93, 96%, 99% | ×1.10, 60%, 85% → ×1.06, 65%, 87% | 3.2% → 1.9% |
| 700–1,000 m | ×1.05, 97%, 100% → ×0.94, 100%, 100% | ×1.04, 69%, 92% → ×1.03, 70%, 92% | 1.8% → 1.5% |
| 1,000–1,500 m | ×1.01, 100%, 100% → ×1.00, 100%, 100% | ×0.96, 75%, 94% → ×0.96, 76%, 95% | 1.9% → 1.8% |
| 1,500–2,000 m | the live wave's | the live wave's | 0.9% → 0.9% |
| All | ×1.02, 91%, 97% → ×0.97, 96%, 99% within ×1.5 | ×1.02, 68%, 90% → ×1.00, 70%, 91% within ×1.5 | 3.1% → 2.3% |

A recompute on the judged plans took 65 ms median at 4 m and 19 ms at 8 m, against 67 ms and 24 ms
unblended. The blend adds nothing measurable to the network's 21–22 ms on Beirut's 8 m drag plan.

**In the app.** Learned Refinement is now on unless the user has turned it off; a choice made
before is remembered. Until the weights are on this Mac the wave is the plain one. The bar says
"The live wave is shown without its learned refinement until its weights, 15.7 MB, are
downloaded", with a **Download Refinement…** button. That button asks first, with the file's size
and URL, and nothing is fetched without the click. Declining turns the option off, and that is
remembered. A failed download leaves it off, saying why. A path set by hand that holds nothing is
reported and never filled.

Its standing stays illustrative (`LiveWave.Refinement.standing`, worded from the figures here).

## Using it

- **In the app:** Simulation ▸ Show Live Blast Wave (⌥⌘B), before a run. A bar under the view has:
  - play and pause;
  - a slider over the wave's time;
  - the time;
  - a speed (real time, ¼, 1/10, 1/50, 1/200);
  - the colour key;
  - Done.

  - **Learned Refinement**, on by default within about 1 km of the charge, with **Download
    Refinement…** until its weights are on this Mac
    ([adopted as the default](#adopted-as-the-default-2-november-2026)).

  It opens at the end of the wave, with every peak and shadow shown. With Place Charge on, drag the
  charge and the wave follows it. It stays on screen with the quick estimate's colours and the
  drag preview, which it does not touch. A run's own wave replaces it, and Reset brings it back.
  VoiceOver reads the bar's slider and the view's description as the time, how far out the front
  is and how strong, and how much of the plan it has reached.
- **Headless:**
  - `blastmodel live-wave-judge --runs dir[,dir] [--only ids] [--layouts beirut|made] [--coarsen 2] [--coefficients none|fitted|fit.json] [--samples file.tsv --every n] [--out judged.json]`
    judges the live wave against field-export runs.
  - `blastmodel live-wave-time <district inputs> --radius 2500 --mass kg [--cells 4,8]` times it.
  - `scenebench field-export … --arrival [--arrival-threshold 500]` records a run's arrivals.
  - `blastmodel live-wave-features --runs dir --out pairs [--coarsen 1,2]` writes the refinement's
    training pairs; `scenebench live-wave-judge --learned weights.bcfw …` and
    `scenebench live-wave-time --learned weights.bcfw …` judge and time it on the GPU, and
    `scenebench live-wave-predict` checks it against PyTorch.

  The runs, samples, fit and judgements are under `$BOMBCAD_DATA/live-wave`: `arrivals/`, `judge2/`
  for the fit's samples and `final/` for the tables above.

## Limitations

- **It is the 4 m runs' wave, artefacts and all.** Those runs' peaks are below a converged run's
  close in (see the [surrogate](surrogate-first-look.md#limitations)), and the live wave copies
  them.
- **Its time is the time a run first sees 500 Pa,** about 4% before the middle of a smeared
  shock.
- **One charge on the ground.** It has no delays, no height of burst (beyond the charge's height
  in the straight line), and no deflagrations.
- **No reflections, no streets channelling, no second shock.** The pulse is one Friedlander
  pulse, with Kingery–Bulmash's impulse and duration at the path's length. A street that
  channels the wave is seen only on average, through the fit.
- **The paths hug the surface,** as described above.
- **Close in, within 200 m behind buildings,** the peaks read high, up to ×1.7, and the arrivals
  up to 10% early.

## Next

- **A path through the air.** A Theta*-style parent in sight, or a rise charged at less than its
  height, so that a front over a roof is a stretched string. Fit it and judge it the same way.
- **Stage 2: a learned refinement.** Done on 2 November 2026
  ([above](#the-learned-refinement-2-november-2026)), as an option. What follows was the plan. The
  field network would give the arrival and the waveform as
  well as the peak, trained on the PC.
  1. Record `--arrival` (and a decay time) for the whole 200-run list. That is 5.2 GPU hours on
     the Studio, or the mini through `field-runs.py --on`. The CUDA path has no exposure plane yet.
  2. Train `train_field.py` with the live wave's own channels as inputs (ln Z of the path, ln L/R,
     its arrival and peak). Its targets would be the log ratios of the run's arrival and peak over
     the live wave's. That is a residual over this model, not over straight-line
     Kingery–Bulmash.
  3. Judge it with `live-wave-judge`, by distance and sight, on Beirut held out.

  The arrival is already within 1–3% beyond 400 m, so the most to gain is in the peaks behind
  buildings (68% within ×1.25) and close in.
- **The refinement's far field.** Training runs over more kinds of real place, so that its
  shielded peaks beyond 1 km hold as they do on the made-up districts.
- **Faster 4 m paths on large plans,** so the drag need not coarsen. Options are a parallel
  relaxation on the GPU, or the bucket queue run per tile.
- **Item 3 of #112:** yield and the glass re-colouring the wave live.
