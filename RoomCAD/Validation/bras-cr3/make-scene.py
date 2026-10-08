#!/usr/bin/env python3
"""Write scene.json: BRAS scene CR3, the chamber music hall of the Konzerthaus Berlin, simplified for
RoomCAD.

The dimensions are read from the corners in BRAS's model CR3_RIR_Dodecahedron.skp, grouped by height
(see README.md), in metres in BRAS's coordinates: x runs from the stage to the back of the hall, y across
it, and z up from the audience floor. The room is built from pieces of air, joined, with the stage
shell's panels and the seating cut out of it. The material rows come from BRAS's CSV files in the cache
that RoomCAD/Scripts/fetch-bras.py fills.

Usage: python3 RoomCAD/Validation/bras-cr3/make-scene.py
"""

import csv
import json
import pathlib

HERE = pathlib.Path(__file__).resolve().parent
CACHE = HERE.parent.parent / ".cache" / "bras-cr3"
NAMES = ["ceiling", "floor", "plaster", "seating", "stagePanels", "structuredPlaster", "windows"]


def material(kind, name):
    rows = [[float(x) for x in row] for row in csv.reader(open(CACHE / kind / f"mat_CR3_{name}.csv")) if row]
    return {"absorption": rows[1], "scattering": rows[2]}, rows[0]


def box(name, low, high, materials, operation="union"):
    return {"operation": operation, "name": name, "box": [low, high], "materials": materials}


def mirrored(name, low, high, materials):
    """A box and its mirror image across y = 0, its -y and +y materials swapped."""
    m = materials
    return [
        box(name, low, high, m),
        box(name + " (other side)", [low[0], -high[1], low[2]], [high[0], -low[1], high[2]],
            [m[0], m[1], m[3], m[2], m[4], m[5]]),
    ]


S = "structuredPlaster"
pieces = [
    # The stage house behind the proscenium: stage floor 1.0 m above the audience floor, walls of stage
    # panels, open at the top into the attic.
    box("stage house", [-10.21, -5.62, 1.0], [-2.61, 5.62, 7.73],
        ["stagePanels", S, "stagePanels", "stagePanels", "floor", "plaster"]),
    # The proscenium opening, 8.9 m wide and 4.84 m high above the stage floor.
    box("proscenium", [-2.61, -4.47, 1.0], [-2.21, 4.47, 5.84], [S, S, S, S, "floor", S]),
    # The hall between the balcony fronts (y = ±4.9), up to its flat ceiling at 7.64 m.
    box("hall", [-2.21, -4.9, 0.0], [14.62, 4.9, 7.64], [S, S, S, S, "floor", "ceiling"]),
    # In front of the rear balcony, under its ceiling at 6.75 m.
    box("hall, rear", [14.62, -4.9, 0.0], [15.79, 4.9, 6.75], [S, S, S, S, "floor", S]),
    # The rear balcony: floor 3.98 m, ceiling 6.75 m, back wall with the control room's windows.
    box("rear balcony", [15.79, -6.6, 3.98], [18.53, 6.6, 6.75], [S, "windows", S, S, "floor", S]),
    # The attic under the pitched roof, open to the stage house: ridge at 12.08 m.
    {"operation": "union", "name": "attic",
     "extrusion": {"points": [[-6.8, 7.73], [6.8, 7.73], [0.0, 12.08]], "axis": 0, "from": -10.21,
                   "to": 17.22, "sides": ["plaster", "plaster", "plaster"], "ends": ["plaster", "plaster"]}},
]
# The aisles under the side balconies (soffit 3.57 m, wall at y = ±5.79), the side galleries above them
# (floor 3.98 m, back wall at y = ±6.6, ceiling 6.75 m), and the band of hall above the galleries' ceiling.
pieces += mirrored("aisle", [-0.95, 4.9, 0.0], [14.55, 5.79, 3.57], [S, S, S, S, "floor", S])
pieces += mirrored("side gallery", [-0.95, 4.9, 3.98], [15.79, 6.6, 6.75], [S, S, S, S, "floor", S])
pieces += mirrored("cornice", [-0.95, 4.9, 6.75], [14.62, 5.79, 7.64], [S, S, S, S, S, S])

