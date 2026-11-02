#!/usr/bin/env python3
"""Builds the live drag's learned response into the app (emmettl/bombcad-work#112): writes
Sources/BlastModel/LiveResponse+Embedded.swift from a `train_response.py` live-response.bclr, its
bytes as base64 lines in one string literal, with the file's SHA-256 beside them.

    python3 -I Scripts/ml/embed_response.py $BOMBCAD_DATA/ml/live-response-2/out/live-response.bclr \
        --broken-threshold -1.5 --out $BOMBCAD_DATA/ml/live-response-2/app/live-response.bclr

With `--add other.bclr`, the networks of `other` that the weights lack are added to them, the
weights' own left as they are to the byte (emmettl/bombcad-work#117: the glass thrown network,
trained alone, beside the shipped three).
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
    parser.add_argument("--add", help="another .bclr whose networks the weights lack are added")
    parser.add_argument("--extra", help="write the weights as a further built-in file, "
                        "Sources/BlastModel/LiveResponse+<Extra>.swift, its networks added to the main ones' at load "
                        "(`LiveResponse.Weights.builtIn`): the main file left as it is")
    args = parser.parse_args()
    source = Path(args.weights)
    data = source.read_bytes()
    assert data[:4] == b"BCLR", "not a .bclr file"
    version, length = struct.unpack("<II", data[4:12])
    header = json.loads(data[12:12 + length])
    if args.add:
        other = Path(args.add).read_bytes()
        assert other[:4] == b"BCLR", "not a .bclr file"
        _, other_length = struct.unpack("<II", other[4:12])
        other_header = json.loads(other[12:12 + other_length])
        assert other_header.get("dtype") == header.get("dtype"), "the two weights' tensors differ in type"
        size = 2 if header.get("dtype", "float16") == "float16" else 4
        blob = data[12 + length:]
        other_blob = other[12 + other_length:]
        start = len(blob) // size
        for name, network in other_header["networks"].items():
            if name in header["networks"]:
                continue
            first = min(layer["offset"] for layer in network["layers"])
            last = max(layer["offset"] + layer["inputs"] * layer["outputs"] + layer["outputs"]
                       for layer in network["layers"])
            moved = json.loads(json.dumps(network))
            for layer in moved["layers"]:
                layer["offset"] = layer["offset"] - first + start
            blob += other_blob[first * size:last * size]
            start += last - first
            header["networks"][name] = moved
            header.setdefault("added", []).append(f"{name} from {other_header.get('trainedOn', args.add)}")
        text = json.dumps(header).encode()
        data = b"BCLR" + struct.pack("<II", version, len(text)) + text + blob
        length = len(text)
    if args.broken_threshold is not None:
        header["brokenThreshold"] = args.broken_threshold
        text = json.dumps(header).encode()
        data = b"BCLR" + struct.pack("<II", version, len(text)) + text + data[12 + length:]
    if args.out:
        Path(args.out).write_bytes(data)
    digest = hashlib.sha256(data).hexdigest()
    text = base64.b64encode(data).decode()
    lines = [text[i:i + 100] for i in range(0, len(text), 100)]
    body = "\n".join(lines)
    if args.extra:
        name = args.extra[0].upper() + args.extra[1:]
        target = ROOT / "Sources" / "BlastModel" / f"LiveResponse+{name}.swift"
        target.write_text(
            f"// The live drag's learned response's {args.extra} network, built in beside the main weights\n"
            "// (`LiveResponse+Embedded.swift`; emmettl/bombcad-work#117): written by Scripts/ml/embed_response.py\n"
            f"// --extra {args.extra} from `train_response.py`'s live-response.bclr, base64.\n"
            f"// {header.get('trainedOn', '')}; {len(data):,} bytes, SHA-256 {digest}.\n"
            "// swift-format-ignore-file\n"
            "extension LiveResponse.Weights {\n"
            f"    static let embedded{name}SHA256 = \"{digest}\"\n"
            f"    static let embedded{name}Weights: String? = \"\"\"\n"
            f"{body}\n"
            "\"\"\"\n"
            "}\n")
        print(f"{target.relative_to(ROOT)}: {len(data):,} bytes, {digest}")
        return
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
