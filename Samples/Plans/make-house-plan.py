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
any CAD program reads; `python3 make-house-plan.py` rewrites it, and two variants:

  house-plan-turned.dxf  the same plan turned 17 degrees, as a site plan drawn to north would be
  house-plan-bay.dxf     a curved bay 2 m wide and 0.4 m deep in the front wall (a polyline with a
                         bulge on WALL-EXT), a window in it on each floor, the partition at 6.6 m
  house-plan.svg and house-plan-bay.svg  the same two plans as SVG, as a drawing program exports
                         them: A4 in millimetres at 1:100, Inkscape layers, the walls as paths (the
                         bay an arc), the doors and windows as symbols placed with <use>
"""

import math
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


def turned(lines, degrees, centre=(4000.0, 3000.0)):
    t = math.radians(degrees)
    def turn(p):
        x, y = p[0] - centre[0], p[1] - centre[1]
        return (centre[0] + x * math.cos(t) - y * math.sin(t), centre[1] + x * math.sin(t) + y * math.cos(t))
    return [(turn(a), turn(b)) for a, b in lines]


def num(v):
    return f"{v:.3f}".rstrip("0").rstrip(".")


def dxf(layers, polylines=()):
    out = ["0", "SECTION", "2", "HEADER", "9", "$INSUNITS", "70", "4", "0", "ENDSEC",
           "0", "SECTION", "2", "TABLES", "0", "TABLE", "2", "LAYER", "70", str(len(layers))]
    for name in layers:
        out += ["0", "LAYER", "2", name, "70", "0", "62", "7", "6", "CONTINUOUS"]
    out += ["0", "ENDTAB", "0", "ENDSEC", "0", "SECTION", "2", "ENTITIES"]
    for name, lines in layers.items():
        for (x0, y0), (x1, y1) in lines:
            out += ["0", "LINE", "8", name, "10", num(x0), "20", num(y0), "30", "0",
                    "11", num(x1), "21", num(y1), "31", "0"]
    # Polylines with bulges: (layer, [(x, y, bulge to the next vertex)]).
    for name, vertices in polylines:
        out += ["0", "LWPOLYLINE", "8", name, "90", str(len(vertices)), "70", "0"]
        for x, y, bulge in vertices:
            out += ["10", num(x), "20", num(y)] + (["42", f"{bulge:g}"] if bulge else [])
    out += ["0", "ENDSEC", "0", "EOF"]
    return "\n".join(out) + "\n"


def svg(layers, arcs=(), symbols=None):
    """The plan on A4 landscape at 1:100, in millimetres, y down: lines as paths, `arcs` as
    (layer, start, end, radius, sweep) paths with an arc command, and the openings on the layers in
    `symbols` as <use> of a symbol one millimetre long, stretched to their width and turned."""
    symbols = symbols or set()
    def paper(p):
        return (20 + p[0] / 100, 190 - p[1] / 100)
    out = ['<?xml version="1.0" encoding="UTF-8"?>',
           '<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" '
           'xmlns:inkscape="http://www.inkscape.org/namespaces/inkscape" width="297mm" height="210mm" '
           'viewBox="0 0 297 210">',
           '<defs><symbol id="opening"><line x1="0" y1="0" x2="1" y2="0" stroke="black" stroke-width="0.25"/>'
           '</symbol></defs>']
    for name, lines in layers.items():
        out.append(f'<g inkscape:groupmode="layer" inkscape:label="{name}" id="layer-{name.lower()}">')
        for a, b in lines:
            (x0, y0), (x1, y1) = paper(a), paper(b)
            if name in symbols:
                length = math.hypot(x1 - x0, y1 - y0)
                angle = math.degrees(math.atan2(y1 - y0, x1 - x0))
                out.append(f'<use xlink:href="#opening" transform="translate({num(x0)} {num(y0)}) '
                           f'rotate({num(angle)}) scale({num(length)} 1)"/>')
            else:
                out.append(f'<path d="M {num(x0)},{num(y0)} L {num(x1)},{num(y1)}" fill="none" stroke="black"/>')
        for layer, a, b, radius, sweep in arcs:
            if layer != name:
                continue
            (x0, y0), (x1, y1) = paper(a), paper(b)
            out.append(f'<path d="M {num(x0)},{num(y0)} A {num(radius / 100)} {num(radius / 100)} 0 0 {sweep} '
                       f'{num(x1)},{num(y1)}" fill="none" stroke="black"/>')
        out.append('</g>')
    out.append('</svg>')
    return "\n".join(out) + "\n"


if __name__ == "__main__":
    here = os.path.dirname(os.path.abspath(__file__))
    text = dxf({"WALL-EXT": EXT, "WALL-INT": INT, "DOOR": DOOR, "WINDOW-GF": WINDOW_GF,
                "WINDOW-FF": WINDOW_FF})
    with open(os.path.join(here, "house-plan.dxf"), "w") as f:
        f.write(text)
    layers = {"WALL-EXT": EXT, "WALL-INT": INT, "DOOR": DOOR, "WINDOW-GF": WINDOW_GF, "WINDOW-FF": WINDOW_FF}
    with open(os.path.join(here, "house-plan-turned.dxf"), "w") as f:
        f.write(dxf({name: turned(lines, 17) for name, lines in layers.items()}))
    # The bay: the front wall broken from 2700 to 4700, an arc there bulging out 400 mm.
    a, b, bulge = 2700.0, 4700.0, 0.4
    half = (b - a) / 2
    sagitta = bulge * half
    radius = (half * half + sagitta * sagitta) / (2 * sagitta)
    centre = ((a + b) / 2, C - sagitta + radius)
    def on_arc(x):
        return centre[1] - math.sqrt(radius * radius - (x - centre[0]) ** 2)
    bay_ext = [((C, C), (a, C)), ((b, C), (8000 - C, C))] + EXT[1:]
    bay_window = [((3300.0, on_arc(3300.0)), (4100.0, on_arc(4100.0)))]
    with open(os.path.join(here, "house-plan-bay.dxf"), "w") as f:
        f.write(dxf(
            {"WALL-EXT": bay_ext, "WALL-INT": [((6600.0, 280.0), (6600.0, 5720.0))], "DOOR": DOOR,
             "WINDOW-GF": WINDOW_GF + bay_window, "WINDOW-FF": WINDOW_FF + bay_window},
            polylines=[("WALL-EXT", [(a, C, bulge), (b, C, 0)])]))
    openings = {"DOOR", "WINDOW-GF", "WINDOW-FF"}
    with open(os.path.join(here, "house-plan.svg"), "w") as f:
        f.write(svg(layers, symbols=openings))
    bay_layers = {"WALL-EXT": bay_ext, "WALL-INT": [((6600.0, 280.0), (6600.0, 5720.0))], "DOOR": DOOR,
                  "WINDOW-GF": WINDOW_GF + bay_window, "WINDOW-FF": WINDOW_FF + bay_window}
    # On paper y runs down: the arc bulging to -y in the plan bulges down the page, clockwise from
    # its left end there, so the sweep flag is 0.
    with open(os.path.join(here, "house-plan-bay.svg"), "w") as f:
        f.write(svg(bay_layers, arcs=[("WALL-EXT", (a, C), (b, C), radius, 0)], symbols=openings))
