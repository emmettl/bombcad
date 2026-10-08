#!/usr/bin/env python3
"""Read the cells of an Excel 97 (BIFF8) workbook without third-party packages.

Prints each sheet as tab-separated rows, or, with --json, writes {sheet: [[cell, ...], ...]} to stdout.
Only what a data table needs is supported: shared strings, numbers, RK and MULRK numbers, and inline
strings. Formulas give their cached numeric result where it is a number.

Usage: python3 RoomCAD/Scripts/read-xls.py FILE.xls [--json]
"""

import json
import struct
import sys

FREE, END_OF_CHAIN = 0xFFFFFFFF, 0xFFFFFFFE


def compound_stream(data, wanted="Workbook"):
    """A named stream from an OLE2 compound file."""
    if data[:8] != b"\xd0\xcf\x11\xe0\xa1\xb1\x1a\xe1":
        raise ValueError("Not an OLE2 compound file.")
    sector_shift, mini_shift = struct.unpack("<HH", data[30:34])
    sector = 1 << sector_shift
    mini = 1 << mini_shift
    fat_sectors, directory_start = struct.unpack("<I", data[44:48])[0], struct.unpack("<I", data[48:52])[0]
    mini_cutoff, mini_fat_start, mini_fat_count, difat_start, difat_count = struct.unpack("<IIIII", data[56:76])

    def read_sector(n):
        start = (n + 1) * sector
        return data[start:start + sector]

    difat = list(struct.unpack("<109I", data[76:512]))
    next_difat = difat_start
    for _ in range(difat_count):
        block = read_sector(next_difat)
        entries = struct.unpack(f"<{sector // 4}I", block)
        difat += entries[:-1]
        next_difat = entries[-1]
    fat = []
    for n in difat[:fat_sectors]:
        fat += struct.unpack(f"<{sector // 4}I", read_sector(n))

    def chain(start):
        out = []
        while start not in (END_OF_CHAIN, FREE) and len(out) <= len(fat):
            out.append(start)
            start = fat[start]
        return out

    def read_chain(start):
        return b"".join(read_sector(n) for n in chain(start))

    directory = read_chain(directory_start)
    entries = []
    for i in range(0, len(directory), 128):
        entry = directory[i:i + 128]
        length = struct.unpack("<H", entry[64:66])[0]
        name = entry[:max(length - 2, 0)].decode("utf-16-le")
        kind = entry[66]
        start, size = struct.unpack("<II", entry[116:124])
        entries.append((name, kind, start, size))
    root = entries[0]
    mini_stream = read_chain(root[2])
    mini_fat = []
    for n in chain(mini_fat_start):
        mini_fat += struct.unpack(f"<{sector // 4}I", read_sector(n))
    for name, kind, start, size in entries:
        if name not in (wanted, "Book"):
            continue
        if size < mini_cutoff:
            out = []
            while start not in (END_OF_CHAIN, FREE):
                out.append(mini_stream[start * mini:(start + 1) * mini])
                start = mini_fat[start]
            return b"".join(out)[:size]
        return read_chain(start)[:size]
    raise ValueError("No workbook stream.")


def rk_value(rk):
    if rk & 2:
        value = float(rk >> 2 if rk < 0x80000000 else (rk >> 2) - (1 << 30))
    else:
        value = struct.unpack("<d", struct.pack("<Q", (rk & 0xFFFFFFFC) << 32))[0]
    return value / 100 if rk & 1 else value


def read_string(record, offset, length_bytes=2):
    """A BIFF8 unicode string at offset; returns (text, end offset). Ignores rich text and phonetics runs."""
    count = struct.unpack("<H" if length_bytes == 2 else "<B", record[offset:offset + length_bytes])[0]
    offset += length_bytes
    flags = record[offset]
    offset += 1
    runs = phonetic = 0
    if flags & 8:
        runs = struct.unpack("<H", record[offset:offset + 2])[0]
        offset += 2
    if flags & 4:
        phonetic = struct.unpack("<I", record[offset:offset + 4])[0]
        offset += 4
    if flags & 1:
        text = record[offset:offset + 2 * count].decode("utf-16-le", "replace")
        offset += 2 * count
    else:
        text = record[offset:offset + count].decode("latin-1")
        offset += count
    return text, offset + 4 * runs + phonetic


