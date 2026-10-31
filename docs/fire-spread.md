# Fire after the blast: spread across a district

A blast's fire often does more harm than the blast itself. Wooden houses with their stoves knocked
over burned whole streets of Halifax's North End in 1917. Fires after earthquakes destroyed more
of San Francisco in 1906 and of Kobe in 1995 than the shaking did. This page covers the first step
of emmettl/bombcad-work#38: fire spreading from building to building over a district's buildings,
for hours after the blast.
- **Seeds:** BombCAD's ignitions.
- **What it spreads through:** the glass the blast broke and the walls it failed.

**Standing: illustrative.** The model is a published one, built for the New Zealand Fire Service
and judged there against historical fires. Here it is adapted in two ways:
- **from cells to buildings**, and
- **from earthquakes to blasts.**

It has been checked against its own published tables, and judged only qualitatively against a
blast's fire, on Beirut 2020. Its seeds are illustrative too: either the surface heating's flags,
which are test thresholds and not a fire model, or the user's choice.

Use it to see where a district's construction and spacing would carry a fire, and how much the
broken glass and the wind change that. It does not predict which buildings burn.

## What holds and what does not (31 October 2026)

- **Holds: the model's own numbers.**
  - Its radiation is Report 27's Table 2 to the decimal, on 110 of its 120 cells. The other ten
    are the 24 m column, which repeats the unbounded column, a slip in the report.
  - Its critical separations through windows are Report 44's Table 2.1, on 23 of the 24 cells.
  - Its sparks follow the wind as Report 27's Table 3.
- **Holds, qualitatively: Beirut.** No fire spread through the city after the blast. The model
  agrees: in a district of concrete and stone it carries nothing far, even with nearly every pane
  broken.
  - Twenty ignitions placed at random within 1.5 km of the port burn a median of 112 buildings in
    all (63–181 over 200 draws), and every fire is out within about nine hours.
  - The same district built of timber burns 3,818 buildings (3,472–4,090) by 12 hours and is
    still alight, out to 2.1 km.
  - The broken glass is what spreads it at all: with every window intact, the twenty fires take
    two neighbours between them.
- **Does not: anything measured.** No open record gives a post-blast fire's spread through
  buildings by hour. Halifax's fires have extent but no times, and Beirut had no spread to time.
  The post-earthquake fires with times, such as Napier 1931, Kobe 1995 and Sakata 1976 (a fire
  without an earthquake), have no BombCAD district.
- **Does not: the ignitions.** The surface heating's flags are test thresholds on an inert
  surface. On a city of concrete and stone they flag nothing. What ignites buildings after a
  blast is not modelled:
  - heat through broken windows onto curtains and furniture;
  - gas, stoves and wiring in the wreckage.

## Running it

```bash
swift run -c release scenebench fire <the district-scene's inputs> --radius 2500 \
    --ignite-random 20 --ignite-band 0,1500 --wind 5.7@240 --hours 12 --members 200 \
    --look look.json --json fire.json --csv timeline.csv --buildings-csv buildings.csv
```

`blastmodel fire` takes the same arguments on Linux. Its parts:

- **The district.**
  - `scenebench district-scene`'s inputs (`--osm`, `--dem`, `--heights`, `--centre`,
    `--mass`, `--dx`), or a saved layout, `--scene layout.json`.
  - Each envelope building is one fire: its cells' rectangles, its height, its construction and
    use, and its glazing (`GlazingMix`).
  - A map building tagged `building:material=wood` or `timber` is clad with something that
    burns, as is cross-laminated timber. Since 31 October 2026 such a building's construction is
    timber itself, walls and roof, so its roof is not fire-rated either and its blast damage is
    timber's ([below](#grey-for-no-chance-and-wood-tags-31-october-2026)); `--wood-tags ignore`
    keeps the earlier construction, the cladding alone burning.
  - `--cladding combustible` makes every building timber-clad, for the contrast below.
- **The blast's damage.**
  - From the quick estimate's full look, as [People in the scene](people-in-the-scene.md) makes
    it: each side's share of glass broken, and each building's chance of heavily damaged walls.
  - `--look` keeps it, the same file `scenebench people` keeps, so later runs take a second or
    two. `--no-glass` leaves every window whole.
