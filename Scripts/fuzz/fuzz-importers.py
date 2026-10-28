#!/usr/bin/env python3
"""A mutation fuzzer for the importers that read a user's files: the DXF and SVG floor-plan
readers, the OBJ and STL mesh reader (ContinuumKit's MeshFile) and what the import sheet does
next with a mesh, the ESRI ASCII elevation grid, the GeoTIFF reader (its directory, strips and
tiles, LZW and Deflate), and the OpenStreetMap and GeoJSON readers; and, on a Mac, the app's IFC
importer.

It writes mutated copies of seed files (Fixtures/ and Samples/ by default) into a folder, then
runs a replay test over the folder, from a build made beforehand: ImporterFuzzReplayTests
(Tests/BlastModelTests/ImporterFuzzTests.swift), or for the IFC kinds IFCFuzzReplayTests
(Tests/BombCADTests/IFCFuzzTests.swift, macOS only). The test names each input before reading
it, so a crash or a hang is put down to its input; the driver then starts the test again after
it. An input that takes longer than --timeout seconds is a hang; a run whose processes grow past
--memory-mb of resident memory is stopped and counted as running out of memory. On Linux the
run's processes are its session's, read from /proc; on a Mac they are the driver's descendants
and their process groups, read from `ps`.

    Scripts/fuzz/fuzz-importers.py --work DIR [--scratch-path .build] [--sanitize address]
        [--count 2000] [--seed 1] [--timeout 20] [--memory-mb 3000] [--only dxf,svg]
        [--package DIR] [--corpus DIR] [--converter IfcConvert]

The build must already have the tests in it: `swift build --build-tests` with the same
--scratch-path and --sanitize. The inputs, each outcome (DIR/outcomes.tsv) and the findings
(DIR/findings.json, crashes, hangs and runs out of memory, with the log's last lines) stay in
DIR; nothing is written into the repository. Mutations are deterministic for a given --seed.

Kinds (--only): dxf, svg, obj, stl, asc, tif, lzw, zlib, osm, geojson; and the IFC importer's
ifc (the STEP file as BombCAD reads it itself, and with --converter the whole import through
IfcConvert), ifcxml and ifcobj (what IfcConvert hands back, its seeds made by --converter from
the sample IFCs). IFC kinds run alone: `--only ifc,ifcxml,ifcobj`.
"""
import argparse
import json
import os
import random
import re
import shutil
import signal
import struct
import subprocess
import sys
import tempfile
import time
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent.parent
SEED_GLOBS = {
    "dxf": ["Fixtures/FloorPlans/*.dxf", "Samples/Plans/*.dxf"],
    "svg": ["Fixtures/FloorPlans/*.svg", "Samples/Plans/*.svg"],
    "obj": ["Samples/Importer/**/*.obj"],
    "stl": ["Samples/Importer/**/*.stl"],
    "asc": ["Samples/Terrain/*.asc", "Fixtures/SyntheticDistrict/*.asc"],
    "tif": ["Samples/Terrain/*.tif"],
    "osm": ["Fixtures/SyntheticDistrict/*.osm"],
    "geojson": ["Samples/MapBuildings/*.geojson"],
    "ifc": ["Samples/Importer/**/*.ifc", "Samples/Plans/*.ifc"],
}
# Kinds whose replay is the app's (BombCAD's tests, macOS only), and those made, not found.
IFC_KINDS = {"ifc", "ifcxml", "ifcobj"}
MADE_KINDS = {"lzw", "zlib", "ifcxml", "ifcobj"}
# Numbers that break arithmetic: extremes, non-finite spellings, integers past Int and Int32.
EXTREMES = [
    "0", "-0", "1", "-1", "1e308", "-1e308", "1e309", "-1e309", "1e-320", "nan", "NaN", "inf",
    "-inf", "infinity", "9223372036854775807", "9223372036854775808", "-9223372036854775809",
    "2147483648", "4294967296", "1e18", "1e10", "123456789", "0.1e1", "1.5", "99999999999",
    "", " ", "1e", "--1", "0x10",
]
NUMBER = re.compile(rb"-?\d+(?:\.\d+)?(?:[eE][-+]?\d+)?")


def seeds(kinds):
    found = []
    for kind in kinds:
        for pattern in SEED_GLOBS[kind]:
            for path in sorted(ROOT.glob(pattern)):
                if "blind" in path.parts:
                    continue
                found.append((kind, path.stem, path.read_bytes()))
    return found


# --- Mutators: each takes (data, rng) and returns new bytes. ---


