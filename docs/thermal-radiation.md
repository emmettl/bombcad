# Thermal radiation from the fireball

The fireball's radiant heat on the ground and the scene's faces, reckoned frame by frame
alongside a run: the irradiance at each point, its peak, and its time integral, the fluence. The
fireball is the air model's own hot gas, so it grows, moves and cools as the blast does; the
radiation is worked out from a few numbers a frame, which is what makes it the best candidate in
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
  "samples": 128
}
```

## In the app

Turn on **Fireball's radiant heat** in the Run tab's Thermal radiation section, and set the
**emissivity** and the temperature the gas is **luminous above**; the receivers' spacing and the
directions sampled keep their defaults. The description is saved with the project (as
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
receivers that is a few milliseconds a frame on the Mac Studio (see [Measured](#measured)), well
ahead of the run. A sweep's cases on this Mac reckon it
too, as they fly any fragments, and wait for the last frames before they are kept; cases sent to
other Macs run the blast alone.

On another Mac it is a session of `BombCAD worker`, of the kind any model fed by the blast uses
(see [Several consumers on several machines](distributed-computing.md#several-consumers-on-several-machines)):
the fireball goes out, a few numbers a frame, and in the app each receiver's fluence and peak
irradiance so far come back after each frame, as raw floats, to draw. The receivers are laid out on both sides from the same
scene and description, and the worker's result is the same as this Mac's for the same frames, to
the last bit, whether either Mac tests the receivers' view on its GPU or its CPU.

## The model

- **The fireball** at each frame is every cell of air at least `luminousTemperature` kelvin hot
  (1,500 K by default), from the gas model's own temperature, p / (ρR) for ideal and thermally
  perfect air and the equilibrium temperature for dissociating air. It is reduced to an
  equivalent sphere: the cells' volume, their centroid, and the fourth root of their mean T⁴,
  the temperature of a black body that radiates as the gas does on average. This "solid flame"
  treatment is the usual one for fireballs in hazard assessment, there with an empirical
  diameter, duration and surface emissive power; here the air model supplies them.
- **Its surface radiates** a grey body's εσT⁴, ε the `emissivity`. The default of 1, a black
  body, is the most it could radiate; real fireballs are partly transparent and cooler at their
  surface than within, so set it to what is known for the explosive.
- **Each receiver** sees the sphere as a uniformly bright disc of radiance εσT⁴ / π, so its
  irradiance is that radiance times the integral of cos θ over the directions in which it sees
  the sphere. `samples` directions are spread evenly over the cone the sphere subtends, each
  counted where it is above the receiver's horizon and reaches the sphere above the ground with
  no block or structure (its starting outline) in the way. For a sphere in full view this is
  the exact (r/d)² cos θ εσT⁴ at any distance; a receiver inside the fireball gets all of εσT⁴.
  Whether each direction is clear is tested on the GPU's ray-tracing hardware where the Mac has
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
sphere above the ground, as a share of the charge's energy. Nothing takes that energy out of the
gas, so a share beyond what fireballs of that explosive are seen to radiate shows the emissivity
is too high.

## Measured

The street canyon on the medium grid (0.25 m cells, 100 kg, 0.17 s), frames every millisecond,
defaults otherwise, on the Mac Studio (M4 Max), heavily loaded by other work at the time, so the
times are rough:

| Gas | Largest fireball | Luminous until | Radiated (ε = 1) | Highest fluence | Run, without and with |
|---|---|---|---|---|---|
| Default (cold air, no afterburning) | 4.2 m across, at 1 ms | 44 ms | 0.4 MJ, under 1% | 8 kJ/m², ground | 4 to 7 s and 6.5 s |
| Afterburning and hot air | 14.6 m across, still growing at 170 ms | the run's end | 78 MJ, 19% | 182 kJ/m², ground; 171 kJ/m², a block's face | 8.3 s and 28.3 s; later, less loaded, 10.5 s and 11.5 s |

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

**The receivers on the GPU.** Measured on the afterburning street later the same day, the M4 Max
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
rays and summing them, still on the CPU; a fireball that is not one sphere will add the search
for where each ray meets it. The two tests agreed to the bit on every receiver.

## Output

- **The summary** printed gives the largest fireball, its temperature and how long it was
  luminous, what it radiated, and each surface's highest peak irradiance and fluence.
- **`--thermal-results`** writes the description, every receiver (position, normal, surface),
  its peak irradiance (W/m²) and fluence (J/m²), and the fireball at every frame, as JSON.
- **The USD scene** (`--usd`) gains `/Scene/Thermal`, a Points prim of the receivers with float
  primvars `fluence` (kJ/m²) and `peakIrradiance` (kW/m²), for colouring in Blender.

## Limitations

- Illustrative, as above: no comparison with measurements of fireball radiation.
- One equivalent sphere: a fireball pressed into a street or round a corner is not a sphere, and
  its parts hidden from a receiver are judged by the sphere's.
- The fireball's surface temperature is taken as its volume's mean; real fireballs are hotter
  within than at their edge, and partly transparent.
- The radiated energy is not taken from the gas, and the air between is transparent.
- On coarse grids the charge's gas is spread over large cells and comes out cooler: on 0.5 m
  cells, 0.5 kg of TNT starts at under 800 K, below the default luminous temperature.
- Only the coarse grid's cells, also where refinement sharpens the blast.
- `BombCAD run --thermal` reckons it on this Mac only; the app can send it to another Mac.
- The GPU's and the CPU's visibility tests have agreed to the bit on every scene tried, but only
  the M4 Max's GPU has been tried; on an M1 or M2, ray tracing runs in software and may be slower
  than the CPU.
- Only the visibility test is on the GPU; laying out the rays and summing them take most of the
  receivers' CPU time. Following each ray to where it meets a fireball that is not one sphere,
  tens of milliseconds a frame on the CPU, is the next candidate for the GPU.
- The receivers are drawn as dots, not painted onto the surfaces.
- Receivers on the structure's starting outline do not follow it as it moves or fails.

## Sources

- F. P. Incropera et al., *Fundamentals of Heat and Mass Transfer*, Wiley: radiation between
  surfaces, view factors.
- Committee for the Prevention of Disasters, *Methods for the calculation of physical effects*
  ("Yellow Book", CPR 14E), 3rd ed., 1997, chapter 6: the solid-flame model of fireballs.
- Long-term scope: [Long-term vision](long-term-vision.md); where it can run:
  [Distributed computing](distributed-computing.md#the-long-term-visions-effects).
