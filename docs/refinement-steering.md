# Refinement steered by the decision

[Horizons](roadmap.md#horizons) item 1 asks whether refining only where the user's answer is in
doubt lets refined districts beat uniform cells by a clear factor at equal answers. Traced
19 October 2026 on Beirut's 1 km box and on a 150 m block. Short answer:

- **For a district, no.** When a district is sized to the reach of its damage, as New District
  sizes it, the buildings whose outcome the coarse cells leave in doubt fill the domain, and
  confining refinement to them saves nothing.
- **For one building, yes.** Refining a corridor from the charge to a chosen building gives full
  refinement's answer for that building at 2–9% of its refined work. On Beirut that is 2.75 times
  less GPU time than refining everywhere and 3.3 times less than the uniform fine cells.
- **Refining only beside a building is worse than not refining.** The shock must be fine along its
  way, not only where it arrives.

## The tool

`SolverConfiguration.refinementConfinedTo` (BlastCore) is a list of boxes. Outside every box a
coarse cell is never refined, and nor are the bands held there. It marks those cells with the same
bit as the [refinement ceiling](beirut-2020.md#what-cell-size-the-glass-and-the-damage-need), so the flagging kernel is unchanged. Nil, the
default, refines anywhere. A box holding the whole domain leaves the air bit for bit as it was
(`EnvelopeComponentTests.refinementConfined`).

`scenebench district-compare` takes three ways of choosing the boxes:

- **`--steer 0.8,1.5`.** A first pass on the coarse cells alone judges every building twice, with
  its components' loads scaled by each factor. A building whose glass (each side broken or not at
  the median strength) or structure (its concrete and stone damage levels) comes out differently
  between the two is in doubt. `--steer-on glass|structure` keeps one kind of decision.
  - `--steer-by ring`, the default: refines a disc about the charge out to the farthest building
    in doubt, plus `--steer-reach` (12 m).
  - `--steer-by near`: refines only boxes about the buildings in doubt, widened by the reach.
- **`--corridor x,y[,half-width]`.** Refines along the line from the charge to a point in the
  domain (m), a given distance either side (60 m by default) and that distance beyond it.

The report adds the first pass's wall time and the buildings in doubt. Each refined level's
*block-steps* (its blocks summed over the run's steps) measure the refinement's work apart from
the Mac's load, since wall times on the shared Studio vary several times over. Buildings are
matched across runs by their centres (`centreM`), since their ids are made afresh each run.

## Beirut's 1 km box

500 t on the port, radius 1,000 m, top 320 m, run to 2.5 s. The reference is 4 m uniform cells.
The refined runs are 8 m cells refined once to 4 m under the auto ceiling, with footprints on 4 m
cells (`--refine 2 --threshold 0.005 --ceiling auto --place-dx 4`), as in
[Beirut](beirut-2020.md). Against the reference:

| Run | Glass sides agreeing | Concrete levels agreeing | Façade peak / reference, p10 / median / p90 | Refined block-steps | GPU s |
|---|---|---|---|---|---|
| 8 m, coarse | 99% | 93% | 0.62 / 0.82 / 0.99 | | 1.6 |
| 8 m refined to 4 m | 99% | 97% | 0.74 / 0.96 / 1.03 | 7.39 M | 21.2 |
| Steered, both decisions | 99% | 97% | as refined | at most 9,146 blocks against 9,199 | |
| Steered, structure only | 99% | 97% | as refined | 7.33 M | |
| 4 m uniform | | | | | 25.2 |

GPU times are from `--profile` (batches of 16 steps).

**Why steering by the district's doubt saves nothing here.** Between ×0.8 and ×1.5, 936 of 1,513
buildings are in doubt, and 853 for the structure alone. They reach 1,110–1,145 m from the charge
on a box whose corners lie at 1,414 m, so the disc covers nearly all of it. Glass at 1 km is still
changing from intact to broken: GEER found some windows broken on 62% of façades at 750–1,000 m.
The concrete and stone levels change across the whole box too. Any band wide enough to cover the
coarse cells' error, whose façade peaks read 0.62–0.99 of the reference, leaves this much in doubt.
A district drawn to the reach of its damage contains that damage's edge, and the edge is where
the doubt is.

**One building, by a corridor.** Four buildings 400–850 m out, chosen where the refined run
settles the structure differently from the coarse one:

| Building | Answer, 4 m / 8 m / refined | Corridor 60 m: block-steps, answer | Corridor 120 m |
|---|---|---|---|
| 631 m, concrete level | 1 / 0 / 1 | 2.4%, 1; side peaks within 7% of refined | 6.1%, 1; peaks as refined |
| 402 m, stone level | 4 / 4 / 2 | 2.0%, 2; peaks within 0.3% | 4.4%, 2; as refined |
| 700 m, concrete level | 1 / 0 / 1 | 4.1%, 1; peaks within 1.1% | 9.4%, 1; as refined |
| 852 m, stone level | 2 / 0 / 2 | 2.9%, 2; peaks within 1.6% | 6.3%, 2; peaks within 2% |

Every corridor gives the refined run's answer for its building. At 402 m that answer is the refined
run's own error: refining everywhere gets that building's stone wrong too. The 60 m corridor of the
631 m building took 7.7 GPU s against 21.2 for refining everywhere, 25.2 for 4 m uniform cells and
1.6 for the coarse cells alone.

The corridor's time falls 2.75 times while its block-steps fall 16 times, because the refinement's
fixed costs barely shrink:

| Stage | Everywhere | Corridor |
|---|---|---|
| Sweeps | 8.40 s | 0.75 s (scale with the blocks) |
| Ghosts | 3.31 s | 1.53 s |
| Fill | 2.47 s | 1.27 s |
| Cut cells | 1.10 s | 0.49 s |

The fill follows the blocks newly placed, which a corridor renews as the shock crosses it.

## A 150 m block

1 t in a square 19 m across among 217–223 buildings, radius 150 m, top 200 m, run to 0.4 s. The
reference is 1 m uniform cells. The others are 4 m cells, and 4 m cells refined twice to 1 m under
the ceiling.

- **Refinement does not pay at this size.** The 1 m uniform run took 6 s on the Studio and the
  refined one 18 s. So did the port's 300 m box under 500 t: 2 m uniform cells took 9 s, refined
  16 s.
- **Refining only beside the buildings in doubt is worse than coarse cells.** With `--steer-by
  near`, the façade peaks' median was 0.50 of the reference, against 0.58 on the coarse cells
  alone and 0.71 refined everywhere. The shock crosses coarse cells to reach each box and arrives
  smeared. The façade then reads the finest cells, which hold that smeared shock before it has
  steepened, below the coarse cell's own mean.
- **The disc.** 120–132 of 217 buildings were in doubt, so the disc (185–201 m) covered the box,
  and the answers and refined blocks were those of refining everywhere.

## Refining toward chosen buildings

Since 19 October 2026 this is a feature. In the app, click a building in the view (or use its row's
toggle among the exposure-only buildings) and turn on **Refine toward this building**; choose as
many as matter. The run refines corridors from each charge to each of them
(`Scenario.refinementCorridors`, `RefinementRegion.corridors`): the line over the ground to the
building's middle and on past its far side, 1.5 m/kg^(1/3) either side (120 m for 500 t, the wider
of the two tried above), and the building itself widened as much. The rest of the scene stays on
the coarse cells, which the sidebar says, with the advisor's estimate of the run's time against
refining everywhere. A saved run keeps the buildings chosen (`ProjectRunSettings.refineToward`), so
`BombCAD run` does the same. Headless, `scenebench district-compare --refine-toward x,y[;x,y]`
refines toward the buildings nearest those points, and `Scripts/compare-refine-toward.py` sets a
coarse run, one refined everywhere and one refined toward them side by side for those buildings.

On Beirut's 1 km box (as above, 8 m cells refined once to 4 m, to 2.5 s, today's air), toward three
of the four buildings at once:

| Building | Coarse cells | Refined everywhere | Toward the three |
|---|---|---|---|
| 402 m | concrete 2, stone 2; 27.8 kPa | 2, 2; 29.3 kPa | 2, 2; 29.3 kPa |
| 700 m | 0, 0; 19.6 kPa | 1, 2; 22.5 kPa | 1, 2; 22.5 kPa |
| 852 m | 0, 0; 14.0 kPa | 0, 2; 21.9 kPa | 0, 2; 22.2 kPa |

(Their glass breaks on every side in all three.) Each building takes refining everywhere's answer,
where the coarse cells get two of the three wrong. The refined GPU time, from `--profile`'s stages,
beyond the coarse cells' 3.0 s:

| Refined toward | Block-steps of refining everywhere | Refined GPU s | Of everywhere's 21.5 |
|---|---|---|---|
| One building (700 m) | 20% | 9.6 | 0.45 |
| Three buildings | 35% | 8.3 | 0.39 |

The two are within the Studio's noise of each other: the fixed costs, not the blocks, set a few
corridors' time. The advisor prices a confinement as its share of the refined work plus 0.29 of
the rest (`RunCost.confinedRefinementFixedShare`), which gives 0.31 for the 60 m corridor above,
0.43 for one building and 0.54 for three; making the fixed costs follow the blocks held ([Horizons](roadmap.md#horizons))
would bring all three down.

## Limitations

- **The decisions judged are the bench's.** Each side's glass is judged at the median strength,
  and each building's concrete and stone levels. Injury contours and the app's own glass mixes
  were not tried.
- **The doubt band is fixed by hand.** ×0.8 to ×1.5 does not come from the
  [reflected-peak table](air-blast-model.md#reflected-peaks-at-a-wall). On Beirut the coarse
  cells' façade peaks fell between 0.62 and 0.99 of the reference, so no band that covers them
  would leave less in doubt.
- **Few targets.** The corridor's agreement rests on four buildings in one city and one charge,
  refined once. Twice-refined air and charges near the targets were not tried.
- **A corridor is straight.** A building in a street's shadow is reached by waves that turn
  corners; a half-width of 120 m (1.5 m/kg^(1/3) here) held for the four.

## What it could become

- **Refine toward chosen buildings:** built ([above](#refining-toward-chosen-buildings)).
- **Show the doubt.** The coarse first pass with its loads rescaled takes 1–3 s for Beirut's
  1 km box. Shown as an overlay, it tells the user which buildings' outcomes the cells could
  flip, before choosing what to refine.
- **Make the fixed costs scale.** If ghosts, fill and cut cells followed the blocks held, a
  corridor would cost nearer its block-steps' share.
