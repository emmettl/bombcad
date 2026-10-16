#!/usr/bin/env python3
"""Summarises the envelope damage references (stage 3a) into a small fixture.

Reads the records `scenebench envelope-damage` writes (<layout>-<wall>-<kg>.json, detailed, and
<layout>-<wall>-<kg>-envelope.json, the envelope twin) and writes, per run and component, the
detailed building's response (peak and residual deflection, rotation, the panel's failed share,
when a pane broke) beside the loads each representation put on it (peak net pressure and outer
positive impulse), and each building's inside peak. The full histories stay in the records.

    python3 Scripts/summarize-envelope-damage.py /Volumes/StudioData/bombcad/envelope-damage/reference \
        --out Benchmarks/EnvelopeDamage/summary.json

See docs/building-envelopes.md#damage-references.
"""

import argparse
import glob
import json
import os


def positive(bins):
    return sum(b for b in bins if b > 0)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("directory")
    parser.add_argument("--out", required=True)
    arguments = parser.parse_args()
    runs = []
    for path in sorted(glob.glob(os.path.join(arguments.directory, "*.json"))):
        if path.endswith("-envelope.json"):
            continue
        detailed = json.load(open(path))
        twin_path = path[: -len(".json")] + "-envelope.json"
        twin = json.load(open(twin_path)) if os.path.exists(twin_path) else None
        twin_components = {c["id"]: c for c in twin["components"]} if twin else {}
        components = []
        for c in detailed["components"]:
            e = twin_components.get(c["id"])
            row = {
                "id": c["id"],
                "building": c["building"],
                "kind": c["kind"],
                "material": c["material"],
                "shortSpanM": c["shortSpanM"],
                "peakMm": round(c["peakM"] * 1000, 2),
                "residualMm": round(c["residualM"] * 1000, 2),
                "rotationDeg": round(c["rotationDeg"], 3),
                "interiorFailedShare": round(c.get("interiorFailedShare", 0), 3),
                "failedShare": round(c["failedShare"], 3),
                "detailedPeakNetKPa": round(c["peakNetPa"] / 1000, 2),
                "detailedOuterImpulsePaS": round(positive(c["outerImpulsePaS"]), 1),
            }
            if c["kind"] == "pane":
                row["broken"] = c["broken"]
                row["brokenAtMs"] = round(c["brokenAtS"] * 1000, 1) if c.get("brokenAtS") is not None else None
            if e:
                row["envelopePeakNetKPa"] = round(e["peakNetPa"] / 1000, 2)
                row["envelopeOuterImpulsePaS"] = round(positive(e["outerImpulsePaS"]), 1)
            components.append(row)
        inside = {
            g["name"]: round(g["peakOverpressurePa"] / 1000, 2) for g in detailed["gauges"] if "inside" in g["name"]
        }
        inside_twin = (
            {g["name"]: round(g["peakOverpressurePa"] / 1000, 2) for g in twin["gauges"] if "inside" in g["name"]}
            if twin
            else {}
        )
        runs.append(
            {
                "run": os.path.basename(path)[: -len(".json")],
                "layout": detailed["layout"],
                "wall": detailed["wall"],
                "chargeKg": detailed["chargeKg"],
                "sourceRevision": detailed["sourceRevision"],
                "stable": detailed["stable"] and (twin["stable"] if twin else True),
                "insidePeakKPa": inside,
                "envelopeInsidePeakKPa": inside_twin,
                "components": components,
            }
        )
    summary = {
        "schemaVersion": 1,
        "notes": [
            "Invented buildings under invented charges: numerical references for the one-way model, not measured damage.",
            "Deflections from the settled state, positive inward; rotation atan(peak / (short span / 2)).",
            "Loads by spec §2-§3 on each representation: peak of the area-mean net pressure, and the outer face's positive impulse.",
            "Full histories, geometry and materials are in the records and their README on StudioData.",
        ],
        "runs": runs,
    }
    os.makedirs(os.path.dirname(os.path.abspath(arguments.out)), exist_ok=True)
    with open(arguments.out, "w") as handle:
        json.dump(summary, handle, indent=1, sort_keys=True)
        handle.write("\n")
    print(f"{len(runs)} runs, {sum(len(r['components']) for r in runs)} components -> {arguments.out}")


if __name__ == "__main__":
    main()
