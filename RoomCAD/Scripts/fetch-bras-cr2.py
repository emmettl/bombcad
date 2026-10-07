#!/usr/bin/env python3
"""Fetch the parts of the BRAS database used to compare RoomCAD with the measured seminar room CR2.

BRAS (Benchmark for Room Acoustical Simulation, Aspöck et al., TU Berlin and RWTH Aachen) is published
under CC BY-SA 4.0 at https://depositonce.tu-berlin.de/items/38410727-febb-4769-8002-9c710ba393c4.
Its archives are large, so this reads each archive's directory and then only the members needed, with
HTTP range requests: about 7.5 MB instead of 850 MB. Files land in RoomCAD/.cache/bras-cr2, which git
ignores; RoomCAD's repository keeps only numbers derived from them, with attribution.

Usage: python3 RoomCAD/Scripts/fetch-bras-cr2.py
"""

import pathlib
import struct
import sys
import urllib.request
import zlib

BITSTREAMS = "https://api-depositonce.tu-berlin.de/server/api/core/bitstreams"
ARCHIVES = {
    "scene": (f"{BITSTREAMS}/53c3cf64-3547-4aa6-946b-1b4755729f2a/content", 615_751_495),
    "surfaces": (f"{BITSTREAMS}/b2970524-fb10-482a-ab14-f07da5ad7615/content", 235_694_104),
}
SCENE = "1 Scene descriptions/CR2 small room (seminar room)/"
WANTED = {
    "scene": lambda name: name.startswith(SCENE)
    and (
        ("RIRs/wav/" in name and name.endswith("_Dodecahedron.wav"))
        or name.endswith("Geometry/CR2_RIR_Dodecahedron.skp")
        or name.endswith("Geometry/CR2_RIR_Dodecahedron.png")
        or name.endswith("Geometry/CR2_ModelSimplifications.pdf")
        or name.endswith("Pictures/Details/0_roomPlan.pdf")
    ),
    "surfaces": lambda name: "/_csv/" in name and "mat_CR2_" in name and name.endswith(".csv"),
}
DESTINATION = pathlib.Path(__file__).resolve().parent.parent / ".cache" / "bras-cr2"


def read_range(url, start, end):
    request = urllib.request.Request(url, headers={"Range": f"bytes={start}-{end}"})
    with urllib.request.urlopen(request) as response:
        data = response.read()
    if len(data) != end - start + 1:
        raise RuntimeError(f"Asked for {end - start + 1} bytes from {url}, got {len(data)}.")
    return data


def members(url, size):
    """Each member's name, compressed size, method and local header offset, from the central directory."""
    tail = read_range(url, size - 65_536, size - 1)
    end = tail.rfind(b"PK\x05\x06")
    count, directory_size, directory_offset = struct.unpack("<HII", tail[end + 10 : end + 20])
    if directory_offset == 0xFFFFFFFF or count == 0xFFFF:
        locator = tail.rfind(b"PK\x06\x06")
        count, directory_size, directory_offset = struct.unpack("<QQQ", tail[locator + 32 : locator + 56])
    directory = read_range(url, directory_offset, directory_offset + directory_size - 1)
    position = 0
    while directory[position : position + 4] == b"PK\x01\x02":
        method = struct.unpack("<H", directory[position + 10 : position + 12])[0]
        compressed, uncompressed = struct.unpack("<II", directory[position + 20 : position + 28])
        name_length, extra_length, comment_length = struct.unpack("<HHH", directory[position + 28 : position + 34])
        offset = struct.unpack("<I", directory[position + 42 : position + 46])[0]
        name = directory[position + 46 : position + 46 + name_length].decode("utf-8")
        extra = directory[position + 46 + name_length : position + 46 + name_length + extra_length]
        # Zip64 sizes and offset, in that order, for the fields that overflowed.
        e = 0
        while e + 4 <= len(extra):
            tag, length = struct.unpack("<HH", extra[e : e + 4])
            if tag == 1:
                values = list(struct.unpack(f"<{length // 8}Q", extra[e + 4 : e + 4 + length]))
                if uncompressed == 0xFFFFFFFF:
                    uncompressed = values.pop(0)
                if compressed == 0xFFFFFFFF:
                    compressed = values.pop(0)
                if offset == 0xFFFFFFFF:
                    offset = values.pop(0)
            e += 4 + length
        yield name, method, compressed, uncompressed, offset
        position += 46 + name_length + extra_length + comment_length


def extract(url, method, compressed, uncompressed, offset):
    header = read_range(url, offset, offset + 29)
    name_length, extra_length = struct.unpack("<HH", header[26:30])
    start = offset + 30 + name_length + extra_length
    data = read_range(url, start, start + compressed - 1) if compressed else b""
    if method == 8:
        data = zlib.decompress(data, -15)
    elif method != 0:
        raise RuntimeError(f"Unsupported compression method {method}.")
    if len(data) != uncompressed:
        raise RuntimeError("Extracted size does not match the archive's directory.")
    return data


def main():
    total = 0
    for archive, (url, size) in ARCHIVES.items():
        for name, method, compressed, uncompressed, offset in members(url, size):
            if name.endswith("/") or not WANTED[archive](name):
                continue
            target = DESTINATION / archive / pathlib.PurePosixPath(name).name
            if "fitted_estimates" in name:
                target = DESTINATION / "fitted" / target.name
            elif "initial_estimates" in name:
                target = DESTINATION / "initial" / target.name
            if target.exists() and target.stat().st_size == uncompressed:
                continue
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(extract(url, method, compressed, uncompressed, offset))
            total += compressed
            print(f"{target.relative_to(DESTINATION)} ({uncompressed:,} bytes)")
    print(f"Fetched {total:,} bytes into {DESTINATION}.")


if __name__ == "__main__":
    sys.exit(main())
