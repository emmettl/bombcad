# Thermal radiation from the fireball

The fireball's radiant heat on the ground and the scene's faces, reckoned frame by frame
alongside a run: the irradiance at each point, its peak, and its time integral, the fluence. The
fireball is the air model's own hot gas, so it grows, moves, takes the shape of the streets and
cools as the blast does; the radiation is worked out from that shape in blocks, a few to a
hundred kilobytes a frame, which is what makes it the best candidate in
[Distributed computing](distributed-computing.md#the-long-term-visions-effects) for running apart
from the blast.

**Standing: illustrative.** Each ingredient is a textbook approximation, the fireball is only as
good as the gas model makes it (below), and nothing here has been compared with a measurement of
a fireball's radiation. Use it to see where a scene's surfaces see the fireball and how that
compares between layouts, not for burn, ignition or damage thresholds.

```bash
swift run -c release BombCAD run street.bombcad --thermal thermal.json --thermal-results thermal-results.json --usd street.usda
```

With `--consumer thermal=<ssh host>` the radiation is reckoned on another Mac, fed the fireball
frame by frame (see [Several consumers on several machines](distributed-computing.md#several-consumers-on-several-machines)).

The description is JSON; any field left out takes its default, so `{}` will do:

```json
{
  "luminousTemperature": 1500,
  "emissivity": 1,
  "surfaceSpacing": 1,
  "groundSpacing": 2,
  "samples": 128,
  "fireball": "shape"
}
```

## In the app

Turn on **Fireball's radiant heat** in the Run tab's Thermal radiation section, and set the
**emissivity** and the temperature the gas is **luminous above**; the receivers' spacing, the
directions sampled and the fireball's shape (rather than its sphere) keep their defaults. The description is saved with the project (as
`thermal.json`), takes effect from the next run, and is undone and redone with the layout's edits
(⌘Z). With Macs set for sweeps in Settings, **Run on** reckons the radiation on the one chosen, over
a connection kept open between runs and shared with any other model run there, such as the
[fragments](fragments.md#in-the-app); should that Mac drop, it carries on here.

During a run the view draws every receiver as a dot, coloured by its fluence so far on a log
scale: slate grey with none, through dark red and orange, to pale yellow at 1 MJ/m² (1 J/m² at
the bottom of the scale). Under Display, **Thermal fluence** hides them. A line under the section
gives the largest fireball so far, its temperature now, the highest fluence and the number of
receivers, and any frames still to reckon; Reset clears it all.

![The street canyon's receivers at 60 ms, 100 kg with afterburning and hot air, coloured by fluence as the app draws them: the faces turned to the fireball orange, the roofs and the faces turned away grey](street-thermal-60ms.png)

`blastbench snapshot --thermal thermal.json` reckons it alongside an offscreen snapshot, a frame a
millisecond, and draws the receivers as the view does (the figure above, with `--preset street
--air thermal --afterburn --time 0.06 --mode now --no-wave --dot 7`).

**Keep Run** keeps the result with the run: the description, every receiver with its peak
irradiance and fluence, and the fireball at each frame, as `--thermal-results` writes them.
Compare gives a line for each run that reckoned it (the largest fireball, how long it was
luminous, the highest fluence), the run's CSV adds the fireball's diameter and temperature
through the run, and **Use this run's inputs** brings the description back. Like the fragments,
it does not act on the air, so it is no part of the run's input fingerprint.

**The air is untouched.** The app finds the fireball at the end of the first batch in each
millisecond of simulated time, and at the run's end, rather than stopping the run there: batches
take fewer steps, never shorter ones, to end just past each millisecond. The tests check that the
gauges and the structure's response are the same to the last bit with it on or off. The frames
therefore fall a little after each millisecond, where a step ends, and differ slightly from those
of `BombCAD run --thermal`, which stops at each; for a study that repeats exactly, use that.

The receivers are reckoned on a queue of their own, here or on the other Mac; the run may get up
to four frames ahead of them, and then waits, as for the fragments. On the street's 10,500
receivers that is about 80 ms a frame on the Mac Studio once the fireball fills the street,
nearly all of it following the rays through the flame (a few milliseconds with its sphere; see
[Measured](#measured)), so at the default playback speed of 100 times slower, about the same pace
as the run. A sweep's cases on this Mac reckon it
too, as they fly any fragments, and wait for the last frames before they are kept; cases sent to
other Macs run the blast alone.

On another Mac it is a session of `BombCAD worker`, of the kind any model fed by the blast uses
(see [Several consumers on several machines](distributed-computing.md#several-consumers-on-several-machines)):
the fireball goes out, its shape a few to a hundred kilobytes a frame, and in the app each receiver's fluence and peak
irradiance so far come back after each frame, as raw floats, to draw. The receivers are laid out on both sides from the same
scene and description, and the worker's result is the same as this Mac's for the same frames, to
the last bit, whether either Mac tests the receivers' view on its GPU or its CPU.

## The model

- **The fireball** at each frame is every cell of air at least `luminousTemperature` kelvin hot
  (1,500 K by default), from the gas model's own temperature, p / (ρR) for ideal and thermally
  perfect air and the equilibrium temperature for dissociating air. The GPU sums it in blocks of
  two cells a side at the end of the batch that lands on the frame, and the blocks are doubled
  until their box holds no more than 32,768 (a metre a side when the fireball fills the street
  on 0.25 m cells, half a metre while it is smaller). Each keeps the share of its air that is
  luminous and the fourth root of that gas's mean T⁴, the temperature of a black body that
  radiates as it does on average.
- **Its shape** is a solid flame: its surface is where that share, interpolated between the
  blocks' centres, is one half, and it radiates from there at the temperature of the block it is
  in. This "solid flame" treatment is the usual one for fireballs in hazard assessment, there
  with an empirical sphere's diameter, duration and surface emissive power; here the air model
  supplies the shape and temperatures. Interpolating the share, rather than taking each block
  as a cube, keeps a ragged outline of cubes from catching grazing rays: as cubes, a ball 40
  blocks across came out 4% too bright from 10 m. With `"fireball": "sphere"` it is instead one
  equivalent sphere (the luminous volume, its centroid and the mean T⁴), as before, for
  comparison.
- **Its surface radiates** a grey body's εσT⁴, ε the `emissivity`. The default of 1, a black
  body, is the most it could radiate; real fireballs are partly transparent and cooler at their
  surface than within, so set it to what is known for the explosive.
- **Each receiver** sees the flame's surface at a radiance of εσT⁴ / π, so its irradiance is
  that radiance times cos θ, integrated over the directions in which it sees the flame. Those are
  sampled tile by tile: the luminous blocks are gathered into up to 16 compact tiles (the least
  compact cut in two across its longest side, until each fills at least a fifth of the sphere
  round it), and each tile's directions are spread evenly over the cone its sphere subtends,
  `samples` in all, shared by each cone's solid angle and how much of it the tile fills, at least
  four a tile. Each direction is followed through the blocks to where it first meets the
  surface, so the flame in front hides what is behind it; where the cones overlap, each ray
  counts over the density of samples there from every cone it lies in (the balance heuristic),
  so every ray that meets the flame counts and none twice. A ray counts where it is above the
  receiver's horizon and nothing is in the way, above the ground, of a block or the structure's
  starting outline (tested together, see [Ray tracing](ray-tracing.md)). One compact fireball is
  one tile, sampled as the sphere is, and gives the sphere's answer; a receiver inside the flame
  gets all of εσT⁴.
  Whether each ray is clear is tested on the GPU's ray-tracing hardware where the Mac has
  it, and otherwise on the CPU's cores, with the same answer ([Ray
  tracing](ray-tracing.md#in-bombcad-the-fireballs-radiation)); `BOMBCAD_THERMAL_VISIBILITY=cpu`
  in the environment keeps it on the CPU.
- **The fluence** at each receiver is the irradiance integrated over the frames by the trapezium
  rule; the peak irradiance is the highest at any frame.
- **The receivers** lie over the ground, `groundSpacing` apart, and over every face of the blocks
  and the structure's starting regions that the air touches, `surfaceSpacing` apart, a millimetre
  off their surface. Points inside another solid are left out, as are undersides.
- **The air between is transparent**: no absorption by water vapour or carbon dioxide, which
  over tens of metres takes a few per cent to a few tens of per cent, nor by smoke or dust.

The run's summary also gives what the fireball **radiated in all**, εσT⁴ over the part of its
equivalent sphere above the ground, as a share of the charge's energy; a flame drawn out along a
street has more surface, so this is the least it radiated. Nothing takes that energy out of the
gas, so a share beyond what fireballs of that explosive are seen to radiate shows the emissivity
is too high.

## Measured

The street canyon on the medium grid (0.25 m cells, 100 kg, 0.17 s), frames every millisecond,
defaults otherwise, on the Mac Studio (M4 Max), heavily loaded by other work at the time, so the
times are rough:

| Gas | Largest fireball | Luminous until | Radiated (ε = 1) | Highest fluence | Run, without and with |
|---|---|---|---|---|---|
| Default (cold air, no afterburning) | 4.2 m across, at 1 ms | 44 ms | 0.4 MJ, under 1% | 9 kJ/m², ground | 4 to 7 s and 6.5 s |
| Afterburning and hot air | 14.6 m across, still growing at 170 ms | the run's end | 78 MJ, 19% | 265 kJ/m², ground; 264 kJ/m², a block's face | 8.3 s and 28.3 s; later, less loaded, 10.5 s and 11.5 s |

The largest fireball is given as the sphere of its volume; the fluences are from its shape. The
runs' times were measured with the sphere (below for the shape's cost).

**The gas model decides the answer.** With the default gas the charge's products cool by
expanding as cold air would, so the luminous region is a few metres across and gone within
50 ms. With afterburning and hot air the products burn with the air they mix with and the gas
keeps its heat, and the fireball fills the street. Fireballs of high explosives are known to
scale with the cube root of the charge, last for tens to hundreds of milliseconds, and to be near
1,800 K and above early on; the second is the more plausible, and the one to use for a thermal
study. Since the radiated energy is not taken from the gas, its 19% at emissivity 1 is an upper
bound that a lower emissivity scales down in proportion.

Without a structure, each frame stops the run, ending a time step there (1,856 steps instead of
1,780 with afterburning), as for [fragments](fragments.md#running-alongside-the-blast). The
receivers, about 10,500 of them in the street, each sampling 128 directions against six blocks,
are reckoned on a queue of their own, so the run does not wait for them until the end.

**The receivers on the GPU.** Measured with the fireball as its sphere, on the afterburning
street later the same day, the M4 Max
loaded by other work (load averages of 13 to 51), each build run four times, interleaved, with
the CPU time from `time` and the GPU time from the process's `accumulatedGPUTime` in the
I/O Registry:

| `BombCAD run`, 0.17 s | Wall | CPU time | Of it the radiation's |
|---|---|---|---|
| Without `--thermal` | 9.8 to 12.0 s | 0.5 to 0.7 s | |
| With, before the GPU test | 11.0 to 12.6 s | 3.6 to 4.3 s | about 3.4 s |
| With, the visibility tested on the CPU | 11.6 to 12.1 s | 3.6 to 4.2 s | about 3.4 s |
| With, the visibility tested on the GPU | 11.6 to 12.5 s | 2.7 to 3.2 s | about 2.4 s |

The run takes as long either way: the receivers were never what it waited for. What the GPU
saves is the CPU's cores, a third of the radiation's CPU time, for a few hundredths of a second of
GPU time over the run, too little to see against the blast's 4 to 7 s (and other sessions' work
inflating it). `blastbench thermal --frames 171` times the receivers alone, on a sphere growing to
15 m across: 12 ms of the cores' time a frame on the CPU (1.6 ms of wall time), 5 ms with the
visibility on the GPU (1.3 ms), which takes it in 0.16 to 0.22 ms. The rest is laying out the
rays and summing them, still on the CPU, to which the fireball's shape adds the search for where
each ray meets it (below). The two tests agreed to the bit on every receiver.

**The shape against the sphere.** `blastbench snapshot --thermal thermal.json --thermal-compare`
reckons the same frames with both. In the street with afterburning and hot air, by 170 ms the
flame fills the street in blocks a metre a side, 23 by 20 by 11 of them, in 16 tiles:

| Surface | Highest fluence, shape | Highest fluence, sphere | Mean fluence, shape against sphere |
|---|---|---|---|
| Ground | 265 kJ/m² | 182 kJ/m² | +15% |
| Block 1 | 264 kJ/m² | 171 kJ/m² | +17% |
| Block 4 | 139 kJ/m² | 93 kJ/m² | +1% |
| Block 0 | 98 kJ/m² | 51 kJ/m² | −8% |
| Blocks 2, 3 and 5 | 10 to 21 kJ/m² | 16 to 25 kJ/m² | −20 to −35% |

The flame pressed against the faces and the ground of the street gives the receivers nearest it
half as much again as a ball of the same volume at its centroid, and nearly twice as much on
block 0; the faces that see little of the flame (blocks 2, 3 and 5) get a fifth to a third less.
On the ground most receivers get less from the shape (the median ratio is 0.65) and the nearest
much more; on blocks 1 and 4 most get more (median ratios 2.1 and 1.6). With the default gas the fireball is a
compact ball a few metres across, one tile, and the two agree to within 8% at the highest
fluence (9 against 8 kJ/m²). With 512 samples instead of 128, each surface's highest fluence
moves by under 5% and its mean by under 2%.

Its cost, measured alternately with the sphere on the same frames while the Mac Studio was
loaded by other work: about 80 ms a frame on the CPU's cores for the street's 10,500 receivers
once the flame fills the street, against 4 ms for the sphere, almost all of it following the
rays through the blocks (the sight lines take under a millisecond). Finding the fireball,
on the thread that drives the GPU, went from 0.05 ms to 0.1 to 1.7 ms a frame as the flame grows,
sorting its blocks and doubling them, under half a per cent of the 0.4 s each frame's blast
took. A frame of the shape is 3 bytes a block, 15 to 90 KB, and as JSON a third more.

## Output

- **The summary** printed gives the largest fireball, its temperature and how long it was
  luminous, what it radiated, and each surface's highest peak irradiance and fluence.
- **`--thermal-results`** writes the description, every receiver (position, normal, surface),
  its peak irradiance (W/m²) and fluence (J/m²), and the fireball at every frame, as JSON.
- **The USD scene** (`--usd`) gains `/Scene/Thermal`, a Points prim of the receivers with float
  primvars `fluence` (kJ/m²) and `peakIrradiance` (kW/m²), for colouring in Blender.

## Limitations

- Illustrative, as above: no comparison with measurements of fireball radiation.
- The shape is resolved only to its blocks, a metre a side when it fills the street on the
  medium grid: its edges and corners are rounded within half a block (a long box's view factor
  came out 3% low on blocks an eighth of its width), and a flame thinner than a block is lost.
  A fireball so small that no block of two cells is half luminous is taken as its sphere.
- The flame is opaque, at each block's mean temperature from its surface inwards. A partly
  transparent flame, its emissivity growing with the path length through it, would need an
  absorption coefficient for the explosive's hot products, for which no source was found.
- A run keeps its frames without their shapes, so a kept run's radiation can be reckoned again
  only from the sphere.
- Each block's temperature is its luminous gas's mean; real fireballs are hotter within than at
  their edge, and partly transparent.
- The radiated energy is not taken from the gas, and the air between is transparent.
- On coarse grids the charge's gas is spread over large cells and comes out cooler: on 0.5 m
  cells, 0.5 kg of TNT starts at under 800 K, below the default luminous temperature.
- Only the coarse grid's cells, also where refinement sharpens the blast.
- `BombCAD run --thermal` reckons it on this Mac only; the app can send it to another Mac.
- The GPU's and the CPU's visibility tests have agreed to the bit on every scene tried, but only
  the M4 Max's GPU has been tried; on an M1 or M2, ray tracing runs in software and may be slower
  than the CPU.
- Only the visibility test is on the GPU; laying out the rays and summing them take most of the
  receivers' CPU time. Following each ray to where it meets the fireball's shape, about twenty
  times the sphere's reckoning and tens of milliseconds a frame on the CPU, is the next candidate
  for the GPU.
- The receivers are drawn as dots, not painted onto the surfaces.
- Receivers on the structure's starting outline do not follow it as it moves or fails.

## Sources

- F. P. Incropera et al., *Fundamentals of Heat and Mass Transfer*, Wiley: radiation between
  surfaces, view factors.
- J. R. Howell, *A Catalog of Radiation Heat Transfer Configuration Factors*, case B-3: a small
  surface to a parallel rectangle, used by the tests for the box, the L and the corner.
- J. Amanatides and A. Woo, "A fast voxel traversal algorithm for ray tracing", Eurographics
  1987: following a ray through the blocks.
- E. Veach and L. J. Guibas, "Optimally combining sampling techniques for Monte Carlo rendering",
  SIGGRAPH 1995: the balance heuristic, for the tiles' overlapping cones.
- Committee for the Prevention of Disasters, *Methods for the calculation of physical effects*
  ("Yellow Book", CPR 14E), 3rd ed., 1997, chapter 6: the solid-flame model of fireballs.
- Long-term scope: [Long-term vision](long-term-vision.md); where it can run:
  [Distributed computing](distributed-computing.md#the-long-term-visions-effects).
