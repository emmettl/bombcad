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

The full tables are [below](#judged-against-the-solver-1-november-2026).

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

## Using it

- **In the app:** Simulation ▸ Show Live Blast Wave (⌥⌘B), before a run. A bar under the view has:
  - play and pause;
  - a slider over the wave's time;
  - the time;
  - a speed (real time, ¼, 1/10, 1/50, 1/200);
  - the colour key;
  - Done.

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
- **Stage 2: a learned refinement.** The field network would give the arrival and the waveform as
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
- **Faster 4 m paths on large plans,** so the drag need not coarsen. Options are a parallel
  relaxation on the GPU, or the bucket queue run per tile.
- **Item 3 of #112:** yield and the glass re-colouring the wave live.