def flip_bits(data, rng):
    b = bytearray(data)
    for _ in range(rng.randint(1, 8)):
        if b:
            b[rng.randrange(len(b))] ^= 1 << rng.randrange(8)
    return bytes(b)


def truncate(data, rng):
    return data[: rng.randrange(max(1, len(data)))]


def random_bytes(data, rng):
    b = bytearray(data)
    at = rng.randrange(len(b) + 1)
    b[at:at] = bytes(rng.randrange(256) for _ in range(rng.randint(1, 32)))
    return bytes(b)


def numeric_extreme(data, rng):
    matches = list(NUMBER.finditer(data))
    if not matches:
        return flip_bits(data, rng)
    out = data
    for m in sorted(rng.sample(matches, min(len(matches), rng.randint(1, 4))), key=lambda m: -m.start()):
        out = out[: m.start()] + rng.choice(EXTREMES).encode() + out[m.end() :]
    return out


def lines_of(data):
    return data.split(b"\n")


def delete_lines(data, rng):
    lines = lines_of(data)
    if len(lines) < 2:
        return truncate(data, rng)
    at = rng.randrange(len(lines))
    del lines[at : at + rng.randint(1, 4)]
    return b"\n".join(lines)


def duplicate_lines(data, rng):
    lines = lines_of(data)
    at = rng.randrange(len(lines))
    span = lines[at : at + rng.randint(1, 30)]
    times = rng.choice([2, 10, 100, 1000])
    lines[at:at] = span * times
    return b"\n".join(lines)[:30_000_000]


def swap_lines(data, rng):
    lines = lines_of(data)
    if len(lines) < 2:
        return data
    i, j = rng.randrange(len(lines)), rng.randrange(len(lines))
    lines[i], lines[j] = lines[j], lines[i]
    return b"\n".join(lines)


def splice_self(data, rng):
    # A slice of the file inserted elsewhere in it: sections, blocks or elements repeated.
    if len(data) < 4:
        return data
    a = rng.randrange(len(data))
    b = min(len(data), a + rng.randint(1, 2000))
    at = rng.randrange(len(data))
    return data[:at] + data[a:b] + data[at:]


def nest_xml(data, rng):
    depth = rng.choice([50, 300, 3000, 100_000])
    tag = rng.choice([b"g", b"svg", b"a", b"switch"])
    inner = b"<line x1='0' y1='0' x2='1000' y2='0'/>"
    nested = (b"<" + tag + b">") * depth + inner + (b"</" + tag + b">") * depth
    at = data.rfind(b"</svg>")
    if at < 0:
        return data + nested
    return data[:at] + nested + data[at:]


def mutate_dxf_value(data, rng):
    # A group's value replaced, keeping the group codes on their lines.
    lines = lines_of(data)
    if len(lines) < 4:
        return data
    k = rng.randrange(1, len(lines), 2) if len(lines) > 2 else 1
    lines[k] = rng.choice(EXTREMES + ["SECTION", "ENDSEC", "BLOCK", "ENDBLK", "INSERT", "EOF", "SEQEND"]).encode()
    return b"\n".join(lines)


def mutate_dxf_code(data, rng):
    lines = lines_of(data)
    if len(lines) < 4:
        return data
    k = rng.randrange(0, len(lines) - 1, 2)
    lines[k] = rng.choice(["0", "2", "8", "10", "20", "40", "42", "50", "51", "70", "230", "-1", "999999999999999999999", "x"]).encode()
    return b"\n".join(lines)


# --- TIFF: a directory's values changed in place, and seeds the samples lack. ---

TIFF_TAGS = [256, 257, 258, 259, 273, 277, 278, 279, 284, 317, 322, 323, 324, 325, 339, 33550, 33922, 34264]
TIFF_EXTREMES = [0, 1, 2, 3, 5, 7, 8, 9, 15, 16, 17, 31, 32, 33, 63, 64, 65, 255, 256, 4096, 32767, 32768, 65535,
                 65536, 2**31 - 1, 2**31, 2**32 - 1]
BIG_EXTREMES = TIFF_EXTREMES + [2**32, 2**40, 2**62, 2**63 - 1, 2**63, 2**64 - 1]
DOUBLE_EXTREMES = [0.0, -1.0, 1e-300, 1e300, float("inf"), float("-inf"), float("nan"), 5e-324]


