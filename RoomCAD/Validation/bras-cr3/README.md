# BRAS scene CR3, the chamber music hall

These files describe a measured room for comparison with RoomCAD (see
[RoomCAD against measured rooms](../../../docs/roomcad-validation.md)). The room is the chamber music
hall of the Konzerthaus Berlin. The files are derived from the Benchmark for Room Acoustical
Simulation (BRAS):

> L. Aspöck, M. Vorländer, F. Brinkmann, D. Ackermann and S. Weinzierl, *Benchmark for Room
> Acoustical Simulation (BRAS)*, TU Berlin and RWTH Aachen, 2020, DOI 10.14279/depositonce-6726.3,
> https://depositonce.tu-berlin.de/items/38410727-febb-4769-8002-9c710ba393c4

BRAS is licensed under the Creative Commons Attribution-ShareAlike 4.0 International licence
(https://creativecommons.org/licenses/by-sa/4.0/). These derived files are distributed under the same
licence. They contain neither BRAS's impulse responses nor its models.
`RoomCAD/Scripts/fetch-bras.py CR3` fetches the source files into `RoomCAD/.cache`, which git ignores.

## `scene.json`

`make-scene.py` writes this file. Unlike CR2's plan, it describes the room as pieces of air: boxes
and extrusions that are joined or cut away. RoomCAD builds a closed mesh from them with `Solid`. The
mesh has 1,452 faces on 81 planes.

### Geometry

The dimensions are read from the corners in `CR3_RIR_Dodecahedron.skp`, in metres, in BRAS's
coordinates:

- **x** runs from the stage to the back of the hall;
- **y** runs across it;
- **z** runs up from the audience floor.

The corners were grouped by height to find the floors, soffits and ceilings. The pieces are:

- **The hall.** It is 9.8 m wide between the balcony fronts and 7.64 m high under a flat ceiling.
  It runs from the proscenium to the rear balcony.
- **The stage house.** Its floor is 1.0 m above the audience floor, and it is open at the top. It
  joins the hall through a proscenium 8.9 m wide and 4.84 m high.
- **Side aisles.** These run under the side balconies, up to 3.57 m.
- **Side galleries and the rear balcony.** Their floors are at 3.98 m and their ceilings at 6.75 m.
  The rear balcony's back wall holds the control room's windows.
- **The attic.** It sits under the pitched roof, with its ridge at 12.08 m, and is open to the
  stage house.
- **The stage shell.** Its nine panels are cut out of the air as 2 cm slabs, 1.02–5.5 m high.
- **Seating.** As in BRAS, seating is a material on the floor. Here it is a 1 cm layer cut out of
  the stalls, the side galleries and the rear balcony.

The volume is 3,119 m³, against 3,331 m³ in BRAS's model. The surface area is 2,286 m², against
BRAS's 2,763 m².

### What is left out

- The pillars between the galleries.
- The coffers, mouldings and other ornament on the walls and ceiling.
- The chairs, which are modelled as a flat layer.

Most of the missing area is structured plaster. It covers 565 m² here, against BRAS's 1,172 m².

### Material areas

| Material | Here (m²) | BRAS (m²) |
|---|---|---|
| Floor | 238 | 343 |
| Seating | 149 | 179 |
| Plaster | 790 | 450 |
| Ceiling | 165 | 168 |
| Stage panels | 343 | 426 |
| Structured plaster | 565 | 1,172 |
| Windows | 37 | 25 |

The plaster here includes all of the attic's surfaces.

### Materials, positions and air

- **Material data.** The absorption and scattering rows are copied from BRAS's
  `3 Surface descriptions/_csv/{initial,fitted}_estimates/mat_CR3_*.csv`, in third octaves.
- **Positions.**
  - The sources and receivers are read from the labels in `CR3_RIR_Dodecahedron.skp`.
  - Each source is a dodecahedron with three drivers, at 2.117, 2.38 and 2.68 m. These heights
    include the stage's 1 m rise.
  - The crossovers between drivers, at 177 Hz and 1.42 kHz, come from BRAS's documentation.
- **Air.** The temperature (22.4 °C) and humidity (40.9%) are BRAS's measurement conditions.

## `measured.json`

`acousticbench --bras-cr3 --update-fixture` derives this file from the ten dodecahedron room impulse
responses `CR3_RIR_LS{1,2}_MP{1–5}_Dodecahedron.wav`, as for CR2. For each source and receiver pair
it gives:

- the ISO 3382-1 parameters in each octave band, with Lundeby's noise compensation;
- the low-frequency spectrum, 30–175 Hz, at 1/24-octave steps;
- the early reflections above 500 Hz, in 1 ms bins.
