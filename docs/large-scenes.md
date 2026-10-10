# Large scenes

Surface bursts of hundreds of tonnes to kilotonnes of TNT, over kilometres of ground: how
well the air model holds at that scale, what it costs on one Mac, which grid and refinement to
choose, and what still stands in the way of running such scenes in the app.

The runner is `blastbench landscape` (`Sources/blastbench/LandscapeBench.swift`); its outputs
from October 2026 are on `/Volumes/StudioData/bombcad/landscape/`.

## A big burst costs what a small one does

Without gravity, the air model solves the Euler equations, which have no length scale of their
own, and every part of the charge model is scaled by the charge's cube root: the charge's
radius, its burning time (`afterburnTime`, per kg^(1/3)) and the minimum sphere it is laid down
in (in cells). A burst of W on cells of size h is therefore the same calculation as a burst of
λ³W on cells of λh, in a domain λ times as large, read λ times later (Hopkinson–Cranz
scaling). This holds in the code to the last digit printed:

- 4,000 t on 32 m cells gives exactly the peaks and impulses of 500 t on 16 m cells, scaled, at
  every gauge out to 40 m/kg^(1/3);
- the terrain's shielding study at 500 t, every length times 17.1, gives the ratios of the
  100 kg study to three decimals (below).

So the cost of a large burst is set by two numbers, not by its mass: the **scaled cell**, h /
W^(1/3), and the **scaled extent** of the domain. There is no largest charge this Mac can run,
only a finest scaled cell for a given reach (below). The largest run here, 4,000 t of TNT, stands
for Minor Scale's 4.8 kt of ANFO, taking ANFO's TNT equivalence for air blast as about 0.82 (its
heat of detonation against TNT's); that equivalence is an assumption, not something checked here. What breaks the scaling is anything with a
length or time of its own: gravity, the atmosphere's height, terrain and structures of a
given size, and the wind and humidity of the cloud models.

Gravity, under which a kilometre-high domain is 11% thinner at its top, changes the ground's
peaks and impulses by under 2% at 4,000 t, and the terrain's ratios at 500 t by at most 0.03 in
peak and 0.07 in impulse. It matters for the fireball's rise (see [the fireball's rise and
cloud](fireball-rise.md)), not for the blast.

## Against Kingery–Bulmash to 40 m/kg^(1/3)

`blastbench landscape`: a hemispherical TNT surface burst on rigid ground in a quarter of its
domain. The charge sits where two mirrored sides meet the ground, a quarter of it laid down
there, so that the air sees the whole charge; gauges stand on the ground along one mirrored
side and along the diagonal at scaled distances 1 to 40 m/kg^(1/3), and are compared with
Swisdak's fit to the Kingery–Bulmash curves (see [validation](validation.md#kingerybulmash-the-design-practice-standard)),
which reach 40 for every quantity used. For 500 t that is 79 m to 3.2 km; for 4,000 t, 159 m to
6.4 km. The air is an ideal gas without afterburning unless said otherwise.

The quarter domain reproduces the existing open-air record at equal scaled cells (0.5 m cells
on 100 kg are 0.108 m/kg^(1/3); 8 m on 500 t are 0.101): peaks 66–70% there against 57–69%,
impulse 80–85% against 81–86%.

Incident peak overpressure, as a share of Kingery–Bulmash's, along the mirrored side, 500 t
(4,000 t is the same at twice the cells):

| Grid | Scaled cell (finest) | Z = 1 | 2 | 5 | 10 | 14 | 20 | 28 | 40 | Coarse cells | GPU memory | Time |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 16 m | 0.20 | 47% | 53% | 52% | 52% | 51% | 49% | 49% | 51% | 2.2M | 0.13 GB | 2 s |
| 8 m | 0.10 | 66% | 66% | 70% | 69% | 67% | 65% | 64% | 66% | 18M | 1.0 GB | 37 s |
| 4 m | 0.05 | 82% | 80% | 81% | 81% | 77% | 74% | 75% | 79% | 144M | 8.2 GB | 650 s |
| 16 m, refined twice, threshold 0.1 | 0.05 | 82% | 79% | 80% | 57% | 52% | 49% | 49% | 50% | 2.2M | 4.4 GB* | 11 s |
| 16 m, refined twice, threshold 0.02 | 0.05 | 82% | 79% | 81% | 80% | 77% | 72% | 55% | 52% | 2.2M | 4.4 GB* | 31 s |
| 16 m, refined twice, threshold 0.005 | 0.05 | 82% | 79% | 80% | 80% | 78% | 76% | 74% | 76% | 2.2M | 4.4 GB* | 155 s |
| 8 m, refined twice, threshold 0.02 | 0.025 | 98% | 86% | 90% | 88% | 85% | 81% | 68% | 68% | 18M | 9.6 GB* | 231 s |