def tiff_entries(data):
    """(byte order, big, [(tag, type, count, value offset in the file, value size)]) or None."""
    if len(data) < 16 or data[:2] not in (b"II", b"MM"):
        return None
    bo = "<" if data[:2] == b"II" else ">"
    magic = struct.unpack(bo + "H", data[2:4])[0]
    big = magic == 43
    word, count_size, entry_size = (8, 8, 20) if big else (4, 2, 12)
    try:
        ifd = struct.unpack(bo + ("Q" if big else "I"), data[(8 if big else 4):(16 if big else 8)])[0]
        n = struct.unpack(bo + ("Q" if big else "H"), data[ifd:ifd + count_size])[0]
    except struct.error:
        return None
    sizes = {1: 1, 2: 1, 3: 2, 4: 4, 5: 8, 6: 1, 7: 1, 8: 2, 9: 4, 10: 8, 11: 4, 12: 8, 16: 8, 17: 8, 18: 8}
    out = []
    for k in range(min(n, 500)):
        at = ifd + count_size + entry_size * k
        if at + entry_size > len(data):
            break
        tag, typ = struct.unpack(bo + "HH", data[at:at + 4])
        count = struct.unpack(bo + ("Q" if big else "I"), data[at + 4:at + 4 + word])[0]
        size = sizes.get(typ, 1) * count
        if size <= word:
            offset = at + 4 + word
        else:
            offset = struct.unpack(bo + ("Q" if big else "I"), data[at + 4 + word:at + 4 + 2 * word])[0]
        out.append((tag, typ, count, offset, sizes.get(typ, 1), at))
    return bo, big, out


def mutate_tiff_tag(data, rng):
    """One of the raster's tags (size, samples, compression, strips, tiles, georeferencing) given an
    extreme value, or its count or type changed."""
    parsed = tiff_entries(data)
    if not parsed or not parsed[2]:
        return flip_bits(data, rng)
    bo, big, entries = parsed
    wanted = [e for e in entries if e[0] in TIFF_TAGS] or entries
    tag, typ, count, offset, size, at = rng.choice(wanted)
    b = bytearray(data)
    word = 8 if big else 4
    choice = rng.random()
    if choice < 0.15:
        # The count: past the file, zero, or one more.
        new = rng.choice([0, 1, count + 1, count * 2, 2**31, 2**32 - 1] + ([2**63, 2**64 - 1] if big else []))
        b[at + 4:at + 4 + word] = struct.pack(bo + ("Q" if big else "I"), new % (2**(8 * word)))
        return bytes(b)
    if choice < 0.25:
        b[at + 2:at + 4] = struct.pack(bo + "H", rng.choice([1, 3, 4, 5, 11, 12, 16, 0, 99]))
        return bytes(b)
    k = rng.randrange(max(1, min(count, 64)))
    place = offset + k * size
    if place + size > len(b):
        return bytes(b)
    if typ == 12:
        b[place:place + 8] = struct.pack(bo + "d", rng.choice(DOUBLE_EXTREMES))
    elif typ == 11:
        b[place:place + 4] = struct.pack(bo + "f", rng.choice(DOUBLE_EXTREMES))
    else:
        limit = 2**(8 * size)
        b[place:place + size] = (rng.choice(BIG_EXTREMES) % limit).to_bytes(size, "little" if bo == "<" else "big")
    return bytes(b)


def mutate_tiff_strip(data, rng):
    """A strip's or tile's bytes changed, its directory left whole: what the decoders read."""
    parsed = tiff_entries(data)
    if not parsed:
        return flip_bits(data, rng)
    bo, big, entries = parsed
    by_tag = {e[0]: e for e in entries}
    offsets, counts = by_tag.get(324) or by_tag.get(273), by_tag.get(325) or by_tag.get(279)
    if not offsets or not counts:
        return flip_bits(data, rng)

    def values(entry):
        tag, typ, count, offset, size, _ = entry
        fmt = {1: "B", 3: "H", 4: "I", 16: "Q"}.get(typ)
        if not fmt or offset + size * count > len(data):
            return []
        return list(struct.unpack(bo + fmt * count, data[offset:offset + size * count]))
    starts, lengths = values(offsets), values(counts)
    if not starts or len(starts) != len(lengths):
        return flip_bits(data, rng)
    k = rng.randrange(len(starts))
    start, length = starts[k], lengths[k]
    if start + length > len(data) or length == 0:
        return flip_bits(data, rng)
    strip = bytearray(data[start:start + length])
    kind = rng.random()
    if kind < 0.5:
        for _ in range(rng.randint(1, 6)):
            strip[rng.randrange(len(strip))] ^= 1 << rng.randrange(8)
    elif kind < 0.75:
        cut = rng.randrange(len(strip))
        strip[cut:] = bytes(len(strip) - cut)
    else:
        strip = bytearray(rng.randrange(256) for _ in strip)
    return data[:start] + bytes(strip) + data[start + length:]