# The stage shell: a back panel and four angled panels each side, 2 cm thick, 1.02 to 5.5 m high.
shell = [
    [[-8.22, -3.54], [-8.20, -3.54], [-8.20, 3.43], [-8.22, 3.43]],
    [[-7.21, -2.91], [-6.49, -4.10], [-6.47, -4.09], [-7.20, -2.90]],
    [[-6.07, -3.12], [-5.33, -4.32], [-5.32, -4.31], [-6.05, -3.11]],
    [[-4.67, -3.28], [-4.11, -4.56], [-4.09, -4.55], [-4.65, -3.27]],
    [[-3.76, -3.47], [-3.16, -4.75], [-3.14, -4.74], [-3.75, -3.46]],
    [[-7.03, 2.76], [-7.01, 2.75], [-6.55, 4.07], [-6.57, 4.08]],
    [[-6.00, 2.99], [-5.98, 2.98], [-5.39, 4.23], [-5.41, 4.24]],
    [[-4.64, 3.19], [-4.62, 3.18], [-4.10, 4.48], [-4.12, 4.49]],
    [[-3.72, 3.37], [-3.71, 3.36], [-3.13, 4.63], [-3.14, 4.64]],
]
for i, panel in enumerate(shell):
    pieces.append({"operation": "subtract", "name": f"stage panel {i + 1}",
                   "extrusion": {"points": panel, "axis": 2, "from": 1.02, "to": 5.5,
                                 "sides": ["stagePanels"] * 4, "ends": ["stagePanels", "stagePanels"]}})

# Seating, as BRAS models it: a material on the floor, here 1 cm thick. The main audience area is 16 rows
# across 8.6 m; the side galleries have one row and the rear balcony three.
seat = ["floor", "floor", "floor", "floor", "seating", "seating"]
pieces.append(box("seating, stalls", [1.6, -4.3, 0.0], [13.3, 4.3, 0.01], seat, "subtract"))
pieces.append(box("seating, rear balcony", [15.85, -4.9, 3.98], [18.4, 4.9, 3.99], seat, "subtract"))
for y in (1, -1):
    low, high = sorted([4.9 * y, 5.7 * y])
    pieces.append(box("seating, side gallery", [0.0, low, 3.98], [14.6, high, 3.99], seat, "subtract"))

# The chairs themselves, which BRAS leaves out, as fitted zones 0.9 m high over the seating. BRAS's
# CR3_ModelSimplifications.pdf counts them: 246 in the stalls (16 rows: 14 of 16, then 14 and 12, less
# 4 removed for the measurements), 22 in each side gallery and 61 on the rear balcony. Each chair's
# surface area, 1.5 m², is an estimate. Their absorption stays with the seating material.
CHAIR_AREA = 1.5
CHAIRS = "Chairs counted in BRAS's CR3_ModelSimplifications.pdf; 1.5 m² of surface each, estimated."
fittings = [
    {"name": "chairs, stalls", "box": [[1.6, -4.3, 0.01], [13.3, 4.3, 0.9]], "count": 246,
     "area": CHAIR_AREA, "reference": CHAIRS},
    {"name": "chairs, rear balcony", "box": [[15.85, -4.9, 3.99], [18.4, 4.9, 4.88]], "count": 61,
     "area": CHAIR_AREA, "reference": CHAIRS},
]
for y in (1, -1):
    low, high = sorted([4.9 * y, 5.7 * y])
    fittings.append({"name": "chairs, side gallery", "box": [[0.0, low, 3.99], [14.6, high, 4.88]], "count": 22,
                     "area": CHAIR_AREA, "reference": CHAIRS})

initial = {}
fitted = {}
for name in NAMES:
    initial[name], frequencies = material("initial", name)
    fitted[name], _ = material("fitted", name)

scene = {
    "description": "BRAS scene CR3, the chamber music hall of the Konzerthaus Berlin, simplified for RoomCAD. "
    "Derived from the BRAS database (Aspöck, Vorländer, Brinkmann, Ackermann and Weinzierl, TU Berlin and "
    "RWTH Aachen), CC BY-SA 4.0, https://depositonce.tu-berlin.de/items/38410727-febb-4769-8002-9c710ba393c4. "
    "See README.md for what was derived and how.",
    "frequencies": frequencies,
    "temperatureCelsius": 22.4,
    "relativeHumidity": 40.9,
    "geometry": {"pieces": pieces},
    "fittings": fittings,
    "materials": {"initial": initial, "fitted": fitted},
    "sources": {
        "LS1": {"position": [-2.02, 2.0], "drivers": [2.117, 2.38, 2.68]},
        "LS2": {"position": [-3.32, -2.0], "drivers": [2.117, 2.38, 2.68]},
    },
    "driverCrossovers": [177, 1420],
    "receivers": {
        "MP1": [7.84, 0.0, 1.23], "MP2": [2.165, 3.441, 1.23], "MP3": [9.227, 2.366, 1.23],
        "MP4": [5.86, -2.359, 1.23], "MP5": [12.726, -3.24, 1.23],
    },
}
(HERE / "scene.json").write_text(json.dumps(scene, indent=1, ensure_ascii=False) + "\n")
print(f"Wrote {HERE / 'scene.json'} with {len(pieces)} pieces.")