def shared_strings(records):
    """The SST, following CONTINUE records, whose strings may switch between 8- and 16-bit characters."""
    pieces = records
    strings = []
    piece, offset = 0, 8
    total = struct.unpack("<I", pieces[0][4:8])[0]
    while len(strings) < total and piece < len(pieces):
        data = pieces[piece]
        if offset >= len(data):
            piece, offset = piece + 1, 0
            continue
        count = struct.unpack("<H", data[offset:offset + 2])[0]
        flags = data[offset + 2]
        offset += 3
        runs = phonetic = 0
        if flags & 8:
            runs = struct.unpack("<H", data[offset:offset + 2])[0]
            offset += 2
        if flags & 4:
            phonetic = struct.unpack("<I", data[offset:offset + 4])[0]
            offset += 4
        wide = flags & 1
        text = []
        remaining = count
        while remaining > 0:
            width = 2 if wide else 1
            available = (len(data) - offset) // width
            take = min(remaining, available)
            chunk = data[offset:offset + take * width]
            text.append(chunk.decode("utf-16-le" if wide else "latin-1", "replace"))
            offset += take * width
            remaining -= take
            if remaining > 0:
                piece += 1
                data = pieces[piece]
                wide = data[0] & 1
                offset = 1
        skip = 4 * runs + phonetic
        while skip > 0:
            available = len(data) - offset
            if skip <= available:
                offset += skip
                skip = 0
            else:
                skip -= available
                piece += 1
                data = pieces[piece]
                offset = 0
        strings.append("".join(text))
    return strings


def workbook(path):
    stream = compound_stream(open(path, "rb").read())
    records = []
    position = 0
    while position + 4 <= len(stream):
        kind, length = struct.unpack("<HH", stream[position:position + 4])
        records.append((kind, stream[position + 4:position + 4 + length]))
        position += 4 + length
    sheets_names = []
    strings = []
    for i, (kind, data) in enumerate(records):
        if kind == 0x0085:  # BOUNDSHEET
            name, _ = read_string(data, 6, length_bytes=1)
            sheets_names.append(name)
        elif kind == 0x00FC:  # SST
            group = [data]
            j = i + 1
            while j < len(records) and records[j][0] == 0x003C:
                group.append(records[j][1])
                j += 1
            strings = shared_strings(group)
    sheets = {}
    current = None
    index = -1
    for kind, data in records:
        if kind == 0x0809 and struct.unpack("<H", data[2:4])[0] == 0x0010:  # BOF of a worksheet
            index += 1
            current = {}
            sheets[sheets_names[index] if index < len(sheets_names) else f"Sheet{index + 1}"] = current
        elif current is None:
            continue
        elif kind == 0x00FD:  # LABELSST
            row, col, _, sst = struct.unpack("<HHHI", data[:10])
            current[(row, col)] = strings[sst] if sst < len(strings) else ""
        elif kind == 0x0203:  # NUMBER
            row, col, _ = struct.unpack("<HHH", data[:6])
            current[(row, col)] = struct.unpack("<d", data[6:14])[0]
        elif kind == 0x027E:  # RK
            row, col, _, rk = struct.unpack("<HHHI", data[:10])
            current[(row, col)] = rk_value(rk)
        elif kind == 0x00BD:  # MULRK
            row, first = struct.unpack("<HH", data[:4])
            n = (len(data) - 6) // 6
            for k in range(n):
                rk = struct.unpack("<I", data[4 + 6 * k + 2:4 + 6 * k + 6])[0]
                current[(row, first + k)] = rk_value(rk)
        elif kind == 0x0204:  # LABEL
            row, col, _ = struct.unpack("<HHH", data[:6])
            current[(row, col)], _ = read_string(data, 6)
        elif kind == 0x0006:  # FORMULA: a cached number unless the top bytes say otherwise
            row, col, _ = struct.unpack("<HHH", data[:6])
            if data[12:14] != b"\xff\xff":
                current[(row, col)] = struct.unpack("<d", data[6:14])[0]
    tables = {}
    for name, cells in sheets.items():
        if not cells:
            tables[name] = []
            continue
        rows = max(r for r, _ in cells) + 1
        cols = max(c for _, c in cells) + 1
        tables[name] = [[cells.get((r, c), "") for c in range(cols)] for r in range(rows)]
    return tables


if __name__ == "__main__":
    tables = workbook(sys.argv[1])
    if "--json" in sys.argv:
        json.dump(tables, sys.stdout, ensure_ascii=False)
    else:
        for name, rows in tables.items():
            print(f"## {name} ({len(rows)} rows)")
            for row in rows:
                print("\t".join(str(v) for v in row))
