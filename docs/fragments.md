# Fragments flown alongside a run

A cased charge's fragments, and passive tracers, flown through the blast one way: the air pushes
them, they do not push back. The app draws them over a run as it goes; headless runs export them.
The model can run on this Mac's CPU or on another Mac, fed the air a frame at a time over SSH, which is what it was built to try: a live one-way consumer, the first
of the separable models in [Distributed computing](distributed-computing.md#separate-models-on-separate-machines).

**Standing: approximation when the casing's thickness and diameter are given, illustrative
otherwise.** With the casing's dimensions, the masses and their number are Mott's, the launch
speed Gurney's and the drag measured, the recognised method; it reproduces Cooper's worked
examples and is within a factor of 1.36 of his counted bomb fragments ([below](#against-coopers-data)).
No arena test of speeds or ranges has been compared. Without them the number of fragments is
chosen, not derived, and the result is illustrative.

```bash
swift run -c release BombCAD run street.bombcad --fragments casing.json --consumer my-mac.local --usd street.usda --vdb street.volumes --fragment-results impacts.json
```

`--consumer local` (the default) runs the fragments on this Mac's CPU. The description is JSON;
any field left out takes its default:

```json
{
  "casingMass": 50,
  "count": 2000,
  "casing": "cylinder",
  "axis": [0, 0, 1],
  "spread": 0.25,
  "gurneyVelocity": 2440,
  "wallThickness": 0.012,
  "innerDiameter": 0.25,
  "explosive": "TNT",
  "fragmentDensity": 7850,
  "tracers": 500,
  "tracerRegion": {"min": [22, 21, 0.5], "max": [38, 37, 6]},
  "seed": 1
}
```

## The model

- **Masses** follow Mott's distribution, P(mass > m) = exp(−√(m/μ)). Given the casing's wall
  thickness t and inside diameter d (`wallThickness`, `innerDiameter`, in metres), μ is Mott's,
  M_K = B t^(5/6) d^(1/3) (1 + t/d) in pounds and inches, the mean mass 2 M_K², and the real
  number of fragments the casing's mass over it (Cooper's §27.3; his t^(5/16) is a misprint, as his
  Example 27.7 shows). B is the explosive's for mild steel (Cooper's Table 27.2), or
  `mottCoefficient`. Each fragment flown then stands for as many real ones as share the casing's
  mass, its weight in the results. Without the dimensions, `count` fragments share the casing's
  mass and each stands for one. `massExponent` (½, Mott's) generalises the form to
  exp(−(m/μ)^β); 1 is Grady's exponential, which fits Cooper's bomb better (below). The largest of
  2,000 from a 50 kg casing is about 0.7 kg.
- **The explosive** (`explosive`: TNT, Composition B, Composition A-3, Cyclotol (75/25), H-6 or
  Tetryl) sets √(2E) and B together, from Cooper's Tables 27.1 and 27.2; `gurneyVelocity` and
  `mottCoefficient` override them.
- **Launch speed** is the Gurney equation's, √(2E) / √(M/C + ½) for a cylinder and
  √(2E) / √(M/C + ³⁄₅) for a sphere, M the casing's mass and C the charge's; √(2E) is 2,440 m/s
  for TNT. A cylinder sprays its fragments out round its axis within `spread` of square to it, a
  sphere evenly. They start at the charge's radius.
- **Flight** is gravity and drag from the local air, ½ ρ C_d A |u − v| (u − v): the blast's
  density and wind act on each fragment. A fragment is taken as a tumbling cube, whose mean
  presented area is a quarter of its surface, 1.5 e². C_d is the measured curve for tumbling
  fragments on that area, Hansche and Rinehart's for tumbling cubes from Mach 0.5 to 3.5, as Moxnes
  et al. (2017) restate it: 0.82 at Mach 0.5, held below (their cubes' drag fell further there),
  rising to 1.25 at Mach 1.25, down to 1.1 at Mach 3 and 1.1 beyond. Drag is integrated exactly for a rate held over each step, so the stiff
  drag on the smallest fragments does not limit the step.
- **Tracers** are massless and go with the air.
- **Impacts** are recorded where a fragment first meets the ground, a rigid block or the
  structure's starting outline: the point, time, speed and energy. A fragment does not load what
  it hits, and the structure's outline does not move. Every independent structure contributes
  its starting regions; impacts in multiple-structure scenes include the stable `objectID`.
  The optional owner table and impact ID preserve decoding of older single-structure streams
  and results. Beyond the air's domain the air is still, and fragments still in flight when the
  run ends fly on in still air until they land (up to five minutes more), so the results count
  every fragment's landing.

## In the app

Turn on **Cased charge** in the Run tab's Fragments section. It starts with a casing a tenth of
the charge's mass, 2,000 fragments and 300 tracers across 16 m round the charge, and sets the
casing's mass, the number of fragments and tracers, and the casing's shape; the launch speed it
gives is shown. **Casing metal** is steel (Mott's distribution) or cast iron (Grady's exponential,
`massExponent` 1, at 7,200 kg/m³), as [below](#against-coopers-data). **Casing dimensions** sets
the wall's thickness and the inside diameter. Turned on, they start from a casing that holds the
charge (TNT at 1,600 kg/m³, a cylinder twice as long as wide, or a sphere) and weighs the casing's
mass as a thin wall. With them the fragments' number and sizes follow Mott's scaling, a caption
gives how many there are and their mean mass, and the fragments' standing becomes an
approximation. `BombCAD run --fragments casing.json --casing 0.006,0.25,castIron` does the same
for a headless run, in metres. The description is saved with the project (as `fragments.json`), takes effect
from the next run, and is undone and redone with the layout's edits (⌘Z). With Macs set for sweeps in Settings, **Fly on** sends the fragments to
the one chosen, over a connection kept open between runs and shared with any other model run
there; should that Mac drop, they carry on here.

During a run the view draws them over the blast as dots of a fixed size on screen, whatever their
true size: fragments in flight dark when slow and white-hot at their launch speed, tracers in cyan,
and where fragments landed, from yellow at a joule to dark red at ten megajoules. Under Display,
each kind can be hidden and the dots' size set. A line under the section counts the fragments in
flight and landed, and the hardest impact.

**Keep Run** keeps the fragments with the run: what was flown, its launch speed and every impact.
Compare gives a line for each run that flew them, the run's CSV lists the impacts (time and
energy in joules, by fragment and surface), and **Use this run's inputs** brings its casing back.
They do not act on the air, so they are no part of the run's input fingerprint.

![Fragments, tracers and landings over the street canyon's blast at 24 ms, as the app draws them](street-fragments-app-24ms.png)

**The air is untouched.** The app takes a frame at the end of the first batch past each
millisecond, and one at the end, rather than stopping the run at fixed times, and with fragments
on holds a batch to about a millisecond of simulated time by taking fewer steps, never shorter
ones; the tests check that the air's gauges and the structure's response are the same to the last
bit with fragments on or off. The cost is that the frames fall where batches end, which follows
the playback's timing, so the fragments in the app differ a little from one run to the next. For a fragment study that repeats exactly, use `BombCAD run
--fragments`, which stops at fixed frames.

`blastbench snapshot --fragments casing.json` flies them alongside an offscreen snapshot, as the
view draws them (the figure above).

## Running alongside the blast

At each frame, the run cuts out a block of the air (`AirSlice`) around the particles, density,
velocity and pressure as 16-bit floats, and sends it to the consumer (`FragmentConsumer`), which
flies the particles from the last frame's air to this one's, interpolating in space and between
the two in time, and reports where they have got. The block for frame *k* is the report after
frame *k* − 5 grown by as far as the fastest particle (or, for tracers, the blast's wind, taken as
up to 2.5 km/s) can go in the frames between, and thinned to every second or third cell above a
million samples.

The run may get up to four frames ahead; then it waits, through a gate in `SimulationModel`'s run
loop that holds the next batch without blocking the main thread. Because each block comes from a
report always in by then, the air sent, and so the result, do not depend on how the two sides keep
time: the consumer on another Mac gives the same result as on this one, to the last bit.

On another Mac, the consumer is a session of `BombCAD worker` (see
[Sharing a sweep](run-comparison.md#sharing-a-sweep-with-another-mac)), over the same SSH
connection: the worker protocol (since version 2) carries each block as a raw binary payload, and the
trajectories come back the same way.

Frames are the export's (`--frame-interval`, 1 ms by default). Without a structure the run stops
at each frame, ending a time step there: every millisecond, in the street on the medium grid,
1,608 steps instead of 1,527 and a near-façade peak 1% lower; every 2 ms, 1,562 steps.

## Measured

The street canyon on the medium grid (8.4 million cells, 0.17 s, 100 kg), a 50 kg casing, frames
every millisecond, the Mac Studio (M4 Max) running the blast and either itself or the CI Mac mini
(M4) the fragments, over Thunderbolt:

| Particles | Consumer | Air sent | Rate | Run waited | Run | Same result |
|---|---|---|---|---|---|---|
| 2,000 fragments, 500 tracers | This Mac | 1.63 GB, 171 frames | about 200 MB/s | 0 s | 6.6 s | |
| 2,000 fragments, 500 tracers | The mini | 1.63 GB | about 200 MB/s | 0 s | 8.4 s | Yes |
| 50,000 fragments, 10,000 tracers | This Mac | 1.59 GB | 203 MB/s | 1.66 s of 7.84 | 8.1 s | |
| 50,000 fragments, 10,000 tracers | The mini | 1.59 GB | 205 MB/s | 1.43 s of 7.79 | 9.7 s | Yes |

Against 3.9 s for the run without fragments. The Studio was heavily loaded by other work at the
time, so the run times are rough; the mini's extra second or two is connecting and sending it this
build. The fragments are cheap: one CPU core keeps up with a few thousand, and only around 60,000
does the run wait for the consumer, on the mini or here. So this consumer gains nothing by moving,
as [expected](distributed-computing.md#separate-models-on-separate-machines); it exercises the
streaming a costlier consumer would need. The Thunderbolt link carried the air at about 200 MB/s
without the run waiting for it.

![Fragments outrunning the blast in the street canyon at 24 ms, rendered in Blender](street-fragments-24ms.png)

At 24 ms the blast still fills the street while the fragments (dark, drawn enlarged) have outrun
it past the blocks; the tracers (light) are carried in it. Rendered in Blender 5.2 with Cycles from
the export, the fragments enlarged by a geometry-nodes modifier: at true size they are millimetres
to centimetres across.

## Against Cooper's data

Cooper (1996, ch. 27) gives the data digitised in `Fixtures/Cooper1996/`: B for mild steel
cylinders and 13 explosives (Table 27.2), √(2E) for 25 (Table 27.1), one counted fragmentation
test (Fig. 27.13, a cast-iron aerial bomb from Strømsøe and Ingebrigtsen, its geometry not
given), and Hoerner's drag against Mach for idealised shapes (Figs. 27.15–27.18). Steel
cylinders and the common military explosives, then; nothing for other metals, spheres,
pre-formed fragments or improvised casings. `FragmentCloudTests` check the first two.

- **His worked examples.** A 1 in steel cylinder with a quarter-inch wall round Detasheet
  (B 0.08) gives M_K 0.0315 and 140.6 fragments, of them over 10, 5, 1 and 0.1 g 1.3, 5.0, 31.7
  and 87.7, his 1, 5, 31 and 87, rounded down; Gurney for M/C 6.39 and √(2E) 2,357 m/s gives his
  0.898 km/s.
- **The counted bomb.** Mott's form fitted to the points, N₀ 686 and μ 0.252 g, is within a
  factor of 1.36 (rms) across 0.13 to 8.8 g: too many of the smallest and the largest, too few
  in between. The generalised form fits with β 0.94 within 1.12, so set `massExponent` 1 for cast
  iron and other brittle casings; Mott's ½ stays the default, as fitted to steel shells.
- **Velocity decay.** The distances steel cubes launched at 1,500 m/s fly to half their speed,
  and until they carry less than 79 J (the hazardous-fragment energy), at sea level:

  | Drag | 1 g | 11 g | 100 g |
  |---|---|---|---|
  | The previous law (0.9, 1.3, 1.1) | 26.5 m, 48 m | 58.8 m, 228 m | 123 m, 721 m |
  | The measured tumbling curve (now the default) | 26.7 m, 49 m | 59.4 m, 234 m | 124 m, 756 m |
  | Hoerner's cube face-on, on e² | 27.0 m, 51 m | | |
  | Hoerner's cube edge-on, on e² | 40.6 m, 75 m | | |
  | Hoerner's cube face-on, on 1.5 e² | 18.0 m, 34 m | | |

  Hoerner's curves are for a fixed orientation, and turned into a tumbling fragment's drag they
  span 30% shorter to 50% longer, depending on the area and orientation assumed. The measured
  tumbling curve needs no such choice, so it is now the default; it moves the distances by under
  5%.

## Hazard

Fragments are judged as the US explosives safety standards judge them (`GroundHazard`):

- **Hazardous fragments** strike with 79 J (58 ft-lb) or more, and the **hazardous fragment
  distance** is where they fall below one per 55.7 m² (600 ft²), a 1% chance of one striking a
  person's 0.56 m² (6 ft²): DoD 6055.09-M (now DESR 6055.09) and DoD 4145.26-M §C5.8.1.3, as FAA
  Guide 437.53-1 (2011) restates it. Fragments of 14.9 J (11 ft-lb) or more, FAA's threshold for
  serious injury, are counted too.
- **In flight.** The density is the one a person standing there meets: on a surface across the
  fragments' paths (DDESB Technical Paper 12, Zaker 1975, as the explosives safety seminars quote
  it), not where they land. As each fragment flies, the spheres it crosses round the charge (the
  first a metre out, each after a tenth further) are counted if it is hazardous and within 10° of
  the horizontal there (`FragmentCrossings`); a direction's distance is the furthest sphere it
  crosses at one per 55.7 m² or more of that band.
- **On the ground.** Landings are binned in rings (the same steps) and directions too, for where
  fragments come down; fragments stopped by a structure or block are counted apart, as they do not
  reach the open ground behind it.
- The **hazard distance** is the larger of the two, in eight directions. Until 17 October it was the
  ground's alone, which reads a sixth to a fifteenth of DoD's distances ([below](#against-dods-distances)).
- **Sampling.** The density at a far sphere or ring rests on the few fragments flown that cross or
  land there. When fewer than ten set the distance, the summary says so: fly more fragments
  (`count`) and the distance settles.

**An example**: 100 kg of TNT in a 150 kg steel cylinder (12 mm wall, 250 mm bore, its axis
level along x), 1 m above open ground. Mott gives 18,400 fragments of a mean 8 g, launched at
1,725 m/s. With 200,000 flown, 44% of the landings are hazardous and the furthest hazardous one
lands 1,341 m out. The hazardous fragment distance is 172 m side-on to the casing, where its
spray goes, in flight; on the ground alone, 50 m. DoD's default for 100 kg in the open, a
policy distance for items not tested, is 294 m (DoD 4145.26-M Table AP2.T2).

Shown in the summary printed, in `--fragment-results` (`hazard`: the cells, the directions'
distances, the shares hazardous and injurious, the furthest hazardous landing), in the USD scene
as a ring of points (`/Scene/FragmentHazard`), and in the app (below).

**In the app**, once a run ends, the fragments still in flight are flown on to land, and the line
under the Fragments section gives the hazardous fragment distance. Under Display, **Hazardous
fragment distance** draws it on the ground: a red circle at the distance, and a lighter arc in
each direction that falls short of it, at its own distance. A kept run keeps the hazard: Compare
gives the distance, and the CSV a row for it and for each direction.

The same criteria judge [debris](structural-model.md#debris-as-a-hazard) where a run makes it (rubble particles,
`StructureModel.rubbleParticles`), flown on from where the run leaves it (`DebrisResult`,
`BombCAD run --debris-results`), and the [glass of envelope buildings](building-envelopes.md#one-way-damage-single-degree-of-freedom)
is graded by GSA's and ASTM's window hazard levels.

## Against DoD's distances

DoD 4145.26-M (2008) lists hazardous fragment distances for single items in the open, determined
by DDESB's test protocol (Table AP2.T3): 126.5 m for a 155 mm projectile and 204.2 m for a 500 lb
general-purpose bomb, among others. With the items described only by public overall figures (a
155 mm projectile as 6.6 kg of TNT in some 36 kg of steel; a 500 lb bomb as 87 kg of filler in
some 130 kg), lying level half their diameter off the ground, their fragments flown in still air
(`blastbench fragment-throw`, 100,000 flown, 13 s):

| Item | Wall, bore | In flight | On the ground | DoD | Ratio |
|---|---|---|---|---|---|
| 155 mm projectile | 38 mm, 138 mm (the casing helper's) | 54.8 m | 9.8 m | 126.5 m | 0.43 |
| | 20 mm, 115 mm | 80.2 m | 13.1 m | | 0.63 |
| | 12 mm, 131 mm | 97.0 m | 19.2 m | | 0.77 |
| 500 lb bomb | 25 mm, 326 mm (the helper's) | 117.4 m | 19.2 m | 204.2 m | 0.57 |
| | 15 mm, 243 mm | 156.2 m | 23.2 m | | 0.77 |
| | 10 mm, 253 mm | 171.9 m | 30.9 m | | 0.84 |

Each distance is set by 700 to 2,200 fragments flown. BombCAD falls short of DoD's by between a
sixth and a half, closest with walls near the items' own; the wall, which sets Mott's mean mass
and so how many fragments there are, decides it, and the items' real walls are not public. The
ground's landings alone are a sixth to a fifteenth of DoD's. What may account for the rest: DDESB
counts fragments from the whole item, nose and base too, where this casing is a plain cylinder
spraying within 0.25 rad of square to its axis; it counts fragments bouncing on and skipping off
the ground, which stop here where they land; and its distances carry its own margins. So the
hazard distance is an approximation, on the unsafe side, by a factor of up to 2.3. No arena test's
fragment-by-fragment data has been compared ([wanted](data-wanted.md#to-fetch)).

## What fragments do to what they strike

Each fragment that strikes a block or a structure whose material the scene knows is judged there,
one way (`FragmentPenetration`, `FragmentTarget`), by the standard empirical methods:

| Target | Method | Gives |
|---|---|---|
| Concrete | UFC 3-340-02 §4-60: Equations 4-198 and 4-199 (the modified NDRC form, x/d = 2√G or G + 1) for UFC's standard fragment of the same weight (d = 0.695 W^(1/3), in and oz), 4-202 for the strength, Table 4-16's 0.7 for mild steel | The depth into thick concrete; the thicknesses that prevent perforation (4-204) and spalling (4-207); the speed beyond (4-205, 4-206) |
| Masonry | The same, at the masonry's compressive strength | As concrete: no method of its own was found |
| Steel and aluminium plates | Project THOR (Technical Report 47, 1961), with the fragment's mean presented area and its angle to the plate | The speed just to perforate and the speed beyond |
| Glass | Kim et al. (2025): steel balls always broke 5 mm annealed glass at 0.084–0.087 N s of momentum, and neither did at less | Broken and holed past 0.085 N s, not slowed |

Concrete and masonry are judged nose-on, as UFC designs (the standard fragment is the critical
shape); THOR's fragments were compact cubes and short cylinders, like these. UFC's own steel plate
equation (5-65) is kept as a check. Each impact carries its outcome (`penetration`: stopped,
spalled or perforated, the depth, the thicknesses, the speed beyond), and an envelope's impacts
name the building and the pane.

**Against the methods' own examples.** UFC's Examples 4A-10 to 4A-12 are reproduced within 1%:
30 oz at 3,500 fps is stopped by 18 in of 4,000 psi concrete (T_pf 15.2 in), 20 oz at 4,700 fps
goes through 12 in of 4,500 psi keeping 0.55 of its speed, and an armour-piercing 40 oz at
3,000 fps spalls 19 in of 5,000 psi (T_sp 20.3 in). For a 1 oz fragment on a quarter-inch mild
steel plate, UFC's Equation 5-65 and THOR give speeds to perforate of 1,154 and 1,130 fps, and
speeds beyond within 10% of each other. No penetration test has been compared
([wanted](data-wanted.md#to-fetch)).

**Envelope buildings.** A fragment that holes a pane breaks it then, if before the blast does,
and its glass is pushed in from rest by the load that follows ([glazing hazard](building-envelopes.md#one-way-damage-single-degree-of-freedom));
the inside fills through it from then. Each building's damage counts the panes fragments broke,
those before the blast reached them (its load first past a hundredth of its peak), and the
fragments striking its walls and roofs, spalling them and going through, judged at the
construction's thickness, 30 MPa for concrete and 8 MPa for masonry. In the app's envelope
damage line, `--envelope-damage` and its JSON.

**Holed panes vent.** With **Vent broken glazing** (building-envelopes.md), a pane a fragment
holes also opens in the air when it is holed, and the blast enters through it. When is known
before the run: the same fragments (the description's seed) are flown first in still air
(`FragmentCloud.paneHoles`), and each pane they hole opens on the step the run's clock reaches
the time (`BlastSolver.setEnvelopePaneHoles`), through the same path as glass that breaks. So the
air is the same however the run is batched and however the fragments' consumer keeps up with
it. Ahead of the blast the air is still, and a fragment that holes a pane before the blast
reaches it flies mostly ahead of it; behind the shock the wind would carry it a little faster.
A cased kilogram 5 m in front of a glazed window (`FragmentVentingTests`, 0.25 m cells) holes
its pane at 3.15 ms, which opens on that step; the blast alone breaks the glass at 13.0 ms. By
20 ms the room's mean has peaked at 1.47 kPa through the hole (past 1 kPa at 15.6 ms), against
75 Pa with the glass left to the blast, and the run is the same to the bit however its steps
are batched. `FragmentCloud.envelopeHoles` gives every hole the same flight makes through envelope
walls, roofs and panes, with its time, place and area, for the air to open them: a hole is the
fragment's mean presented area (times the real fragments it stands for), for want of a cited
hole size (UFC 3-340-02 §4-60.1 describes craters wider than the fragment but gives no size), so
the open area is a lower bound.

**In the app** a strike on a judged target is drawn larger than a landing: grey where the
fragment stopped, amber where it spalled the far face, crimson where it went through. The
summary printed counts them (`struck targets: … stopped, … spalled, … through`).

## Output

- **The USD scene** (`--usd`) gains `/Scene/Fragments` and `/Scene/Tracers`, Points prims whose
  positions follow the frames; a fragment's width is its edge. Blender imports them as point clouds.
- **`--fragment-results`** writes the impacts, masses, counts and [hazard](#hazard) as JSON,
  without the trajectories, which are in the scene; `/Scene/FragmentHazard` rings the hazard
  distance.
- The summary printed gives the fragments landed on each surface and the highest impact energy,
  and how much air was sent and how long the run waited.

## Limitations

- Masses checked against one counted bomb and Cooper's examples; launch speeds and ranges against
  no arena test. The spray's angles are rough, and every fragment is a tumbling cube of the
  casing's steel.
- Mott's B is for mild steel cylinders; other metals, spheres, pre-formed and improvised casings
  need their own `mottCoefficient` and `massExponent`, which nothing here supplies.
- One way: fragments do not load the structure or the air, and the structure they can hit is its
  starting outline.
- The casing's own energy is not taken from the air's: the blast is the bare charge's.
- No break-up and no ricochet; a fragment stops where it first hits, through or not, and does
  not load or hole what it hits (the structure's outline and the air are unchanged). Its
  penetration is judged by design methods for nose-on impact; masonry borrows concrete's.
- With **Vent broken glazing** the holes come from the fragments flown before the run in still
  air (below), not from the run's own fragments, which the blast's wind carries a little faster.
- Only the coarse grid's air, also where refinement sharpens the shock.
- In the app, frames fall at the ends of batches, just past each millisecond, so its fragments vary
  a little from run to run (above).
- A kept run keeps the fragments' impacts, not their paths.
- The hazard distance falls short of DoD's test-derived distances for two items by a sixth to a
  half ([above](#against-dods-distances)); no ricochet, no fragments stopped by people or
  vegetation, and the spray of a plain cylinder, without nose or base.

## Sources

- R. W. Gurney, *The initial velocities of fragments from bombs, shells and grenades*, BRL Report
  405, 1943.
- N. F. Mott, Fragmentation of shell cases, *Proceedings of the Royal Society A* 189 (1947) 300–308.
- P. W. Cooper, *Explosives Engineering*, Wiley-VCH, 1996: Gurney's equations and constants
  (Table 27.1), Mott's B (Table 27.2), Fig. 27.13's counted fragments, Hoerner's drag curves.
- J. F. Moxnes, Ø. Frøyland, I. J. Øye et al., Projected area and drag coefficient of high
  velocity irregular fragments that rotate or tumble, *Defence Technology* 13 (2017) 269–280,
  doi:10.1016/j.dt.2017.03.008: the projected area of a tumbling body (a quarter of its surface)
  and Hansche and Rinehart's measured drag of tumbling cubes, Mach 0.5 to 3.5.
- UFC 3-340-02, *Structures to Resist the Effects of Accidental Explosions*, US Department of
  Defense, 2008: §2-17.5 (the standard fragment), §4-60 and Examples 4A-10 to 4A-12 (concrete),
  §5-49 (steel plates).
- Project THOR, *The resistance of various metallic materials to perforation by steel fragments*,
  Technical Report 47, Johns Hopkins University, 1961, its constants as T. Deniz, *Ballistic
  penetration of hardened steel plates*, MSc thesis, Middle East Technical University, 2010,
  Tables 3.2 and 3.3, reproduces them.
- S. Kim, J.-H. Mun, S. Park, C. Choi and S. Hong, Damage limit velocity and fracture patterns in
  single glass plates impacted by steel balls of varying diameters, *Applied Sciences* 15 (2025)
  386, doi:10.3390/app15010386.
- DoD 4145.26-M, *DoD Contractor's Safety Manual for Ammunition and Explosives*, 2008 (open on
  epa.gov): §C5.8 and Tables AP2.T2 and AP2.T3, the hazardous fragment distances.
- T. A. Zaker, *Fragment and Debris Hazards*, DDESB Technical Paper 12, 1975: the density on a
  surface normal to the fragments' rays, and a person's 6 ft², as quoted in DDESB's seminar
  minutes (the paper itself not read here).
- FAA, *Calculation of Safety Clear Zones for Experimental Permits*, Guide 437.53-1 (2011): the
  hazardous fragment's 79 J and 600 ft² from DoD 6055.09-M, and its own 11 ft-lb.
- D. E. Grady, *Fragmentation of Rings and Shells*, Springer, 2006: the exponential form.
