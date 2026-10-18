# Beirut, 4 August 2020: a district reconstruction

At about 18:08 local time on 4 August 2020, ammonium nitrate stored in Warehouse 12 of the Port
of Beirut exploded after a fire. More than 200 people were killed, thousands were injured and
some 300,000 lost their homes. This page reconstructs the blast over the port's district as a
technical comparison: BombCAD's first at the scale of a city, with the surveys made after it. It
reports what the model and the sources say; it does not judge the event.

![The blast 1.5 s after the explosion, over the 14,169 map buildings within 2.5 km](beirut-2020.png)

## What holds and what does not

At 0.5 kt on 4 m cells, against the surveys below:

- **Holds: the shock's arrival.** Over the city's own geometry the model finds Rigby's yield
  again from his 30 observers; from 400 m out 25 of 27 arrive within 10% of the observed time.
- **Holds: the glass's far edge, and its grid.** Beyond 1.5 km the share of façades blown out is
  GEER's W3 (0.07 and 0.02 against 0.09 and 0.02), and the glass has converged by 4 m.
- **Does not: the peaks.** They are 0.68–0.78 of Kingery–Bulmash and still rising on finer cells
  (0.78–0.83 at 3 m); refinement, which would give more, does not yet run this scene cleanly.
- **Does not: the glass close in, or its total.** The model's façades break together: inside
  1.5 km every side has some pane broken (GEER 0.35–0.84) and inside 1.25 km nearly all are blown
  out (GEER 0.17–0.77). It breaks 3.8 times the army's count of broken glass, on a glazed share
  that is assumed.
- **Does not: the structure.** It has not converged with the grid, and it damages less than GEER
  found: at 0.5–0.75 km 8 of 293 stone buildings fall where 7 of GEER's 13 partly collapsed, and
  concrete is barely touched beyond 750 m. Every building is one of two typical walls, not Beirut's frames with block infill.

## The scene

`scenebench district-scene` builds it from open data (the files are not in the repository; their
SOURCE.md files say where each came from and under what licence):

| | Source | In the scene |
|---|---|---|
| Buildings | OpenStreetMap, 17 October 2026 (ODbL): 14,502 buildings within about 2.5 km; 330 tagged with a height or levels | Each a block envelope on 4 m cells, standing on the lowest ground under it: 14,169 placed, 342 left out (too small or outside) |
| Heights | OSM tags where given; otherwise GHSL's average net building height (GHS-BUILT-H R2023A, 2018, 90 m cells, CC BY 4.0) | 89 by height, 187 by levels, 13,893 from GHSL |
| Ground | Copernicus GLO-30, a surface model (roofs and trees in it), 1″ | Opened over 100 m (a morphological opening: the lowest point within 100 m, then the highest of those), the sea flat at 6 m above the terrain's zero; the charge on it 1.4 m above the sea |
| Charge | Rigby et al. 2020: 0.50 kt TNT (best), 1.12 kt (upper); fireball and crater estimates 0.2–0.6 kt | 0.2, 0.5 and 1.1 kt TNT, hemispherical on saturated ground (0.9 of it to the air), at Warehouse 12's centre (33.901425 N, 35.519042 E) |
| Air | | The recommended air (afterburning, hot air, far-field open faces), 4 m cells, terrain on cut cells, 5 × 5 × 0.32 km: 125 million cells |

Today's map is not August 2020's: damaged buildings have since been repaired or rebuilt, and the
port's silos and warehouses are mapped as they now stand. The buildings' construction is not in
the map; each is judged twice, as 0.2 m reinforced concrete (the default) and as 0.5 m
unreinforced masonry, for the old sandstone houses.

### The recipe

```bash
scenebench district-scene --osm beirut-port-buildings.osm --dem Copernicus_DSM_COG_10_N33_00_E035_00_DEM.tif --ground-radius 100 --sea 1 --heights GHS_BUILT_H_ANBH_E2018_GLOBE_R2023A_4326_3ss_V1_0_R6_C22.tif --centre 35.519042,33.901425 --radius 2500 --dx 4 --height 320 --mass 500000 --out beirut.json
```

`beirut.json` opens in the app and runs headless:

```bash
BombCAD run beirut.json --resolution 4 --ground saturated --duration 8 --envelope-window 0.5 --envelope-damage damage.json
```

