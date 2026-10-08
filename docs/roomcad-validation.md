# RoomCAD against measured rooms

This report compares RoomCAD's responses with measurements in two real rooms from the Benchmark for
Room Acoustical Simulation (BRAS):

- scene CR2, the seminar room at RWTH Aachen University;
- scene CR3, the chamber music hall of the Konzerthaus Berlin, which is 20 times larger (see
  [A larger room](#a-larger-room-the-chamber-music-hall)).

It is the comparison that roadmap milestone M4 item 5 asks for. It sets out what agrees, what doesn't and why,
and separates agreement with the measurements from what the model's assumptions decide.

## The room and the data

BRAS describes CR2 as a room with a simple geometry and challenging low-frequency behaviour: 145 m³,
almost empty, with hard walls and a reverberation time of about 2 s at mid frequencies. BRAS
provides:

- a SketchUp model;
- photographs;
- the positions of two dodecahedron loudspeakers and five omnidirectional microphones;
- ten measured room impulse responses at 44.1 kHz, one per source–microphone pair;
- each material's random-incidence absorption and scattering in third octaves, in two sets.

The two material sets are:

- **Initial estimates**, from published data and impedance-tube measurements, made without
  reference to the room's measured decay. This is an honest prediction.
- **Fitted estimates**, the initial ones scaled in each third octave so that Eyring's formula gives
  the measured reverberation time. This is what a designer would do after measuring.

RoomCAD's version of the room is in `RoomCAD/Validation/bras-cr2/scene.json`, and how it was derived
is in that folder's README. In short:

- **Geometry.** The plan is 14 vertical walls, taken from the SketchUp model's vertices; it ignores
  three 12 cm window recesses. Its volume is 145.7 m³, against BRAS's 145 m³.
- **Walls of mixed material.** Walls with two materials take an area-weighted mean: the window
  wall, and two walls that are partly plaster and partly concrete.
- **Materials by octave.** Each material's octave values are the mean of its three third octaves.
- **The source's drivers.** The dodecahedron has three drivers at different heights, with
  crossovers at 177 Hz and 1.42 kHz. RoomCAD simulates each driver at its own height. The three
  responses are kept to their bands by complementary crossovers and summed.
- **Air.** It is set to the measured 19.5 °C and 41.7% relative humidity.

## Method

`make roomcad-validate` runs `acousticbench --bras-cr2` and then `--bras-cr3`. For CR2 it simulates all ten pairs, 3.5 s long like the
measurements, in four configurations:

- the initial materials with the wave solver;
- BRAS's fitted materials with the wave solver;
- materials fitted to this model, with the wave solver and without it;
- for a scene with fitted zones, the same with them;
- materials fitted by simulating this model, with the wave solver.

BRAS fitted its materials to its own model, with its own volume and areas, in third octaves.
**Fitted to this model** instead takes the initial materials and scales their absorption in each
octave so that Eyring's formula, with this model's volume, areas and air, gives the measured mean
T30 (`ValidationScene.refitting`). This is what a designer with a measurement would do. The two
fitted sets differ by up to 10% in Eyring's estimate here.

**Fitted by simulating this model** goes one step further. It takes the set fitted to this model and
scales its absorption in each band until RoomCAD's own simulated T30 matches the measured mean
(`AbsorptionCalibration`; see
[Matching a measured reverberation time](room-acoustics-model.md#matching-a-measured-reverberation-time)).
The fit simulates one driver of loudspeaker 1 at all five microphones. With T30 matched by
construction, what remains to compare is the shape of the decay: EDT, clarity, definition and centre
time.

It analyses the measured and the simulated responses in the same way. Each one is timed in each
octave band from that band's own onset, the first sample within 20 dB of the band's peak. This
matters because the dodecahedron's crossover delays its low-frequency driver by up to 20 ms.

**Parameters.** These are the ISO 3382-1 parameters: EDT, T20, T30, C50, C80, D50 and centre time
Ts, all from Schroeder's backward integral (`RoomParameters`). A measured response ends in
background noise, so it is cut where its decay meets the noise, and the missing decay is added back
from the slope, after Lundeby et al. A simulated response has no noise and is integrated whole. The
tables give the mean over the ten pairs. Each simulated mean is followed by its difference from the
measured mean in just-noticeable differences (JNDs): 5% for decay times, 1 dB for C50 and C80, 0.05
for D50 and 10 ms for Ts (ISO 3382-1, Annex A).

**Low-frequency fine structure.** From 30 to 175 Hz, the spectrum's level 1/24 octave apart, less
its mean over the surrounding octave, leaves the modal peaks and dips. The source's and the room's
broad trends are removed. The correlation between measured and simulated fine structure is given at
the same position, and, as a baseline, against the other positions. The simulated spectrum is also
read with its frequencies scaled by up to ±4%, which shows any systematic shift of the mode
frequencies.

**Early reflections.** Above 500 Hz, the energy in 1 ms bins from 1.5 to 19.5 ms after the direct
sound is compared as a level. It is correlated at the same position, and at other positions as a
baseline.

The measured parameters are kept in `RoomCAD/Validation/bras-cr2/measured.json`, so the comparison
runs without downloading the measurements. `RoomCAD/Scripts/fetch-bras.py` fetches the 6 MB of
BRAS that the fixture is derived from, and `acousticbench --bras-cr2 --update-fixture` rebuilds the
fixture from it. A run takes about 6 minutes on a Mac Studio (M4 Max), almost all of it in the wave
solver.

## Results

The first run of this comparison found the wave solver's low-frequency decay too long. Its walls are
locally reacting, and they take only half as much energy from modes that graze them as from modes that
strike them. With the fitted materials, its T30 at 63 and 125 Hz came out 2.02 and 1.85 s, against
1.71 and 1.40 s measured. The solver now damps each band so the room decays, on average, at Eyring's
diffuse rate (see [the wave solver](room-acoustics-model.md#low-frequencies-the-wave-solver)). The
results below include that matching. The probes measured the bare decay at 1.25–1.35 times Eyring's
estimate in each of the solver's bands.

### Reverberation time

T30, mean over the pairs (measured ± spread across the pairs), with JNDs in brackets:

| | 63 Hz | 125 Hz | 250 Hz | 500 Hz | 1 kHz | 2 kHz | 4 kHz | 8 kHz |
|---|---|---|---|---|---|---|---|---|
| Measured | 1.71 ± 0.47 | 1.40 ± 0.12 | 1.72 ± 0.14 | 2.02 ± 0.04 | 1.94 ± 0.04 | 1.75 ± 0.02 | 1.57 ± 0.01 | 1.03 ± 0.02 |
| Initial | 3.22 (+18) | 2.61 (+17) | 1.92 (+2.3) | 1.81 (−2.1) | 1.84 (−1.0) | 1.67 (−0.9) | 1.27 (−3.7) | 0.71 (−6.2) |
| Fitted by BRAS | 1.53 (−2.1) | 1.45 (+0.7) | 1.91 (+2.2) | 2.24 (+2.2) | 2.12 (+1.9) | 1.92 (+1.9) | 1.67 (+1.3) | 0.94 (−1.7) |
| Fitted to this model | 1.69 (−0.2) | 1.52 (+1.6) | 2.01 (+3.4) | 2.16 (+1.4) | 2.01 (+0.8) | 1.81 (+0.7) | 1.58 (+0.2) | 0.99 (−0.7) |
| Fitted to this model, no wave solver | 1.70 (−0.1) | 1.68 (+3.9) | 2.01 (+3.3) | 2.16 (+1.4) | 2.01 (+0.8) | 1.81 (+0.7) | 1.58 (+0.2) | 0.99 (−0.7) |

T20 and EDT follow the same pattern.

- **250 Hz to 2 kHz, initial materials.** RoomCAD predicts the measured T30 to within 12% (−10% to
  +12%) from published material data alone. That is the most useful result, because a designer
  usually has no measurement.
- **Fitted materials.** Fitted to this model, Eyring's estimate equals the measured T30 by
  construction. RoomCAD's decay is then within 4% of it from 1 to 8 kHz, but 7–17% longer from 125 to
  500 Hz. In a room this close to a box, with scattering of only 0.05–0.07 below 1 kHz on the walls
  and floor, some sound keeps travelling between parallel surfaces and decays more slowly than in a
  diffuse field. This is the non-diffuse decay that Kuttruff describes, and the geometrical model
  shows it for that reason. The real room has chairs, radiators and fittings that scatter more.
  BRAS's fitted set gives decay 6–11% long from 250 Hz to 4 kHz.
- **4 and 8 kHz, initial materials.** The decay is 19% and 31% too short. The initial high-frequency
  absorption, including air, is too high for this room. The fitted sets correct it.
- **63 and 125 Hz, initial materials.** The decay is nearly twice as long as measured. The published
  absorption of plaster and concrete is only 0.02–0.05 there. The real room loses much more energy at
  low frequencies, through the windows' and doors' flexibility and transmission. A designer needs
  realistic low-frequency absorption for small rooms, which published coefficients for hard walls
  don't give.
- **63 and 125 Hz, fitted materials.** With the wave solver, the decay is within 11% and 4% of the
  measurement with BRAS's set, and 1% and 9% with the set fitted to this model. Geometrical acoustics
  alone gives −1% and +20% with the latter.

### Clarity, definition and early decay

| | | 63 Hz | 125 Hz | 250 Hz | 500 Hz | 1 kHz | 2 kHz | 4 kHz | 8 kHz |
|---|---|---|---|---|---|---|---|---|---|
| C80 (dB) | Measured | 2.7 ± 2.4 | 0.8 ± 2.0 | 1.0 ± 1.3 | −1.4 ± 0.7 | −0.8 ± 0.6 | −0.1 ± 0.6 | 0.2 ± 0.4 | 6.8 ± 0.5 |
| | Initial | −2.9 (−5.6) | −1.9 (−2.6) | −2.4 (−3.4) | −0.6 (+0.8) | −1.2 (−0.4) | 0.1 (+0.2) | 2.1 (+1.9) | 6.4 (−0.3) |
| | Fitted by BRAS | 1.1 (−1.6) | 1.7 (+0.9) | −2.5 (−3.4) | −1.9 (−0.5) | −2.1 (−1.3) | −0.9 (−0.7) | 0.1 (−0.0) | 3.8 (−3.0) |
| | Fitted to this model | 0.5 (−2.1) | 1.5 (+0.8) | −2.9 (−3.9) | −1.7 (−0.3) | −1.8 (−1.0) | −0.5 (−0.4) | 0.4 (+0.2) | 3.1 (−3.6) |
| | Fitted to this model, no wave solver | −1.1 (−3.8) | −0.6 (−1.3) | −3.0 (−4.0) | −1.7 (−0.3) | −1.8 (−1.0) | −0.5 (−0.4) | 0.4 (+0.2) | 3.1 (−3.6) |
| D50 | Measured | 0.48 ± 0.14 | 0.36 ± 0.09 | 0.42 ± 0.12 | 0.30 ± 0.05 | 0.32 ± 0.04 | 0.36 ± 0.03 | 0.36 ± 0.02 | 0.69 ± 0.03 |
| | Initial | 0.26 (−4.4) | 0.28 (−1.6) | 0.26 (−3.1) | 0.34 (+0.7) | 0.29 (−0.5) | 0.36 (+0.1) | 0.46 (+2.0) | 0.66 (−0.6) |
| | Fitted by BRAS | 0.44 (−0.8) | 0.44 (+1.6) | 0.26 (−3.2) | 0.28 (−0.5) | 0.26 (−1.2) | 0.32 (−0.8) | 0.36 (+0.0) | 0.54 (−3.0) |
| | Fitted to this model | 0.42 (−1.3) | 0.43 (+1.4) | 0.24 (−3.6) | 0.29 (−0.3) | 0.27 (−0.9) | 0.33 (−0.5) | 0.38 (+0.3) | 0.51 (−3.6) |
| | Fitted to this model, no wave solver | 0.28 (−4.1) | 0.29 (−1.4) | 0.23 (−3.7) | 0.29 (−0.3) | 0.27 (−0.9) | 0.33 (−0.5) | 0.38 (+0.3) | 0.51 (−3.6) |

- **500 Hz to 2 kHz.** C80 and D50 are within about one JND with any material set. EDT is within
  about 2 JND with the initial set and the set fitted to this model; BRAS's set gives EDT 2–3 JND
  long, like its T30.
- **63 and 125 Hz, fitted materials.** With the wave solver, clarity, definition and EDT are within
  about 1.6 JND with BRAS's set, and 2.1 JND with the set fitted to this model, except EDT at 63 Hz
  (3.3 JND long). Without the solver, clarity and definition at 63 Hz are about 4 JND too low:
  geometrical acoustics misses how the room's modes shape the early energy.
- **250 Hz.** Every configuration gives 3.4–4 dB less clarity than measured. This band lies
  above the wave solver's crossover (174 Hz), where the geometrical model's slow, nearly specular
  decay applies.
- **8 kHz.** The measured response is much clearer than its own decay suggests: EDT 0.68 s against
  T30 1.03 s, and C80 6.8 dB. BRAS's fitted set gives 3 dB less. At 8 kHz a dodecahedron is
  noticeably directional, which RoomCAD's omnidirectional source does not reproduce, so this is
  probably the source, not the room. The set fitted to this model gives 3.6 dB less.

### Low-frequency fine structure

From 30 to 175 Hz:

| | Same position | Other positions | Best frequency scale |
|---|---|---|---|
| Initial | 0.63 ± 0.08 | 0.39 | 0.67, simulated frequencies 1.5% higher |
| Fitted by BRAS | 0.63 ± 0.09 | 0.37 | 0.68, simulated frequencies 1.5% higher |
| Fitted to this model | 0.63 ± 0.09 | 0.38 | 0.68, simulated frequencies 1.5% higher |
| Fitted to this model, no wave solver | 0.14 ± 0.15 | 0.02 | 0.15, simulated frequencies 1% higher |

- **The wave solver reproduces the room's modal structure.** At the same position the fine
  structure correlates at 0.63, against 0.14 for geometrical acoustics alone, whose low end has no
  modes. Matching the decay left this unchanged.
- **Position-specific structure.** The correlation is higher at the same position than at others
  (0.37), so the solver captures where each mode is loud or quiet, not just its frequency.
- **Mode frequencies.** Raising the simulated frequencies by 1–1.5% improves the agreement slightly,
  so the measured modes lie about 1.5% higher than the simulated ones. The solver's own mode
  frequencies are checked to 0.25% in a rigid box. The likely cause is that the simplified room is a
  little too large acoustically: it leaves out radiators, sills, window frames and ceiling lights.

### Early reflections

Above 500 Hz, between 1.5 and 19.5 ms, the correlation is the same in every configuration, since
the wave solver works only below 174 Hz: 0.60–0.61 ± 0.25 at the same position, against 0.21–0.22 at
others.

The simulated early reflections follow the measured pattern at most positions. They are not identical.
The dodecahedron spans about 30 cm, and its drivers radiate unevenly. The measured onsets imply
positions that agree with the documented ones to within about ±20 cm. The model also leaves out the
window recesses, sills and fittings, which add reflections of their own. One pair, loudspeaker 1 to
microphone 2, doesn't correlate at all. Two of the measured responses from loudspeaker 2 have a weak
direct sound and strong arrivals near 10 and 16 ms that the model lacks.

### Fitted by simulating the model

The fit took three simulations. The absorption rose by 4–25% from 125 Hz to 2 kHz, most at 250 Hz,
and by 13% at 8 kHz; it fell by 2% at 63 Hz.

| | | 63 Hz | 125 Hz | 250 Hz | 500 Hz | 1 kHz | 2 kHz | 4 kHz | 8 kHz |
|---|---|---|---|---|---|---|---|---|---|
| T30 (s) | Measured | 1.71 ± 0.47 | 1.40 ± 0.12 | 1.72 ± 0.14 | 2.02 ± 0.04 | 1.94 ± 0.04 | 1.75 ± 0.02 | 1.57 ± 0.01 | 1.03 ± 0.02 |
| | Simulated | 1.73 (+0.2) | 1.35 (−0.8) | 1.72 (−0.0) | 2.01 (−0.1) | 1.94 (−0.0) | 1.75 (−0.0) | 1.57 (+0.0) | 0.97 (−1.2) |
| EDT (s) | Measured | 1.36 ± 0.27 | 1.41 ± 0.23 | 1.45 ± 0.10 | 1.98 ± 0.14 | 1.90 ± 0.07 | 1.72 ± 0.05 | 1.58 ± 0.03 | 0.68 ± 0.03 |
| | Simulated | 1.62 (+3.8) | 1.32 (−1.2) | 1.63 (+2.5) | 2.05 (+0.7) | 2.01 (+1.1) | 1.71 (−0.1) | 1.56 (−0.3) | 1.01 (+9.6) |
| C80 (dB) | Measured | 2.7 ± 2.4 | 0.8 ± 2.0 | 1.0 ± 1.3 | −1.4 ± 0.7 | −0.8 ± 0.6 | −0.1 ± 0.6 | 0.2 ± 0.4 | 6.8 ± 0.5 |
| | Simulated | 0.4 (−2.3) | 2.2 (+1.5) | −1.8 (−2.7) | −1.2 (+0.2) | −1.5 (−0.8) | −0.3 (−0.2) | 0.5 (+0.3) | 3.4 (−3.4) |
| D50 | Measured | 0.48 ± 0.14 | 0.36 ± 0.09 | 0.42 ± 0.12 | 0.30 ± 0.05 | 0.32 ± 0.04 | 0.36 ± 0.03 | 0.36 ± 0.02 | 0.69 ± 0.03 |
| | Simulated | 0.41 (−1.4) | 0.46 (+2.1) | 0.29 (−2.6) | 0.31 (+0.1) | 0.28 (−0.7) | 0.34 (−0.3) | 0.38 (+0.3) | 0.52 (−3.4) |

- **500 Hz to 4 kHz.** With T30 matched, EDT, C80, D50 and centre time are all within about 1.1 JND.
  The model's decay has the right shape there.
- **250 Hz.** Clarity is still 2.7 JND low and EDT 2.5 JND long, better than with Eyring-fitted
  materials (3.9 and 7.3 JND). This band lies just above the wave solver's crossover, where the
  geometrical model's nearly specular decay is too slow at first.
- **8 kHz.** The early decay is still far too slow, as with every material set: probably the
  dodecahedron's directivity, as above.
- **Low frequencies and early reflections.** These are unchanged: fine structure 0.63, early
  reflections 0.61.

## A larger room: the chamber music hall

### The room

BRAS's scene CR3 is the chamber music hall of the Konzerthaus Berlin. Its features are:

- a flat floor of seating;
- side aisles under galleries, and a rear balcony;
- a stage behind a proscenium, 1 m above the floor, with a shell of angled panels;
- a flat ceiling at 7.6 m, with an attic above it that opens into the stage house.

The reverberation time is about 1.3 s at mid frequencies. Its Schroeder frequency is about 40 Hz,
so modes matter much less here than in CR2.

RoomCAD's version is in `RoomCAD/Validation/bras-cr3/`. Unlike CR2's, it is not a floor plan.

- **Pieces of air.** The room is built from 12 boxes and extrusions of air, joined, with the stage
  shell's panels and a 1 cm layer of seating cut out. RoomCAD turns them into a closed mesh with
  constructive solid geometry (see [Rooms of any shape](room-acoustics-model.md#rooms-of-any-shape)).
- **Simplifications.** The mesh leaves out the pillars between the galleries, the ornament on the
  walls and ceiling, and the chairs themselves.
- **Size.** Its volume is 3,119 m³, against 3,331 m³ in BRAS's model. Its surface area is 2,286 m²,
  against 2,763 m². Most of the missing area is structured plaster: 565 m² here, against 1,172 m².

The folder's README lists the pieces and the material areas.

### Materials fitted to this model

BRAS's fitted materials make Eyring's formula give the measured T30 in BRAS's own model. Here the
volume and surface areas differ, so with those materials Eyring's formula gives times up to 19%
longer than measured: 16–19% from 500 Hz to 2 kHz. The set **fitted to this model** (see [Method](#method)) matters more here than in
CR2, where the two sets differ by up to 10%.

### Results

T30, mean over the ten pairs, with JNDs in brackets:

| | 63 Hz | 125 Hz | 250 Hz | 500 Hz | 1 kHz | 2 kHz | 4 kHz | 8 kHz |
|---|---|---|---|---|---|---|---|---|
| Measured | 1.98 ± 0.25 | 1.62 ± 0.07 | 1.45 ± 0.04 | 1.29 ± 0.03 | 1.33 ± 0.03 | 1.32 ± 0.01 | 1.06 ± 0.02 | 0.72 ± 0.03 |
| Initial | 3.05 (+11) | 2.83 (+15) | 2.93 (+21) | 2.24 (+15) | 1.69 (+5.3) | 1.36 (+0.6) | 1.14 (+1.5) | 0.70 (−0.6) |
| Fitted by BRAS | 2.01 (+0.3) | 2.25 (+7.8) | 2.22 (+11) | 1.89 (+9.2) | 1.81 (+7.1) | 1.71 (+5.9) | 1.30 (+4.5) | 0.80 (+2.3) |
| Fitted to this model | 1.98 (+0.0) | 2.00 (+4.7) | 2.03 (+8.0) | 1.70 (+6.3) | 1.57 (+3.6) | 1.49 (+2.6) | 1.21 (+2.9) | 0.82 (+2.8) |
| Fitted to this model, no wave solver | 2.45 (+4.8) | 2.06 (+5.5) | 2.03 (+8.0) | 1.70 (+6.3) | 1.57 (+3.6) | 1.49 (+2.6) | 1.21 (+2.9) | 0.82 (+2.8) |

Clarity and centre time, fitted to this model:

| | | 63 Hz | 125 Hz | 250 Hz | 500 Hz | 1 kHz | 2 kHz | 4 kHz | 8 kHz |
|---|---|---|---|---|---|---|---|---|---|
| C80 (dB) | Measured | 0.4 ± 2.2 | 0.4 ± 1.0 | 0.8 ± 2.1 | 1.6 ± 1.5 | 1.7 ± 0.7 | 1.6 ± 0.6 | 3.3 ± 0.8 | 9.0 ± 1.4 |
| | Simulated | −0.5 (−0.8) | 0.1 (−0.4) | −0.4 (−1.2) | 0.8 (−0.8) | 1.3 (−0.5) | 1.5 (−0.1) | 2.9 (−0.4) | 6.3 (−2.7) |
| Ts (ms) | Measured | 116 ± 21 | 113 ± 6 | 99 ± 17 | 94 ± 15 | 92 ± 9 | 91 ± 7 | 70 ± 8 | 36 ± 7 |
| | Simulated | 128 (+1.2) | 123 (+1.0) | 131 (+3.2) | 105 (+1.2) | 99 (+0.7) | 95 (+0.4) | 75 (+0.6) | 48 (+1.2) |

- **Clarity, definition and centre time.** Fitted to this model, these are within about one JND
  from 500 Hz to 4 kHz. Without the wave solver, C80 at 63 Hz is 3 JND low, as in CR2.
- **Decay.** T30 is still too long: 23–40% at 125–500 Hz, and 13–18% from 1 to 8 kHz. EDT is about
  3 JND long. With BRAS's own fitted set, the decay is 36–53% too long from 125 Hz to 1 kHz.
- **Low frequencies.** At 63 Hz the wave solver gives the measured T30 exactly, and EDT, C80 and D50
  within about 1.3 JND. Without it, T30 is 24% long and C80 is 3.3 JND low. The low-frequency fine
  structure doesn't correlate in any configuration (0.02–0.06). That is expected: the hall's modes
  above 40 Hz overlap, so its spectrum is a random pattern that depends on details the model
  leaves out.
- **Early reflections.** These correlate at 0.46 ± 0.23 at the same position, against 0.22 at others.
  With the initial materials the correlation is 0.53.
- **The initial materials.** From 2 to 8 kHz they predict T30 within 8%, but at 125–500 Hz the decay
  is 1.7–2 times too long. As in CR2, the published low-frequency absorption is too low.

### Why the decay is long

The geometrical model decays more slowly than Eyring's formula, even with the same volume and
absorption, because the room is not fully diffuse. Probing the hall with BRAS's fitted set, from
source LS1 to three receivers, without the wave solver:

| | 500 Hz | 1 kHz | 2 kHz |
|---|---|---|---|
| As modelled | +25% | +13% | +8% |
| Every surface scattering at least 0.5 | +13% | +6% | +3% |
| Every surface scattering fully | +13% | +7% | +4% |
| Without the attic | +23% | +11% | +10% |

These are T30 above Eyring's estimate for the same room. Two things make up the excess:

- **Scattering.** More scattering takes away about half of it. The simplified hall has smooth walls
  where the real one has pillars, coffers and mouldings, and a flat layer where it has chairs. BRAS's
  scattering coefficients describe surfaces on their own, not the objects in front of them.
- **Concentrated absorption.** The rest remains even when every surface scatters fully. Most of the
  hall's absorption is in the seating, on the floor, and Eyring's formula takes absorption to be spread
  evenly. With it concentrated, a diffuse room still decays more slowly than the formula says. Any
  model of the room would show this; fitting absorption to the formula cannot remove it.

The attic makes little difference.

### Chairs as fitted zones

BRAS models the seating as a material on the floor. It counts the chairs in its notes on the model:
246 in the stalls, 22 in each side gallery and 61 on the rear balcony. The configuration **fitted to
this model, with chairs** adds them as
[fitted zones](room-acoustics-model.md#fitted-zones), 0.9 m high over the seating. Each chair is
taken to have 1.5 m² of surface, an estimate, which gives a density of 0.8–1.0 per metre. Their
absorption stays with the seating material, so the fitted absorption is unchanged. T30, against the
measurement:

| | 125 Hz | 250 Hz | 500 Hz | 1 kHz | 2 kHz | 4 kHz | 8 kHz |
|---|---|---|---|---|---|---|---|
| Without chairs | +23% | +40% | +32% | +18% | +13% | +14% | +14% |
| With chairs | +15% | +31% | +22% | +15% | +12% | +15% | +11% |

The chairs shorten the decay by 8–10 points from 125 to 500 Hz, and make little difference above.
Clarity, definition and centre time change by less than a JND. The early reflections correlate at
0.45 ± 0.18, as before. Doubling each chair's surface did not shorten the decay further in a shorter
probe.

### Fitted by simulating the model

The fit kept, in each band, the closest of six simulations. The absorption rose by 12–61% from
125 Hz to 8 kHz, most at 250 and 500 Hz. At 63 Hz, which the wave solver holds, the time answered
the absorption erratically, and the fit lowered it by 40% to reach the measured 1.98 s.

| | | 63 Hz | 125 Hz | 250 Hz | 500 Hz | 1 kHz | 2 kHz | 4 kHz | 8 kHz |
|---|---|---|---|---|---|---|---|---|---|
| T30 (s) | Measured | 1.98 ± 0.25 | 1.62 ± 0.07 | 1.45 ± 0.04 | 1.29 ± 0.03 | 1.33 ± 0.03 | 1.32 ± 0.01 | 1.06 ± 0.02 | 0.72 ± 0.03 |
| | Simulated | 1.92 (−0.6) | 1.77 (+1.9) | 1.42 (−0.3) | 1.30 (+0.0) | 1.35 (+0.2) | 1.35 (+0.5) | 1.08 (+0.5) | 0.74 (+0.6) |
| EDT (s) | Measured | 1.62 ± 0.23 | 1.58 ± 0.20 | 1.37 ± 0.09 | 1.34 ± 0.10 | 1.31 ± 0.08 | 1.24 ± 0.04 | 1.04 ± 0.04 | 0.53 ± 0.06 |
| | Simulated | 1.64 (+0.2) | 1.45 (−1.6) | 1.24 (−1.8) | 1.10 (−3.6) | 1.27 (−0.5) | 1.27 (+0.5) | 1.04 (−0.1) | 0.70 (+6.3) |
| C80 (dB) | Measured | 0.4 ± 2.2 | 0.4 ± 1.0 | 0.8 ± 2.1 | 1.6 ± 1.5 | 1.7 ± 0.7 | 1.6 ± 0.6 | 3.3 ± 0.8 | 9.0 ± 1.4 |
| | Simulated | −0.2 (−0.5) | 1.8 (+1.4) | 2.4 (+1.6) | 3.4 (+1.9) | 2.7 (+0.9) | 2.2 (+0.7) | 3.6 (+0.3) | 6.4 (−2.5) |
| D50 | Measured | 0.42 ± 0.14 | 0.36 ± 0.11 | 0.42 ± 0.14 | 0.43 ± 0.12 | 0.43 ± 0.07 | 0.42 ± 0.05 | 0.52 ± 0.06 | 0.76 ± 0.06 |
| | Simulated | 0.38 (−0.8) | 0.49 (+2.6) | 0.45 (+0.6) | 0.56 (+2.4) | 0.52 (+1.7) | 0.48 (+1.4) | 0.55 (+0.5) | 0.67 (−1.7) |

- **T30.** It now matches within 0.6 JND, except at 125 Hz (+9%).
- **The shape of the decay.** From 1 to 4 kHz, EDT, clarity and centre time are within about 1.3
  JND. At 500 Hz, though, the early decay is now too fast: EDT is 3.6 JND short, and clarity and
  definition about 2 JND high. With Eyring-fitted materials, EDT and T30 were both too long. The
  simulated decay sags, falling quickly at first and more slowly later, where the measured one
  falls in a straight line. Matching one end of it leaves the other wrong. That is what a room
  that mixes its sound too little does: early on, sound meets the absorbing audience often; later,
  what is left travels between the walls and ceiling and meets it less. It points the same way as
  the diagnosis above: the simplified hall needs the scattering its smooth surfaces and missing
  objects lack.
- **Early reflections.** These correlate at 0.47 ± 0.26, as before.

## What the comparison shows

1. **Mid frequencies.** In the seminar room, from 250 Hz to 2 kHz, with only published material data,
   RoomCAD predicts reverberation time within 12%, and clarity and definition within about one JND.
   In the chamber music hall, with materials fitted to the model, clarity, definition and centre time
   are within about one JND from 500 Hz to 4 kHz.
2. **Diffuseness.** With absorption fitted so that Eyring's formula gives the measured T30, the
   geometrical model decays more slowly than the measurement, because the simplified rooms are not
   fully diffuse: 7–17% from 125 to 500 Hz in the seminar room, and 13–40% in the chamber music hall.
   Fitting materials to a measured T30 should therefore be done with RoomCAD itself rather than with
   Eyring's formula, which `AbsorptionCalibration` now does. In the seminar room, absorption fitted
   that way leaves EDT, clarity, definition and centre time within about 1.1 JND from 500 Hz to 4 kHz.
   In the chamber music hall, it shows the simplified hall's decay sagging at 500 Hz.
3. **Scattering by objects.** A hall simplified to smooth surfaces needs the scattering of its
   pillars, ornament and seating put back. Raising every surface's scattering to at least 0.5 halves
   the chamber music hall's excess decay.
4. **Low-frequency modes.** In the seminar room, the wave solver reproduces the modal fine structure
   and its position dependence, with mode frequencies within about 1.5%. In the hall, whose modes
   overlap above 40 Hz, neither model reproduces the fine structure, nor is it expected to.
5. **Low-frequency decay.** The bare wave solver's locally reacting walls let modes that graze them
   outlast a diffuse field, by about 30% here. With each band matched to the diffuse decay, the solver
   gives the measured T30, EDT, clarity and definition at 63 and 125 Hz within about 2 JND in the
   seminar room, and the measured T30 at 63 Hz in the hall.
6. **Early reflections.** These follow the measured pattern at most positions in both rooms
   (correlation 0.61 and 0.46, against 0.22 at the wrong position).
7. **Published low-frequency absorption.** For walls such as plaster and concrete, it is much lower
   than real rooms behave, in both rooms, which a designer must allow for.

## Limitations of the comparison

- **Two rooms.** Both are rectangular in essence. BRAS's CR4, an auditorium with a raked floor,
  rising side galleries and a fan-shaped plan, could be built from solids in the same way but has not
  been.
- **Large objects.** The chamber music hall's chairs are modelled as fitted zones, with an estimated
  surface area each. Its pillars and ornament are not modelled.
- **The source.** It is treated as omnidirectional, at each driver's height. Its directivity, the
  size of its drivers, and the crossover's phase are not modelled.
- **Geometry.** It is simplified, as listed above, and wall materials are averaged by area.
- **Fitted estimates.** They were fitted to the measured times with Eyring's formula, so they are not
  an independent prediction; they test the model's shape of decay.
- **Not a listening test.** The roadmap asks for listening comparisons as well; these have not been
  made.

## Tests

`MeasuredRoomTests` keeps parts of this comparison in the regular test suite, using the fixture:

- the simplified room's volume and material averaging;
- the early-reflection correlation, above 0.55 at the same position and below 0.35 at others.
- that the chamber music hall's solids make a valid closed room, within 10% of BRAS's volume, with
  every source and receiver inside;
- that refitting its materials makes Eyring's estimate the time asked for, within 1%.

The decay and wave-solver comparisons take minutes in a debug build. They run in the bench and are
not part of the tests.

## Sources

- L. Aspöck, M. Vorländer, F. Brinkmann, D. Ackermann and S. Weinzierl, *Benchmark for Room
  Acoustical Simulation (BRAS)*, TU Berlin and RWTH Aachen, 2020, DOI 10.14279/depositonce-6726.3,
  https://depositonce.tu-berlin.de/items/38410727-febb-4769-8002-9c710ba393c4, CC BY-SA 4.0.
- ISO 3382-1:2009, *Acoustics — Measurement of room acoustic parameters — Part 1: Performance
  spaces*, for the parameters and their just-noticeable differences.
- A. Lundeby, T. E. Vigran, H. Bietz and M. Vorländer, "Uncertainties of measurements in room
  acoustics", *Acustica* 81, 344–355, 1995, for the treatment of background noise.
- H. Kuttruff, *Room Acoustics*, 6th edn, CRC Press, 2016, for decay in rooms that are not diffuse.
