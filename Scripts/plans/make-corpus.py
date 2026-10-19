#!/usr/bin/env python3
"""Writes Fixtures/FloorPlans: small floor plans that each try one thing the plan importer
(FloorPlan, DXFDrawing) meets in drawings from offices, with the answer expected of it.

    /Volumes/StudioData/bombcad/plans-venv/bin/python Scripts/plans/make-corpus.py

The DXFs are written with ezdxf (a venv of it, not a dependency of the repository), as a CAD
program writes them: R2010, handles, tables, blocks with attributes, hatches and dimensions. The
SVGs are written by hand, as drawing programs export them. Each plan has a JSON beside it: the
options to read it with and what reading it should give (`FloorPlanCorpus.Expected`). The answers
come from the plans' own geometry, not from the importer. CC0, like the rest of the fixtures it
writes; `Scripts/plans/check-corpus.py` judges them.
"""

import json
import math
import os

import ezdxf

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(os.path.dirname(os.path.dirname(HERE)), "Fixtures", "FloorPlans")

# The house most cases build on: 8 x 6 m over its outer faces, walls 300 mm, a 100 mm partition.
W, D, T, P = 8000.0, 6000.0, 300.0, 100.0


def new(units=4):
    doc = ezdxf.new("R2010", setup=True)
    if units is not None:
        doc.header["$INSUNITS"] = units
    else:
        doc.header["$INSUNITS"] = 0
    return doc


def faces_house(msp, layer="A-WALL", partition=True, scale=1.0, origin=(0.0, 0.0)):
    """Outer and inner faces as closed polylines, the partition by its two faces."""
    ox, oy = origin
    def p(x, y):
        return (ox + x * scale, oy + y * scale)
    msp.add_lwpolyline([p(0, 0), p(W, 0), p(W, D), p(0, D)], close=True, dxfattribs={"layer": layer})
    msp.add_lwpolyline([p(T, T), p(W - T, T), p(W - T, D - T), p(T, D - T)], close=True,
                       dxfattribs={"layer": layer})
    if partition:
        x = W / 2
        msp.add_line(p(x - P / 2, T), p(x - P / 2, D - T), dxfattribs={"layer": layer})
        msp.add_line(p(x + P / 2, T), p(x + P / 2, D - T), dxfattribs={"layer": layer})


def centre_house(msp, layer="WALL-EXT", inner="WALL-INT"):
    c = T / 2
    msp.add_lwpolyline([(c, c), (W - c, c), (W - c, D - c), (c, D - c)], close=True, dxfattribs={"layer": layer})
    msp.add_line((W / 2, T), (W / 2, D - T), dxfattribs={"layer": inner})


def door_block(doc, name="DOOR900", width=900.0):
    """A door as offices draw one: the opening's threshold, the leaf open at 90° and its swing."""
    if name in doc.blocks:
        return name
    b = doc.blocks.new(name)
    b.add_line((0, 0), (width, 0))
    b.add_line((0, 0), (0, width))
    b.add_arc((0, 0), width, 0, 90)
    b.add_attdef("TAG", (0, -200), dxfattribs={"height": 100})
    return name


def window_block(doc, name="WIN1200", width=1200.0, depth=T):
    """A window across the wall: its frame's two faces and the glass between."""
    if name in doc.blocks:
        return name
    b = doc.blocks.new(name)
    for y in (-depth / 2, -20, 20, depth / 2):
        b.add_line((0, y), (width, y))
    b.add_line((0, -depth / 2), (0, depth / 2))
    b.add_line((width, -depth / 2), (width, depth / 2))
    return name


def chair_block(doc):
    if "CHAIR" in doc.blocks:
        return "CHAIR"
    b = doc.blocks.new("CHAIR")
    b.add_lwpolyline([(0, 0), (450, 0), (450, 450), (0, 450)], close=True)
    b.add_circle((225, 225), 150)
    return "CHAIR"


CASES = []


