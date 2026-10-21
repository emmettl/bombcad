# Large scenes

Surface bursts of hundreds of tonnes to kilotonnes of TNT, over kilometres of ground: how
well the air model holds at that scale, what it costs on one Mac, which grid and refinement to
choose, and what still stands in the way of running such scenes in the app.

The runner is `blastbench landscape` (`Sources/blastbench/LandscapeBench.swift`); its outputs
from October 2026 are on `$BOMBCAD_DATA/landscape/`.

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
| 16 m | 0.20 | 47% | 53% | 52% | 52% | 51% | 49% | 49% | 51% | 2.2M | 0.13 GB | 0.5 s |
| 8 m | 0.10 | 66% | 66% | 70% | 69% | 67% | 65% | 64% | 66% | 18M | 1.0 GB | 9 s |
| 4 m | 0.05 | 82% | 80% | 81% | 81% | 77% | 74% | 75% | 79% | 144M | 8.2 GB | 137 s |
| 16 m, refined twice, threshold 0.1 | 0.05 | 82% | 79% | 80% | 57% | 52% | 49% | 49% | 50% | 2.2M | 4.4 GB* | 1.7 s |
| 16 m, refined twice, threshold 0.02 | 0.05 | 82% | 79% | 81% | 80% | 77% | 72% | 55% | 52% | 2.2M | 4.4 GB* | 6.4 s |
| 16 m, refined twice, threshold 0.005 | 0.05 | 82% | 79% | 80% | 80% | 78% | 76% | 74% | 76% | 2.2M | 4.4 GB* | 25 s |
| 8 m, refined twice, threshold 0.02 | 0.025 | 98% | 86% | 90% | 88% | 85% | 81% | 68% | 68% | 18M | 9.6 GB* | 52 s |