`scenebench district-compare` (the same inputs, `--observers` Rigby's CSV) runs the event and
sets it against the surveys below; `scenebench district` times it at several sizes.

## Cost

The whole box, 125 million cells (1,250 × 1,250 × 80) and 738,387 components, runs its 8 s
of event in about 5,000 steps: 25–28 minutes each on the CI mini (a base M4 with 24 GB, shared),
the air taking about 8 GB and the components' histories 4 GB (0.5 s from each one's arrival in
0.7 ms bins). Placing the buildings and building the solver take seconds. At 2 km and a lower
top (40 million cells) the event takes 172 s, and 184 s with every component's history: the
histories cost 7%. The view draws the 40,000 blocks in about 20 ms a frame, through a grid of
columns rather than testing every block.

Things found and fixed on the way, and one that set the domain:

- **A cut cell of 8% air** beside the charge, under a silo whose base lay below the opened
  ground, went negative and the run skipped silently to its end; it is now solid at load, and a
  batch with a NaN in the air is reported unstable.
- **Masonry rocking against the masonry above it** (SBEDS's wall held by its axial load), and
  **a façade strip spanning its storey** rather than as tall as the cells cut it: without them
  the old stone houses fell far too readily, and the coarser the grid the more.
- **The domain's top.** At 160 m, faces that copy the air out channel the wave (1.7 times
  Kingery–Bulmash's peak at 2.4 km) and far-field faces drain it (0.2–0.3 times beyond 1.5 km);
  at 320 m the peaks are those of a 640 m top to 2.4 km, so the runs use 320 m.

## What it is compared with

All on the final setting (above), at 0.2, 0.5 and 1.1 kt.

### Arrival times (Rigby et al. 2020)

The shock's arrival at 30 of Rigby's observers 250 m to 2.35 km away (audio and video; the
fireball's own points left out), at a gauge 2 m above the ground where each stood:

| Yield | Simulated against observed, median (range) | Within 0.05 s of the observed window |
|---|---|---|
| 0.2 kt | 1.06 (0.87–1.16) | 9 of 30 |
| 0.5 kt | **0.98** (0.71–1.10) | **19 of 30** |
| 1.1 kt | 0.90 (0.57–1.03) | 5 of 30 |

The model over the city's own geometry finds Rigby's yield again from his observations: 0.5 kt.
The three nearest observers (250–300 m) saw the shock later than the model and Kingery–Bulmash
both (0.71–0.83 of the observed time at 0.5 kt), as Dewey's lower TNT equivalence close in
would have it; from 400 m out the model is within 0.83–1.10 of the observed times, 25 of the 27 within
10%.

### Peak overpressure

On a line north over the basin and the sea, against Kingery–Bulmash at the same TNT mass:
0.68 of it at 100 m, 0.74 at 200 m, 0.78 at 500 m, 0.76 at 1 km and 0.77 at 2.4 km, at every
yield. About 5 points of that is the ground taking a tenth of the charge; the rest is 4 m cells,
which spread the shock (8 m cells refined twice to 2 m at the shock give 84–94% on the
landscape benchmark). The JRC's simulation at 1.1 kt (124, 46, 24 and 15 kPa at 300, 500, 750 and
1,000 m, read second-hand) against this run's 1.1 kt line: 94, 37, 20 and 13 kPa.

### Glass against the street survey (GEER, 2021)

GEER's surveyors classed 9,183 street façades from photographs two months later (some already
repaired): W0 no visible damage to W3 blown out. Map buildings carry no windows, so each storey of
each façade is taken to hold one annealed pane, 1.2 × 1.5 m; a building side's glass is broken
where any storey's is. Sides broken at the pane's median strength / at E1300's design strength
(8 in 1,000 break), with GEER's share of façades W1 or worse:

| Distance | 0.2 kt, 6 mm | 0.5 kt, 6 mm | 0.5 kt, 4 mm | 0.5 kt, 8 mm | 1.1 kt, 6 mm | GEER |
|---|---|---|---|---|---|---|
| 0.5–0.75 km | 1.00 / 1.00 | 1.00 / 1.00 | 1.00 / 1.00 | 1.00 / 1.00 | 1.00 / 1.00 | 0.84 |
| 0.75–1 km | 0.97 / 1.00 | 1.00 / 1.00 | 1.00 / 1.00 | 0.97 / 1.00 | 1.00 / 1.00 | 0.62 |
| 1–1.25 km | 0.52 / 1.00 | 1.00 / 1.00 | 1.00 / 1.00 | 0.58 / 1.00 | 1.00 / 1.00 | 0.39 |
| 1.25–1.5 km | 0.07 / 1.00 | 0.92 / 1.00 | 1.00 / 1.00 | 0.10 / 1.00 | 1.00 / 1.00 | 0.35 |
| 1.5–1.75 km | 0.00 / 0.79 | 0.36 / 0.98 | 0.98 / 1.00 | 0.00 / 0.94 | 0.91 / 1.00 | 0.38 |
| 1.75–2 km | 0.00 / 0.42 | 0.11 / 0.80 | 0.79 / 1.00 | 0.00 / 0.68 | 0.61 / 0.96 | 0.28 |
| 2–2.5 km | 0.00 / 0.09 | 0.01 / 0.55 | 0.53 / 0.91 | 0.00 / 0.28 | 0.20 / 0.82 | 0.26 |
| 2.5–3 km | 0.00 / 0.00 | 0.00 / 0.07 | 0.06 / 0.65 | 0.00 / 0.01 | 0.00 / 0.45 | 0.11 |

