#!/usr/bin/env python3
"""Writes house-plan.dxf: the floor plan of a small two-storey house, 8 x 6 m over its outer
faces, as a draughtsman would hand it over. Lines in millimetres, one layer for each kind of thing:

  WALL-EXT   the cavity walls' centrelines (280 mm: 102.5 brick, 50 insulation, 27.5 air, 100 block)
  WALL-INT   the partition's centreline (100 mm block)
  DOOR       a door's width along its wall, on the ground floor
  WINDOW-GF  a window's width along its wall, on the ground floor
  WINDOW-FF  a window's width along its wall, on the first floor

Both storeys share the walls. The plan is drawn here rather than taken from elsewhere so that its
licence is plain: CC0, like the rest of Samples/Plans. Plain ASCII DXF R12, LINE entities only, which
any CAD program reads; `python3 make-house-plan.py` rewrites it.
"""

import os

# Wall centrelines: the outer faces at 0 and 8000 by 0 and 6000, the walls 280 thick.
C = 140.0
EXT = [((C, C), (8000 - C, C)), ((8000 - C, C), (8000 - C, 6000 - C)),
       ((8000 - C, 6000 - C), (C, 6000 - C)), ((C, 6000 - C), (C, C))]
# The partition, from the inner face of the front wall to that of the back wall.
INT = [((4000.0, 280.0), (4000.0, 5720.0))]
# Openings, along the walls' centrelines: the front (south, y = 140) and back (north, y = 5860).
DOOR = [((1200.0, C), (2100.0, C))]
WINDOW_GF = [((5000.0, C), (6200.0, C)), ((5000.0, 6000 - C), (6200.0, 6000 - C))]
WINDOW_FF = [((1200.0, C), (2400.0, C)), ((5000.0, C), (6200.0, C)),
             ((1200.0, 6000 - C), (2400.0, 6000 - C))]


def dxf(layers):
    out = ["0", "SECTION", "2", "HEADER", "9", "$INSUNITS", "70", "4", "0", "ENDSEC",
           "0", "SECTION", "2", "TABLES", "0", "TABLE", "2", "LAYER", "70", str(len(layers))]
    for name in layers:
        out += ["0", "LAYER", "2", name, "70", "0", "62", "7", "6", "CONTINUOUS"]
    out += ["0", "ENDTAB", "0", "ENDSEC", "0", "SECTION", "2", "ENTITIES"]
    for name, lines in layers.items():
        for (x0, y0), (x1, y1) in lines:
            out += ["0", "LINE", "8", name, "10", f"{x0:g}", "20", f"{y0:g}", "30", "0",
                    "11", f"{x1:g}", "21", f"{y1:g}", "31", "0"]
    out += ["0", "ENDSEC", "0", "EOF"]
    return "\n".join(out) + "\n"


if __name__ == "__main__":
    here = os.path.dirname(os.path.abspath(__file__))
    text = dxf({"WALL-EXT": EXT, "WALL-INT": INT, "DOOR": DOOR, "WINDOW-GF": WINDOW_GF,
                "WINDOW-FF": WINDOW_FF})
    with open(os.path.join(here, "house-plan.dxf"), "w") as f:
        f.write(text)
