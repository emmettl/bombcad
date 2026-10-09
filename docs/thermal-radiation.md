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
| Afterburning and hot air | 14.6 m across, still growing at 170 ms | the run's end | 78 MJ, 19% | 182 kJ/m², ground; 171 kJ/m², a block's face | 8.3 s and 28.3 s |

**The gas model decides the answer.** With the default gas the charge's products cool by
expanding as cold air would, so the luminous region is a few metres across and gone within
50 ms. With afterburning and hot air the products burn with the air they mix with and the gas
keeps its heat, and the fireball fills the street. Fireballs of high explosives are known to
scale with the cube root of the charge, last for tens to hundreds of milliseconds, and to be near
1,800 K and above early on; the second is the more plausible, and the one to use for a thermal
study. Since the radiated energy is not taken from the gas, its 19% at emissivity 1 is an upper
bound that a lower emissivity scales down in proportion.

Without a structure, each frame stops the run, ending a time step there (1,856 steps instead of
1,780 with afterburning), as for [fragments](fragments.md#running-alongside-the-blast). The cost
is the receivers: about 10,500 of them in the street, each sampling 128 directions against six
blocks each frame on the CPU's cores, on a queue of its own so that the run does not wait for it
until the end. Ray tracing on the GPU ([Ray tracing](ray-tracing.md)) would take most of it.

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
- Headless only, on this Mac; the app does not show it yet, and the exchange is small enough to
  run on another Mac like the fragments, which is not yet wired up.
- Receivers on the structure's starting outline do not follow it as it moves or fails.

## Sources

- F. P. Incropera et al., *Fundamentals of Heat and Mass Transfer*, Wiley: radiation between
  surfaces, view factors.
- Committee for the Prevention of Disasters, *Methods for the calculation of physical effects*
  ("Yellow Book", CPR 14E), 3rd ed., 1997, chapter 6: the solid-flame model of fireballs.
- Long-term scope: [Long-term vision](long-term-vision.md); where it can run:
  [Distributed computing](distributed-computing.md#the-long-term-visions-effects).