- **Close in, the model breaks more than GEER saw.** Inside 1.25 km every side breaks at
  0.5 kt, where GEER found 0.39–0.84 damaged. GEER's photographs are of street façades two months
  on, some repaired, and its edge of damage is "~0.7–0.9 km in the central part", 1.2 km in the
  east and 1.5 km in the west: its fraction does not reach 1 even at 0.5 km.
- **The edge depends on the glass more than on the yield.** At 0.5 kt half the sides break at
  about 1.6 km with 6 mm panes, 2.1 km with 4 mm and 1.1 km with 8 mm; between the median and
  the design strength it moves by about 0.6 km. Rigby et al.'s check with Viper at 465 t found old
  annealed façades broken at about 1.86 km and newer, toughened ones whole: inside the 0.5 kt
  band.
- **Beyond 2 km** GEER still finds a quarter of façades damaged and broken glass was reported
  to 3 km; the model at 0.5 kt breaks them only at the design strength or with thin panes. Many
  panes to a façade, of all ages and sizes, make some break where a typical one does not: one
  pane a storey cannot show that tail.

### Glass as a mix of panes

One typical pane can only break or not. The app now gives each map building a mix of panes by
its height (older low-rise to 10 m: small 4 mm panes; apartments to 30 m: 4 and 6 mm; taller or
commercial: large 6–10 mm panes), each breaking with E1300's probability, so a façade breaks by
degrees (building-envelopes.md). The mixes are assumptions; no survey of Beirut's glazing by
building was found. By the map's mixes, on the same 4 m runs:

| Distance | Panes broken, 0.2 / 0.5 / 1.1 kt | Sides with some pane broken, 0.2 / 0.5 / 1.1 kt | GEER W1 or worse |
|---|---|---|---|
| 0.5–0.75 km | 1.00 / 1.00 / 1.00 | 1.00 / 1.00 / 1.00 | 0.84 |
| 0.75–1 km | 0.95 / 1.00 / 1.00 | 1.00 / 1.00 / 1.00 | 0.62 |
| 1–1.25 km | 0.70 / 0.98 / 1.00 | 1.00 / 1.00 / 1.00 | 0.39 |
| 1.25–1.5 km | 0.40 / 0.89 / 0.99 | 0.99 / 1.00 / 1.00 | 0.35 |
| 1.5–1.75 km | 0.12 / 0.57 / 0.89 | 0.87 / 0.99 / 1.00 | 0.38 |
| 1.75–2 km | 0.05 / 0.31 / 0.63 | 0.59 / 0.89 / 0.98 | 0.28 |
| 2–2.5 km | 0.02 / 0.11 / 0.33 | 0.24 / 0.63 / 0.89 | 0.26 |
| 2.5–3 km | 0.00 / 0.01 / 0.05 | 0.03 / 0.21 / 0.57 | 0.11 |

GEER's W1 is "some windows broken, frames intact", so a side with some pane broken is the
model's W1 or worse: the middle column is the like-for-like one, not the panes broken. GEER's W3
is "nearly complete blow-out of windows, doors and frames"; against it, a side counted as blown
out when nine in ten of its panes are expected broken (the model has no frames to blow out):

| Distance | Sides blown out, 0.2 / 0.5 / 1.1 kt | GEER W3 |
|---|---|---|
| 0.5–0.75 km | 0.99 / 1.00 / 1.00 | 0.77 |
| 0.75–1 km | 0.82 / 1.00 / 1.00 | 0.28 |
| 1–1.25 km | 0.13 / 0.96 / 1.00 | 0.17 |
| 1.25–1.5 km | 0.01 / 0.59 / 0.99 | 0.18 |
| 1.5–1.75 km | 0.00 / 0.07 / 0.74 | 0.09 |
| 1.75–2 km | 0.00 / 0.02 / 0.40 | 0.02 |
| 2–2.5 km | 0.00 / 0.00 / 0.06 | 0.15 |
| 2.5–3 km | 0.00 / 0.00 / 0.00 | 0.04 |