\* A pool of 4 or 8 GB for the refined blocks was asked for and reserved; the most in use was a
eighth to a quarter of it (the default 1 GB holds the threshold-0.1 and 0.02 runs on 16 m cells).

The domains are 3.3 km square and 0.83 km high. The times are this Mac's (an M4 Max, shared with
other work, so ±30%).

Positive impulse is 82–90% of Kingery–Bulmash's beyond Z = 2 on every grid (76–101% at Z = 1),
as in the open-air record without afterburning. With afterburning and hot air (the app's
"Afterburning and hot air"), on 16 m cells refined twice at threshold 0.02, it is **90–108% out
to Z = 40**, and the peaks 75–87% out to Z = 20. The arrival time is within 2% beyond Z = 10 on
every grid, within 5% beyond Z = 5 on 8 m cells or finer, and 3–27% early at Z = 1, where the
charge is spread over cells larger than itself (12% early at Z = 3 on 16 m cells).

Reading these:

- **The peak's share is set by the scaled cell where the shock is, not by how far it has
  come.** On a uniform grid it holds at about 50%, 67% and 80% (cells of 0.2, 0.1 and 0.05
  m/kg^(1/3)) from Z = 2 to Z = 40. A captured shock is smeared over two or three cells, and the
  wave behind it is about 2 W^(1/3) long however far out, so the same cells resolve it about
  equally well everywhere. Peaks along the diagonal read 5–15% higher than along an axis, the
  grid's own anisotropy.
- **Where the refined cells stop, the peak falls to the coarse cells' share** within 3–5
  m/kg^(1/3). The refinement follows the shock only where the pressure jumps by more than the
  threshold's fraction across a cell. At 0.1 (the default) that is out to about 20 kPa
  (Z ≈ 7 to 10); at 0.02, about 5 kPa (Z ≈ 20 to 28); at 0.005, beyond Z = 40.
- **Refinement buys the fine grid's peaks for a fraction of its cost.** Refined twice from
  16 m, at threshold 0.005, the burst has the 4 m grid's peaks everywhere in a quarter of its time
  and half its memory (most of that the blocks' pool, a quarter used). From 8 m it reaches cells of 2 m near the shock (88–98% out to Z = 10),
  which uniformly would take 1.2 billion cells, more than this Mac holds.
- **Impulse and arrival need no refinement**; the peak close in does. For impulse alone, 16 m
  cells (0.2 m/kg^(1/3)) do in 2 s what 4 m cells do in 11 minutes, within 5% beyond Z = 3 and
  10% beyond Z = 2.

### The domain's height

The domain's top is open, and lets waves leave, but not perfectly: a little of each wave is
reflected down. A ground gauge at range R hears that reflection within its positive phase,
which is about L ≈ 2 W^(1/3) long, unless the top is higher than about √(R L / 2), that is
√(R W^(1/3)). The runs found it so:

- 0.83 km over 3.2 km (500 t) gives the same gauges as 1.67 km, to the last digit;
- 0.42 km gives impulses of 118% and 155% of Kingery–Bulmash's at Z = 28 and 40 (2.2 and
  3.2 km) instead of 84%, and is right inside Z = 20;
- 0.21 km over 0.8 km, with afterburning, gives 125% and 148% at Z = 7 and 10, and 0.375 km
  brings them back to 107% and 103%.

