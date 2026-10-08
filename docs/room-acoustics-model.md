# Room-acoustics model

RoomCAD's first acoustic backend generates impulse responses of rooms for convolution reverb. It lives in the separate `RoomCAD` package: `Sources/AcousticCore` holds the
model and `Sources/ImpulseResponseKit` holds the response format and WAV files. It covers milestone
M2 and the scattering part of M4 of the [RoomCAD roadmap](roomcad-roadmap.md). The app that edits rooms and generates responses is
described in [RoomCAD app and documents](roomcad-app.md).

## What it models

The model covers one omnidirectional point source and up to 16 point receivers, each omnidirectional
or a first-order microphone (below), in a
rectangular room whose interior spans `[0, size]` in metres, z up. Each receiver becomes one output
channel. Two receivers give the mono-to-stereo case. Each of the six surfaces has its own material,
given as energy absorption coefficients α and scattering coefficients s in eight octave bands (nominally
63 Hz to 8 kHz). The model is geometrical acoustics, with no wave effects except those the coherent
sum of images reproduces.

At each reflection the energy that is not absorbed, a fraction 1 − α, splits in two:

- a fraction 1 − s leaves specularly, like light from a mirror;
- a fraction s leaves diffusely, in a Lambert (cosine) distribution.

This is the scattering coefficient's definition in ISO 17497-1. Image sources give the paths that are
specular at every reflection. Ray tracing gives the energy that has scattered at least once, so each
path is counted once.

## Image sources

Along an axis of length L, a source at s has images at (1 − 2q)s + 2nL for integer n and q ∈ {0, 1}.
Such an image has met the wall at 0 |n − q| times and the wall at L |n| times (Allen and Berkley,
1979). An image's reflection order is the total over the three axes. Each image delivers one arrival,
with:

| Quantity | Value |
|---|---|
| Delay | r / c, with c = 331.3 √(T / 273.15 K) m/s (343.2 m/s at 20 °C) |
| Spreading | 1 / r, relative to the free-field pressure 1 m from the source |
| Reflection | the product of √((1 − α)(1 − s)) over the surfaces met, per band; real and positive, so no phase shift and no angle dependence |
| Air | exp(−m r) per band, with m the ISO 9613-1 attenuation at the band centre |

The image list is built per axis and sorted by distance, so the triple loop stops early at the
response duration. Each list also records the lowest reflection order from each position onwards, so
the loop also stops once nothing further along is within the order limit. The first image skipped this
way is the nearest omitted one. Without this, a capped order in a small room over a long duration
still visited every image within reach: 5.2 s instead of 0.08 s for the tiled bathroom's 2.3 million
arrivals. A test compares the arrivals and the earliest omission with brute-force enumeration. Arrivals are streamed to the renderer rather than stored. A 1.5 s response of an 8 × 6 × 3 m room has
about four million arrivals per receiver.

Each arrival's 64-tap kernel is computed by rotating its sine and cosine phases from tap to tap,
which needs four transcendental calls per arrival instead of 128. Receivers render in parallel, one
per core. Rays are traced in 16 fixed chunks with their own random streams, merged in order, so a
response is identical on any Mac. Each receiver's diffuse tail is seeded from its identity, so its
channel does not change when other receivers are added, removed or reordered. Cancellation reaches
every worker through a shared flag. Together these made the presets about four times faster: the
living room takes 0.9 s, the tiled bathroom 1.0 s and the stone church 1.25 s.

Two limits bound the work, and both are explicit settings:

- **Duration.** Arrivals later than the duration are omitted.
- **Maximum reflection order.** Image sources above it are omitted, and the diagnostics record
  `orderLimitedAfter`, the earliest such delay. The ray tracer then carries those specular paths, as
  rays with more reflections than the limit, so no energy is lost. They become part of the energy
  envelope rendered as the diffuse tail, which is the usual hybrid of image sources for early
  reflections and ray tracing later.

Settings that would need more than 40 million image sources per receiver are rejected.

## Scattered energy

`DiffuseRayTracer` follows rays from the source: enough for about 50 to cross each receiver per
millisecond (a ray crosses a sphere of radius R about cπR²/V times a second), at least 5,000 and at
most the `diffuseRays` setting, 40,000 by default. They start in evenly spread directions (a
spherical Fibonacci lattice) given a random rotation.

At each wall a ray keeps a fraction 1 − α of its energy per band. It then either scatters, leaving in a
cosine-weighted random direction, or reflects specularly. It scatters with probability p, the
surface's mean scattering coefficient, kept between 0.05 and 0.95 when the surface scatters at all.
Each band's energy is then multiplied by s/p or (1 − s)/(1 − p), so every band keeps its exact
expectation even though one path serves all eight. Rays stop at the response duration, or once their
energy is about 150 dB down.

Each receiver is a sphere whose radius is a tenth of the room's cube-root volume, between 0.3 and
1.5 m, so enough rays cross it in large rooms. Once a ray has scattered, crossing a sphere deposits its
energy × 4π × chord length / V. V is the volume of the part of the sphere inside the room, so receivers
near walls are not biased. That normalization makes a free-field source give 1/r², the same units as
an image source's squared gain. Deposits go into 1 ms bins per octave band, with air absorption applied
over the path length.