- **The seeds**, any of them together:
  - `--thermal-results` from `BombCAD run --thermal`: the buildings whose faces or roofs the
    [surface heating](surface-heating.md#ignition-illustrative) flags. Past the short pulse's
    ignition fluence by default; with `--thermal-seeding either`, past either of its thresholds.
  - `--ignite-within` metres of the charge, or of `--ignite-at east,north` metres from it.
  - Map ids, `--ignite way/123,way/456`.
  - `--ignite-random n`: n buildings drawn afresh in each draw, from those whose centres lie
    `--ignite-band from,to` metres from the charge. Report 27 ran Wellington the same way, from
    the 27 ignitions its history gave it (§5.2).
- **The wind**, `--wind speed@from`, m/s and degrees clockwise from north. It is constant through
  the fire.
- **The draws.** Sparks, openings, roofs and brands ignite with a chance, so the fire is drawn
  `--members` times (100 by default) from `--seed`. Each draw is deterministic: the same
  arguments give the same fire on any machine.
- **The output.**
  - Printed: the buildings alight and burnt out each hour (5th, 50th and 95th percentiles over the
    draws), the buildings that caught, by mode and distance band, and the standing.
  - `--json`: all of it, with every building's chance of burning, its median time of ignition
    and how it most often caught. Since 31 October 2026 also the draws in which it was a starting
    fire (`seedDraws`) and its chance of catching from a neighbour over the others
    (`neighbourChance`).
  - `--csv`: the timeline every `--step-minutes` (10).
  - `--buildings-csv`: one row a building, with its map id and its place east and north of the
    charge, and the same two at its end (`seed_draws`, `neighbour_chance`).
  - Printed last, the app's map at the horizon counted in bands of distance: grey, up to 1%,
    1–2.5%, 2.5% to an eighth and above. `--map-chance neighbour` (the default) counts the chance
    of catching from a neighbour, `--map-chance caught` the chance of catching at all, the map's
    before 31 October 2026.

The app shows it as a layer on the quick estimate and on a run's damage ([The app](#the-app-stage-3-31-october-2026)).

## The model

The model is a building-by-building form of the dynamic fire-spread model that GNS Science and
Victoria University of Wellington built for the New Zealand Fire Service.
- Cousins et al. 2002, Report 27: the rules.
- Heron et al. 2003, Report 44: buildings that do not burn from outside.
- Thomas, Heron and Baker 2008, Report 80: the chances, before and after an earthquake.

Their model is a cellular automaton on 3 m cells, scanned every 2.5 minutes. It was judged against
Napier's fire after the 1931 earthquake, more than 400 buildings over 11 blocks for almost 24
hours, and against a house fire in Wellington. Here each building is one fire.

### A building's fire

| Stage | How long | From |
|---|---|---|
| Growth to full involvement | 7.5 minutes, then 2.5 minutes for each 3 m of the footprint's side, √(area) | Report 27 §4.2 and §4.3.1: 7.5 minutes from ignition to full intensity in a cell, 2.5 minutes from one cell to the next |
| Fully developed | The fire load over its floors, burnt at the lesser of its ventilation-controlled rate (1.5 MW per m^(5/2) of A√H, its windows' area and height) and its fuel-controlled rate (250 kW per m² of floor), a band of 12 m (three storeys) at a time | Kawagoe's ventilation factor. EN 1991-1-2 Annex E's fire loads and RHRf. Report 44 §2.3.3.1: three storeys alight at once |
| Burning down | 12.5 minutes | Report 27 §4.2 |

- **Fire loads**, MJ/m² of floor, by the building's use. They are EN 1991-1-2 Annex E's means,
  from the CIB W14 surveys:
  - dwelling 780;
  - office 420;
  - shopping centre 600;
  - classroom 285;
  - hospital room 230;
  - hotel room 310;
  - theatre 300, for places of worship;
  - transport 100, for unoccupied buildings.

  Industry and storage have no row there and take the shopping centre's: an assumption. An
  untagged building takes `--untagged` (residential).
- **An example.** A two-storey house of 100 m², 15% glazed, burns fully involved for 52 minutes,
  on its fuel-controlled rate. Report 80 holds a cell at full intensity for 40 minutes, and
  Report 27 for 15.
- **The windows that ventilate it** are all its windows: glass the blast left in place fails at
  flashover (Report 44 §2.3.5). So the broken glass changes how a building takes fire, not how
  long it burns.
- **Doors and openings that are not glass** are taken as at least 5% of the façade: an
  assumption.

### From one building to the next

While a building is fully involved, it radiates from the face that looks at each neighbour. That
face is as wide as the building across the line between them, and as high as the building, up to
12 m.
- A combustible building radiates from its whole face.
- One that does not burn from outside radiates only from its windows. Its glazed share is taken as
  one opening across the face (Report 44 §2.3.3.2).

The radiator is at 1000 °C with emissivity 0.9, 134 kW/m² (Report 27 §4.3.2). The flux on the
neighbour is that power times the face's configuration factor from a point on its centre's normal,
at the least distance between the two footprints.

One scan (2.5 minutes) after a building is fully involved, each neighbour within reach catches by
the first of these that holds:

| Mode | When | Chance | From |
|---|---|---|---|
| Contact | A combustible neighbour within 1 m | Certain | Report 27 §4.3.1. Flame from a window reaches under 1.3 m (Report 44 §2.2.5) |
| Spontaneous | A combustible neighbour under 30 kW/m² or more | Certain | Report 27 §4.3.4 |
| Sparks (piloted) | A combustible neighbour under 12.5 kW/m² or more, within the sparks' reach | 10% | Report 27 §4.3.5, Report 80 Table 1 |
| Brands | A combustible neighbour within 45 m downwind, in a 45° arc, in a near gale (50 km/h) | 0 | Report 27 §4.3.6. Report 80 sets it to 0, Wellington's roofs being steel |
| Openings | A neighbour that does not burn from outside, through its facing windows. Broken: 12.5 kW/m² on them. Intact: 30 kW/m² through the half that glass lets through | Intact 4%, 10% and 1%, broken 5%, 41% and 30%, at 0–3, 3–6 and 6–18 m | Report 44 §2.3, Report 80 Table 1, "pre-" and "post-earthquake" |
| Roof | From a roof that is not fire-rated to a taller neighbour within 5 m | 30% | Report 44 §2.2.3 (the NZ Building Code's 5 m), Report 80 Table 1 |

- **The sparks' reach.** Report 27's Table 3 gives 12 m in calm air and across or against the
  wind. Downwind it gives 15 m in a moderate breeze (20 km/h), 21 m in a fresh breeze (30 km/h)
  and 45 m in a near gale (50 km/h). Here it runs linearly between those speeds, is held beyond
  them, and the downwind gain falls off as the cosine of the angle off the wind, to none across
  it: the cosine is this model's choice.
- **The blast's damage.**
  - A side's share of glass broken is the chance that its windows are open to a fire facing it,
    drawn once a side.
  - A building's chance of heavily damaged walls is the chance that it burns and takes fire as a
    combustible building would, drawn once a building. Report 44 §2.2.2 treats a collapsed
    building so, and Report 80 §3.1 recoded masonry shaken hard ("as flammable as wooden
    buildings").
- **What burns.**
  - Cross-laminated timber walls, and map buildings tagged wood or timber, are combustible. The
    rest are not: concrete, masonry, blockwork and steel sheeting.
  - Concrete and blockwork roofs are fire-rated; sheeting and timber roofs are not.
- **How the draws work.** Each chance is drawn once for its pair and mode. So a draw's fire is a
  graph of the links that came up, and each building's ignition is its earliest arrival over it
  (Dijkstra's order): the seed's time, plus each building's growth and a scan.
- **Reach.** The neighbours each building looks at lie within the farthest any mode reaches. Calm,
  that is 26 m: spontaneous ignition from a face of unbounded width, 12 m high.

**Against Report 27's cells.** Their model counts burning cells within each distance, without
checking how they are arranged. Here a building's whole face radiates at once. It is the model's
"fast variant" (Report 80 §3.1), which ignites a whole building once one cell burns, with the
growth across the building kept as a delay.

## Checks

`swift test --filter FireSpreadTests` runs on Linux.

- **Report 27's Table 2.** The flux from a radiator 4.5 m high, 3 to 75 m wide and of unbounded
  width, at 1.5 to 28.5 m. It is within 0.1 kW/m² on all 110 cells but the 24 m column, which
  repeats the unbounded one in the report. Its worked example also holds: 12 m by 4.5 m, 12 m
  away, 13.5 kW/m².
- **Report 44's Table 2.1.** The separations at which façades 10, 20 and 30 m wide, with 10–40%
  openings and 12 m alight, ignite a building through broken windows or intact ones. Each of the
  table's whole metres is within a metre below the flux's reach, or a tenth above it, on 23 of
  the 24. The exception is 10% of 10 m broken: 6 m in the table, 4.7 m by its own equation.
- **Report 27's Table 3.** The sparks' reach by wind, downwind and across.
- **A row of timber houses, 10 m square and 4.5 m high:**
  - **6 m apart**, inside spontaneous ignition's 6.72 m, they burn in turn, one every growth and
    scan: 18.3 minutes, 52 m an hour along the row. Hamada's formula for bare timber in calm air
    (FireBench's implementation) gives 166 m an hour, three times faster. Its rates are fitted to dense Japanese
    wooden blocks. This model's is the Wellington one's.
  - **11 m apart**, inside piloted ignition's 11.58 m and the calm sparks' 12 m, the fire
    crosses with the sparks' chance: 10% of 2,000 draws, 0.1 ± 0.025.
  - **12 m apart**, past the critical separation, nothing spreads, even with every chance set to 1.
- **The wind's bias.** A burning block 30 m wide with neighbours 14 m off on four sides puts 17.8
  kW/m² on each, past piloted ignition but beyond calm sparks' 12 m.
  - Calm, none catches.
  - In a fresh westerly only the east one catches; in a southerly only the north one.
- **Openings.** Two concrete blocks 5 m apart, 25% glazed, 12 m high: 51.6 kW/m² from the burning
  one's windows, 25.8 through intact glass.
  - With intact glass, none catches.
  - With all the glass broken, 41% catch, Report 80's chance (within 0.03 over 4,000 draws).
  - With half broken, 20.5%.
  - A concrete building whose walls failed burns as a timber one.
- **The roof.** A low building with a roof that is not fire-rated sets a taller neighbour alight
  4 m off, and not 6 m off.
- **The stages.** The house above, worked by hand. Twelve storeys burn as three bands, each as
  long as one.
- **Determinism.** The same draws give the same fire. The horizon stops it.
- **From a scene.** Envelopes, their glass by side, their walls and construction, and a thermal
  result's flagged receivers mapped to buildings.

## Judged against Beirut 2020 (31 October 2026)

Beirut's 14,169 map buildings within 2.5 km, at 0.5 kt (`/Volumes/StudioData/bombcad/fire-spread/run.sh`,
outputs beside it):
- **Construction.** As [Beirut 2020](beirut-2020.md) lays them out: none tagged timber, so all of
  them non-combustible, with concrete roofs.
- **The blast's glass.** The quick estimate's full look broke 99% of the panes 0.5–1 km out, 87%
  at 1–1.5 km, 60% at 1.5–2 km and 32% at 2–2.5 km. It gave seven buildings a better-than-even
  chance of heavily damaged walls.
- **The wind** at the airport at the hour of the explosion, 240° at 11 kt (5.7 m/s, 041500Z), held
  for 12 hours.
- **The draws:** 200.

**The record.** Beirut's fires after the blast were in the port.
- GEER's street survey of 9,183 façades and UN-Habitat's rapid building assessment class the city's
  damage by blast. Neither records a building burnt.
- "By the next morning, the main fire that led to the explosion had been extinguished."
- No source found describes fire spreading from building to building in the city
  ([Data wanted](data-wanted.md) lists the Civil Defence's records as the check).

What the model does:

| Seeds and district | Caught by 12 h, 5th–50th–95th percentile, seeds included | Alight at 12 h | How |
|---|---|---|---|
| The building within 150 m of Warehouse 12 (the silos, in today's map) | 1 | 1 | Nothing within reach: today's port is nearly empty of buildings |
| 20 at random within 1.5 km, as built | 63–112–181 | 0–0–1 | Through broken windows (97 a draw), at 0.5–1.5 km. The last fires are out by 9–12 h |
| The same, every window intact | 20–22–25 | 0 | Two through intact glass |
| The same, every building timber-clad | 3,472–3,818–4,090 | 217–355–525 | Spontaneous ignition (3,226 a draw) and contact (545): a conflagration out to 2.1 km |

**Judged: consistent, qualitatively.**
- The model does not carry a fire through a city of concrete and stone, though its glass is nearly
  all broken out to 1.5 km. Each ignition takes about five buildings with it, through their open
  windows, and dies out within hours.
- The same streets of timber burn by the thousand, as Halifax's North End did.
- What it does not show:
  - **How many ignitions Beirut had.** No source counts them, and BombCAD's own flag none.
  - **Whether the five a fire are right.** No record gives that.
  - **The wind.** In this model wind carries only sparks, which ignite only combustible
    cladding, so in Beirut it changes nothing.
- **A finding on the seeds.** The silos' building, the only one near the seat in today's map,
  burns for 22 hours. Its 5% of openings keep its fire ventilation-controlled. The silo's grain
  did smoulder for weeks in 2022, but that is another fire, and this one is the openings'
  assumption.

## The app (stage 3, 31 October 2026)

The sidebar's **Fire after the blast** section, below People in the scene, draws the fire over a
scene's envelope buildings once the quick estimate's glass is in (File ▸ New District's, or any
scene's), or a run's damage once the run has stopped. It is `FireSpread.layer`, with the same
model and the same defaults as `scenebench fire`.

- **Where fires start**, any of them together:
  - **buildings picked in the view.** With Pick buildings in the view on, a click on a building
    starts a fire there and a second click takes it away. A selected building's panel has a Start
    a fire here switch, for the keyboard and VoiceOver;
  - **near the charge:** every building within 25–500 m of it;
  - **at random:** 5–100 buildings a draw, from a band of distance from the charge;
  - **the run's surface heating:** the buildings its flags mark, past the ignition fluence or
    either threshold, once a run with the thermal radiation's surface heating has stopped.
- **The wind,** its speed and the bearing it comes from, as two sliders.
- **Over** 3, 6, 12 or 24 hours. Under Assumptions: every building timber-clad as a contrast, and
  the use of untagged buildings.
- **What it shows.** Colour Buildings by Fire colours each building by its chance of having caught
  by the hour on a slider, or of burning then, on the chance legend, with the seeds outlined in
  orange. A building that no draw has caught (or burning) by then is grey
  ([below](#grey-for-no-chance-and-wood-tags-31-october-2026)). Since 31 October 2026 the chance
  is of catching from a neighbour, over the draws in which the building was not itself a starting
  fire; Caught ▸ At all keeps the earlier map
  ([below](#the-chance-of-catching-from-a-neighbour-31-october-2026)). Beside it: the buildings alight, burnt out and the floor reached at that hour (median and
  5–95%), the buildings caught by the end, those more likely than not to burn, and how they caught.
- **Its standing leads,** as the people estimate's does: the note that it is illustrative and not a
  prediction first, the standing's badge, and `FireSpread.standing` beneath.

**How it is drawn.** The district and the draws run away from the main thread. A change of seeds,
wind, hours or construction cancels the draws under way, between chunks of 20, and starts again.
- While the charge is dragged or a slider held, 40 draws make a preview. When it is let go, the
  full 200 follow.
- The progress shows as draws done of the total.
- Each building's ignition times over the draws are kept, so the hour slider recolours the view
  without drawing again.

**Timings,** on the M4 Max, optimised build, Beirut at 0.5 kt within 2.5 km through File ▸ New
District (the advisor's 6 m cells place 9,708 buildings; `scenebench fire` at 4 m places 14,169):

| Step | Time |
|---|---|
| Laying out the district | 1.7 s |
| The quick estimate's full look (already there before this stage) | 26.3 s |
| The fire, 200 draws over 12 h, 20 at random within 1.5 km | 0.05 s |
| A preview, 40 draws | 0.03 s |
| Every building timber-clad, 200 draws (a conflagration) | 0.23 s |

The draws' summary now looks at each draw's burning buildings only, not at every building. So
`scenebench fire` on the stage's own Beirut run takes 0.05 s for its 200 draws, not 0.22 s, with
the same output to the byte.

**On Beirut in the app,** with 20 fires at random within 1.5 km in the airport's wind (240° at 5.7
m/s):
- 73 (49–112) buildings are alight 2 hours after the blast;
- 92 (55–154) have caught by 12 hours, the seeds with them, and none is more likely than not to
  burn;
- every building timber-clad, 3,995 (3,622–4,296) catch.

These are the headless figures' pattern on the app's coarser district.

**Checks.**
- `FireSpreadTests`, Linux-safe:
  - the layer's chances match the ensemble's at the horizon, rise with the hours, and are none for
    a seed that has burnt out when asked for those alight;
  - draws in chunks are the same as all at once, and stop between chunks when asked;
  - seeds near the charge and at random in a band are as expected;
  - a run's judgement gives each side's broken glass and failed walls, and its surface heating
    seeds the fire.
- `FireAfterBlastTests`, in the app:
  - a quick estimate with no seeds asks for them;
  - a picked building sets 200 draws going, and the view is coloured;
  - a held slider gives 40 draws, and letting go gives the full 200;
  - a newer request replaces one under way;
  - the timber contrast, seeds near the charge and at random, and clicking a building on and off
    while picking;
  - loading the scene again lets the fire go.
- `InterfaceReviewFireTests` captures the section in light and dark and the view by the hour on
  Beirut (`BOMBCAD_INTERFACE_REVIEW` and `BOMBCAD_HYBRID_INPUTS`, in an optimised build:
  `swift test -c release -Xswiftc -enable-testing --filter InterfaceReviewFireTests`). The captures
  of 31 October are in `$BOMBCAD_DATA/fire-spread/app-review/fire/`.

**Not done here:**
- The layer's settings are not kept in the project, as the people estimate's are not.
- A map building's wood tag was not carried into the app's district, so there the timber contrast,
  or a building's construction set to timber, stood in for it. It is now
  ([below](#grey-for-no-chance-and-wood-tags-31-october-2026)).
- The far buildings of a hybrid district are not in the fire.

## Grey for no chance, and wood tags (31 October 2026)

The user's decisions of 31 October on stage 3's questions (emmettl/bombcad-work#38):
- **The section still starts with no seeds,** and asks for them. Nothing changed.
- **Buildings with no chance of burning are grey.** On the chance legend a chance of none was the
  ramp's first eighth, a strong yellow, the same as one up to an eighth. In stage 3's capture of
  Beirut at 12 hours nearly every building was that yellow, and the few at real risk were hard to
  see.
  - **The threshold:** no draw has the building caught by the hour shown, or with Alight then, no
    draw has it burning then. The chances are counts of draws, so below one draw and none are the
    same thing. One draw in 200 is yellow, as before.
  - **The grey** is the one the close calls give settled buildings (`EnvelopeDoubtColour`, sRGB
    0.78, 0.80, 0.82), the app's neutral for a building a judgement leaves alone, and the code the
    view already draws (`EnvelopeChanceColour.neutral`), so the shader is unchanged. The view is
    drawn the same in light and dark, and the legend's swatch is the same, outlined.
  - **The legend** gains a line under the ramp: "Grey: caught in no draw", or "burning in no draw"
    with Alight then, and the caption says so.
  - **The seeds** stay outlined in orange.
  - `FireSpread.Layer.colourCode` gives the code, Linux-safe, and the app takes it.
- **A map's wood tags make a building timber,** in New District, the Run tab's Map buildings and
  the headless district benches (`EnvelopeConstruction.fromMap`):
  - `building:material` of `wood`, `timber_framing`, `timber`, `wood_frame` or `log` (case aside)
    gives walls and roof of cross-laminated timber 0.105 m thick (three lamellae), the one timber
    construction the envelope damage model has. Its detail says the thickness is assumed.
  - So such a building burns from outside, its roof is not fire-rated, and its walls, roof and
    glass are judged as CLT's ([building envelopes](building-envelopes.md#buildings-from-map-data)).
  - **Before,** a wood tag said nothing: the building took the default concrete, and only
    `scenebench fire` made its cladding combustible. That stays by name, to reproduce earlier
    estimates: New District ▸ "Wood tags not read (earlier estimates)", or `--wood-tags ignore`
    headless.
  - **What it moves on Beirut: nothing.** Its map's 14,502 buildings carry no `building:material`
    tag of any kind (the file's tag keys counted), so no construction changes. `scenebench fire` on
    Beirut at 0.5 kt within 2.5 km on 4 m cells (14,169 buildings, 0 combustible), with the tags read
    and with `--wood-tags ignore`, gives the same quick estimate's look (53,530 sides' glass and
    14,169 buildings' walls and roof, the same values) and the same fire: caught 63–112–181 by 12
    hours, as stage 1 found, the same timeline and the same chances by building
    (`$BOMBCAD_DATA/fire-spread/wood-tags/`).
  - **Other districts:** none that the project has used carries a wood tag either. The made-up
    district's fixture tags seven buildings brick, none wood; the synthetic neighbourhood and the
    protective-design and surrogate cases' maps carry none. It is for districts whose wooden
    buildings are tagged so.

**In the app on Beirut** (InterfaceReviewFireTests, optimised build, the same 20 fires at random
within 1.5 km in the airport's wind; the fire's own figures unchanged, 92 (55–154) caught by 12 h):

| Caught by | Grey, of 9,708 | On the ramp |
|---|---|---|
| 1 h | 6,916 | 2,792 |
| 3 h | 6,758 | 2,950 |
| 12 h | 6,744 | 2,964 |

So the grey clears the city beyond the band the random fires are drawn from, but not the band
itself. With 20 fires a draw among the 2,880 buildings within 1.5 km (`scenebench fire`'s 4 m
district), 200 draws seed nearly every one of them at least once, and the fire through broken
windows reaches more. Within 1.5 km 75 buildings have no chance by 12 hours, 420 have up to 1%, and
1,817 more than 2%. Over the whole district, 3,013 of 14,169 have some chance, but only 75 more than
an eighth: the other 2,938 share the ramp's first eighth, the same yellow. They are real chances,
of a few percent, and the decision was to keep the scale for every chance above none, so they stay
yellow. Seeding by picking buildings or near the charge leaves the grey wherever the fire does not
reach. The captures, light and dark, are in `$BOMBCAD_DATA/fire-spread/app-review/fire-v2/`
beside stage 3's.

**Checks.** `FireSpreadTests` (the layer's colours: none is grey and one draw in 200 the ramp's
first eighth, at the blast only the seed coloured, a house beyond reach grey to the horizon, a
seed burnt out grey among those alight) and `EnvelopeConstructionTests` (each wood value gives
timber walls and roof, unread they say nothing; a laid-out district of three houses gives two
timber, combustible and with roofs not fire-rated, and the untagged one concrete, and all three
concrete with the tags unread).

## The chance of catching from a neighbour (31 October 2026)

The user's decision of 31 October (emmettl/bombcad-work#38): the map colours each building by its
chance of catching from a neighbour, leaving out the draws in which it was itself one of the
starting fires.

**Why.** With fires at random, re-drawn in each draw, nearly every building in the band they are
drawn from is a starting fire in a few of the 200 draws. Coloured by its chance of catching at all,
each of those has a chance of 1 in 200 or more from its own starting fires alone, so the band shows
where the random fires happened to land rather than where fire spreads.

**What is counted.** For each building, over the draws:
- `seedDraws`: the draws in which it was a starting fire. Buildings picked, near the charge or
  flagged by the surface heating are starting fires in every draw. A random one is a starting
  fire in the draws whose random fires picked it, found again from the draw's own numbers
  (`FireSpread.summary`).
- `neighbourChance`: of the other draws, the share in which it caught by the horizon. The layer
  keeps its ignition times over those draws (`Layer.fromNeighbour`), so the hour slider and Alight
  then work on it as on the chance at all.
- **The denominator is the draws in which it was not a starting fire,** not all 200. Over all 200,
  a building that was a random fire in many draws would look safer for it; over the others, the
  figure is the chance a fire reaches it given that it did not start there. A building that is a
  starting fire in every draw has none to count: its chance is none, and it is drawn grey under
  its orange outline.
- **The chance at all is kept** (`chance`), and is never below the chance from a neighbour.

**In the app.** Under the hour slider, **Caught** picks the measure:
- **From a neighbour**, the default: the legend's grey line reads "Grey: caught from a neighbour in
  no draw" ("burning from a neighbour in no draw" with Alight then), and the caption says the
  chance is over the draws in which the building was not itself a starting fire.
- **At all, seeds with it (earlier map)**: the map as it was, with its own legend line and caption.
- **The selected building's panel** says which it shows, "Caught from a neighbour by 2 h" or
  "Caught at all by 2 h", and, where the building was a starting fire, in how many of the draws
  and over how many the chance is taken.

**Headless.** `scenebench fire` and `blastmodel fire` write both chances per building (`--json`,
`--buildings-csv`) and print the map's bands, by `--map-chance neighbour` (the default) or
`caught` ([Running it](#running-it)).

**Beirut, headless** (`blastmodel fire`, 4 m cells, 14,169 buildings, 20 fires at random within 1.5
km in the airport's wind, 200 draws, the map at 12 hours; `$BOMBCAD_DATA/fire-spread/neighbour/`).
The 2,880 buildings within 1.5 km:

| Map's band | At all (before) | From a neighbour |
|---|---|---|
| Grey | 75 | 320 |
| Up to 1% | 420 | 344 |
| 1–2.5% | 834 | 821 |
| 2.5% to an eighth | 1,476 | 1,324 |
| Above an eighth | 75 | 71 |

Over the whole district 11,401 buildings are grey, against 11,156; 71 are above an eighth,
against 75. Beyond 1.5 km nothing changes, as no random fire starts there.

**What it does not do: clear the band.** A building within 1.5 km is a random fire in about 1.4 of
the 200 draws on average (2,193 of the 2,880 in at least one), so leaving those draws out moves
only the buildings whose whole chance
was their own starting fires: 245 turn grey. The rest have real chances of catching from a
neighbour, a few percent: each draw's 20 fires are scattered through the band, and their windows
carry fire to about 94 others (114 expected to burn within 1.5 km, the 20 seeds among them). Of
the 2,880, 2,489 still share the ramp's first eighth. Clearing it further
is a question of the ramp, not of the measure: the options of the last section stand (a grey
threshold above none, or a ramp finer at the low end).

**Fires picked by hand: the map does not move but for the seeds.** With the 21 buildings within 40
m of the district's most exposed building (723 m east, 584 m south of the charge) alight, and no
random fires: the 14,148 other buildings have the same chance either way, to the draw. Only the 21
seeds change: from certain, above an eighth, to grey under their outlines. The district's greys
are 13,821 from a neighbour, 13,800 at all; above an eighth, 89 and 110.

**In the app on Beirut** (InterfaceReviewFireTests, optimised build, the same 20 fires at random
within 1.5 km in the airport's wind):

The district's 9,708 buildings grey, by the hour:

| Caught by | At all (before) | From a neighbour |
|---|---|---|
| 1 h | 6,916 | 7,408 |
| 3 h | 6,758 | 7,040 |
| 12 h | 6,744 | 7,018 |

The 2,862 buildings within 1.5 km at 12 hours, as headless:

| Map's band | At all (before) | From a neighbour |
|---|---|---|
| Grey | 88 | 362 |
| Up to 1% | 470 | 397 |
| 1–2.5% | 911 | 877 |
| 2.5% to an eighth | 1,374 | 1,210 |
| Above an eighth | 19 | 16 |

The fire itself is as before: 92 (55–154) caught by 12 hours. In the view the port's warehouses
and the isolated buildings round the basin, which only their own random fires had coloured, turn
grey; the dense blocks east and south stay yellow.

The captures, light and dark, and the view by the hour both ways (`beirut-neighbour-*` and
`beirut-caught-*`), are in `$BOMBCAD_DATA/fire-spread/app-review/fire-v3/`.

**No default but the map's changed.** The fire, its draws and its figures (alight, burnt out,
caught, more likely than not) are the same; only which chance colours the map, and the panel's
line, follow the decision.

**Checks.**
- `FireSpreadTests`, Linux-safe: over random draws, each building's starting-fire draws are those
  the draws' own numbers pick, its chance from a neighbour is its catches in the other draws over
  their number, and the two together give its chance at all. Two houses far from the rest are
  coloured by their own starting fires at all and grey from a neighbour. A seed picked by hand has
  no draw to count and is grey, and every other building's colour is the earlier map's.
- `FireAfterBlastTests`, in the app: the default measure, the seed grey under its outline, the
  other buildings coloured as at all with a seed picked by hand, and at random never above the
  chance at all.
- `InterfaceReviewFireTests` prints both maps' greys and bands within 1.5 km.

## The literature, and why this model

Models of fire spreading through a city, as surveyed for this step (31 October 2026):

- **Hamada (1951)** and its later forms. The Japanese standard for decades: the time for fire to
  cross one building and its gap, downwind, sideways and upwind, by wind speed, building size,
  gap and the share of fire-resistant buildings. It is fitted to the fires in Japan's dense
  wooden cities. [FireBench](https://github.com/wirc-sjsu/firebench) (Apache-2.0) implements two
  forms, with an elliptic front for the wind.
  - **Not chosen:** it gives a district's mean speed, not a building's fire. Every gap is
    crossed, only slower, so there is no critical separation. It has no openings, and so nothing
    for the broken glass, and nothing for buildings that do not burn from outside, which is most
    of a modern city.
  - **Kept:** as a cross-check of spread rates in wooden districts.
- **Himoto and Tanaka (2008),** physics-based. Each building is a compartment fire model, heated
  by radiation and plumes from its neighbours, with firebrands added by Nishino, Himoto and
  Tanaka (2010). It was judged against the Sakata fire of 1976, 1,774 buildings and 22.5 ha in
  about half a day.
  - **The next step,** if a stage 2 is wanted: it would make the openings and the fire inside
    each building physics rather than chances.
  - **Not now:** its paper is not open here (Fire Safety Journal), and it needs each building's
    rooms and openings, which a map does not give.
- **Lee, Davidson and colleagues.** Their review (Lee, Davidson, Ohnishi and Scawthorn, Earthquake
  Spectra 2008) sets out the field. Lee and Davidson (2010) give a physics-based building-to-building
  model in Himoto–Tanaka's line. Not open here.
- **Post-earthquake loss models: HAZUS** (FEMA's fire following earthquake) and Scawthorn's.
  Ignition rates are regressed on ground shaking per floor area, spread follows a Hamada-type
  rate, and suppression is modelled.
  - **Their ignition regressions are what BombCAD lacks.** No blast analogue was found: no
    regression of ignitions on overpressure or damage.
- **The GNS / Victoria University of Wellington model,** chosen.
  - **Open.** Every rule and parameter is in reports on the Fire Service's site.
  - **Physics-based rules.** Radiation from a face of known size against ignition fluxes, sparks
    by wind, brands, openings and roofs, each with a chance.
  - **Built for what follows a disaster.** Its post-earthquake broken windows are what the
    quick estimate's broken glass gives. It reaches non-combustible buildings through their
    openings, which matters for concrete and stone. Its critical separations are tabulated, so
    they can be checked to the number.

Historical fires after a blast, looked for a case to judge against:

| Event | What is open | Use here |
|---|---|---|
| Beirut, 4 August 2020 | BombCAD's own district and charge. GEER's and UN-Habitat's surveys class blast damage, with no fire damage recorded. "By the next morning, the main fire that led to the explosion had been extinguished" (Wikipedia, citing the press) | **Judged**, qualitatively (above) |
| Halifax, 6 December 1917 | Wooden Richmond; fires from overturned stoves and lamps burned whole blocks of the North End; a blizzard the next day helped put them out. About 1,630 homes destroyed by blast and fire together | No district (the city was rebuilt), and no map of what burned found open. The case for timber, with the contrast run below as its stand-in |
| Texas City, 16 April 1947 | Fires through the port's warehouses and refineries after the Grandcamp's ammonium nitrate | Industrial fires of fuel and stores, not spread between buildings |
| Tianjin, 12 August 2015 | Fires in the chemical warehouses before and after the explosions | The same |
| Napier, 3 February 1931 (an earthquake) | The Wellington model's own calibration: more than 400 buildings, 11 blocks, almost 24 hours (Report 80 §1) | No district here; GNS's Napier report is listed in [Data wanted](data-wanted.md) |
| Sakata, 29 October 1976 (no blast) | 1,774 buildings, 22.5 ha, from late afternoon to the next morning | Himoto and Tanaka's case. No district here |

## Limitations

- **Illustrative throughout.** These are the Wellington model's rules on BombCAD's buildings. Its
  chances were set for Wellington's timber houses and steel roofs, and for an earthquake's broken
  windows, not a blast's.
- **The seeds.**
  - The surface heating flags a surface that passed a test threshold. It does not follow heat
    through windows onto contents, and on concrete it flags nothing.
  - Ignitions from gas, stoves and wiring in the wreckage, the usual cause after an earthquake or
    a blast, are not modelled. They are the user's to place.
- **Buildings.**
  - One fire each, with no spread inside from room to room or floor to floor beyond its growth
    and its 12 m band.
  - Construction, use, glazing and fire load are from map tags where there are any, assumed
    otherwise, and today's map is not the city's at the time of the event.
- **Not modelled:**
  - no firefighting, and no change of wind;
  - no vegetation, vehicles, ships, or stores of fuel and goods;
  - no slope;
  - no fire whirl or mass fire that makes its own wind;
  - no smoke.
- **Collapse.** Only the walls' chance of heavy damage opens a building. No collapse is predicted
  (see [standing](standing.md#collapse)).
- **Geometry.**
  - Faces are the buildings' cells' rectangles; the flux is at the nearest point, with no shading
    by buildings between.
  - Diagonal neighbours see the source's full projected width.

## Future work

- **The app's next steps** ([The app](#the-app-stage-3-31-october-2026)): the layer's settings kept
  in the project, a map building's wood tag carried into the app, and the fire beyond a hybrid
  district's hand-over.
- **Ignitions that are not illustrative (stage 4).** Heat through broken windows onto contents,
  from the thermal receivers behind each façade's glass. A damage-driven rate of ignitions, if a
  blast record or analogue can be found, as HAZUS regresses earthquake ignitions on shaking.
- **Himoto and Tanaka's physics (stage 5).** For the openings and the fire inside each building,
  once their paper and a case with times are in hand.

## Sources

- W. J. Cousins, D. Heron, S. Mazzoni, G. Thomas and D. Lloydd, *Estimating Risks from Fire
  Following Earthquake*, New Zealand Fire Service Commission Research Report 27 (GNS client report
  2002/60), 2002.
- D. Heron et al., *Modelling Fire-Spread In and Around Urban Centres*, New Zealand Fire Service
  Commission Research Report 44, GNS, December 2003.
- G. Thomas, D. W. Heron and G. Baker, *Implementation of Urban Fire Spread Model as NZFS Tools*,
  New Zealand Fire Service Commission Research Report 80 (GNS client report 2007/249), March 2008.
- M. Hamada, *On fire spreading velocity in disasters*, Sagami Shobo, Tokyo, 1951 (in Japanese).
  As implemented in FireBench (WIRC, San José State University, Apache-2.0),
  `ros_models/surface_for_urban.py`.
- K. Himoto and T. Tanaka, "Development and validation of a physics-based urban fire spread
  model", *Fire Safety Journal* 43 (2008) 477–494. H. Nishino, K. Himoto and T. Tanaka, on
  firebrand spotting and the Sakata fire, 2010.
- S. Lee, R. Davidson, N. Ohnishi and C. Scawthorn, "Fire following earthquake: reviewing the
  state-of-the-art of modeling", *Earthquake Spectra* 24 (2008) 933–967.
- FEMA, *Hazus Earthquake Model Technical Manual*, the chapter on fire following earthquake.
- EN 1991-1-2:2002, *Eurocode 1: Actions on structures, Part 1-2: Actions on structures exposed to
  fire*, Annex E (fire load densities, Table E.4; rates of heat release, Table E.5).
- K. Kawagoe, *Fire behaviour in rooms*, Building Research Institute Report 27, Tokyo, 1958; D.
  Drysdale, *An Introduction to Fire Dynamics*, Wiley: the ventilation factor and the
  configuration factor.
- Beirut: the GEER-070 report (2021) and UN-Habitat's rapid building assessment (2020), as in
  [Beirut 2020](beirut-2020.md); OLBA's METARs for 4 August 2020 (Iowa Environmental Mesonet's
  archive): 041500Z 24011KT and 041600Z 23010KT. Wikipedia, "2020 Beirut explosion", for the fire
  out by the next morning.
- Halifax: Wikipedia, "Halifax Explosion", citing J. Kitz and J. Payzant, *December 1917:
  Re-visiting the Halifax Explosion* (2006).