def tiff_file(width, height, bits=32, fmt=3, compression=1, predictor=1, samples=1, planar=1, tile=None,
              rows=None, big=False, order="<", values=None):
    """A georeferenced TIFF of elevations: strips (`rows` each) or square tiles, uncompressed or
    Deflate, with or without a predictor; classic or BigTIFF."""
    import array
    rng = random.Random(width * 31 + height)
    values = values or [100 + 20 * ((x - width / 2) ** 2 + (y - height / 2) ** 2) ** 0.5 / width + rng.random()
                        for y in range(height) for x in range(width)]
    code = {(3, 4): "f", (3, 8): "d", (1, 1): "B", (1, 2): "H", (1, 4): "I", (2, 1): "b", (2, 2): "h",
            (2, 4): "i"}[(fmt, bits // 8)]
    bytes_per = bits // 8
    chunk_w, chunk_h = (tile, tile) if tile else (width, rows or height)
    across = (width + chunk_w - 1) // chunk_w
    down = (height + chunk_h - 1) // chunk_h
    stride = samples if planar == 1 else 1

    def sample(x, y, s):
        if x >= width or y >= height:
            return 0
        v = values[x + width * y] + s
        return v if fmt == 3 else int(v) % (2**(bits - (fmt == 2)))

    chunks = []
    for c in range(across * down):
        cx, cy = c % across, c // across
        rows_here = chunk_h if tile else min(chunk_h, height - cy * chunk_h)
        raw = b""
        for r in range(rows_here):
            row = [sample(cx * chunk_w + i, cy * chunk_h + r, s) for i in range(chunk_w) for s in range(stride)]
            packed = array.array(code, row)
            if (order == ">") != (sys.byteorder == "big"):
                packed.byteswap()
            data = bytearray(packed.tobytes())
            if predictor == 2:
                ints = [int.from_bytes(data[k:k + bytes_per], "little" if order == "<" else "big")
                        for k in range(0, len(data), bytes_per)]
                diff = [(ints[k] - (ints[k - stride] if k >= stride else 0)) % 2**bits for k in range(len(ints))]
                data = bytearray(b"".join(v.to_bytes(bytes_per, "little" if order == "<" else "big") for v in diff))
            elif predictor == 3:
                n = len(data) // bytes_per
                # Big-endian byte planes, most significant first, then differenced along the row.
                be = bytearray(packed.tobytes()) if order == ">" else bytearray(
                    b"".join(data[k:k + bytes_per][::-1] for k in range(0, len(data), bytes_per)))
                planes = bytearray(be[k * bytes_per + p] for p in range(bytes_per) for k in range(n))
                data = bytearray(planes[k] - (planes[k - stride] if k >= stride else 0) & 255
                                 for k in range(len(planes)))
            raw += bytes(data)
        if tile:
            raw += bytes(chunk_w * stride * bytes_per * (chunk_h - rows_here))
        chunks.append(zlib.compress(raw) if compression == 8 else raw)
    tags = {256: (4, [width]), 257: (4, [height]), 258: (3, [bits] * samples), 259: (3, [compression]),
            277: (3, [samples]), 284: (3, [planar]), 339: (3, [fmt] * samples),
            33550: (12, [10.0, 10.0, 0.0]), 33922: (12, [0.0, 0.0, 0.0, 500000.0, 4000000.0, 0.0]),
            34735: (3, [1, 1, 0, 1, 1024, 0, 1, 1])}
    if predictor != 1:
        tags[317] = (3, [predictor])
    if tile:
        tags[322], tags[323] = (3, [chunk_w]), (3, [chunk_h])
    else:
        tags[278] = (4, [chunk_h])
    word = 8 if big else 4
    off_type = 16 if big else 4
    header = 16 if big else 8
    entry_size = 20 if big else 12
    n_tags = len(tags) + 2
    ifd_size = (8 if big else 2) + entry_size * n_tags + word
    blob = bytearray()
    base = header + ifd_size
    starts = []
    for ch in chunks:
        starts.append(base + len(blob))
        blob += ch
    tags[324 if tile else 273] = (off_type, starts)
    tags[325 if tile else 279] = (off_type, [len(ch) for ch in chunks])
    fmt_of = {3: "H", 4: "I", 12: "d", 16: "Q"}
    size_of = {3: 2, 4: 4, 12: 8, 16: 8}
    extra = bytearray()
    entries = bytearray()
    extra_base = base + len(blob)
    for tag in sorted(tags):
        typ, vals = tags[tag]
        payload = struct.pack(order + fmt_of[typ] * len(vals), *vals)
        entries += struct.pack(order + "HH", tag, typ) + struct.pack(order + ("Q" if big else "I"), len(vals))
        if len(payload) <= word:
            entries += payload + bytes(word - len(payload))
        else:
            entries += struct.pack(order + ("Q" if big else "I"), extra_base + len(extra))
            extra += payload
    head = (b"II" if order == "<" else b"MM") + struct.pack(order + "H", 43 if big else 42)
    head += struct.pack(order + "HHQ", 8, 0, header) if big else struct.pack(order + "I", header)
    ifd = struct.pack(order + ("Q" if big else "H"), len(tags)) + entries + bytes(word)
    ifd += bytes(ifd_size - len(ifd))
    return bytes(head + ifd + blob + extra)


def made_tiffs():
    """GeoTIFFs in the layouts the samples lack: BigTIFF, tiled floats, several samples, planar
    bands, 64-bit floats, predictors on each, and big-endian."""
    specs = [
        dict(width=24, height=18, big=True),
        dict(width=24, height=18, big=True, compression=8, tile=16),
        dict(width=24, height=18, bits=64, compression=8, predictor=3, rows=5),
        dict(width=24, height=18, bits=32, compression=8, predictor=3, tile=16, order=">"),
        dict(width=24, height=18, bits=16, fmt=2, compression=8, predictor=2, samples=3, rows=4),
        dict(width=24, height=18, bits=16, fmt=1, compression=8, samples=2, planar=2, rows=6),
        dict(width=24, height=18, bits=8, fmt=1, predictor=2, rows=7, order=">"),
        dict(width=40, height=33, bits=32, fmt=2, compression=8, tile=16, big=True, order=">"),
    ]
    out = []
    for n, spec in enumerate(specs):
        name = "made-" + "-".join(f"{k}{v}" for k, v in spec.items() if k not in ("width", "height"))
        out.append(("tif", name.replace(">", "be").replace("<", "le")[:50], tiff_file(**spec)))
    return out


def zlib_seeds(tiffs, rng):
    """Deflate streams as GeoTIFF strips hold them: each Deflate strip of the TIFF seeds, and
    zlib's own streams of floats, of repeats and of noise at each level."""
    out = []
    for _, stem, data in tiffs:
        parsed = tiff_entries(data)
        if not parsed:
            continue
        bo, big, entries = parsed
        by_tag = {e[0]: e for e in entries}
        if 259 not in by_tag:
            continue
        tag, typ, count, offset, size, _ = by_tag[259]
        if int.from_bytes(data[offset:offset + size], "little" if bo == "<" else "big") != 8:
            continue
        for start_tag, count_tag in ((273, 279), (324, 325)):
            if start_tag in by_tag and count_tag in by_tag:
                def values(entry):
                    _, typ, count, offset, size, _ = entry
                    f = {3: "H", 4: "I", 16: "Q"}.get(typ, "I")
                    return struct.unpack(bo + f * count, data[offset:offset + size * count])
                for k, (s, c) in enumerate(zip(values(by_tag[start_tag]), values(by_tag[count_tag]))):
                    out.append(("zlib", f"{stem}-strip{k}", data[s:s + c]))
    for level in (0, 1, 6, 9):
        floats = struct.pack("<500f", *[100 + (k % 37) * 0.5 for k in range(500)])
        out.append(("zlib", f"floats-l{level}", zlib.compress(floats, level)))
        out.append(("zlib", f"repeats-l{level}", zlib.compress(b"ab" * 4000 + bytes(3000), level)))
        out.append(("zlib", f"noise-l{level}", zlib.compress(bytes(rng.randrange(256) for _ in range(3000)), level)))
    return out



TEXT_MUTATORS = [
    flip_bits, truncate, random_bytes, numeric_extreme, numeric_extreme, numeric_extreme, delete_lines,
    duplicate_lines, swap_lines, splice_self,
]
def mutate_step(data, rng):
    """An IFC entity's argument changed: a reference to a missing or to its own entity, a number
    made extreme, a string or list cut open, or the entity repeated."""
    lines = lines_of(data)
    entities = [k for k, line in enumerate(lines) if line.startswith(b"#") and b"=" in line]
    if not entities:
        return flip_bits(data, rng)
    k = rng.choice(entities)
    line = lines[k]
    choice = rng.random()
    if choice < 0.3:
        refs = list(re.finditer(rb"#\d+", line[1:]))
        if refs:
            m = rng.choice(refs)
            new = rng.choice([b"#0", b"#999999999", b"#99999999999999999999", line.split(b"=")[0], b"$", b"*"])
            line = line[:1 + m.start()] + new + line[1 + m.end():]
    elif choice < 0.55:
        line = numeric_extreme(line, rng)
    elif choice < 0.7:
        cut = rng.randrange(len(line)) if line else 0
        line = line[:cut] + rng.choice([b"'", b"(", b")", b",", b"", b"/*"]) + line[cut:]
    elif choice < 0.85:
        lines[k:k] = [line] * rng.choice([2, 100])
    else:
        line = line.replace(b"(", b"((", 1) if rng.random() < 0.5 else re.sub(rb"\(", b"(" * 200, line, count=1)
    lines[k] = line
    return b"\n".join(lines)


MUTATORS = {
    "dxf": TEXT_MUTATORS + [mutate_dxf_value, mutate_dxf_value, mutate_dxf_code],
    "svg": TEXT_MUTATORS + [nest_xml],
    "obj": TEXT_MUTATORS,
    "stl": TEXT_MUTATORS,
    "asc": TEXT_MUTATORS,
    "tif": [flip_bits, truncate, random_bytes, splice_self] + [mutate_tiff_tag] * 4 + [mutate_tiff_strip] * 2,
    "zlib": [flip_bits, flip_bits, truncate, random_bytes, splice_self],
    "osm": TEXT_MUTATORS + [nest_xml],
    "geojson": TEXT_MUTATORS,
    "ifc": TEXT_MUTATORS + [mutate_step] * 3,
    "ifcxml": TEXT_MUTATORS + [nest_xml],
    "ifcobj": TEXT_MUTATORS,
}


def converter_seeds(converter, ifc_seeds, timeout):
    """What IfcConvert makes of each sample IFC, as the importer asks for it: the metadata XML
    (`-y`) and the geometry OBJ (`--use-element-guids --weld-vertices`)."""
    out = []
    with tempfile.TemporaryDirectory(prefix="fuzz-ifc-") as folder:
        for _, stem, data in ifc_seeds:
            source = Path(folder) / "source.ifc"
            source.write_bytes(data)
            for kind, target, extra in (("ifcxml", "metadata.xml", []),
                                        ("ifcobj", "geometry.obj", ["-v", "--use-element-guids", "--weld-vertices"])):
                path = Path(folder) / target
                if path.exists():
                    path.unlink()
                try:
                    subprocess.run([str(converter), str(source), str(path), "-y"] + extra, stdin=subprocess.DEVNULL,
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=timeout * 6)
                except subprocess.TimeoutExpired:
                    continue
                if path.exists() and path.stat().st_size < 30_000_000:
                    out.append((kind, stem, path.read_bytes()))
    return out


def lzw_inputs(rng, count):
    """Random code streams for TIFF's LZW decoder: noise, and runs that grow the table."""
    out = []
    for n in range(count):
        size = rng.choice([1, 2, 16, 1000, 20000])
        if n % 3 == 0:
            out.append(("lzw", "noise", bytes(rng.randrange(256) for _ in range(size))))
        else:
            # Clear code (256) then codes that are always just defined: 9-bit codes, MSB first.
            bits = "100000000"
            table = 258
            for _ in range(size):
                code = rng.choice([rng.randrange(256), table - 1 if table > 258 else 65, table])
                width = 9 if table < 511 else 10 if table < 1023 else 11 if table < 2047 else 12
                bits += format(min(code, (1 << width) - 1), f"0{width}b")
                table += 1
            bits += "0" * (-len(bits) % 8)
            out.append(("lzw", "grow", int(bits, 2).to_bytes(len(bits) // 8, "big")))
    return out


def generate(args, rng, work):
    corpus = work / "corpus"
    if corpus.exists():
        shutil.rmtree(corpus)
    corpus.mkdir(parents=True)
    kinds = args.only.split(",") if args.only else [k for k in SEED_GLOBS if k not in IFC_KINDS] + ["lzw", "zlib"]
    pool = seeds([k for k in kinds if k in SEED_GLOBS])
    if "tif" in kinds:
        pool += made_tiffs()
    if "zlib" in kinds:
        pool += zlib_seeds(seeds(["tif"]) + made_tiffs(), rng)
    if {"ifcxml", "ifcobj"} & set(kinds):
        if not args.converter:
            raise SystemExit("ifcxml and ifcobj seeds are made by IfcConvert: pass --converter")
        made = converter_seeds(args.converter, seeds(["ifc"]), args.timeout)
        pool += [item for item in made if item[0] in kinds]
    pool = [item for item in pool if item[0] in kinds]
    if not pool and kinds != ["lzw"]:
        raise SystemExit("no seeds for " + ",".join(kinds))
    items = []
    # The seeds themselves first: they must all read as before.
    for kind, stem, data in pool:
        items.append((kind, f"{stem}-seed", data))
    for n in range(args.count if pool else 0):
        kind, stem, data = rng.choice(pool)
        mutator = rng.choice(MUTATORS[kind])
        out = data
        names = []
        for _ in range(rng.choice([1, 1, 1, 2, 3])):
            out = mutator(out, rng)
            names.append(mutator.__name__)
            mutator = rng.choice(MUTATORS[kind])
        items.append((kind, f"{stem}-{'+'.join(names)}", out))
    if "lzw" in kinds:
        items += lzw_inputs(rng, max(10, args.count // 20))
    for n, (kind, name, data) in enumerate(items):
        (corpus / f"{n:06d}-{name[:60]}.{kind}").write_bytes(data)
    return corpus, len(items)


class ProcessTracker:
    """The processes of a run started with start_new_session, so that its pid is its session's
    and its first process group's id: measured together and stopped together.

    On Linux, the swift driver starts the test runner in a process group of its own but in the
    driver's session, so the session's processes are read from /proc. A Mac has no /proc: there
    the run's processes are the started one's descendants (by parent, read from `ps`), and any
    process in one of their process groups, which keeps a runner whose parent has died."""

    def __init__(self):
        self.linux = os.path.isdir("/proc/self")

    def members(self, root):
        if self.linux:
            pids = []
            for entry in os.listdir("/proc"):
                if entry.isdigit():
                    try:
                        if os.getsid(int(entry)) == root:
                            pids.append(int(entry))
                    except OSError:
                        continue
            return {pid: None for pid in pids}
        listing = subprocess.run(["ps", "-A", "-o", "pid=,ppid=,pgid=,rss="], capture_output=True, text=True).stdout
        table = {}
        for line in listing.splitlines():
            fields = line.split()
            if len(fields) == 4 and all(f.lstrip("-").isdigit() for f in fields):
                pid, ppid, pgid, rss = map(int, fields)
                table[pid] = (ppid, pgid, rss)
        if root not in table and not any(v[1] == root for v in table.values()):
            return {}
        found, groups = {root}, {root}
        changed = True
        while changed:
            changed = False
            for pid, (ppid, pgid, _) in table.items():
                if pid not in found and (ppid in found or pgid in groups):
                    found.add(pid)
                    groups.add(pgid)
                    changed = True
        return {pid: table[pid][2] for pid in found if pid in table}

    def stop(self, root):
        for pid in self.members(root):
            if pid != os.getpid():
                try:
                    os.kill(pid, signal.SIGKILL)
                except OSError:
                    pass

    def resident_mb(self, root):
        members = self.members(root)
        if not self.linux:
            return sum(rss or 0 for rss in members.values()) // 1024
        total = 0
        for entry in map(str, members):
            try:
                with open(f"/proc/{entry}/status") as status:
                    for line in status:
                        if line.startswith("VmRSS:"):
                            total += int(line.split()[1]) // 1024
            except (OSError, ValueError):
                continue
        return total


def run(args, work, corpus, total):
    outcomes = work / "outcomes.tsv"
    progress = work / "progress.txt"
    for f in (outcomes, progress):
        if f.exists():
            f.unlink()
    findings = []
    skip = 0
    env = dict(os.environ)
    env.update(
        BLASTMODEL_FUZZ_DIR=str(corpus), BLASTMODEL_FUZZ_OUT=str(outcomes), BLASTMODEL_FUZZ_PROGRESS=str(progress)
    )
    if args.sanitize == "address":
        env["ASAN_OPTIONS"] = f"hard_rss_limit_mb={args.memory_mb}:detect_leaks=0:allocator_may_return_null=0"
    if args.converter:
        env["BOMBCAD_FUZZ_CONVERTER"] = str(Path(args.converter).resolve())
    suite = "IFCFuzzReplayTests" if args.ifc else "ImporterFuzzReplayTests"
    command = ["swift", "test", "--skip-build", "--scratch-path", args.scratch_path, "--filter", suite]
    if args.sanitize:
        command += ["--sanitize", args.sanitize]
    tracker = ProcessTracker()

    started = time.time()
    while skip < total:
        env["BLASTMODEL_FUZZ_SKIP"] = str(skip)
        log_path = work / f"run-{skip:06d}.log"
        with open(log_path, "wb") as log:
            proc = subprocess.Popen(
                command, cwd=args.package, env=env, stdout=log, stderr=subprocess.STDOUT, start_new_session=True
            )
            current, since, hung, oom = None, time.time(), False, False
            while proc.poll() is None:
                time.sleep(0.5)
                text = progress.read_text() if progress.exists() else ""
                if text != current:
                    current, since = text, time.time()
                elif current and time.time() - since > args.timeout:
                    hung = True
                if current and tracker.resident_mb(proc.pid) > args.memory_mb:
                    oom = True
                if hung or oom:
                    tracker.stop(proc.pid)
                    proc.wait()
                    break
            # Nothing of the run outlives it.
            tracker.stop(proc.pid)
        text = progress.read_text().split() if progress.exists() else []
        index = int(text[0]) if text and int(text[0]) >= skip else None
        done = outcomes.read_text().count("\n") if outcomes.exists() else 0
        tail = log_path.read_text(errors="replace").splitlines()[-40:]
        failed = hung or oom or proc.returncode != 0
        if not failed or index is None:
            if failed:
                findings.append({"kind": "harness", "returncode": proc.returncode, "log": tail})
            break
        recorded = {line.split("\t")[0] for line in outcomes.read_text().split("\n")} if outcomes.exists() else set()
        if str(index) in recorded and not hung:
            # The crash came after the input's outcome was written: in the runner, not a reader.
            findings.append({"kind": "after-input", "index": index, "returncode": proc.returncode, "log": tail})
            skip = index + 1
            continue
        name = text[1]
        joined = "\n".join(tail)
        kind = (
            "oom" if oom or "rss limit" in joined or "out of memory" in joined.lower() else "hang" if hung else "crash"
        )
        findings.append({"kind": kind, "index": index, "input": name, "returncode": proc.returncode, "log": tail})
        print(f"{kind}: {name}", flush=True)
        skip = index + 1
    elapsed = time.time() - started
    (work / "findings.json").write_text(json.dumps(findings, indent=1))
    return findings, elapsed


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--work", required=True, type=Path)
    parser.add_argument("--scratch-path", default=".build")
    parser.add_argument("--sanitize", default=None, choices=[None, "address", "thread"])
    parser.add_argument("--count", type=int, default=2000)
    parser.add_argument("--seed", type=int, default=1)
    parser.add_argument("--timeout", type=float, default=20)
    parser.add_argument("--memory-mb", type=int, default=3000)
    parser.add_argument("--only", default="")
    parser.add_argument("--corpus", type=Path, help="replay this folder instead of generating one")
    parser.add_argument("--package", type=Path, default=ROOT, help="the package to test (the repository)")
    parser.add_argument("--converter", type=Path, help="IfcConvert, for the ifcxml and ifcobj seeds and the whole IFC import")
    args = parser.parse_args()
    kinds = set(args.only.split(",")) if args.only else set()
    args.ifc = bool(kinds & IFC_KINDS)
    if args.ifc and kinds - IFC_KINDS:
        parser.error("IFC kinds run alone (their replay is BombCAD's tests): --only ifc,ifcxml,ifcobj")
    if args.ifc and sys.platform != "darwin":
        parser.error("the IFC importer is the app's, and runs on a Mac only")
    if args.corpus:
        args.ifc = any(p.suffix[1:] in IFC_KINDS for p in args.corpus.iterdir())
    args.work.mkdir(parents=True, exist_ok=True)
    rng = random.Random(args.seed)
    if args.corpus:
        corpus, total = args.corpus, len(list(args.corpus.iterdir()))
    else:
        corpus, total = generate(args, rng, args.work)
    print(f"{total} inputs in {corpus}", flush=True)
    findings, elapsed = run(args, args.work, corpus, total)
    # Lines end at a newline only: a message may hold a line or paragraph separator of its own.
    text = (args.work / "outcomes.tsv").read_text() if (args.work / "outcomes.tsv").exists() else ""
    outcomes = [line for line in text.split("\n") if line.count("\t") >= 3]
    slow = sorted((float(l.split("\t")[2]), l.split("\t")[1]) for l in outcomes)[-5:]
    print(f"{len(outcomes)} outcomes in {elapsed:.0f} s; {len(findings)} findings")
    for f in findings:
        print(f"  {f['kind']}: {f.get('input', '')}")
    print("slowest:", ", ".join(f"{name} {s:.1f} s" for s, name in slow))
    nonfinite = [l for l in outcomes if "finite false" in l]
    print(f"{len(nonfinite)} outcomes read with non-finite values")
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main())