- **The model's façades break together; GEER's do not.** At 0.5 kt every side inside 1.5 km has
  some pane broken and nearly every side inside 1.25 km is blown out, where GEER found 117 of its
  750 façades at 0.5–0.75 km with no visible damage and W3 falling to 0.17–0.28 by 1 km. Beyond
  1.5 km the 0.5 kt blow-outs (0.07, 0.02) are GEER's (0.09, 0.02); the 2–2.5 km band's 0.15 W3 has
  nothing in the model at any yield. Within a band the model's sides differ only by their mix and
  their shielding; a street's differ also by glass type (toughened, laminated, filmed), by open
  windows and shutters, and by repair in the two months before the photographs.
- **The tail is there.** Beyond 2 km some panes break, as some did; but a side holds dozens
  of panes, so the chance that one breaks stays near one far out, above GEER's share of façades
  damaged at every yield.
- **The panes broken follow the pane's size more than its thickness.** At 0.5 kt, all four mixes
  on the same loads: 1.25–1.5 km breaks 0.66 of the older low-rise mix's small panes, 0.88 of the
  apartments' and 0.98 of the large commercial panes; 2–2.5 km, 0.07, 0.11 and 0.24.

**The area of glass broken** is the glass assumed times the share of it that breaks, and the two
are separate. Inside 3 km (the surveys' reach: 13,596 map buildings, 12,996 of them taken as
apartments) the mixes assume 6.85 million m² of glass, 82% of it the apartments' 0.25 of façade;
0.20, 0.38 and 0.54 of it breaks at 0.2, 0.5 and 1.1 kt, 1.35, 2.6 and 3.7 million m².

| Inside 3 km, 0.5 kt | Buildings | Glass assumed | Broken | Share broken |
|---|---|---|---|---|
| Apartments (0.25 glazed) | 12,996 | 5.62 M m² | 2.03 M m² | 0.36 |
| Tall or commercial (0.4) | 434 | 1.18 M m² | 0.56 M m² | 0.48 |
| Older low-rise (0.15) | 99 | 0.03 M m² | 0.01 M m² | 0.51 |
| Industrial (0.05) | 67 | 0.03 M m² | 0.004 M m² | 0.17 |