`DiffuseTail` turns each receiver's histogram, smoothed over ±2 ms or ±2% of the time since emission,
whichever is wider, into impulses with random signs at
random times within each bin. Each bin's impulses share its energy equally in every band, so they add
incoherently to it. Their density follows a room's reflection density, 4πc³t²/V per second, between
2,000 and 20,000 per second. They go through the same renderer as the image sources.

The ray directions and the tail's detail come from `randomSeed`, so a response is reproduced exactly.
A surface with s = 0 in every band leaves the response exactly as the image sources alone give it, and
no rays are traced.

## Floor plans

A room can have any floor plan with vertical walls between a flat floor and a flat ceiling: corners
listed anticlockwise, one material per wall. That covers L- and T-shaped rooms, alcoves, angled walls
and fan-shaped halls. Corners lie within the room's length and width, which become the plan's
bounding box. Walls may not cross, and the source and receivers must be inside the plan.

- **Image sources.** Because the walls are vertical, a path's plan and its height separate. Images in
  plan come from reflecting across walls that face them, and floor and ceiling images combine with
  them as in a box. A plan image is valid for a receiver only if, traced back from the receiver, its
  path crosses each mirroring wall within the wall itself and no other wall blocks any leg. That is
  what hides reflections round the corner of an L. Images grow level by level up to the wall order
  that fits 100,000 images, and total order to at most ten floor and ceiling reflections beyond that.
- **Rays.** Rays carry every other specular path, with more wall reflections or more reflections in
  total, as well as scattered energy. They meet the walls by general segment intersection, reflect
  about each wall's normal, and scatter in a Lambert distribution around it.
- **Wave solver.** Cells whose centres lie inside the plan are simulated. Each face between a
  simulated cell and one that is not is a wall with the nearest wall's impedance, or air in an
  opening: a staircase approximation of walls not aligned with the grid. The masked grid costs about
  twice as much per cell, so plans get half the work budget.
- **Openings.** Openings can be in a numbered wall, located by distance along it and height, as well
  as in the floor or ceiling.

Tests check the floor-plan code against the box and against geometry:

- A rectangular plan reproduces the box's image-source arrivals within 10⁻¹² in delay and gain. It
  reproduces the box's scattered energy within 3%, and its wave field to within rounding.
- In an L, a receiver round the corner gets no direct sound but does get reflections, and one in sight
  gets the direct sound exactly.
- In a rigid, fully scattering L, rays arrive at 4πc/V within 5% in both arms.
- Crossed walls, clockwise corners and points outside the plan are rejected.

An L (8 × 6 m less 4 × 3 m), a T and a fan-shaped hall decay within about 10% of their Eyring estimates
at 1 kHz.

## Rooms of any shape

A room can also be a closed mesh (`RoomMesh`): flat polygonal faces whose normals point into the
room, each with a material, and any of them open. That covers sloping ceilings, raked floors,
balconies, galleries, stage houses and attics. The mesh replaces the box's surfaces and any floor
plan; its bounding box must lie within the room's size. A mesh is checked before use:

- each face must be flat (within 2 cm) and have area;
- the faces must close: their areas, weighted by their normals, sum to zero;
- the normals must point inwards, which makes the enclosed volume positive.

Faces that lie in one plane are grouped (`MeshGeometry`), and a bounding-volume hierarchy speeds up
the ray queries. Each part of the model uses the mesh as follows:

- **Image sources.** After Borish (1984), images are mirrored in planes rather than faces, so a wall
  cut into many faces adds no images. An image can only be mirrored in a plane it lies in front of.
  It is valid for a receiver only if, traced back from the receiver, its path meets each mirroring
  plane within one of that plane's faces, that face is not open, and no other face blocks any leg.
  That hides reflections behind a balcony front or round the corner of a stage. Images grow level by
  level up to the order that fits 100,000 images.
- **Rays.** Rays find the nearest face through the hierarchy, reflect about its normal, and scatter
  around it. A ray that reaches an open face leaves the room.
- **Wave solver.** A cell is simulated if its centre is inside the mesh, found by counting the
  mesh's crossings along the cell's vertical column. Each face between a simulated cell and one that
  is not takes the impedance of the nearest mesh face, or of air if that face is open. As with floor
  plans, walls not aligned with the grid become staircases.
- **Inside and clearance.** A point is inside if a ray from it crosses the mesh an odd number of
  times. The source and receivers must be inside.

### Building rooms from solids

Writing a closed mesh by hand is error-prone, so rooms are built from pieces of air with
constructive solid geometry (`Solid`). It follows Evan Wallace's csg.js, which uses binary space
partitioning trees. The pieces are boxes and extrusions of a polygon along an axis, each face with a
material. They can be joined, subtracted or intersected. A balcony, for example, is a slab
subtracted from the hall's air, and the stage house is a box joined to it.

`Solid.room` makes the result into a room. It welds vertices within 10 µm, turns the faces to point
inwards, and drops slivers that the cuts leave. A face's material can be "open".

Two room presets are built this way (`HallShapes`):

- **A shoebox concert hall**, 26 × 18 × 14 m: a balcony along both sides and the back, and a raised
  stage house, 8 m deep, behind a proscenium.
