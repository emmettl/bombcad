"""Stroked paths of a pdftocairo SVG page, in page coordinates (points, y down).

Vector charts in a PDF keep their curves as drawing commands: this reads each stroked <path>,
applies its transform (and its parent groups'), flattens cubic Béziers to 8 segments, and
returns the polyline with its stroke colour and width. Filled glyphs (text) are skipped.
"""
import re
import sys
import xml.etree.ElementTree as ET

import numpy as np

NUMBER = r"-?\d*\.?\d+(?:e-?\d+)?"


def matrix(transform):
    m = np.eye(3)
    if not transform:
        return m
    for name, args in re.findall(r"(\w+)\(([^)]*)\)", transform):
        v = [float(a) for a in re.findall(NUMBER, args)]
        t = np.eye(3)
        if name == "matrix":
            t = np.array([[v[0], v[2], v[4]], [v[1], v[3], v[5]], [0, 0, 1]])
        elif name == "translate":
            t = np.array([[1, 0, v[0]], [0, 1, v[1] if len(v) > 1 else 0], [0, 0, 1]])
        elif name == "scale":
            t = np.array([[v[0], 0, 0], [0, v[1] if len(v) > 1 else v[0], 0], [0, 0, 1]])
        m = m @ t
    return m


def flatten(d):
    """Subpaths of path data `d` (M, L, C, Z, absolute only, as pdftocairo writes them)."""
    tokens = re.findall(r"[MLCZ]|" + NUMBER, d)
    paths, current, i, command = [], [], 0, None
    while i < len(tokens):
        t = tokens[i]
        if t in "MLCZ":
            command = t
            i += 1
            if command == "Z":
                if current:
                    current.append(current[0])
                continue
            if command == "M" and current:
                paths.append(current)
                current = []
            continue
        if command in ("M", "L"):
            current.append((float(tokens[i]), float(tokens[i + 1])))
            i += 2
            if command == "M":
                command = "L"
        elif command == "C":
            p0 = np.array(current[-1])
            c = [np.array((float(tokens[i + 2 * k]), float(tokens[i + 2 * k + 1]))) for k in range(3)]
            for s in np.linspace(0, 1, 9)[1:]:
                q = (1 - s) ** 3 * p0 + 3 * (1 - s) ** 2 * s * c[0] + 3 * (1 - s) * s * s * c[1] + s**3 * c[2]
                current.append((q[0], q[1]))
            i += 6
        else:
            i += 1
    if current:
        paths.append(current)
    return paths


def strokes(path):
    root = ET.parse(path).getroot()
    out = []

    def walk(node, m):
        m = m @ matrix(node.get("transform"))
        tag = node.tag.split("}")[-1]
        if tag == "path" and node.get("stroke") and node.get("stroke") != "none":
            for sub in flatten(node.get("d", "")):
                p = np.array(sub)
                q = (m @ np.c_[p, np.ones(len(p))].T).T[:, :2]
                out.append({"stroke": node.get("stroke"), "width": float(node.get("stroke-width", 1)), "points": q})
        if tag in ("defs", "symbol"):
            return
        for child in node:
            walk(child, m)

    walk(root, np.eye(3))
    return out


if __name__ == "__main__":
    for s in strokes(sys.argv[1]):
        p = s["points"]
        print(s["stroke"], s["width"], len(p), p[:, 0].min().round(1), p[:, 0].max().round(1), p[:, 1].min().round(1), p[:, 1].max().round(1))
