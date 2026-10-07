# Room-acoustics model

RoomCAD's first acoustic backend generates impulse responses of rectangular rooms for
convolution reverb. It lives in the separate `RoomCAD` package: `Sources/AcousticCore` holds the
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
- **Maximum reflection order.** Reflections above it are omitted. When this removes an arrival within
  the duration, the diagnostics record `orderLimitedAfter`, the earliest such delay. The response is
  incomplete from that time. No late tail is synthesized.

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
  inverting Paris's statistical absorption, α = (8/ξ)[1 + 1/(1 + ξ) − (2/ξ) ln(1 + ξ)]. The value is
  averaged over the bands the solver covers, and is at most about 0.951 for a real impedance. Using
  the normal-incidence relation instead made the walls absorb about half as much again at α = 0.3, and
  left the wave part 1.5–5.6 dB too quiet at the crossover.
- **Source and calibration.** The source injects volume velocity, a Gaussian derivative with no net
  volume. Each receiver's spectrum, taken at its exact sample times, is divided by the free-field
  pressure 1 m away, ρ·j2πf·Q(f)/4π. That gives the geometrical model's units and time origin.
- **Microphones.** A directional microphone's output is a·p − (1 − a)·ρc·(u · axis), with the
  velocity interpolated to the pressure's times. Near a source, the velocity's 1/(jkr) term then gives
  real gradient microphones' proximity effect, which the geometrical model's ideal pattern lacks.
- **Blending.** The two models are blended with complementary zero-phase half-cosine crossovers
  (±0.5 octave), which sum to one.

`WavePlan` chooses the crossover: twice the Schroeder frequency, between 80 and 250 Hz, lowered until
the work fits a budget of 4 × 10⁹ cell updates. Work grows as frequency to the fourth power. If even
60 Hz doesn't fit, the solver is skipped with a note: the stone church's modes are dense above about
60 Hz anyway. A fixed crossover from 40 to 500 Hz can be set instead. The solver runs on the CPU's
cores; small grids use one thread.

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
- The impedance inversion reproduces the absorption, and rooms over budget skip the solver.

Across the presets, the two models' energy just below the crossover agrees within 1.5 dB, except in the
chamber music hall (−4.3 dB). There the listener sits over a large absorbent floor of seats, where
sound passing over the seats cancels at low frequencies, the "seat dip" known from concert halls. Only
the wave model can show this, so the difference is probably physical, but it has not been checked
against a measurement. Generation with the solver takes 0.7–5.5 s for the presets.

Limitations of the solver:

- The wall impedance is real and the same at every frequency below the crossover.
- There is no air absorption, which is negligible there.
- It models a bare box: no furniture, scattering or openings.
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
- Without scattering, nothing is traced and the response does not depend on the ray count or seed.
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

- **Geometry.** Only rectangular rooms, with one material per surface, are supported. There are no
  openings, no furniture and no coupled spaces.
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
- **No late tail.** Responses end at the duration, which is a hard cut unless a fade-out is applied.
- **Materials.** Presets give published random-incidence absorption from 125 Hz, extended to 63 Hz
  and, where missing, to 8 kHz (see [the app's presets](roomcad-app.md#material-presets)). The bench's
  α = 0.2 is illustrative.
- **Performance.** Generation runs on the CPU's cores, but not on the GPU.

## Future work

The roadmap orders the work as follows:

- a bounded, labelled late tail if auditioning needs one (M2 item 4);
- more sourced scattering data (M5);
- frequency-dependent wall impedance and a GPU wave solver, for higher crossovers and larger rooms;
- comparison with measured room responses (M4 item 5).

The ray tracer and image sources could run on the GPU.

## Sources

- J. B. Allen and D. A. Berkley, "Image method for efficiently simulating small-room acoustics",
  *J. Acoust. Soc. Am.* 65 (4), 943–950, 1979.
- ISO 9613-1:1993, *Acoustics — Attenuation of sound during propagation outdoors — Part 1:
  Calculation of the absorption of sound by the atmosphere*. The equations are as transcribed by
  [sengpielaudio](https://sengpielaudio.com/LuftdaempfungFormel.htm).
- ISO 3382-1:2009, *Acoustics — Measurement of room acoustic parameters — Part 1: Performance
  spaces*, for Schroeder backward integration and T30.
- H. Kuttruff, *Room Acoustics*, 6th edn, CRC Press, 2016, for the Sabine and Eyring formulae, the
  Schroeder frequency, decay in non-diffuse rooms, the correction for the spread of free path
  lengths, and ray tracing with diffuse reflection.
- M. Vorländer, *Auralization: Fundamentals of Acoustics, Modelling, Simulation, Algorithms and
  Acoustic Virtual Reality*, Springer, 2008, annex, for the material presets, via the pyroomacoustics
  materials database (https://github.com/LCAV/pyroomacoustics, MIT licence).
- ISO 17497-1:2004, *Acoustics — Sound-scattering properties of surfaces — Part 1: Measurement of the
  random-incidence scattering coefficient in a reverberation room*, for the definition of s.
