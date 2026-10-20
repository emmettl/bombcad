"""Made-up districts for the learned field model's training runs: not real places or map data.

    python3 -I Scripts/ml/make_district.py <out-folder> --style perimeter --seed 3 [--extent 2400]
        [--terrain flat|slope|hill|valley] [--density 1.0] [--turn 0]

Writes <out-folder>/district.osm (buildings with height tags, about (0°, 0°)) and, unless the
terrain is flat, <out-folder>/ground.asc (an ESRI ASCII grid of elevations in degrees, as
`scenebench district-scene --dem` reads). Prints the centre (lon,lat) and the building count as
JSON. The same arguments always give the same files.

Styles: perimeter (terraced blocks round courtyards, like the surrogate's fitting district),
grid (detached houses on a street grid), towers (tall blocks in plazas), industrial (large low
sheds, wide yards), mixed (each block one of the others, a quarter of the district turned).
"""
import argparse
import json
import math
import os
import random
import sys

M = 6_371_008.8 * math.pi / 180  # metres per degree, as ElevationGrid.metresPerDegree
STYLES = ("perimeter", "grid", "towers", "industrial", "mixed")
TERRAINS = ("flat", "slope", "hill", "valley")


def lonlat(x, y):
    return x / M, y / M


class Writer:
    def __init__(self):
        self.nodes, self.ways = [], []
        self.next_node, self.next_way = 1, 100

    def polygon(self, points, height):
        ids = []
        for x, y in points:
            lon, lat = lonlat(x, y)
            ids.append(self.next_node)
            self.nodes.append('  <node id="%d" lat="%.8f" lon="%.8f"/>' % (self.next_node, lat, lon))
            self.next_node += 1
        ids.append(ids[0])
        body = "".join('<nd ref="%d"/>' % r for r in ids)
        body += '<tag k="building" v="yes"/><tag k="height" v="%.1f"/>' % height
        self.ways.append('  <way id="%d">%s</way>' % (self.next_way, body))
        self.next_way += 1


def rectangle(x, y, w, h, turn=0.0, about=(0.0, 0.0)):
    points = [(x, y), (x + w, y), (x + w, y + h), (x, y + h)]
    if turn:
        c, s = math.cos(turn), math.sin(turn)
        ax, ay = about
        points = [(ax + (px - ax) * c - (py - ay) * s, ay + (px - ax) * s + (py - ay) * c) for px, py in points]
    return points


