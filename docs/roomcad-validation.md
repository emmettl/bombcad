# RoomCAD against a measured room

This report compares RoomCAD's responses with measurements in a real room: the seminar room at RWTH
Aachen University, scene CR2 of the Benchmark for Room Acoustical Simulation (BRAS). It is the
comparison that roadmap milestone M4 item 5 asks for. It sets out what agrees, what doesn't and why,
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

`make roomcad-validate` (`acousticbench --bras-cr2`) simulates all ten pairs, 3.5 s long like the measurements, in three
configurations:

- the initial materials with the wave solver;
- the fitted materials with the wave solver;
- the fitted materials without it.

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
runs without downloading the measurements. `RoomCAD/Scripts/fetch-bras-cr2.py` fetches the 6 MB of
BRAS that the fixture is derived from, and `acousticbench --bras-cr2 --update-fixture` rebuilds the
fixture from it. A run takes about 6 minutes on a Mac Studio (M4 Max), almost all of it in the wave
solver.

## Results

### Reverberation time

T30, mean over the pairs (measured ± spread across the pairs), with JNDs in brackets:

| | 63 Hz | 125 Hz | 250 Hz | 500 Hz | 1 kHz | 2 kHz | 4 kHz | 8 kHz |
|---|---|---|---|---|---|---|---|---|
| Measured | 1.71 ± 0.47 | 1.40 ± 0.12 | 1.72 ± 0.14 | 2.02 ± 0.04 | 1.94 ± 0.04 | 1.75 ± 0.02 | 1.57 ± 0.01 | 1.03 ± 0.02 |
| Initial | 4.33 (+31) | 3.49 (+30) | 1.93 (+2.4) | 1.84 (−1.8) | 1.88 (−0.6) | 1.66 (−1.0) | 1.27 (−3.7) | 0.71 (−6.2) |
| Fitted | 2.02 (+3.7) | 1.85 (+6.4) | 1.93 (+2.5) | 2.27 (+2.5) | 2.16 (+2.3) | 1.91 (+1.9) | 1.67 (+1.3) | 0.94 (−1.8) |
| Fitted, no wave solver | 1.55 (−1.9) | 1.56 (+2.2) | 1.89 (+2.0) | 2.26 (+2.4) | 2.17 (+2.4) | 1.90 (+1.7) | 1.67 (+1.3) | 0.94 (−1.7) |

T20 and EDT follow the same pattern.

- **250 Hz to 2 kHz, initial materials.** RoomCAD predicts the measured T30 to within 12% (−9% to
  +12%) from published material data alone. That is the most useful result, because a designer
  usually has no measurement.
- **Fitted materials.** These make Eyring's estimate equal the measured times by construction.
  RoomCAD's decay is 6–12% longer than that from 250 Hz to 4 kHz. In a room this close to a box,
  with scattering of only 0.05–0.07 below 1 kHz on the walls and floor, some sound keeps travelling between parallel surfaces
  and decays more slowly than in a diffuse field. This is the non-diffuse decay that Kuttruff
  describes, and the model shows it for that reason. The real room has chairs, radiators and
  fittings that scatter more.
- **4 and 8 kHz, initial materials.** The decay is 19% and 31% too short. The initial high-frequency
  absorption, including air, is too high for this room. The fitted set corrects it.
- **63 and 125 Hz, initial materials.** The decay is two and a half times too long. The published
  absorption of plaster and concrete is only 0.02–0.05 there. The real room loses much more energy
  at low frequencies, through the windows' and doors' flexibility and transmission. A designer needs
  realistic low-frequency absorption for small rooms, which published coefficients for hard walls
  don't give.
- **63 and 125 Hz, fitted materials, with the wave solver.** The decay is still 18% and 32% too long.
  The geometrical model without it comes closer, at −9% and +11%. The wave solver's walls are locally
  reacting with a real impedance, which absorbs nothing at grazing incidence. Below about 150 Hz,
  this room's field is dominated by axial and tangential modes, which graze the floor and ceiling,
  half of its surface. So the solver's modes keep their energy longer than a diffuse field would.
  Real surfaces such as windows, doors and suspended ceilings absorb at grazing incidence too,
  because they are not locally reacting. This is a limitation of the wave solver's boundary model
  (see Limitations).

### Clarity, definition and early decay

| | | 125 Hz | 250 Hz | 500 Hz | 1 kHz | 2 kHz | 4 kHz | 8 kHz |
|---|---|---|---|---|---|---|---|---|
| C80 (dB) | Measured | 0.8 ± 2.0 | 1.0 ± 1.3 | −1.4 ± 0.7 | −0.8 ± 0.6 | −0.1 ± 0.6 | 0.2 ± 0.4 | 6.8 ± 0.5 |
| | Initial | −3.2 (−3.9) | −1.6 (−2.6) | −0.6 (+0.7) | −1.3 (−0.6) | 0.2 (+0.3) | 2.0 (+1.9) | 6.4 (−0.4) |
| | Fitted | 0.1 (−0.6) | −1.7 (−2.7) | −2.2 (−0.8) | −1.9 (−1.1) | −0.7 (−0.5) | 0.0 (−0.1) | 3.8 (−3.0) |
| D50 | Measured | 0.36 ± 0.09 | 0.42 ± 0.12 | 0.30 ± 0.05 | 0.32 ± 0.04 | 0.36 ± 0.03 | 0.36 ± 0.02 | 0.69 ± 0.03 |
| | Initial | 0.23 (−2.6) | 0.28 (−2.7) | 0.31 (+0.3) | 0.30 (−0.3) | 0.37 (+0.1) | 0.46 (+1.9) | 0.65 (−0.7) |
| | Fitted | 0.37 (+0.2) | 0.29 (−2.5) | 0.26 (−0.9) | 0.28 (−0.8) | 0.33 (−0.5) | 0.36 (+0.0) | 0.54 (−3.0) |