`blastbench landscape` therefore makes the domain 1.5 √(R W^(1/3)) high for its farthest gauge
at R, or a quarter of its width if that is more. A burst on its own needs no more; the cloud
needs much more, but that is followed by the [cloud model](fireball-rise.md) after the air's run,
not in the domain.

## Over terrain at scale

No open measurements of large-HE blast over terrain were found (see [data
wanted](data-wanted.md)), so the terrain's own checks were run at scale instead:
`blastbench landscape --study terrain` is the shielding study of [Terrain](terrain.md#shielding-behind-a-ridge)
(100 kg before a ridge, its crest 20 m from the charge) with every length scaled by the cube
root of the charge, and two valleys along the centreline with the charge on their floor. At 500 t
the ridges are 34, 68 and 137 m high with the crest 342 m from the charge, on 4.3 m cells (the
0.25 m cells of the 100 kg study, scaled), 2.2M cells, each case in about 6 s.

- **Without gravity, 500 t gives the 100 kg ratios** to three decimals at every gauge, for the
  three ridges, the wall and the shallower valley. On the steep ridge and the deeper valley the
  gauges agree except one or two on a crest or a valley floor, where rounding in the scaled
  coordinates moves the staircase by a cell (peak ratios differ there by up to 0.25).
- **With gravity, the ratios move by at most 0.03 in peak and 0.07 in impulse.** So the
  shielding table of the terrain page holds for kilotonne bursts over hills of a hundred metres,
  scaled, as far as the model is right at all; its limits (a staircase surface, rigid smooth
  ground, no measurements) are unchanged by scale.
- **A valley channels the blast.** With the charge on a valley's floor, 0.86 W^(1/3) wide
  (68 m at 500 t), its flanks rising over 1.7 W^(1/3) (137 m) to a plateau, the peak along the
  floor is 1.25–1.35 times and the impulse 1.2–1.36 times flat ground's at the same distance when
  the valley is 0.86 W^(1/3) deep (68 m), and 1.55–1.7 and 1.66–1.8 times when it is twice as
  deep; the shock arrives up to 8% sooner. Held between the flanks, the wave spreads less and
  weakens more slowly than over open ground. That is the direction expected of channelling, but
  it has not been compared with any measurement.

A real landscape would come from a DEM (see [importing a DEM](terrain.md#importing-a-dem));
none was downloaded for this work.

## Making large scenes practical

What limits a large scene on this Mac, measured or read from the code, and what was done:

**Memory.** The air takes 57 bytes a cell (66 with the view's volume texture), 73 with
afterburning, and the refined blocks' pool on top (1 GB by default). The GPU's recommended working
set is 28.7 GB and its largest buffer 21.6 GB, so about 400 million cells is the ceiling, and
200–250 million is sensible while anything else uses the GPU: 4 m cells over 3.3 × 3.3 × 0.83 km
(144M cells) held 8.2 GB. No single buffer comes near its limit. A grid is also limited to 2,048
cells along any axis by the view's volume texture, a limit memory reaches first.

**Cost.** Cost goes with the scaled cell and the scaled extent (above). The tile skipping of
still air helps only until the shock has crossed the domain, which is most of the run. For
gauges to 40 m/kg^(1/3), the useful choices are 16 m on 500 t (0.2 m/kg^(1/3)) for impulse and
arrival in seconds, and the same refined twice at threshold 0.005 for peaks within 20–25%, in
minutes.

**Gauges.** Done: a line of gauges by scaled distance. `Scenario.gaugeLine(direction:)` places
gauges 1.5 m above the ground (or the terrain) on a line from the charge at the
Kingery–Bulmash scaled distances that fit in the domain, named by scaled distance and range
("Z 3 · 238 m"), and the editor's **Add Gauge Line** lays one out where the charge has the most
room. The solver now records 64 gauges, not 16.

**Frames for consumers.** Measured: cutting the fireball out for a thermal consumer costs
0.1–0.7 ms of CPU a frame after the batch on these grids (its box of luminous cells, at most 57,000
voxels at 4 m). It is the frames' interruptions that cost: each ends a batch. With refinement, a burst cut out
every 50 ms took about 0.1 s a step against 0.04 s for a burst sixteen times the size unbroken;
on uniform cells it costs little (1,362 steps in 9 s). The
cut-out kernel writes a buffer of 4 bytes for every cell of the grid (0.6 GB at 144M cells), and
takes the fireball from the coarse cells only, so a refined run hands the consumers a fireball
on its coarse cells.

**What remains** (none of it cheap):

1. **The app's cell sizes are fixed** at 0.5, 0.25 and 0.125 m (`Resolution`, used in about 85
   places across 20 files, saved by name in projects and runs, and assumed in the charge's
   0.25 m snapping and the import previews). A landscape needs cell sizes chosen by the
   scene, from the charge's cube root and the domain. Headless runs take the same three.
2. **The app makes no large domain.** Domains come from the presets and from imports; there
   is no domain editor, and the charge slider stops at 2 t.
3. **The camera's zoom stops at 600 m** (`OrbitCamera.zoom(by:)` in ContinuumKit's SceneView).
   A 3 km domain is framed from 5 km but cannot be zoomed back out after zooming in. The
   renderer's clip planes (0.5 m to 20 km) are fine.
4. **The thermal ground receivers are 2 m apart** whatever the domain: 2.8 million over 3.3 km,
   for the march every frame and in the saved run. They should be spaced to the domain.
5. **Saved runs carry the scene, terrain included**, once for each of up to 16 runs. A metre
   DEM over 3.3 km is 11 million heights, 59 MB of base64 in every run kept.
6. **A refined run's fireball reaches consumers on its coarse cells**, and the cut-out
   buffer is the size of the grid (above).

## Effects at scale

- **The cloud's rise** takes the air model's hot gas at the end of the run and is followed by an
  integral model for minutes (see [the fireball's rise and cloud](fireball-rise.md)); it
  works at any scale, with gravity in the air or not, and its tops were checked against those
  measured over 22 TNT detonations.
- **The thermal radiation is illustrative and its work is paused** (see [thermal
  radiation](thermal-radiation.md)): at 500 t its pulse is the wrong shape and 2–5 times too
  bright late. It can be run alongside a large burst, but it is not evidence of anything there.

## Limitations

1. **Peaks are under-resolved** unless refined: 50–80% of Kingery–Bulmash's on the uniform grids
   one Mac holds at kilometre scale, and the refined cells' share only as far as the refinement
   follows the shock.
2. **Kingery–Bulmash is the only reference**, and for a TNT hemisphere on rigid ground. No
   large-HE gauge record was compared directly, nor any ANFO charge, nor soft ground, which takes
   energy into the crater and the ground shock.
3. **Terrain at scale is checked, not validated**, and by scaling the small-scale study, which is
   itself unvalidated.
4. **Not a nuclear burst.** No thermal pulse that heats the ground before the shock, no precursor,
   no radiation-driven fireball; a kiloton of TNT is not a kiloton of nuclear yield.

## Future work

- A refinement criterion that follows weak shocks without refining the wake: a jump relative to
  the overpressure rather than to the pressure, so that the default follows a shock to
  40 m/kg^(1/3) at threshold 0.005's cost or less.
- Cell sizes in the app chosen by the scene (above), a domain editor, and charges of kilotonnes.
- The zoom limit in ContinuumKit, thermal receivers spaced to the domain, and the terrain saved
  once for all runs.
- Large-HE field data: the Defense Nuclear Agency's Minor Scale and Misers Bluff reports, for
  gauge records over flat ground, and any over hills.

## Sources

- C. N. Kingery and G. Bulmash, *Airblast Parameters from TNT Spherical Air Burst and
  Hemispherical Surface Burst*, ARBRL-TR-02555, US Army Ballistic Research Laboratory, 1984;
  through M. M. Swisdak, "Simplified Kingery airblast calculations", 26th DoD Explosives Safety
  Seminar, 1994, as in [validation](validation.md#kingerybulmash-the-design-practice-standard).
- B. Hopkinson, *British Ordnance Board Minutes* 13565, 1915, and C. Cranz, *Lehrbuch der
  Ballistik*, Springer, 1926: the cube-root scaling of blast waves, as stated in any text on
  explosions, for example W. E. Baker, *Explosions in Air*, University of Texas Press, 1973.