- **A raked auditorium**: a fan-shaped plan, 26 m deep and 18 to 32 m wide, with seating rising 6 m
  to the back under a sloping ceiling, and a rear tier above the stalls. It is the intersection of
  an extruded long section and an extruded fan plan, less the tier.

Both hall presets have six materials: audience, other floors, walls, ceiling, stage floor and stage
walls. Measured scenes describe their geometry the same way (see
[the chamber music hall](roomcad-validation.md#a-larger-room-the-chamber-music-hall)).

### Tests

Tests check the mesh code against the box and the floor plan:

- A box and an L-shaped plan, built as meshes, have the right volume, area and inward normals. Inside
  and clearance agree with the plan's at 2,000 random points.
- Open, turned and bent meshes are rejected, as is a room with both a mesh and a plan.
- A box as a mesh has exactly the box's image sources up to the third order. An L-shaped mesh has
  the plan's image sources, including the ones hidden round the corner.
- A box and an L as meshes give the same scattered energy within 5%, and the same wave field to
  within 10⁻⁸ of its energy.
- A whole response for a box as a mesh matches the box's own within 0.5 dB in every band.
- Boxes cut into fragments by solid operations keep the box's image sources. A raked hall with a
  balcony is watertight.

## Openings

An opening is a rectangle on one surface, such as an open door, window or hatch, given by its centre
and size along that surface's two axes. Sound reaching it leaves the room. Each model treats it
differently:

- **Ray tracer.** Exact: a ray that reaches an opening is gone.
- **Image sources and estimates.** Image sources, and the Sabine and Eyring estimates, treat the open
  share f of the surface as absorption, α' = α(1 − f) + f. This is the usual statistical
  approximation, and rays carry everything beyond the order limit exactly anyway.
- **Wave solver.** Boundary faces whose centres lie in an opening take the impedance of air, ξ = 1.
  At low frequencies a real opening smaller than the wavelength reflects part of the sound, so this
  overstates its absorption there. With a 2 × 2.5 m opening in a 5 × 4 × 3 m room, the 63 Hz decay
  fell from 0.90 s to 0.60 s, against about 0.71 s from Sabine.

Tests check the absorption formula and its effect on Sabine's absorption area. A wall wholly open
matches, for rays, a wall that absorbs everything (within 5%). An open door shortens the decay in both
the geometrical model and the wave solver. Openings must lie within their surface, and older settings
load with none. Openings are drawn in the plan and section as green gaps in a wall seen edge-on, or
dashed outlines facing the view.

## Microphones

A receiver can be a first-order microphone aimed by azimuth and elevation. Its gain is
a + (1 − a) cos θ at angle θ from its axis:

| Pattern | Omni | Subcardioid | Cardioid | Supercardioid | Hypercardioid | Figure of eight |
|---|---|---|---|---|---|---|
| a | 1 | 0.7 | 0.5 | 0.37 | 0.25 | 0 |

A figure of eight picks up its rear lobe in inverted polarity, as a real one does. Each image source's
gain is multiplied by the microphone's gain towards the image. Each ray crossing is weighted by the
squared gain towards where the ray comes from. So in a diffuse field a microphone picks up
a² + (1 − a)²/3 of an omni's energy, a third for a cardioid or a figure of eight.

**Arrange First Two as a Stereo Pair** places the first two receivers around their midpoint, facing
the source horizontally, with the first as the left channel:

| Pair | Spacing | Axes | Pattern |
|---|---|---|---|
| A–B | 60 cm | parallel | Omni |
| XY | coincident | ±45° | Cardioid |
| ORTF | 17 cm | ±55° | Cardioid |
| NOS | 30 cm | ±45° | Cardioid |
| Blumlein | coincident | ±45° | Figure of eight |

The patterns are ideal, the same at every frequency. Real microphones narrow at high frequencies and
widen at low ones. Mid-side and binaural (head-related) responses are not modelled. Each channel's JSON
description records its microphone. Receivers saved before microphones existed load as omni.

## Low frequencies: the wave solver

Below a crossover, an optional finite-difference time-domain (FDTD) solver replaces the geometrical
model, which only approximates room modes. `WaveSolver` advances linear acoustics on Yee's staggered
grid, with pressure at cell centres and particle velocity on faces, by leapfrog. The cells exactly
fill the room, at least 10 per wavelength at the top of the crossover's transition.

- **Time step.** The time step is the audio sample period times a power of two, within 95% of the
  stability limit. The solver's spectrum then shares the audio spectrum's bins and needs no
  resampling.
- **Walls.** Walls are locally reacting, with a real normalized impedance ξ, treated semi-implicitly
  so any ξ > 0 is stable. Published coefficients are random-incidence values, so ξ is found by
  inverting Paris's statistical absorption, α = (8/ξ)[1 + 1/(1 + ξ) − (2/ξ) ln(1 + ξ)], which is at
  most about 0.951 for a real impedance. Using
  the normal-incidence relation instead made the walls absorb about half as much again at α = 0.3, and
  left the wave part 1.5–5.6 dB too quiet at the crossover.
- **Frequency-dependent walls.** Each octave band below the crossover's top gets the impedance its own
  absorption gives. Bands whose impedances agree on every boundary share a run, so a room of
  frequency-independent materials needs one run and one with several distinct bands needs one per band.
  Each run's spectrum is kept only in its own bands, through the same octave weights the geometrical
  model uses, which sum to one.
- **Decay matched to a diffuse field.** Published absorption coefficients are diffuse-field values, and
  the geometrical model uses them that way. In the solver a wall is a locally reacting impedance. By
  Morse's first-order theory, a mode loses only half as much energy to a wall it grazes as to one it
  strikes. Axial and tangential modes therefore outlast a diffuse field, and a bare-walled box's decay
  in a band is 20–60% longer than Eyring's estimate for the same coefficients. The measured seminar
  room ([RoomCAD against a measured room](roomcad-validation.md)) decayed at the diffuse rate, because
  real rooms mix grazing and oblique energy through their irregularities, furniture and surfaces that
  are not locally reacting.

  Each run therefore also records 24 probes, spread through the room by a Halton sequence and kept
  0.3 m clear of every boundary. Their summed energy in each band gives the room's average T30.
  Where that is longer than Eyring's estimate for the band, with air absorption and openings, the
  band's response is damped by e^(−Δt) from the direct sound's arrival, so that it decays at Eyring's
  rate. Every mode in the band is damped alike, so the modes' frequencies, their spatial pattern and
  their differences in decay remain, and the response never decays more slowly than before. In boxes
  whose absorption is uniform, on the floor and ceiling only, or on one wall, the damped decay at
  receivers other than the probes was within 12% of Eyring's estimate; bare, it was 20–60% longer. The
  bare decay of each band is reported with the response.
- **Source and calibration.** The source injects volume velocity, a Gaussian derivative with no net
  volume. Each receiver's spectrum, taken at its exact sample times, is divided by the free-field
  pressure 1 m away, ρ·j2πf·Q(f)/4π. That gives the geometrical model's units and time origin.
- **Microphones.** A directional microphone's output is a·p − (1 − a)·ρc·(u · axis), with the
  velocity interpolated to the pressure's times. Near a source, the velocity's 1/(jkr) term then gives
  real gradient microphones' proximity effect, which the geometrical model's ideal pattern lacks.
- **Blending.** The two models are blended with complementary zero-phase half-cosine crossovers
  (±0.5 octave), which sum to one.

`WavePlan` chooses the crossover: three times the Schroeder frequency, where modes have become dense,
between 80 and 500 Hz (250 Hz without a GPU). It is lowered until the work, counting every run, fits a
budget of 1.5 × 10¹⁰ cell updates on the GPU or 4 × 10⁹ on the CPU (half that for a floor plan, whose
masked grid costs about twice as much per cell). Work grows as frequency to the fourth power. If even
60 Hz doesn't fit, as in a 120 × 80 × 30 m hangar, the solver is skipped with a note. A fixed crossover
from 40 to 500 Hz can be set instead.

`MetalWaveSolver` runs the same scheme on the GPU in single precision, as Metal compute kernels
compiled when first used: one for velocity, one for pressure with the walls, and two for the source and
receivers, 128 steps to a command buffer. Box and plan share one layout, in which every cell carries
its six faces' wall coefficients, so the GPU has no separate plan path. It reaches about 3.6 × 10⁹ cell
updates a second on large grids, limited by memory bandwidth. Without a GPU the CPU solver runs as
before, on the CPU's cores, with small grids on one thread.

Other apps can keep the GPU busy and slow a run many times over. Each run therefore starts on the GPU
and, after a quarter of a second, projects its pace to the end. If what remains would take over a
second, and more than 1.5 times as long as the whole run on the CPU, the run is abandoned and redone
on the CPU. The CPU's time is estimated by timing a few steps of the same grid. The crossover and grid
don't change, so the response doesn't depend on which engine ran it, beyond single-precision rounding.
Each run decides afresh, so the GPU is used again once it frees up.

With a separate process saturating the GPU, the L-shaped living room's runs projected to about 30 s
each on the GPU and took 6.5 s on the CPU, which the estimate predicted within about 20%. The response
view says how many runs used each engine.

Tests check the solver against theory:

- In a 16 m room with absorbing walls, the low-frequency direct sound matches the geometrical model
  within 0.25 dB, before any reflection arrives. Their difference is under 1% of the energy, with no
  timing offset (0.03 dB in a release build).
- A rigid 3 × 2.5 × 2 m room's first five modes are within 0.5% of c/2·√((l/Lx)² + (m/Ly)² + (n/Lz)²).
  The first ten are within 0.25% at a finer grid, against the roadmap's 1% target.
- The axial mode between two walls of α = 0.3 decays within 10% of the rate their normal-incidence
  reflection coefficient gives (6% in a release build).
- Far from the source, a cardioid facing it hears it within 10% of an omni. Facing away, or side-on as
  a figure of eight, it hears under 3%.
- With absorption 0.2 in the 63 Hz band and 0.6 above, the first axial mode (43 Hz) and the third
  (129 Hz) each decay within 10% of the rate their own band's impedance gives.
- The GPU and CPU solvers agree to within 10⁻¹⁰ of the energy, in a box and in an L-shaped plan with a
  door, for omni and cardioid receivers.
- The rule itself is tested on its own. End to end, a delay after each GPU command buffer stands in for
  a busy GPU: a long run moves to the CPU and gives exactly the CPU's result, while a run with under a
  second left when judged stays on the GPU.
- The impedance inversion reproduces the absorption, and rooms over budget skip the solver.
- Yee's dispersion relation gives the second-order phase-velocity error along an axis, and less on
  diagonals. For every grid RoomCAD chooses, waves at the crossover travel within 1% of c.
- Over 50,000 steps on either engine, a rigid room keeps ringing at the same strength and an anechoic
  one dies away, so the walls are stable and passive.
- Matched to the diffuse decay, a box decays within 12% of Eyring's estimate at receivers other than
  the probes, with uniform absorption or with absorption on the floor and ceiling only.

On an M-series Mac the presets' crossovers run from 69 Hz (stone church) to 457 Hz (vocal booth), with
one to four runs, and generation with the solver takes 1.4–5.3 s in a release build. Every preset now
gets a wave part; before the GPU solver, the halls and the church were skipped.

In the octave band holding each preset's crossover, the two models' energy at the listeners agrees
within 2 dB, and their T30 within 15%. The stone church is the exception: its crossover (69 Hz) lies
in the 63 Hz band, where the wave part is 4 dB louder and decays over 16.7 s against the geometrical
model's 10.5 s. Eyring's estimate is 18.8 s.

Below the crossover, where only the wave solver is heard, its energy is up to 3.4 dB lower than the
geometrical model's. The geometrical model decays more slowly there, up to twice Eyring's estimate in
the classroom at 63 Hz, because the presets' surfaces scatter little at low frequencies. The wave
solver's decay is matched to Eyring's. There are two exceptions at 63 Hz:

- The L-shaped living room is 5.4 dB louder in the wave model. The listener is round the corner from
  the source, and at 63 Hz (5.4 m) sound diffracts round it, which the geometrical model leaves out.
- The stone church is 4.0 dB louder (above). Source and listener are both within about a quarter
  wavelength of the floor, which raises the level near a boundary (the Waterhouse effect); the
  diffuse tail assumes a uniform field.

Both are probably physical, but neither has been checked against a measurement.

### Accuracy

`acousticbench --wave-accuracy` measures how faithfully the solver carries a travelling wave, the
benchmark that roadmap milestone M3 asks for.

**Dispersion.** On Yee's grid a wave of frequency f travels slightly slower than sound, by an amount
that grows with frequency and is largest along the grid's axes (`WaveAccuracy`). A room mode is low by
about the same fraction. RoomCAD sizes the cells for 10 points per wavelength at the top of the
crossover's transition, so the crossover itself has about 14. For a 250 Hz crossover (9.7 cm cells,
83 µs steps) the errors are:

| Frequency | Points per wavelength | Axis | Face diagonal | Body diagonal |
|---|---|---|---|---|
| 63 Hz | 57 | −0.05% | −0.02% | −0.01% |
| 125 Hz | 28 | −0.19% | −0.08% | −0.05% |
| 177 Hz | 20 | −0.38% | −0.17% | −0.10% |
| 250 Hz | 14 | −0.76% | −0.34% | −0.20% |
| 354 Hz | 10 | −1.53% | −0.68% | −0.40% |

Below the crossover, which is where the solver is heard, mode frequencies are therefore within 1%,
the roadmap's target. Each response reports its own worst error at the crossover.

**Travelling waves.** A pulse travels from the centre of a large anechoic box (30 m for a 100 Hz
crossover, 20 m for 250 Hz) to receivers 1, 2, 3.5 and 5 m away, along an axis and along the body
diagonal. Each response is windowed before the walls' first reflection. The solver's part of it is
divided by the geometrical model's exact direct sound, at a quarter, half, 0.71 and all of the
crossover frequency.

- **Amplitude.** The error is within 0.36 dB everywhere, against the roadmap's 1 dB over the declared
  test distance of 5 m.
- **Phase.** The phase lag grows with distance as the dispersion relation predicts. Along an axis at
  5 m, at a 250 Hz crossover, it is 9.9° measured against 10.0° predicted, and 3.4° against 3.5° at
  177 Hz. On the diagonal at 5 m, it is 2.8° against 2.6°. At the lowest frequencies the window, a
  little shorter than a period, adds up to 3° of its own.

So the solver's usable band is everything below its crossover. There, amplitude is within 0.4 dB
over 5 m, and phase velocity and mode frequencies within 1%. The scheme is linear, so these hold at
any level. Each export's model description states the crossover and the phase-velocity error there.

Limitations of the solver:

- The wall impedance is real, and constant within each octave band.
- Walls are locally reacting. The decay matching above makes each band decay, on average, as a
  diffuse field would. It does not model how real surfaces absorb at grazing incidence, so which modes
  decay faster than others may differ from a real room. In a room that really is a smooth, bare box,
  matching makes the low end decay faster than it would.
- There is no air absorption, which is negligible there.
- It models bare walls: no furniture or scattering. Openings are walls of ξ = 1.
- The grid's dispersion grows towards the top frequency.

## Rendering

Each arrival is a Hann-windowed sinc of 64 taps, cut off at 0.9 of the Nyquist frequency. It is placed
at the arrival's exact fractional delay, so timing is not rounded to a sample. The renderer keeps one
signal per octave band and adds each arrival into every band with that band's gain. Each band signal
is then filtered in the frequency domain by a zero-phase weight, and the bands are summed.

The weights are half-cosine crossovers in log frequency, ±0.5 octave about the geometric mean of
adjacent centres. They sum to exactly one at every frequency. An arrival with equal gains in all bands
therefore passes through unchanged. The lowest band extends to 0 Hz and the highest to Nyquist.

Every reflection coefficient is real and positive, so the raw response accumulates a slowly decaying
offset below the lowest room mode. In the 8 × 6 × 3 m reference room it held 11% of the response's
energy, and it would add a DC offset to a convolution reverb. By default a zero-phase high-pass keeps
content above 20 Hz and removes content below 10 Hz. Setting `lowFrequencyCutoff` to 0 gives the raw
model.

## Output

The complete response keeps the propagation delay: frame 0 is emission. The reflections-only response
omits the direct path and keeps the timing of the reflections. Samples are pressure relative to the
free-field pressure 1 m from the source. Each arrival is a band-limited impulse whose samples sum to
that relative pressure.

Responses are written as 32-bit float WAV with a JSON description beside them (same name, `.json`):

- Mono and stereo files use `WAVE_FORMAT_IEEE_FLOAT` with a `fact` chunk.
- Files with more than two channels use `WAVE_FORMAT_EXTENSIBLE` with no speaker mask. This is
  reserved for true-stereo LL, LR, RL and RR paths.

The description has format `dev.roomcad.impulse-response`, version 1, and covers:

- sample rate and frame count;
- each channel's source, receiver and position;
- content (complete or reflections only) and the emission frame;
- the gain convention and a common gain;
- the usable band, and the frequency below which the model is approximate;
- the model's assumptions;
- every conditioning step, in order.

The generator's settings and diagnostics go under `generatorDetails`, so the run can be reproduced.
Readers of the interchange contract may ignore that key.

Conditioning never changes relative channel levels or timing. A common gain, such as peak
normalization, scales all channels together and multiplies `commonGain`. Removing leading delay trims
every channel by the same number of frames and makes `emissionFrame` negative. A fade-out applies a
half-cosine taper to the end of every channel.

## Verification

`swift test --package-path RoomCAD` (also part of `make check`) tests the following:

- The band weights sum to one at every frequency.
- First-order image positions, and reflection gains as products of coefficients.
- Rendered peaks for the direct sound and for each of the six first-order reflections, each from a
  room with only that surface reflecting, fall within half a sample of path length divided by c.
- An anechoic room gives energy proportional to 1/r² to within 1%. It has less than 10⁻⁶ of its energy
  more than 1 ms from the arrival.
- The reflections-only response equals the complete response minus the direct sound.
- The order limit is reported when it removes arrivals within the duration.
- The decay of a uniformly absorbing, purely specular room matches the decay expected of specular
  reflection (below).
- In a rigid room that scatters fully, the detected energy arrives at the diffuse-field rate 4πc/V to
  within 3%, including at a receiver 0.2 m from a corner.
- Scattering weakens each specular reflection by √(1 − s).
- With full scattering, the 1–8 kHz T30 averages within 6% of the Eyring estimate corrected for the
  spread of free path lengths (below), and at least 3% shorter than without scattering. In that small,
  absorbent room the difference is only about 8%, and single bands vary by a few percent between
  random realizations.
- Without scattering, and with an order limit that omits nothing, nothing is traced and the response
  does not depend on the ray count or seed.
- Beyond the order limit, rays carry the omitted images' incoherent energy within 0.5 dB in every
  window.
- In a room that scatters (s = 0.3), image sources to order 4 plus rays match image sources to order
  100 within 1.5 dB from 50 to 250 ms; within 0.6 dB at three positions in a release build. Without
  scattering, the gap depends on the listener's position: from −5.4 to +1.5 dB at three positions. An
  ideal mirror box's image sources add coherently with fixed phases, which incoherent rays cannot
  reproduce, but real rooms scatter enough to break that coherence.
- The same seed reproduces a response exactly. Another seed keeps the traced energy within 5%. The
  rendered 1 kHz band energy of a 0.2 s response stays within 1.5 dB, a random realization's
  variation, much like that between nearby points in a real room.
- Materials and settings saved before scattering existed decode with s = 0 and the default ray count
  and seed.
- First-order patterns have their textbook gains, including a figure of eight's inverted rear lobe. A
  cardioid hears the direct sound fully when facing the source, not at all facing away, and at a
  quarter of the energy side-on. In a fully scattering rigid room each pattern picks up its
  diffuse-field share of an omni's energy to within 5%. Stereo pairs are placed and aimed as specified,
  with left on the left.
- Responses are identical whether generated synchronously or asynchronously. A receiver rendered
  alone matches the same receiver among others, and a cancelled generation stops at once.
- The high-pass removes the low-frequency offset without changing the audible bands.
- WAV and metadata round trip, including unknown chunks and extensible files; integer PCM,
  non-finite samples and truncated files are rejected.

`swift run -c release --package-path RoomCAD acousticbench` repeats the analytical checks, renders
a reference room and exports its responses. Its results on the development Mac:

| Check | Result |
|---|---|
| Direct and first-reflection arrival times | worst error 0.42 samples at 48 kHz |
| Anechoic energy × r², 0.5 to 4 m | 1.0000 to 1.0001 |
| Anechoic energy more than 1 ms after the arrival | 10⁻³² without the high-pass; 2.9 × 10⁻⁴ with it |
| Reference room, 2 receivers × 1.5 s | about 4.0 million arrivals per receiver, 5.7 s; with scattering, 6.0 s including 40,000 rays |

### Comparison with a measured room

[RoomCAD against measured rooms](roomcad-validation.md) compares RoomCAD with ten measured responses
in each of two rooms from the BRAS database. In the 145 m³ seminar room:

- **Reverberation.** With only published absorption data, the reverberation time from 250 Hz to
  2 kHz is within 12%, and clarity within about one just-noticeable difference.
- **Modes.** The wave solver reproduces the room's modal fine structure at each position, with mode
  frequencies within about 1.5%.
- **Early reflections.** These follow the measured pattern at most positions (correlation 0.61,
  against 0.22 for the wrong position).
- **Low-frequency decay.** The bare wave solver's was about 30% too long. With each band matched to
  the diffuse decay, T30, EDT, clarity and definition at 63 and 125 Hz are within about 2 JND.

In the 3,100 m³ chamber music hall, built from solids, with absorption fitted to this model:

- **Clarity and definition.** C80, D50 and centre time are within about one JND from 500 Hz to 4 kHz.
- **Reverberation.** The decay is 13–40% too long, because the simplified hall lacks the pillars,
  ornament and chairs that scatter sound in the real one.

`RoomParameters` computes the ISO 3382-1 parameters it uses: EDT, T20, T30, C50, C80, D50 and
centre time, with Lundeby's noise compensation for measured responses.

### Playback in Driftbox

The exported stereo file was also played through Driftbox's own engine. That code is independent of
RoomCAD: native Driftbox's WAV decoder and its zero-latency `PartitionedConvolver`. Convolving a noise
burst matched direct convolution to 3 × 10⁻⁷ of the peak, and an impulse input reproduced the
response.

### Decay without scattering

With purely specular reflection, a path in direction u meets about r(|uₓ|/Lₓ + |u_y|/L_y + |u_z|/L_z)
walls. The energy arriving at time t is therefore the average over directions of β^(2ct·n(u)), where β
is the reflection coefficient and n(u) is that bracket. Eyring's formula replaces this average with
the value at the mean of n(u). Directions that rarely meet a wall dominate the late decay, so the
specular decay is slower than Eyring's.

Two checks confirm the model behaves this way:

- In a 5 × 4 × 3 m room with α = 0.5, the 1–8 kHz octave-band T30 averages within 6% of the specular
  average. It is longer than the Eyring estimate.
- With α = 0.3, the arrivals' incoherent energy gives T30 = 0.339 s, against 0.336 s for the specular
  average and 0.288 s for Eyring.

The reference room (8 × 6 × 3 m, α = 0.2) shows the same thing:

| Band | Sabine | Eyring | Rendered T30 |
|---|---|---|---|
| 500 Hz | 0.64 s | 0.57 s | 0.87–0.91 s |
| 1 kHz | 0.63 s | 0.57 s | 0.87–0.89 s |
| 4 kHz | 0.58 s | 0.53 s | 0.69–0.70 s |

Without scattering, the rendered reverberation is longer than in real rooms with the same absorption,
because real rooms scatter sound and that makes the field more diffuse.

### Decay with scattering

When every reflection scatters, the decay should approach diffuse-field theory. Eyring's formula
assumes every free path between reflections has the mean length 4V/S. Kuttruff corrects it for the
spread of path lengths:

T ≈ T_Eyring / (1 + (γ²/2) ln(1 − α))

Here γ² is the relative variance of the free path lengths, about 0.4 in rooms of ordinary shape. This
correction is quoted from Kuttruff from memory and should be checked against the book. It predicts
times 7.7% and 16% longer than Eyring's for α = 0.3 and 0.5. In a fully scattering 5 × 4 × 3 m room the
tracer gives 8% and 12.5% longer, and the test above holds the α = 0.5 case to within 6% of the
corrected value.

The reference room with scattering rising from 0.1 at 63 Hz to 0.6 at 4–8 kHz, an illustrative
furnished room, decays between the Eyring and Sabine estimates. About 75% of its energy from 500 Hz to
4 kHz arrives scattered:

| Band | Sabine | Eyring | T30 specular only | T30 with scattering |
|---|---|---|---|---|
| 125 Hz | 0.64 s | 0.58 s | 0.98–1.02 s | 0.55–0.57 s |
| 500 Hz | 0.64 s | 0.57 s | 0.87–0.91 s | 0.58–0.65 s |
| 1 kHz | 0.63 s | 0.57 s | 0.87–0.89 s | 0.60–0.61 s |
| 4 kHz | 0.58 s | 0.53 s | 0.69–0.70 s | 0.54–0.55 s |

## Limitations

- **Geometry.** Rooms are boxes, floor plans with vertical walls, or closed meshes of flat faces.
  Curved walls are approximated by flat faces. Pillars, furniture and ornament are not modelled as
  objects, and nothing yet stands in for the sound they scatter. Coupled spaces work only as one mesh.
  A floor plan's or mesh's image sources reach only modest orders, with rays carrying the rest.
- **Meshes in the app.** A mesh comes from a preset or a measured scene. The app shows it and edits
  its materials, but it cannot edit its shape. Openings in a mesh are open faces, not rectangles.
- **Scattering.** Published scattering values exist only for a few surfaces (seven presets). Others
  are inputs, and the starter room's are illustrative. With little scattering, decay is too long and flutter between parallel surfaces is
  exaggerated (above).
- **Diffuse part.** The scattered part is an energy envelope with random detail, not a wave solution.
  It carries no direction and no interference between scattered paths. Each bin's energy is shared
  equally across its impulses in every band, so its fine structure is the same in all bands. The
  tracer's noise (a few percent per 5 ms at 40,000 rays) is smoothed but remains.
- **Diffraction.** There is none.
- **Reflection coefficients.** These are angle-independent, real and positive. Without the wave
  solver, the low-frequency behaviour is approximate below the reported Schroeder frequency,
  `2000 √(T/V)` with the Sabine time at 500 Hz–1 kHz.
- **Air attenuation.** This uses each band's centre value, so it is underestimated above about
  11 kHz.
- **Filter artefacts.** The zero-phase band filters and high-pass can put small pre-echoes ahead of
  an arrival whose band gains differ. The high-pass also spreads about 3 × 10⁻⁴ of each arrival's
  energy around it.
- **Hard end.** Responses end at the duration, which is a hard cut unless a fade-out is applied.
- **Incoherent late specular energy.** Specular reflections beyond the order limit are rendered as an
  incoherent envelope, which misses an ideal mirror box's coherent interference (above).
- **Materials.** Presets give published random-incidence absorption from 125 Hz, extended to 63 Hz
  and, where missing, to 8 kHz (see [the app's presets](roomcad-app.md#material-presets)). The bench's
  α = 0.2 is illustrative.
- **Performance.** The wave solver runs on the GPU; image sources and ray tracing run on the CPU's
  cores.

## Future work

The roadmap orders the work as follows:

- more sourced scattering data (M5);
- wave-solver walls that also absorb at grazing incidence, such as extended-reaction or
  frequency-dependent complex impedances, checked against the measured room;
- a way to stand in for the scattering of pillars, ornament and seating in a simplified hall, which
  the chamber music hall's comparison shows is needed;
- the remaining BRAS auditorium, CR4, built from solids.

A synthetic late tail (M2 item 4) is no longer needed: rays carry every reflection beyond the image
sources' order.

The ray tracer and image sources could run on the GPU.

## Sources

- J. B. Allen and D. A. Berkley, "Image method for efficiently simulating small-room acoustics",
  *J. Acoust. Soc. Am.* 65 (4), 943–950, 1979.
- J. Borish, "Extension of the image model to arbitrary polyhedra", *J. Acoust. Soc. Am.* 75 (6),
  1827–1836, 1984, for image sources in rooms of any shape.
- E. Wallace, csg.js (https://github.com/evanw/csg.js, MIT licence), for constructive solid geometry
  with binary space partitioning trees.
- ISO 9613-1:1993, *Acoustics — Attenuation of sound during propagation outdoors — Part 1:
  Calculation of the absorption of sound by the atmosphere*. The equations are as transcribed by
  [sengpielaudio](https://sengpielaudio.com/LuftdaempfungFormel.htm).
- ISO 3382-1:2009, *Acoustics — Measurement of room acoustic parameters — Part 1: Performance
  spaces*, for Schroeder backward integration, T30 and the other room-acoustic parameters.
- H. Kuttruff, *Room Acoustics*, 6th edn, CRC Press, 2016, for the Sabine and Eyring formulae, the
  Schroeder frequency, decay in non-diffuse rooms, the correction for the spread of free path
  lengths, and ray tracing with diffuse reflection.
- M. Vorländer, *Auralization: Fundamentals of Acoustics, Modelling, Simulation, Algorithms and
  Acoustic Virtual Reality*, Springer, 2008, annex, for the material presets, via the pyroomacoustics
  materials database (https://github.com/LCAV/pyroomacoustics, MIT licence).
- L. Aspöck, M. Vorländer, F. Brinkmann, D. Ackermann and S. Weinzierl, *Benchmark for Room
  Acoustical Simulation (BRAS)*, TU Berlin and RWTH Aachen, 2020, DOI 10.14279/depositonce-6726.3,
  CC BY-SA 4.0, for the measured seminar room and chamber music hall.
- A. Lundeby, T. E. Vigran, H. Bietz and M. Vorländer, "Uncertainties of measurements in room
  acoustics", *Acustica* 81, 344–355, 1995, for noise compensation in measured decay.
- ISO 17497-1:2004, *Acoustics — Sound-scattering properties of surfaces — Part 1: Measurement of the
  random-incidence scattering coefficient in a reverberation room*, for the definition of s.