LIMITATIONS = {
    "hatch-only-walls": "Hatches are not read: a plan whose walls are drawn only as hatching, with no outline "
                        "lines, has no walls to find. Their boundaries could be read as faces; not done, as most "
                        "plans outline walls and hatch them too, and a hatch's boundary is often the room's.",
}


def case(name, description, options, expect, kind="dxf"):
    CASES.append((name, kind, description, options, expect))


def write_dxf(doc, name):
    doc.saveas(os.path.join(OUT, name + ".dxf"))


GUESS = "guess"


def main():
    os.makedirs(OUT, exist_ok=True)
    for f in os.listdir(OUT):
        if f.endswith((".dxf", ".svg", ".json")):
            os.remove(os.path.join(OUT, f))

    # 1. Walls by both faces, the partition meeting them at Ts.
    doc = new(); msp = doc.modelspace(); faces_house(msp); write_dxf(doc, "faces-house")
    case("faces-house", "Walls drawn by both faces as closed polylines; a 100 mm partition at Ts.",
         {"roles": GUESS},
         {"units": 0.001, "byFaces": True, "wallThicknesses": {"0.3": 4, "0.1": 1}, "bounds": [8, 6],
          "notes": ["drawn by their outlines"], "notNotes": ["left out"]})

    # 2. Centrelines: L corners, a T and an X.
    doc = new(); msp = doc.modelspace(); centre_house(msp)
    msp.add_line((T, D / 2), (W - T, D / 2), dxfattribs={"layer": "WALL-INT"})  # crosses the partition: an X
    write_dxf(doc, "centrelines-ltx")
    case("centrelines-ltx", "Centrelines: the outer walls' L corners, a partition at Ts to them and another crossing it (an X).",
         {"roles": {"WALL-EXT": "wall:cavityBrickBlock", "WALL-INT": "wall:block100"}},
         {"units": 0.001, "byFaces": False, "wallThicknesses": {"0.28": 4, "0.1": 2}, "wallsAtMost": 8,
          "bounds": [8.14, 6.14], "boundsTolerance": 0.2, "notes": ["centrelines"]})

    # 3. Thin partitions: one 60 mm (a wall) and one 40 mm (under the 50 mm limit, not a wall).
    doc = new(); msp = doc.modelspace(); faces_house(msp, partition=False)
    for x, t in ((2500, 60), (5500, 40)):
        msp.add_line((x - t / 2, T), (x - t / 2, D - T), dxfattribs={"layer": "A-WALL"})
        msp.add_line((x + t / 2, T), (x + t / 2, D - T), dxfattribs={"layer": "A-WALL"})
    write_dxf(doc, "thin-partitions")
    case("thin-partitions", "Partitions by faces 60 mm apart (a wall) and 40 mm apart (under the 50 mm limit).",
         {"roles": GUESS},
         {"units": 0.001, "byFaces": True, "wallThicknesses": {"0.3": 4, "0.06": 1}, "noWallThinnerThan": 0.05})

    # 4. Doors and windows as blocks (a door with its leaf and swing, windows across the wall),
    #    turned into each wall, in centreline walls; an attribute on the door.
    doc = new(); msp = doc.modelspace(); centre_house(msp)
    door_block(doc); window_block(doc)
    c = T / 2
    d = msp.add_blockref("DOOR900", (1200, c), dxfattribs={"layer": "A-DOOR"})
    d.add_auto_attribs({"TAG": "D1"})
    msp.add_blockref("WIN1200", (5000, c), dxfattribs={"layer": "A-GLAZ"})
    msp.add_blockref("WIN1200", (W - c, 2000), dxfattribs={"layer": "A-GLAZ", "rotation": 90})
    msp.add_blockref("WIN1200", (3000, D - c), dxfattribs={"layer": "A-GLAZ", "rotation": 180})
    write_dxf(doc, "opening-blocks")
    case("opening-blocks", "A door block with its leaf and swing, and window blocks turned into three walls.",
         {"roles": {"WALL-EXT": "wall:cavityBrickBlock", "WALL-INT": "wall:block100", "A-DOOR": "door",
                    "A-GLAZ": "window"}},
         {"units": 0.001, "doors": 1, "windows": 3, "gaps": 0, "notNotes": ["drawn away from any wall"]})

    # 5. Openings left as gaps in walls drawn by faces, nothing drawn in them: two in outer walls,
    #    one in the partition.
    doc = new(); msp = doc.modelspace()
    def wall_faces_with_gap(x0, x1, y, t, gap):
        g0, g1 = gap
        for yy in (y - t / 2, y + t / 2):
            msp.add_line((x0, yy), (g0, yy), dxfattribs={"layer": "A-WALL"})
            msp.add_line((g1, yy), (x1, yy), dxfattribs={"layer": "A-WALL"})
        msp.add_line((g0, y - t / 2), (g0, y + t / 2), dxfattribs={"layer": "A-WALL"})
        msp.add_line((g1, y - t / 2), (g1, y + t / 2), dxfattribs={"layer": "A-WALL"})
    wall_faces_with_gap(0, W, T / 2, T, (2000, 3200))  # front
    wall_faces_with_gap(0, W, D - T / 2, T, (5000, 6200))  # back
    for x in (0, W - T):  # the side walls, whole
        msp.add_lwpolyline([(x, T), (x + T, T), (x + T, D - T), (x, D - T)], close=True, dxfattribs={"layer": "A-WALL"})
    # the partition with a door gap from 2500 to 3400
    for xx in (W / 2 - P / 2, W / 2 + P / 2):
        msp.add_line((xx, T), (xx, 2500), dxfattribs={"layer": "A-WALL"})
        msp.add_line((xx, 3400), (xx, D - T), dxfattribs={"layer": "A-WALL"})
    msp.add_line((W / 2 - P / 2, 2500), (W / 2 + P / 2, 2500), dxfattribs={"layer": "A-WALL"})
    msp.add_line((W / 2 - P / 2, 3400), (W / 2 + P / 2, 3400), dxfattribs={"layer": "A-WALL"})
    write_dxf(doc, "opening-gaps")
    case("opening-gaps", "Gaps in walls drawn by faces with jambs, nothing drawn in them: two in outer walls, one in the partition.",
         {"roles": GUESS},
         {"units": 0.001, "byFaces": True, "gaps": 3, "gapWindows": 2, "gapDoors": 1,
          "notes": ["gaps in walls"]})

    # 6. Arcs and bulges: a bay by a polyline's bulge (centrelines) and a curved wall by two arcs
    #    (faces).
    doc = new(); msp = doc.modelspace()
    c = T / 2
    msp.add_lwpolyline([(c, c, 0), (2700, c, 0.4), (4700, c, 0), (W - c, c, 0), (W - c, D - c, 0), (c, D - c, 0)],
                       format="xyb", close=True, dxfattribs={"layer": "WALL-EXT"})
    write_dxf(doc, "bay-bulge")
    case("bay-bulge", "A bay by a polyline's bulge on a centreline wall.",
         {"roles": {"WALL-EXT": "wall:cavityBrickBlock"}},
         {"units": 0.001, "angled": 6, "notes": ["walls at an angle"]})
    doc = new(); msp = doc.modelspace(); faces_house(msp, partition=False)
    # a curved wall 200 thick in the room, its two faces as arcs about one centre
    msp.add_arc((W / 2, D / 2), 1500, 200, 340, dxfattribs={"layer": "A-WALL"})
    msp.add_arc((W / 2, D / 2), 1700, 200, 340, dxfattribs={"layer": "A-WALL"})
    msp.add_line((W / 2 + 1500 * math.cos(math.radians(200)), D / 2 + 1500 * math.sin(math.radians(200))),
                 (W / 2 + 1700 * math.cos(math.radians(200)), D / 2 + 1700 * math.sin(math.radians(200))),
                 dxfattribs={"layer": "A-WALL"})
    msp.add_line((W / 2 + 1500 * math.cos(math.radians(340)), D / 2 + 1500 * math.sin(math.radians(340))),
                 (W / 2 + 1700 * math.cos(math.radians(340)), D / 2 + 1700 * math.sin(math.radians(340))),
                 dxfattribs={"layer": "A-WALL"})
    write_dxf(doc, "curved-faces")
    case("curved-faces", "A curved wall 200 mm thick by its two faces as concentric arcs, in a house by faces.",
         {"roles": GUESS},
         {"units": 0.001, "byFaces": True, "angledAtLeast": 8, "angledThickness": 0.2, "wallThicknesses": {"0.3": 4},
          "notNotes": ["pair with no other"]})

    # 7. Units: the house by faces in cm, m and inches, and with none.
    for name, code, scale, metres in (("units-cm", 5, 0.1, 0.01), ("units-m", 6, 0.001, 1.0),
                                      ("units-inch", 1, 1 / 25.4, 0.0254), ("units-missing", None, 1.0, None)):
        doc = new(code); msp = doc.modelspace(); faces_house(msp, scale=scale); write_dxf(doc, name)
        options = {"roles": GUESS}
        if metres is None:
            options["metresPerUnit"] = 0.001
        case(name, f"The house by faces in {name[6:]}" + ("; the importer must ask for units" if metres is None else "."),
             options, {"units": metres, "wallThicknesses": {"0.3": 4, "0.1": 1}, "bounds": [8, 6], "boundsTolerance": 0.01})

    # 8. Hatching and dimensions on the wall layer, and on layers of their own.
    doc = new(); msp = doc.modelspace(); faces_house(msp)
    h = msp.add_hatch(color=1, dxfattribs={"layer": "A-WALL"})
    h.paths.add_polyline_path([(0, 0), (W, 0), (W, T), (0, T)], is_closed=True)
    h2 = msp.add_hatch(color=2, dxfattribs={"layer": "A-WALL-PATT"})
    h2.paths.add_polyline_path([(0, D - T), (W, D - T), (W, D), (0, D)], is_closed=True)
    dim = msp.add_linear_dim(base=(0, -800), p1=(0, 0), p2=(W, 0), dxfattribs={"layer": "A-WALL"})
    dim.render()
    dim = msp.add_linear_dim(base=(-800, 0), p1=(0, 0), p2=(0, D), angle=90, dxfattribs={"layer": "A-DIMS"})
    dim.render()
    write_dxf(doc, "hatch-dims")
    case("hatch-dims", "Hatching and a dimension on the wall layer, more on layers of their own.",
         {"roles": GUESS},
         {"units": 0.001, "byFaces": True, "wallThicknesses": {"0.3": 4, "0.1": 1}, "bounds": [8, 6],
          "boundsTolerance": 0.01})

    # 9. Text and furniture blocks, on their own layers and (a chair) on the wall layer.
    doc = new(); msp = doc.modelspace(); faces_house(msp); chair_block(doc)
    msp.add_text("Kitchen", dxfattribs={"layer": "A-ANNO-TEXT", "height": 200}).set_placement((1500, 3000))
    msp.add_mtext("Living room", dxfattribs={"layer": "A-ANNO-TEXT"}).set_location((5500, 3000))
    for x in (1000, 2000):
        msp.add_blockref("CHAIR", (x, 1500), dxfattribs={"layer": "A-FURN"})
    msp.add_blockref("CHAIR", (6000, 4500), dxfattribs={"layer": "A-WALL"})
    write_dxf(doc, "text-furniture")
    case("text-furniture", "Room names, chairs on a furniture layer and one chair on the wall layer.",
         {"roles": GUESS},
         {"units": 0.001, "byFaces": True, "wallThicknesses": {"0.3": 4, "0.1": 1}, "wallsAtMost": 5,
          "notes": ["blocks on wall layers"]})

    # 9b. A gap in a wall drawn by faces with no jambs drawn: the faces simply stop.
    doc = new(); msp = doc.modelspace(); faces_house(msp, partition=False)
    for xx in (W / 2 - P / 2, W / 2 + P / 2):
        msp.add_line((xx, T), (xx, 2500), dxfattribs={"layer": "A-WALL"})
        msp.add_line((xx, 3400), (xx, D - T), dxfattribs={"layer": "A-WALL"})
    write_dxf(doc, "gap-no-jambs")
    case("gap-no-jambs", "A partition by faces with a doorway where its faces simply stop, no jambs drawn.",
         {"roles": GUESS},
         {"units": 0.001, "byFaces": True, "wallThicknesses": {"0.3": 4, "0.1": 1}, "gaps": 1, "gapDoors": 1})

    # 9c. Walls drawn only as solid hatches, no outlines: the reader passes over hatches.
    doc = new(); msp = doc.modelspace()
    for (x0, y0, x1, y1) in ((0, 0, W, T), (0, D - T, W, D), (0, T, T, D - T), (W - T, T, W, D - T)):
        h = msp.add_hatch(color=7, dxfattribs={"layer": "A-WALL"})
        h.set_solid_fill()
        h.paths.add_polyline_path([(x0, y0), (x1, y0), (x1, y1), (x0, y1)], is_closed=True)
    write_dxf(doc, "hatch-only-walls")
    case("hatch-only-walls", "Walls drawn only as solid hatches, with no outline lines.",
         {"roles": GUESS},
         {"units": 0.001, "wallThicknesses": {"0.3": 4}},
         )

    # 10. Untidy drafting: corner gaps of 0.5 to 5 mm, a duplicated overlapping wall face, an
    #     outline left open.
    doc = new(); msp = doc.modelspace()
    gaps = [0.5, 1, 2, 5]
    # outer face as four lines, each stopping short of the next by a gap
    pts = [(0, 0), (W, 0), (W, D), (0, D)]
    for k in range(4):
        a, b = pts[k], pts[(k + 1) % 4]
        g = gaps[k]
        dx, dy = (b[0] - a[0], b[1] - a[1])
        L = math.hypot(dx, dy)
        msp.add_line(a, (b[0] - dx / L * g, b[1] - dy / L * g), dxfattribs={"layer": "A-WALL"})
    ipts = [(T, T), (W - T, T), (W - T, D - T), (T, D - T)]
    for k in range(4):
        a, b = ipts[k], ipts[(k + 1) % 4]
        g = gaps[(k + 2) % 4]
        dx, dy = (b[0] - a[0], b[1] - a[1])
        L = math.hypot(dx, dy)
        msp.add_line(a, (b[0] - dx / L * g, b[1] - dy / L * g), dxfattribs={"layer": "A-WALL"})
    msp.add_line((0, 0), (W / 2, 0), dxfattribs={"layer": "A-WALL"})  # a duplicate, overlapping
    write_dxf(doc, "untidy-corners")
    case("untidy-corners", "Outer and inner faces as lines stopping 0.5–5 mm short at the corners, one face drawn twice.",
         {"roles": GUESS},
         {"units": 0.001, "byFaces": True, "wallThicknesses": {"0.3": 4}, "bounds": [8, 6], "boundsTolerance": 0.01})

    # 11. Two storeys on layers: the ground floor's and the first floor's windows, a door on the
    #     ground floor, a partition on the first floor only.
    doc = new(); msp = doc.modelspace(); centre_house(msp, inner="WALL-FF")
    c = T / 2
    msp.add_line((1200, c), (2100, c), dxfattribs={"layer": "DOOR-GF"})
    for x in (5000,):
        msp.add_line((x, c), (x + 1200, c), dxfattribs={"layer": "WINDOW-GF"})
    for x in (1200, 5000):
        msp.add_line((x, c), (x + 1200, c), dxfattribs={"layer": "WINDOW-FF"})
        msp.add_line((x, D - c), (x + 1200, D - c), dxfattribs={"layer": "WINDOW-FF"})
    write_dxf(doc, "two-storeys")
    case("two-storeys", "Each storey's openings on a layer of its own; the partition on the first floor only.",
         {"roles": {"WALL-EXT": "wall:cavityBrickBlock", "WALL-FF": "wall:block100", "DOOR-GF": "door",
                    "WINDOW-GF": "window", "WINDOW-FF": "window"},
          "layerStoreys": {"DOOR-GF": 0, "WINDOW-GF": 0, "WINDOW-FF": 1, "WALL-FF": 1}},
         {"units": 0.001, "doors": 1, "windowsByStorey": {"0": 1, "1": 4}, "elementWalls": {"0": 4, "1": 5}})

    # 12. National-grid coordinates: the house at about 530 km east, 180 km north, in mm.
    doc = new(); msp = doc.modelspace(); faces_house(msp, origin=(530_123_456.0, 180_654_321.0))
    write_dxf(doc, "grid-coordinates")
    case("grid-coordinates", "The house at national-grid coordinates (530 km, 180 km) in millimetres.",
         {"roles": GUESS},
         {"units": 0.001, "byFaces": True, "wallThicknesses": {"0.3": 4, "0.1": 1}, "bounds": [8, 6],
          "boundsTolerance": 0.01})

    # 13. Turned 17°.
    doc = new(); msp = doc.modelspace()
    t = math.radians(17)
    def turn(p):
        return (p[0] * math.cos(t) - p[1] * math.sin(t) + 1000, p[0] * math.sin(t) + p[1] * math.cos(t) + 1000)
    msp.add_lwpolyline([turn(p) for p in [(0, 0), (W, 0), (W, D), (0, D)]], close=True, dxfattribs={"layer": "A-WALL"})
    msp.add_lwpolyline([turn(p) for p in [(T, T), (W - T, T), (W - T, D - T), (T, D - T)]], close=True,
                       dxfattribs={"layer": "A-WALL"})
    write_dxf(doc, "turned-17")
    case("turned-17", "The house by faces turned 17°.",
         {"roles": GUESS},
         {"units": 0.001, "turn": 17, "wallThicknesses": {"0.3": 4}, "angled": 0, "bounds": [8, 6],
          "boundsTolerance": 0.02})

    # 14. Malformed: a DXF cut off half way through a pair, and one whose group code is not a number.
    with open(os.path.join(OUT, "malformed-truncated.dxf"), "w") as f:
        f.write("0\nSECTION\n2\nENTITIES\n0\nLINE\n8\nWALL\n10\n0\n20\n0\n11\n")
    case("malformed-truncated", "A DXF cut off part way through an entity.", {"roles": GUESS},
         {"readError": True})
    with open(os.path.join(OUT, "malformed-codes.dxf"), "w") as f:
        f.write("0\nSECTION\n2\nENTITIES\nLINE\n0\n8\nWALL\n0\nENDSEC\n0\nEOF\n")
    case("malformed-codes", "A DXF whose group codes and values are out of step.", {"roles": GUESS},
         {"readError": True})

    # SVGs.
    def svg(name, body, size='width="297mm" height="210mm" viewBox="0 0 297 210"'):
        with open(os.path.join(OUT, name + ".svg"), "w") as f:
            f.write('<?xml version="1.0" encoding="UTF-8"?>\n<svg xmlns="http://www.w3.org/2000/svg" '
                    'xmlns:xlink="http://www.w3.org/1999/xlink" '
                    'xmlns:inkscape="http://www.inkscape.org/namespaces/inkscape" ' + size + '>\n' + body + '\n</svg>\n')
    # 1:100 on A4: the house's 8 m is 80 mm, at 20 mm from the left, its bottom at 190 mm.
    def rect(x, y, w, h):
        return f'<rect x="{20 + x / 100:g}" y="{190 - (y + h) / 100:g}" width="{w / 100:g}" height="{h / 100:g}"/>'
    svg("svg-faces-rects", '<g inkscape:groupmode="layer" inkscape:label="Walls">' + rect(0, 0, W, D) + rect(T, T, W - 2 * T, D - 2 * T)
        + '</g>\n<g inkscape:groupmode="layer" inkscape:label="Furniture"><circle cx="50" cy="160" r="3"/></g>'
        + '\n<g inkscape:groupmode="layer" inkscape:label="Labels"><text x="40" y="160">Hall</text></g>')
    case("svg-faces-rects", "SVG at 1:100 in mm: walls' two faces as rectangles on an Inkscape layer; furniture and labels on theirs.",
         {"roles": GUESS, "drawingScale": 100}, {"units": 0.001, "byFaces": True, "wallThicknesses": {"0.3": 4},
                                                   "bounds": [8, 6], "boundsTolerance": 0.02}, kind="svg")
    # In pixels: no real units; a group with a transform, paths with relative commands.
    body = ('<g id="walls" transform="translate(100 50) scale(2)">'
            '<path d="M0,0 h80 v60 h-80 z"/><path d="m3,3 h74 v54 h-74 z"/></g>')
    svg("svg-pixels-transform", body, size='width="600" height="400" viewBox="0 0 600 400"')
    case("svg-pixels-transform", "SVG in pixels, the walls in a group scaled and moved, paths in relative commands.",
         {"roles": {"walls": "wall:cavityBrickBlock"}, "metresPerUnit": 0.05},
         {"units": None, "byFaces": True, "wallThicknesses": {"0.3": 4}, "bounds": [8, 6], "boundsTolerance": 0.02},
         kind="svg")
    # Doors and windows as symbols placed with <use>, turned.
    body = ('<defs><symbol id="win"><line x1="0" y1="-1.5" x2="12" y2="-1.5"/><line x1="0" y1="1.5" x2="12" y2="1.5"/>'
            '</symbol><symbol id="door"><line x1="0" y1="0" x2="9" y2="0"/><line x1="0" y1="0" x2="0" y2="-9"/>'
            '<path d="M9,0 A9 9 0 0 0 0,-9"/></symbol></defs>'
            '<g inkscape:groupmode="layer" inkscape:label="WALL-EXT"><path d="M21.5,188.5 H98.5 V131.5 H21.5 Z"/></g>'
            '<g inkscape:groupmode="layer" inkscape:label="WINDOWS"><use xlink:href="#win" x="70" y="188.5"/>'
            '<use xlink:href="#win" transform="translate(98.5 170) rotate(-90)"/></g>'
            '<g inkscape:groupmode="layer" inkscape:label="DOORS"><use xlink:href="#door" x="32" y="188.5"/></g>')
    svg("svg-symbols", body)
    case("svg-symbols", "SVG at 1:100: centreline walls, windows and a door (with its swing) as symbols placed with <use>, one turned.",
         {"roles": {"WALL-EXT": "wall:cavityBrickBlock", "WINDOWS": "window", "DOORS": "door"}, "drawingScale": 100},
         {"units": 0.001, "doors": 1, "windows": 2, "notNotes": ["drawn away from any wall"]}, kind="svg")
    with open(os.path.join(OUT, "svg-malformed.svg"), "w") as f:
        f.write('<svg xmlns="http://www.w3.org/2000/svg"><g><path d="M0,0 L10,10"></svg>')
    case("svg-malformed", "An SVG whose elements are not closed.", {"roles": GUESS}, {"readError": True}, kind="svg")

    for name, kind, description, options, expect in CASES:
        with open(os.path.join(OUT, name + ".json"), "w") as f:
            entry = {"file": f"{name}.{kind}", "description": description, "options": options, "expect": expect}
            if name in LIMITATIONS:
                entry["limitation"] = LIMITATIONS[name]
            json.dump(entry, f, indent=2)
            f.write("\n")
    print(f"wrote {len(CASES)} plans to {OUT}")


if __name__ == "__main__":
    main()