def block_buildings(style, rng, x, y, bw, bh):
    """The buildings of one street block at (x, y), bw by bh m: [(x, y, w, h, height)]."""
    out = []
    if style == "perimeter":
        depth = rng.uniform(10, 14)
        base = rng.uniform(8, 24)

        def terrace(x0, y0, length, along_x, d):
            p = 0.0
            while p < length - 6:
                f = min(rng.uniform(8, 20), length - p)
                h = max(4, base + rng.uniform(-4, 6))
                out.append((x0 + p, y0, f, d, h) if along_x else (x0, y0 + p, d, f, h))
                p += f

        if rng.random() < 0.7 and bh > 2 * depth + 6 and bw > 2 * depth + 6:
            terrace(x, y, bw, True, depth)
            terrace(x, y + bh - depth, bw, True, depth)
            terrace(x, y + depth, bh - 2 * depth, False, depth)
            terrace(x + bw - depth, y + depth, bh - 2 * depth, False, depth)
        else:
            terrace(x, y, bw, True, bh / 2)
            terrace(x, y + bh / 2, bw, True, bh / 2)
    elif style == "grid":
        # Detached houses in plots of 15-25 m, set back from the street.
        plot = rng.uniform(15, 25)
        for i in range(max(1, int(bw // plot))):
            for j in range(max(1, int(bh // plot))):
                if rng.random() < 0.15:
                    continue
                w, h = rng.uniform(8, plot - 4), rng.uniform(8, plot - 4)
                out.append((x + i * plot + 2, y + j * plot + 2, w, h, rng.uniform(5, 11)))
    elif style == "towers":
        s = rng.uniform(18, 40)
        out.append((x + bw / 2 - s / 2, y + bh / 2 - s / 2, s, s, rng.uniform(30, 90)))
        if rng.random() < 0.5:
            # A podium beside it.
            out.append((x + 2, y + 2, bw / 3, bh - 4, rng.uniform(6, 14)))
    elif style == "industrial":
        # One to three sheds side by side across the block, each in its own lot with a yard.
        lots = rng.randint(1, 3)
        lot = bw / lots
        for n in range(lots):
            w, h = rng.uniform(0.5, 0.85) * lot, rng.uniform(0.4, 0.8) * bh
            out.append((x + n * lot + rng.uniform(0, lot - w), y + rng.uniform(0, bh - h), w, h, rng.uniform(6, 14)))
    return out


def district(style, seed, extent, density, turn):
    """The buildings as [(points, height)] over 0..extent each way, the charge's square at the centre left
    open."""
    rng = random.Random("%s-%d" % (style, seed))
    centre = extent / 2
    sizes = {"perimeter": (60, 130), "grid": (60, 110), "towers": (50, 80), "industrial": (80, 150),
             "mixed": (60, 130)}
    lo, hi = sizes[style]
    streets = {"perimeter": (10, 25), "grid": (10, 16), "towers": (20, 40), "industrial": (15, 35),
               "mixed": (10, 30)}
    avenue = centre + rng.uniform(-300, 300)
    buildings = []
    x = 20.0
    while x < extent - 20:
        bw = rng.uniform(lo, hi)
        y = 20.0
        while y < extent - 20:
            bh = rng.uniform(lo, hi)
            if y < avenue + 20 < y + bh or y < avenue - 20 < y + bh:
                y = avenue + 20 + rng.uniform(10, 20)
                continue
            cx, cy = x + bw / 2, y + bh / 2
            r = math.hypot(cx - centre, cy - centre)
            kind = style
            if style == "mixed":
                kind = rng.choice(["perimeter", "perimeter", "grid", "towers", "industrial"])
            block_turn = math.radians(turn)
            if style == "mixed" and cx > centre + 300 and cy > centre + 300:
                block_turn += math.radians(30)
            if r >= 100 and rng.random() < density and rng.random() > 0.05:
                for bx, by, w, h, height in block_buildings(kind, rng, x, y, min(bw, extent - 20 - x),
                                                            min(bh, extent - 20 - y)):
                    if w > 3 and h > 3:
                        buildings.append((rectangle(bx, by, w, h, block_turn, (cx, cy)), height))
            y += bh + rng.uniform(*streets[style])
        x += bw + rng.uniform(*streets[style])
    return buildings


def elevation(terrain, seed, extent, x, y):
    rng = random.Random("ground-%s-%d" % (terrain, seed))
    a, b = rng.uniform(-1, 1), rng.uniform(-1, 1)
    hx, hy = rng.uniform(0.2, 0.8) * extent, rng.uniform(0.2, 0.8) * extent
    tall, wide = rng.uniform(20, 60), rng.uniform(150, 350)
    if terrain == "slope":
        norm = math.hypot(a, b) or 1
        grade = rng.uniform(0.01, 0.03)
        return 10 + grade * (a * x + b * y) / norm + grade * extent
    if terrain == "hill":
        return 5 + tall * math.exp(-((x - hx) ** 2 + (y - hy) ** 2) / (2 * wide ** 2))
    if terrain == "valley":
        # A valley along a line through the centre, the sides rising to `tall`.
        angle = math.atan2(b, a)
        d = abs((x - extent / 2) * math.sin(angle) - (y - extent / 2) * math.cos(angle))
        return 5 + tall * (1 - math.exp(-d ** 2 / (2 * wide ** 2)))
    return 0.0


def write(out, style, seed, extent, terrain, density=1.0, turn=0.0):
    if style not in STYLES or terrain not in TERRAINS:
        raise ValueError("style %s / terrain %s" % (style, terrain))
    os.makedirs(out, exist_ok=True)
    writer = Writer()
    for points, height in district(style, seed, extent, density, turn):
        writer.polygon(points, height)
    lo_lon, lo_lat = lonlat(0, 0)
    hi_lon, hi_lat = lonlat(extent, extent)
    with open(os.path.join(out, "district.osm"), "w") as handle:
        handle.write('<?xml version="1.0" encoding="UTF-8"?>\n'
                     "<!-- Made up for BombCAD's learned field model: not a real place. -->\n")
        handle.write('<osm version="0.6" generator="BombCAD ml">\n  <bounds minlat="%.7f" minlon="%.7f" '
                     'maxlat="%.7f" maxlon="%.7f"/>\n' % (lo_lat, lo_lon, hi_lat, hi_lon))
        handle.write("\n".join(writer.nodes + writer.ways) + "\n</osm>\n")
    ground = None
    if terrain != "flat":
        # 0.0003° cells (about 33 m), a margin of five beyond the district.
        step = 0.0003
        x0 = -5 * step
        n = int(math.ceil(extent / M / step)) + 10
        lines = ["ncols %d" % n, "nrows %d" % n, "xllcorner %.6f" % x0, "yllcorner %.6f" % x0,
                 "cellsize %.6f" % step, "NODATA_value -9999"]
        for r in range(n - 1, -1, -1):
            lines.append(" ".join("%.2f" % elevation(terrain, seed, extent, (x0 + (c + 0.5) * step) * M,
                                                    (x0 + (r + 0.5) * step) * M) for c in range(n)))
        ground = os.path.join(out, "ground.asc")
        with open(ground, "w") as handle:
            handle.write("\n".join(lines) + "\n")
    lon, lat = lonlat(extent / 2, extent / 2)
    return {"osm": os.path.join(out, "district.osm"), "dem": ground, "buildings": len(writer.ways),
            "centre": [lon, lat]}


def main(arguments):
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("out")
    parser.add_argument("--style", choices=STYLES, default="perimeter")
    parser.add_argument("--seed", type=int, default=1)
    parser.add_argument("--extent", type=float, default=2400)
    parser.add_argument("--terrain", choices=TERRAINS, default="flat")
    parser.add_argument("--density", type=float, default=1.0)
    parser.add_argument("--turn", type=float, default=0.0)
    a = parser.parse_args(arguments)
    print(json.dumps(write(a.out, a.style, a.seed, a.extent, a.terrain, a.density, a.turn)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
