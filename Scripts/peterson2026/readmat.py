"""A minimal reader for MATLAB 5 MAT-files holding real double arrays, with numpy and zlib only.

Used for Peterson's DAQ records (scipy and h5py are not installed here).
"""

import struct
import zlib

import numpy as np

TYPES = {1: "i1", 2: "u1", 3: "i2", 4: "u2", 5: "i4", 6: "u4", 7: "f4", 9: "f8", 12: "i8", 13: "u8"}


def _elements(buffer, endian):
    offset = 0
    while offset + 8 <= len(buffer):
        kind, size = struct.unpack_from(endian + "II", buffer, offset)
        if kind >> 16:  # small data element: size in the upper half, data in the tag
            size, kind = kind >> 16, kind & 0xFFFF
            yield kind, buffer[offset + 4 : offset + 4 + size]
            offset += 8
            continue
        data = buffer[offset + 8 : offset + 8 + size]
        yield kind, data
        offset += 8 + size + (-size % 8 if kind != 15 else 0)


def _matrix(data, endian):
    parts = list(_elements(data, endian))
    dims = np.frombuffer(parts[1][1], endian + "i4")
    name = parts[2][1].decode("ascii", "replace").rstrip("\x00")
    kind, raw = parts[3]
    values = np.frombuffer(raw, endian + TYPES[kind]).astype(float)
    return name, values.reshape(tuple(dims[::-1])).T.squeeze()


def load(path):
    with open(path, "rb") as handle:
        content = handle.read()
    endian = "<" if content[126:128] == b"IM" else ">"
    variables = {}
    for kind, data in _elements(content[128:], endian):
        if kind == 15:
            data = zlib.decompress(data)
            kind, size = struct.unpack_from(endian + "II", data, 0)
            data = data[8 : 8 + size]
        if kind == 14:
            name, values = _matrix(data, endian)
            variables[name] = values
    return variables


if __name__ == "__main__":
    import sys

    for name, values in load(sys.argv[1]).items():
        print(name, values.shape, values[:3])