The Lebanese army recorded about 550,000 m² of glass and 140,000 m² of glass façades broken in
the 85,000 damaged units it surveyed (60,818 of them homes; reported in the press): a count of
broken glass in surveyed units, not of glass replaced, and how it was measured is not reported.
UN-Habitat puts 77,000 damaged flats in 10,000 buildings within 3 km, so the survey's reach is
about the model's. The model breaks 3.8 times its 0.69 million m² at 0.5 kt. Broken area is in
proportion to the glazed share, which no source gives for Beirut (it is an assumption, 0.05–0.4
by type); to match the army with the model's breakage every mix would need a quarter of its glazed
share (the apartments' 0.07 of façade, the commercial 0.11), below any plausible window. Both terms are high: the breakage, as GEER's W3
shows inside 1.5 km, and most likely the glazed share as well; the army's count may be
incomplete. The total cannot separate them.

### What cell size the glass and the damage need

The 1 km box (2 km square, 320 m top, 0.5 kt) on three grids, uniform cells:

| | 8 m | 4 m | 3 m |
|---|---|---|---|
| Peaks on the line (of Kingery–Bulmash) | 0.54–0.69 | 0.68–0.78 | 0.78–0.83 |
| Panes broken (map's mixes), 0.5–0.75 / 0.75–1 / 1–1.25 / 1.25–1.5 km | 0.99 / 0.94 / 0.80 / 0.52 | 1.00 / 1.00 / 0.98 / 0.89 | 1.00 / 1.00 / 0.98 / 0.92 |
| Stone heavy / failed, 0.5–0.75 km (of about 290) | 206 / 2 | 249 / 7 | 269 / 10 |
| Stone heavy, 0.75–1 km (of about 660) | 41 | 132 | 176 |
| Concrete moderate, 0.5–0.75 km | 33 | 96 | 139 |

- **The glass has converged by 4 m**: 3 m moves the panes broken by at most 0.03. The peaks are
  still rising (by a tenth from 4 to 3 m), but the glass is past the edge of breaking where most
  of it stands.
- **The structure has not**: each grid finer cracks more stone and concrete, as the peaks rise;
  3 m is the least these need, and finer would crack more still.
- **A strip's height is its storey's.** Before this was fixed, façade strips stood as tall as the
  cells cut them (4 m on 4 m cells, 8 m on 8 m), and a masonry strip's resistance falls with the
  square of its height: the coarse grids' walls were the weak ones, and stone failed in 102
  buildings at 0.5–0.75 km on 4 m cells where the storey's span gives 7.
- Refinement (8 m refined twice to 2 m at the shock, the façades held refined while loaded) gave
  0.80–0.86 of Kingery–Bulmash on the line to 900 m, but its finest pool filled within 14 GB and
  its façades' results cannot be trusted; it is left to a larger Mac.

### Structure against the building survey (GEER, 2021)

GEER inspected 181 buildings (from calls to a hotline, so biased towards concern) and classed
them D0 none to D5 full collapse. The model's levels are its own (concrete by ASCE/SEI 59-11's
rotations; masonry heavy when cracked, failed when it has deflected its thickness), so the
comparison is of where the damage falls, at 0.5 kt:

| Distance | Stone (0.5 m masonry): none / heavy / failed | GEER stone: D1–D2 / D3 / D4 | Concrete (0.2 m): none / moderate / heavy+ | GEER RC: D0–D1 / D2 / D3 |
|---|---|---|---|---|
| 0.5–0.75 km | 32 / 253 / 8 | 1 / 5 / 7 | 200 / 92 / 1 | 8 / 9 / 4 |
| 0.75–1 km | 518 / 142 / 0 | 14 / 9 / 4 | 659 / 1 / 0 | 17 / 11 / 1 |
| 1–1.25 km | 907 / 0 / 0 | 15 / 3 / 0 (1–1.5 km) | 907 / 0 / 0 | 19 / 10 / 2 (1–1.5 km) |

The model damages the buildings less than the survey found, and nearer the charge:

- **Stone cracks where GEER's sandstone houses partly collapsed.** At 0.5–0.75 km nearly every
  stone building cracks (heavy) but 8 of 293 fall, where 7 of GEER's 13 there were D4; at
  0.75–1 km a fifth crack and none fall, where GEER had 9 of 27 at D3 and 4 at D4; beyond 1 km
  nothing, where GEER found D1–D3. Each wall is judged as a 0.5 m panel carrying only the stone
  above it, with no arching, its floors' loads unknown.
- **Concrete is barely touched beyond 750 m**, where GEER's RC buildings were D1–D3 out to 2 km.
  The envelope judges 0.2 m concrete walls; a Beirut "concrete" building is an RC frame with
  hollow-block infill, whose façades are thin masonry, and GEER's classes include the infill and
  partitions.
- **The grid is part of it**: 3 m cells crack more than 4 m (above), so the structure here reads
  low, and an earlier version, whose walls stood as tall as the cells, matched GEER's collapses
  by an error.

## What the model can and cannot represent

- **Today's map.** The buildings are those mapped in October 2026: those destroyed and rebuilt,
  and the port as it now stands. Heights are GHSL's 90 m cell means for all but 276 buildings.
- **A rigid district.** Envelopes stay whole in the air: no glass opening, no wall falling, no
  shielding changing as the buildings break. The silos stand.
- **Assumed glass and typical construction.** Each building's glass is one of four assumed mixes
  by its height and tag, all annealed; walls are either 0.2 m concrete or 0.5 m masonry for every
  building. GEER's survey shows the mix.
- **The ground.** A bare-earth estimate from a surface model; the charge on saturated ground
  gives the air 0.9 of it; the crater is not in the air.
- **Peaks at 4 m, and the structure with them.** The peaks are about three quarters of
  Kingery–Bulmash's and still rise on finer cells. The glass has converged by 4 m; the structure's
  damage has not, and 3 m cells crack more of it (above).
- **Open faces.** The 320 m top is 4 m/kg^(1/3) at 0.5 kt (3.1 at 1.1 kt). On 8 m cells a 640 m
  top gives the same glass and structure to within a building or two in every band. The side
  faces are not that far from the outer buildings: those beyond about 2.2 km lie within
  4 m/kg^(1/3) of one, so the outer bands are less sure.
- **One TNT mass.** Dewey's analysis suggests the TNT equivalence of this ammonium nitrate rose
  with distance (0.15 kt close in, 0.7 kt at 1 km); a single mass cannot follow that.
