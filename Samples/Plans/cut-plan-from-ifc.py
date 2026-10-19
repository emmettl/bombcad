#!/usr/bin/env python3
"""Cuts a floor plan out of an IFC building as a DXF, as an architect's plan is drawn: every
element sliced by a horizontal plane at a height above each storey's floor, the cut drawn as
lines (walls by both faces), each IFC class on a layer of its own (IFCWALL, IFCWINDOW, ...).

    python3 cut-plan-from-ifc.py BUILDING.ifc OUT.dxf [--height 1.0] [--storey NAME]

Uses BombCAD's pinned IfcConvert (`python3 Scripts/prepare-ifc-converter.py` fetches it) for the
geometry and the classes; no other packages. Written to make test plans of buildings whose real
models are known, so that a plan read back into BombCAD can be set against the model it came from.
"""

import argparse
import collections
import os
import subprocess
import tempfile
import xml.etree.ElementTree as ET

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
CONVERTER = os.path.join(ROOT, ".build", "ifc-converter", "IfcConvert")


def convert(ifc, folder):
    obj = os.path.join(folder, "model.obj")
    xml = os.path.join(folder, "model.xml")
    subprocess.run([CONVERTER, "-y", ifc, obj, "--use-element-guids", "--weld-vertices"], check=True,
                   capture_output=True)
    subprocess.run([CONVERTER, "-y", ifc, xml], check=True, capture_output=True)
    return obj, xml


def classes_and_storeys(xml):
    """Each product's class and storey name by GlobalId, and each storey's elevation (m, if given)."""
    tree = ET.parse(xml).getroot()
    found, storeys = {}, {}

    def walk(node, storey):
        tag = node.tag
        if tag == "IfcBuildingStorey":
            storey = node.get("Name") or node.get("id")
            storeys[storey] = float(node.get("Elevation") or "nan")
        guid = node.get("id")
        if guid and len(guid) == 22 and tag.startswith("Ifc"):
            found[guid] = (tag, storey)
        for child in node:
            walk(child, storey)

    for section in tree:
        if section.tag == "decomposition":
            walk(section, None)
    return found, storeys


def read_obj(obj):
    vertices, groups, current = [], collections.defaultdict(list), None
    for line in open(obj):
        if line.startswith("v "):
            _, x, y, z = line.split()[:4]
            vertices.append((float(x), float(y), float(z)))
        elif line.startswith("g "):
            current = line.split(None, 1)[1].strip()
        elif line.startswith("f "):
            ids = [int(p.split("/")[0]) - 1 for p in line.split()[1:]]
            for k in range(1, len(ids) - 1):
                groups[current].append((ids[0], ids[k], ids[k + 1]))
    return vertices, groups


def slice_triangle(a, b, c, z):
    """The segment where the plane at z crosses a triangle, or None."""
    points = []
    for p, q in ((a, b), (b, c), (c, a)):
        if (p[2] - z) * (q[2] - z) < 0:
            t = (z - p[2]) / (q[2] - p[2])
            points.append((p[0] + t * (q[0] - p[0]), p[1] + t * (q[1] - p[1])))
    return (points[0], points[1]) if len(points) == 2 else None


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("ifc")
    parser.add_argument("out")
    parser.add_argument("--height", type=float, default=1.0, help="metres above the storey's floor")
    parser.add_argument("--storey", help="the storey to cut (by name); the lowest by default")
    args = parser.parse_args()
    with tempfile.TemporaryDirectory() as folder:
        obj, xml = convert(args.ifc, folder)
        classes, storeys = classes_and_storeys(xml)
        vertices, groups = read_obj(obj)
    # The storey's floor: its elements' lowest point (elevations are often missing or relative).
    members = {g for g, (_, s) in classes.items() if (args.storey is None or s == args.storey)}
    if args.storey is None:
        lows = collections.defaultdict(list)
        for guid, triangles in groups.items():
            if guid in classes and classes[guid][1] is not None:
                lows[classes[guid][1]].append(min(vertices[i][2] for t in triangles for i in t))
        lowest = min(lows, key=lambda s: min(lows[s]))
        members = {g for g, (_, s) in classes.items() if s == lowest}
    name = args.storey or lowest
    elevation = storeys.get(name, float("nan"))
    # The storey's own elevation where the IFC gives it; else its elements' lowest point.
    floor = elevation if elevation == elevation else min(
        vertices[i][2] for g in members if g in groups for t in groups[g] for i in t)
    z = floor + args.height
    rows = ["0", "SECTION", "2", "HEADER", "9", "$INSUNITS", "70", "6", "0", "ENDSEC",
            "0", "SECTION", "2", "ENTITIES"]
    counts = collections.Counter()
    for guid, triangles in groups.items():
        kind = classes.get(guid, ("IfcBuildingElementProxy", None))[0].upper()
        kind = kind.replace("STANDARDCASE", "")
        for t in triangles:
            seg = slice_triangle(vertices[t[0]], vertices[t[1]], vertices[t[2]], z)
            if seg is None:
                continue
            (x0, y0), (x1, y1) = seg
            if abs(x1 - x0) + abs(y1 - y0) < 1e-6:
                continue
            rows += ["0", "LINE", "8", kind, "10", f"{x0:.4f}", "20", f"{y0:.4f}", "30", "0",
                     "11", f"{x1:.4f}", "21", f"{y1:.4f}", "31", "0"]
            counts[kind] += 1
    rows += ["0", "ENDSEC", "0", "EOF"]
    with open(args.out, "w") as f:
        f.write("\n".join(rows) + "\n")
    print(f"cut at {z:.3f} m: " + ", ".join(f"{n} {k}" for k, n in counts.most_common()))


if __name__ == "__main__":
    main()
