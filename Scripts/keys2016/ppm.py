"""Read binary PPM (P6) images with numpy; pdfimages writes them."""
import numpy as np


def read(path):
    data = open(path, "rb").read()
    fields, pos = [], 0
    while len(fields) < 4:
        while data[pos : pos + 1].isspace():
            pos += 1
        if data[pos : pos + 1] == b"#":
            pos = data.index(b"\n", pos) + 1
            continue
        end = pos
        while not data[end : end + 1].isspace():
            end += 1
        fields.append(data[pos:end])
        pos = end
    pos += 1
    width, height = int(fields[1]), int(fields[2])
    return np.frombuffer(data[pos : pos + width * height * 3], np.uint8).reshape(height, width, 3)