\* A pool of 4 or 8 GB for the refined blocks was asked for and reserved; the most in use was a
eighth to a quarter of it (the default 1 GB holds the threshold-0.1 and 0.02 runs on 16 m cells).
The pools now grow as they are used ([below](#the-refined-pools-memory)), so these runs hold far
less.

The domains are 3.3 km square and 0.83 km high. The times are this Mac's (an M4 Max) with
nothing else running, the mean of two runs that agreed within 5%; the runs first timed here, on a
Mac loaded with other work, took 4 to 7 times as long.

On today's recommended air (afterburning, hot air, far-field faces), 8 m cells, the bench's default
(20 October 2026): on the balloon start the peaks along the mirrored side are 64%, 72%, 77%,
75%, 72%, 69%, 67% and 70% at Z = 1, 2, 5, 10, 14, 20, 28 and 40, and the impulse 97–117%; on
the mapped start, now the default, 126%, 109%, 76%, 76%, 73%, 69%, 69% and 70%, the impulse
85–112%. Within the mapped radius (to Z = 3) the peaks are the one-dimensional solution's;
beyond it the grid carries the wave as before.

Positive impulse is 82–90% of Kingery–Bulmash's beyond Z = 2 on every grid (76–101% at Z = 1),
as in the open-air record without afterburning. Along the mirrored side, on the uniform grids and
with afterburning:

| Grid | Scaled cell | Z = 1 | 2 | 5 | 10 | 14 | 20 | 28 | 40 |
|---|---|---|---|---|---|---|---|---|---|
| 16 m | 0.20 | 101% | 89% | 86% | 85% | 85% | 84% | 84% | 84% |
| 8 m | 0.10 | 85% | 82% | 85% | 84% | 83% | 82% | 82% | 83% |
| 4 m | 0.05 | 79% | 81% | 86% | 84% | 83% | 83% | 82% | 83% |
| 16 m refined twice at 0.02, afterburning | 0.05 | 90% | 91% | 107% | 106% | 102% | 107% | 101% | 102% |

With afterburning and hot air (the app's "Afterburning and hot air"), on 16 m cells refined twice at threshold 0.02, it is **90–108% out
to Z = 40**, and the peaks 75–87% out to Z = 20. The arrival time is within 2% beyond Z = 10 on
every grid, within 5% beyond Z = 5 on 8 m cells or finer, and 3–27% early at Z = 1, where the
charge is spread over cells larger than itself (12% early at Z = 3 on 16 m cells).

The standing's error bands read these tables for gauges beyond 6 m/kg^(1/3), and for every gauge
of a refined run take the cells the shock is on as it passes: the coarse cells where it is weaker
than the threshold's reach (see [standing](standing.md) and, for choosing settings by them,
[performance](performance.md#choosing-settings)).

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
  16 m, at threshold 0.005, the burst has the 4 m grid's peaks everywhere in a fifth of its time
  and half its memory (most of that the blocks' pool, a quarter used). From 8 m it reaches cells of 2 m near the shock (88–98% out to Z = 10),
  which uniformly would take 1.2 billion cells, more than this Mac holds.
- **Impulse and arrival need no refinement**; the peak close in does. For impulse alone, 16 m
  cells (0.2 m/kg^(1/3)) do in half a second what 4 m cells do in over two minutes, within 5% beyond Z = 3 and
  10% beyond Z = 2.

### Following weak shocks further: tried, and not needed to 40 m/kg^(1/3)

The refinement follows a shock where the pressure jumps across a cell by more than the threshold's
share of the lower pressure, so its reach is an absolute jump (about 500 Pa at 0.005). Two criteria
that scale with the shock instead were tried on the same burst (500 t, 16 m cells refined twice,
with afterburning and hot air, the Mac shared; 17 October 2026), added to the threshold's:

| Criterion | Z = 10 | 14 | 20 | 28 | 40 | Most patches | Time |
|---|---|---|---|---|---|---|---|
| Threshold 0.1 alone (the default) | 61% | 55% | 52% | 51% | 53% | 533 | 5 s |
| Threshold 0.005 | 85% | 82% | 78% | 77% | 79% | 3,518 | 55 s |
| Jump over 0.3 of the larger overpressure | 84% | 80% | 77% | 75% | 77% | 10,872 | 100 s |
| Löhner's indicator over 0.5, floor 0.1% of ambient | 85% | 82% | 79% | 80% | 80% | 4,058 | 73 s |
| Löhner's over 0.7 | 85% | 82% | 78% | 71% | 58% | 2,436 | 27 s |
| Löhner's over 0.5, floor 0.5% | 85% | 83% | 77% | 64% | 57% | 2,161 | 22 s |

- **The jump against the overpressure refines the wake**, not less of it: where the wave passes
  through zero into its negative phase, any jump is a large share of the overpressure there.
- **Löhner's indicator** (the second difference over the first differences' sum, with an absolute
  floor in place of his share of the pressure) follows the shock to 40 m/kg^(1/3) at 0.5, at 1.3
  times threshold 0.005's time; stricter, it loses the front as it smears; a higher floor is an
  absolute threshold again.
- **Threshold 0.005 is near the least that following the shock costs there**: by 40 m/kg^(1/3)
  the shock's own shell, a patch thick, is about 3,500 patches of this quarter domain, which is
  what it uses at most. A criterion that scales with the shock would pay only beyond the reach of
  0.005's 500 Pa (by estimate, beyond about 60 m/kg^(1/3)), which no comparison here reaches; the
  advisor already chooses 0.005 where its reach is wanted.
- **The finest cell sets the peak's share**, as above: 8 m cells refined twice (2 m at the shock)
  at threshold 0.005 give **84–94% of Kingery–Bulmash at every distance from 1 to 40 m/kg^(1/3)**
  along the axis (92–97% on the diagonal), impulses 87–95%, in 12 minutes on the shared Mac and a
  14 GB pool of patches (15,742 at most). That is the setting for peaks close to the reference at
  kilometre scale, if the memory is there.

The criteria are kept on the branch `claude/weak-shocks` for the record, not in the solver.

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

### The refined pool's memory

Each refined level keeps its patches in a pool. The pool used to be made at its full size,
`refinementMemory`, at the start, so that which blocks were refined when it ran out did not depend
on the order the GPU's threads ran in (see [the air model](air-blast-model.md)). It now starts at 64 MB
(`refinementStartMemory`) and grows between command buffers, a quarter at a time or more, to stay
eight steps of its fastest growth ahead of the patches in use (`BlastSolver.makeRefinementRoom`).
`refinementMemory` is now the most it may grow to.

A grown pool steps exactly as a full one would:

- every patch keeps its slot and its cells;
- the new slots are what a full pool's unused slots are, never yet used;
- the free stack hands out slots from its top, in the same order at any size, and the new slots go
  to its bottom.

A pool too small for the patches around the charge at the start is grown fourfold and the run
started again. One that runs out while it could still grow is reported
(`refinementPoolGrewLate`), though none has.

The digests (`blastbench digest`, `--refine-start full`, `64` and `1`) match to the bit, on:

- one level and two, ratio 2 and 4;
- with gravity, afterburning and terrain cut cells;
- with solid and shell structures.

The 500 t burst refined twice to 2 m (8 m cells, threshold 0.005, a 12 GB cap) gave every
gauge's peak, impulse and arrival unchanged (17 October 2026), in about half the memory:

| | First level | Second level | Air in all | Process |
|---|---|---|---|---|
| Patches in use at most | 15,816 | 43,911 | | |
| Pool made whole (before) | 55,781 | 111,563 | 14.2 GB | |
| Pool grown (now) | 20,022 | 62,852 | 7.7 GB | 6.4 GB resident |

A patch at ratio 2 takes about 63 kB, 77 kB with the fuel and oxygen of afterburning, and 112 kB
over terrain cut cells. Of the 77 kB:

| Share | What |
|---|---|
| 27% | the fine state, twice |
| 22% | each fine cell's mask, wall velocity, structure count and impulse |
| 13% | the coarse halo saved each step |
| 13% | fine and coarse flux registers |
| 14% | fuel and oxygen, with their ghosts and fluxes |
| 7% | ghost cells |

The structure's count and wall velocity (19%) are needed only with a body, and a cut-cell scene's
cut-cell records (29% of its 112 kB) only near the terrain. Leaving them out without a body
would cut a grown pool by a further fifth. It was not done: every kernel that reads them would
have to be checked for a run without one, and growing already removes the pool's empty share,
which was 60–80% of it.

`RunCost` prices each level's pool from the blocks its busiest moment is expected to hold
(`RunCost.poolShares`). It is fitted to this run and to the Beirut-class one below, on the
larger of the two: the tall domain is priced 1.4 times what it held, the low one as it held. The advisor weighs each setting with that memory, the
coarse grid's and the pools', against what this Mac lets the air take: seven tenths of its
recommended working set, 19.7 GB on the Studio (M4 Max, 36 GB) and 12.4 GB on the mini (M4,
24 GB). The app lets the pools grow into whatever that leaves beside the coarse grid, never less
than 1 GB, so the refinement the advisor prices is what the run gets. Where a target needs more
memory than this Mac has, the advice says so, and names the sweep worker it would fit
(`AdvisorMachine`; each worker reports its memory when it connects).

**A Beirut-class domain.** The Beirut, 2020 district comparison runs 0.5 kt over a domain of
5 × 5 × 0.32 km on uniform 4 m cells (125 million cells, about 8 GB of air). Its open-ground
analogue was run at 2 m at the shock: a quarter of the domain, 500 t at its corner, 8 m cells
refined twice at threshold 0.005, without buildings or terrain. That took 343 s on the shared
Studio, and the pools held 10,252 and 25,745 patches (2.8 GB) beside 0.29 GB of coarse air. By
symmetry, the whole domain takes:

- 1.1 GB of coarse air and 11 GB of pools on flat ground;
- 16 GB of pools over terrain cut cells (112 kB a patch), so 17 GB of air, plus the components'
  histories (4 GB in the district run).

This fits the Studio's 19.7 GB for the air, and the machine's 36 GB with the histories. It does
not fit the mini's 12.4 GB with cut cells; it might on flat ground, and with the terrain as whole
cells (`--staircase`, 77 kB a patch, about 12 GB of air). Pools made whole, as before, would have
had to be asked for at least 13 GB up front with cut cells and no margin. The streets and
buildings refine reflections that open ground does not, so the district will hold more than this
analogue. The advisor's estimate and the run's `refinementPools` will say how much.

**Cost.** Cost goes with the scaled cell and the scaled extent (above). The tile skipping of
still air helps only until the shock has crossed the domain, which is most of the run. For
gauges to 40 m/kg^(1/3), the useful choices are 16 m on 500 t (0.2 m/kg^(1/3)) for impulse and
arrival in half a second, and the same refined twice at threshold 0.005 for peaks within 20–25%,
in under half a minute (on a quiet M4 Max).

**Gauges.** Done: a line of gauges by scaled distance. `Scenario.gaugeLine(direction:)` places
gauges 1.5 m above the ground (or the terrain) on a line from the charge at the
Kingery–Bulmash scaled distances that fit in the domain, named by scaled distance and range
("Z 3 · 238 m"), and the editor's **Add Gauge Line** lays one out where the charge has the most
room. The solver now records 64 gauges, not 16.

**Frames for consumers.** Measured: cutting the fireball out for a thermal consumer costs
0.1–0.7 ms of CPU a frame after the batch on these grids (its box of luminous cells, at most 57,000
voxels at 4 m). It is the frames' interruptions that cost: each ends a batch. With refinement, a
burst cut out every 50 ms took about 0.1 s a step against 0.04 s for a burst sixteen times the
size unbroken; on uniform cells it costs little (1,362 steps in 9 s). Those runs were timed on a
loaded Mac, so their absolute times are long; the comparison between them stands. The cut-out kernel writes a
buffer of 4 bytes for every cell of the grid (0.6 GB at 144M cells).

Done: **a refined run's fireball reaches the consumers on its finest cells.** Where a patch of
refined air covers any of the fireball's box, its cells are cut out at the finest level whose box
stays within the volume model's million voxels, each from the finest patch holding it and from its
coarse cell where none does (`BlastSolver.refinedLuminousCells`). A kilogram's fireball half a
millisecond on, on 0.25 m cells refined by 2, comes out on 0.125 m cells with a volume within 25%
of a uniform 0.125 m grid's. Refinement follows the shock, not the fireball, so once the shock has
left a fireball behind it lies on coarse cells again and goes as before; the 500 t run's frames
at 50 ms intervals were nearly all of that kind.

**The app.** Done:

- **Cell sizes scaled to the scene.** `Resolution` is any cell size from 0.01 to 200 m: the three
  presets are saved by name as they always were, others as `cell:` and the size in metres, which
  readers from before refuse rather than misread. The Grid picker offers cells of 0.2, 0.1 and
  0.05 m/kg^(1/3) for charges large enough that they come to a metre or more, and Cell size takes
  any size. Headless runs take `--resolution` in metres. A grid of more than 2,048 cells along a
  side is refused with that reason.
- **A domain editor.** The Domain section sets the extent from the origin, everything staying
  where it is and gauges left outside removed (`Scenario.resizeDomain(to:)`); offers the height
  the open top needs for the farthest ground, 1.5 √(R W^(1/3)) above the charge
  (`Scenario.suggestedHeight`); and fits an open scene (nothing in it but the charge, gauges and
  terrain) to its charge, a square reaching 10, 20 or 40 m/kg^(1/3), the charge in its middle,
  with the finest scaled grid that keeps within 20 million cells
  (`Scenario.fitOpenScene(scaledReach:)`).
- **Charges to 10 kt**, the slider logarithmic, to two significant figures above 100 kg.
- **Terrain saved once.** A saved run over terrain keeps it by reference: the heights go to
  `results/terrain/<sha256>.json`, shared by every run over the same ground, and the run's record,
  now version 4, names the hash; older readers refuse it rather than open it on flat ground, and
  runs saved inline read as before. The project's own scene keeps its copy, so a project holds the
  heights at most twice, not once more for every run.
- **Thermal ground receivers spaced to the floor.** Over a floor larger than a square kilometre
  they stand far enough apart that there are at most 250,000 (6.7 m over 3.3 km); the Thermal
  section sets the spacing and shows what it comes to.
- **Zoom.** The view zooms out to three times the domain's longest side (never less than 600 m):
  ContinuumKit 0.1.0-alpha.21 lets the controller set the orbit view's zoom limits, which BombCAD
  widens with the domain.

Rendering at this scale was checked offscreen (`blastbench snapshot --fit-reach 10 --mass 500000
--dx 8`, with and without `--terrain hill`): the domain is framed whole from 2.6 km, the hemisphere
of peak overpressure is cut by the open top where it should be, a hill shows the reflection on its
near face and the shadow behind it, and a frame takes 2–6 ms.

**What remains:** the scene's own copy of its terrain besides the runs' (the scene file's format
would have to change), and a domain grown about its centre rather than from its origin, which
would mean moving every kind of object in a scene.

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

- Following weak shocks beyond 60 m/kg^(1/3), where threshold 0.005's reach ends: Löhner's
  indicator follows them at 1.3 times its cost (see [above](#following-weak-shocks-further-tried-and-not-needed-to-40-mkg13)).
- A domain grown about its centre.
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
