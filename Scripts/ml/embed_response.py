#!/usr/bin/env python3
"""Builds the live drag's learned response into the app (emmettl/bombcad-work#112): writes
Sources/BlastModel/LiveResponse+Embedded.swift from a `train_response.py` live-response.bclr, its
bytes as base64 lines in one string literal, with the file's SHA-256 beside them.

    python3 -I Scripts/ml/embed_response.py $BOMBCAD_DATA/ml/live-response-2/out/live-response.bclr \
        --broken-threshold -1.5 --out $BOMBCAD_DATA/ml/live-response-2/app/live-response.bclr
"""

import argparse
import base64
import hashlib
import json
import struct
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
TARGET = ROOT / "Sources" / "BlastModel" / "LiveResponse+Embedded.swift"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("weights")
    parser.add_argument("--broken-threshold", type=float,
                        help="the component network's glass-broken logit threshold, set in the header")
    parser.add_argument("--out", help="the weights, so set, written here too")
    args = parser.parse_args()
    source = Path(args.weights)
    data = source.read_bytes()
    assert data[:4] == b"BCLR", "not a .bclr file"
    _, length = struct.unpack("<II", data[4:12])
    header = json.loads(data[12:12 + length])
    if args.broken_threshold is not None:
        header["brokenThreshold"] = args.broken_threshold
        text = json.dumps(header).encode()
        data = b"BCLR" + struct.pack("<II", 1, len(text)) + text + data[12 + length:]
    if args.out:
        Path(args.out).write_bytes(data)
    digest = hashlib.sha256(data).hexdigest()
    text = base64.b64encode(data).decode()
    lines = [text[i:i + 100] for i in range(0, len(text), 100)]
    body = "\n".join(lines)
    TARGET.write_text(
        "// The live drag's learned response's weights, built in (emmettl/bombcad-work#112): written by\n"
        "// Scripts/ml/embed_response.py from `train_response.py`'s live-response.bclr, base64.\n"
        f"// {header.get('trainedOn', '')}; {len(data):,} bytes, SHA-256 {digest}.\n"
        "// swift-format-ignore-file\n"
        "extension LiveResponse.Weights {\n"
        f"    static let embeddedSHA256 = \"{digest}\"\n"
        "    static let embeddedWeights: String? = \"\"\"\n"
        f"{body}\n"
        "\"\"\"\n"
        "}\n")
    print(f"{TARGET.relative_to(ROOT)}: {len(data):,} bytes, {digest}")


if __name__ == "__main__":
    main()
