# Room-acoustics model

RoomCAD's first acoustic backend generates impulse responses of rectangular rooms for
convolution reverb. It lives in the separate `RoomCAD` package: `Sources/AcousticCore` holds the
model and `Sources/ImpulseResponseKit` holds the response format and WAV files. It is milestone M2
of the [RoomCAD roadmap](roomcad-roadmap.md). There is no RoomCAD app or document yet.

## What it models

The model covers one omnidirectional point source and up to 16 omnidirectional point receivers in a
rectangular room whose interior spans `[0, size]` in metres, z up. Each receiver becomes one output
channel. Two receivers give the mono-to-stereo case. Each of the six surfaces has its own material,
given as energy absorption coefficients α in eight octave bands (nominally 63 Hz to 8 kHz). The model
is geometrical acoustics: specular reflection only, with no wave effects except those the coherent sum
of images reproduces.

## Image sources

Along an axis of length L, a source at s has images at (1 − 2q)s + 2nL for integer n and q ∈ {0, 1}.
Such an image has met the wall at 0 |n − q| times and the wall at L |n| times (Allen and Berkley,
1979). An image's reflection order is the total over the three axes. Each image delivers one arrival,
with:

| Quantity | Value |
|---|---|
| Delay | r / c, with c = 331.3 √(T / 273.15 K) m/s (343.2 m/s at 20 °C) |
| Spreading | 1 / r, relative to the free-field pressure 1 m from the source |
| Reflection | the product of √(1 − α) over the surfaces met, per band; real and positive, so no phase shift and no angle dependence |
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
- The decay of a uniformly absorbing room matches the decay expected of purely specular reflection
  (below).
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
| Reference room, 2 receivers × 1.5 s | about 4.0 million arrivals per receiver, 5.8 s |

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

The rendered reverberation is longer than real rooms with the same absorption. Real rooms scatter
sound, which makes the field more diffuse.

## Limitations

- **Geometry.** Only rectangular rooms, with one material per surface, are supported. There are no
  openings, no furniture and no coupled spaces.
- **Specular reflection only.** There is no scattering or diffraction, so late decay is too long
  and too regular (above). Flutter between parallel surfaces is exaggerated.
- **Reflection coefficients.** These are angle-independent, real and positive. The low-frequency
  behaviour is approximate below the reported Schroeder frequency, `2000 √(T/V)` with the Sabine time
  at 500 Hz–1 kHz.
- **Air attenuation.** This uses each band's centre value, so it is underestimated above about
  11 kHz.
- **Filter artefacts.** The zero-phase band filters and high-pass can put small pre-echoes ahead of
  an arrival whose band gains differ. The high-pass also spreads about 3 × 10⁻⁴ of each arrival's
  energy around it.
- **No late tail.** Responses end at the duration, which is a hard cut unless a fade-out is applied.
- **Materials.** There are no sourced material presets yet, only rigid, anechoic and uniform
  coefficients. The bench's α = 0.2 is illustrative.
- **Performance.** Generation runs on the CPU, on one thread per response.

## Future work

The roadmap orders the work as follows:

- an auditioning preview (M2 item 6);
- a bounded, labelled late tail if auditioning needs one (M2 item 4);
- scattering and diffuse reflection (M4);
- sourced material data (M5);
- the RoomCAD app and its `.roomcad` documents (M1);
- a low-frequency wave solver (M3).

Receivers could be generated in parallel.

## Sources

- J. B. Allen and D. A. Berkley, "Image method for efficiently simulating small-room acoustics",
  *J. Acoust. Soc. Am.* 65 (4), 943–950, 1979.
- ISO 9613-1:1993, *Acoustics — Attenuation of sound during propagation outdoors — Part 1:
  Calculation of the absorption of sound by the atmosphere*. The equations are as transcribed by
  [sengpielaudio](https://sengpielaudio.com/LuftdaempfungFormel.htm).
- ISO 3382-1:2009, *Acoustics — Measurement of room acoustic parameters — Part 1: Performance
  spaces*, for Schroeder backward integration and T30.
- H. Kuttruff, *Room Acoustics*, 6th edn, CRC Press, 2016, for the Sabine and Eyring formulae, the
  Schroeder frequency and decay in non-diffuse rooms.
