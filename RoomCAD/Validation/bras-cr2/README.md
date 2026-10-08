# BRAS scene CR2, the seminar room

These files describe a measured room for comparison with RoomCAD (see
[RoomCAD against a measured room](../../../docs/roomcad-validation.md)). They are derived from the
Benchmark for Room Acoustical Simulation (BRAS):

> L. Aspöck, M. Vorländer, F. Brinkmann, D. Ackermann and S. Weinzierl, *Benchmark for Room
> Acoustical Simulation (BRAS)*, TU Berlin and RWTH Aachen, 2020, DOI 10.14279/depositonce-6726.3,
> https://depositonce.tu-berlin.de/items/38410727-febb-4769-8002-9c710ba393c4

BRAS is licensed under the Creative Commons Attribution-ShareAlike 4.0 International licence
(https://creativecommons.org/licenses/by-sa/4.0/). These derived files are distributed under the same
licence. They do not contain BRAS's impulse responses or models;
`RoomCAD/Scripts/fetch-bras.py` fetches the files they were derived from into `RoomCAD/.cache`,
which git ignores.

## `scene.json`

- **Plan and height.** The plan's 14 corners and the ceiling height (2.988 m) are read from the
  vertices of `CR2_RIR_Dodecahedron.skp`, in metres, in BRAS's coordinates. Three 12 cm window
  recesses, sills, radiators, ceiling lights and a 2 cm door step are left out. The volume is
  145.7 m³, against BRAS's 145 m³.
- **Wall materials.** These follow `0_roomPlan.pdf` and the model's vertices:
  - the window wall: glass from 0.60 to 2.57 m high, 53% of its area, and concrete;
  - side wall A: a plaster panel up to 2.5 m high, about 63% of its area, and concrete;
  - the front wall: about 65% plaster and the rest concrete;
  - every other wall: concrete.

  The plaster fractions are estimated from the drawing, which has no dimensions.
- **Material data.** Absorption and scattering rows are copied from BRAS's
  `3 Surface descriptions/_csv/{initial,fitted}_estimates/mat_CR2_*.csv`, in third octaves.
- **Positions.** The sources and receivers are read from the labels in
  `CR2_RIR_Dodecahedron.skp`. Each dodecahedron has three drivers, at 0.460, 0.723 and 1.023 m; the
  crossovers at 177 Hz and 1.42 kHz come from BRAS's documentation.
- **Air.** The temperature (19.5 °C) and humidity (41.7%) are BRAS's measurement conditions.

## `measured.json`

RoomCAD's `acousticbench --bras-cr2 --update-fixture` derives this file from the ten dodecahedron
room impulse responses `CR2_RIR_LS{1,2}_MP{1–5}_Dodecahedron.wav`. For each pair it gives:

- the ISO 3382-1 parameters in each octave band, with Lundeby's noise compensation;
- the low-frequency spectrum, 30–175 Hz, 1/24 octave apart;
- the early reflections above 500 Hz in 1 ms bins.
