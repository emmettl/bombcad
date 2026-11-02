#!/usr/bin/env python3
"""Builds the charge-from-damage network into the code (emmettl/bombcad-work#116): writes
Sources/BlastModel/ChargeFromDamage+Embedded.swift from a `train_charge.py` charge-net.bccd, its
bytes as base64 lines in one string literal, with the file's SHA-256 beside them, as
embed_response.py builds the live drag's in.

    python3 -I Scripts/ml/embed_charge.py $BOMBCAD_DATA/ml/charge-net-2/out/charge-net.bccd
"""

import argparse
import base64
import hashlib
import json
import struct
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
TARGET = ROOT / "Sources" / "BlastModel" / "ChargeFromDamage+Embedded.swift"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("weights")
    args = parser.parse_args()
    data = Path(args.weights).read_bytes()
    assert data[:8] == b"BCCD0001", "not a .bccd file"
    length = struct.unpack("<I", data[8:12])[0]
    header = json.loads(data[12:12 + length])
    digest = hashlib.sha256(data).hexdigest()
    text = base64.b64encode(data).decode()
    body = "\n".join(text[i:i + 100] for i in range(0, len(text), 100))
    TARGET.write_text(
        "// The charge-from-damage network's weights, built in (emmettl/bombcad-work#116): written by\n"
        "// Scripts/ml/embed_charge.py from `train_charge.py`'s charge-net.bccd, base64.\n"
        f"// {header['name']}, trained on {', '.join(header['trainedOn'])}; {len(data):,} bytes,\n"
        f"// SHA-256 {digest}.\n"
        "// swift-format-ignore-file\n"
        "extension ChargeFromDamage.Network {\n"
        f"    static let embeddedSHA256 = \"{digest}\"\n"
        "    static let embeddedWeights: String? = \"\"\"\n"
        f"{body}\n"
        "\"\"\"\n"
        "}\n")
    print(f"{TARGET.relative_to(ROOT)}: {len(data):,} bytes, {digest}")


if __name__ == "__main__":
    main()