- **500 Hz to 2 kHz.** C80 and D50 are within about one JND with either material set. EDT is within
  about 2 JND with the initial set; the fitted set's EDT is 2–3 JND long, like its T30.
- **250 Hz.** Both sets give about 2.5 dB less clarity than measured. This is the crossover band:
  above it the geometrical model applies, and below it the wave solver's slow low-frequency decay.
- **8 kHz.** The measured response is much clearer than its own decay suggests: EDT 0.68 s against
  T30 1.03 s, and C80 6.8 dB. The fitted model gives 3 dB less. At 8 kHz a dodecahedron is
  noticeably directional, which RoomCAD's omnidirectional source does not reproduce, so this is
  probably the source, not the room.

### Low-frequency fine structure

From 30 to 175 Hz:

| | Same position | Other positions | Best frequency scale |
|---|---|---|---|
| Initial | 0.62 ± 0.08 | 0.39 | 0.67, simulated frequencies 1% higher |
| Fitted | 0.63 ± 0.09 | 0.38 | 0.67, simulated frequencies 1.5% higher |
| Fitted, no wave solver | 0.10 ± 0.14 | 0.05 | 0.12 |

- **The wave solver reproduces the room's modal structure.** At the same position the fine
  structure correlates at 0.63, against 0.10 for geometrical acoustics alone, whose low end has no
  modes.
- **Position-specific structure.** The correlation is higher at the same position than at others
  (0.38), so the solver captures where each mode is loud or quiet, not just its frequency.
- **Mode frequencies.** Raising the simulated frequencies by 1–1.5% improves the agreement slightly,
  so the measured modes lie about 1.5% higher than the simulated ones. The solver's own mode
  frequencies are checked to 0.25% in a rigid box. The likely cause is that the simplified room is a
  little too large acoustically: it leaves out radiators, sills, window frames and ceiling lights.

### Early reflections

Above 500 Hz, between 1.5 and 19.5 ms:

| | Same position | Other positions |
|---|---|---|
| Initial | 0.64 ± 0.20 | 0.20 |
| Fitted | 0.71 ± 0.11 | 0.20 |
| Fitted, no wave solver | 0.65 ± 0.14 | 0.20 |

The simulated early reflections follow the measured pattern at each position: 0.71 against 0.20 for
the wrong position. They are not identical. The dodecahedron spans about 30 cm, and its drivers
radiate unevenly. The measured onsets imply positions that agree with the documented ones to within
about ±20 cm. The model also leaves out the window recesses, sills and fittings, which add
reflections of their own. Two of the measured responses from loudspeaker 2 have a weak direct sound
and strong arrivals near 10 and 16 ms that the model lacks.

## What the comparison shows

1. **Mid frequencies.** From 250 Hz to 2 kHz, with only published material data, RoomCAD predicts
   reverberation time within 12%, and clarity and definition within about one JND.
2. **Diffuseness.** With materials fitted to Eyring's formula, RoomCAD decays about 10% more slowly
   than Eyring's formula and the measurement, because the room is not fully diffuse. Fitting
   materials to a measured T30 should therefore be done with RoomCAD itself rather than with
   Eyring's formula.
3. **Low-frequency modes.** The wave solver reproduces the room's modal fine structure and its
   position dependence, with mode frequencies within about 1.5%.
4. **Low-frequency decay.** The wave solver's locally reacting, real-impedance walls absorb too
   little at grazing incidence, so its decay below about 150 Hz is too long in this room. Without
   the wave solver, decay comes closer but there are no modes.
5. **Early reflections.** These follow the measured pattern at each position.
6. **Published low-frequency absorption.** For walls such as plaster and concrete, it is much lower
   than real rooms behave, which a designer must allow for.

## Limitations of the comparison

- **One room.** It is small and live, and the comparison has not been repeated in larger or more
  absorbent rooms. BRAS's other rooms (CR3, a chamber music hall, and CR4, an auditorium) need
  geometry that RoomCAD does not yet model: balconies, raked seating and sloping ceilings.
- **The source.** It is treated as omnidirectional, at each driver's height. Its directivity, the
  size of its drivers, and the crossover's phase are not modelled.
- **Geometry.** It is simplified, as listed above, and wall materials are averaged by area.
- **Fitted estimates.** They were fitted to the measured times with Eyring's formula, so they are not
  an independent prediction; they test the model's shape of decay.
- **Not a listening test.** The roadmap asks for listening comparisons as well; these have not been
  made.

## Tests

`MeasuredRoomTests` keeps two parts of this comparison in the regular test suite, using the fixture:

- the simplified room's volume and material averaging;
- the early-reflection correlation, above 0.55 at the same position and below 0.35 at others.

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
