# Room-acoustics model

RoomCAD's first acoustic backend generates impulse responses of rectangular rooms for
convolution reverb. It lives in the separate `RoomCAD` package: `Sources/AcousticCore` holds the
model and `Sources/ImpulseResponseKit` holds the response format and WAV files. It covers milestone
M2 and the scattering part of M4 of the [RoomCAD roadmap](roomcad-roadmap.md). The app that edits rooms and generates responses is
described in [RoomCAD app and documents](roomcad-app.md).

## What it models

The model covers one omnidirectional point source and up to 16 omnidirectional point receivers in a
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
response duration. Arrivals are streamed to the renderer rather than stored. A 1.5 s response of an
8 × 6 × 3 m room has about four million arrivals per receiver. On the development Mac it takes about
3 s per receiver.

Two limits bound the work, and both are explicit settings:

- **Duration.** Arrivals later than the duration are omitted.
- **Maximum reflection order.** Reflections above it are omitted. When this removes an arrival within
  the duration, the diagnostics record `orderLimitedAfter`, the earliest such delay. The response is
  incomplete from that time. No late tail is synthesized.

Settings that would need more than 40 million image sources per receiver are rejected.

## Scattered energy

`DiffuseRayTracer` follows rays from the source, by default 40,000 of them, in evenly spread directions
(a spherical Fibonacci lattice) given a random rotation.

At each wall a ray keeps a fraction 1 − α of its energy per band. It then either scatters, leaving in a
cosine-weighted random direction, or reflects specularly. It scatters with probability p, the
surface's mean scattering coefficient, kept between 0.05 and 0.95 when the surface scatters at all.
Each band's energy is then multiplied by s/p or (1 − s)/(1 − p), so every band keeps its exact
expectation even though one path serves all eight. Rays stop at the response duration, or once their
energy is about 150 dB down.

Each receiver is a sphere of radius 0.4 m. Once a ray has scattered, crossing a sphere deposits its
energy × 4π × chord length / V. V is the volume of the part of the sphere inside the room, so receivers
near walls are not biased. That normalization makes a free-field source give 1/r², the same units as
an image source's squared gain. Deposits go into 1 ms bins per octave band, with air absorption applied
over the path length.

`DiffuseTail` turns each receiver's histogram, smoothed over ±2 ms, into impulses with random signs at
random times within each bin. Each bin's impulses share its energy equally in every band, so they add
incoherently to it. Their density follows a room's reflection density, 4πc³t²/V per second, between
2,000 and 20,000 per second. They go through the same renderer as the image sources.

The ray directions and the tail's detail come from `randomSeed`, so a response is reproduced exactly.
A surface with s = 0 in every band leaves the response exactly as the image sources alone give it, and
no rays are traced.

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
  spread of free path lengths (below), and each band decays faster than without scattering.
- Without scattering, nothing is traced and the response does not depend on the ray count or seed.
- The same seed reproduces a response exactly; another seed changes its detail but keeps its energy
  within 5%.
- Materials and settings saved before scattering existed decode with s = 0 and the default ray count
  and seed.
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
- **Reflection coefficients.** These are angle-independent, real and positive. The low-frequency
  behaviour is approximate below the reported Schroeder frequency, `2000 √(T/V)` with the Sabine time
  at 500 Hz–1 kHz.
- **Air attenuation.** This uses each band's centre value, so it is underestimated above about
  11 kHz.
- **Filter artefacts.** The zero-phase band filters and high-pass can put small pre-echoes ahead of
  an arrival whose band gains differ. The high-pass also spreads about 3 × 10⁻⁴ of each arrival's
  energy around it.
- **No late tail.** Responses end at the duration, which is a hard cut unless a fade-out is applied.
- **Materials.** Presets give published random-incidence absorption from 125 Hz, extended to 63 Hz
  and, where missing, to 8 kHz (see [the app's presets](roomcad-app.md#material-presets)). The bench's
  α = 0.2 is illustrative.
- **Performance.** Generation runs on the CPU, on one thread per response.

## Future work

The roadmap orders the work as follows:

- a bounded, labelled late tail if auditioning needs one (M2 item 4);
- more sourced scattering data (M5);
- a crossover to the low-frequency wave solver (the rest of M4);
- a low-frequency wave solver (M3).

Receivers could be generated in parallel, and the ray tracer could run on the GPU.

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
