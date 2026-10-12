#!/usr/bin/env python3
"""How often IFC files carry reinforcement that BombCAD can read.

Walks a folder of IFC files (by default the study volume's corpus) and, for each, counts from
the STEP text alone:
- reinforcing bars, meshes and tendons, and their types (the types hold diameters and areas);
- property sets about reinforcement (Pset_ReinforcementBarPitchOf*, Pset_ConcreteElementGeneral
  and the like), and which of their properties have a numeric value BombCAD could use (cover,
  area or mass ratio, bar pitch, bar diameter), as opposed to only a name or reference;
- whether the file has concrete at all (a material named concrete, beton, C25/30 and so on),
  so that the share is of files that could have reinforcement.

Writes a JSON report and prints a summary. Usage:

    python3 Scripts/ifc-reinforcement-survey.py [folder] [--out report.json]
"""

import json
import os
import re
import sys

DEFAULT = "/Volumes/StudioData/bombcad/data/ifc-corpus"

ENTITIES = {
    "bars": r"IFCREINFORCINGBAR\(",
    "barTypes": r"IFCREINFORCINGBARTYPE\(",
    "meshes": r"IFCREINFORCINGMESH\(",
    "meshTypes": r"IFCREINFORCINGMESHTYPE\(",
    "tendons": r"IFCTENDON\(",
    "tendonTypes": r"IFCTENDONTYPE\(",
}
# Properties whose numeric value maps onto reinforcement.
USEFUL = re.compile(
    r"ConcreteCover|ReinforcementAreaRatio|ReinforcementVolumeRatio|BarPitch|NominalDiameter|"
    r"CrossSectionArea|BarSpacing|BarDiameter",
    re.I,
)
PSET = re.compile(r"IFCPROPERTYSET\('[^']*',[^,]*,'([^']*)'", re.I)
SINGLE = re.compile(r"IFCPROPERTYSINGLEVALUE\('([^']*)',[^,]*,([A-Z0-9_]*\([^)]*\)|[^,)]*)", re.I)
NUMERIC = re.compile(r"IFC[A-Z]*MEASURE\(\s*-?[0-9.]+(?:E-?[0-9]+)?\s*\)|IFCREAL\(", re.I)
# Material names that say the concrete is reinforced, whatever the file gives of its steel.
REINFORCED_NAME = re.compile(r"IFCMATERIAL\('[^']*(reinforced|gewapend|armiert|stahlbeton|\bRC\b|b[eé]ton arm[eé])", re.I)
CONCRETE = re.compile(r"IFCMATERIAL\('[^']*(concrete|beton|b[eé]ton|\bC\d\d/\d\d|reinforced)", re.I)
SCHEMA = re.compile(r"FILE_SCHEMA\s*\(\s*\(\s*'([^']*)'", re.I)


def survey(path):
    with open(path, "rb") as f:
        text = f.read().decode("latin-1")
    entry = {"file": path, "schema": (SCHEMA.search(text).group(1) if SCHEMA.search(text) else None)}
    for key, pattern in ENTITIES.items():
        entry[key] = len(re.findall(pattern, text, re.I))
    psets = [m.group(1) for m in PSET.finditer(text)]
    entry["reinforcementPsets"] = sorted(
        {p for p in psets if re.search(r"reinforc|ConcreteElement|Rebar", p, re.I)})
    useful = {}
    named = set()
    for m in SINGLE.finditer(text):
        name, value = m.group(1), m.group(2)
        if USEFUL.search(name):
            named.add(name)
            if NUMERIC.search(value):
                useful[name] = useful.get(name, 0) + 1
    entry["usefulProperties"] = useful
    entry["reinforcementPropertyNames"] = sorted(named)
    entry["concrete"] = bool(CONCRETE.search(text))
    entry["reinforcedByName"] = bool(REINFORCED_NAME.search(text))
    return entry


def main():
    argv = sys.argv[1:]
    out = None
    if "--out" in argv:
        out = argv[argv.index("--out") + 1]
        del argv[argv.index("--out"):argv.index("--out") + 2]
    args = [a for a in argv if not a.startswith("--")]
    folder = args[0] if args else DEFAULT
    files = []
    for root, _, names in os.walk(folder):
        for name in names:
            if name.lower().endswith(".ifc"):
                files.append(os.path.join(root, name))
    entries = []
    for path in sorted(files):
        try:
            entries.append(survey(path))
        except OSError as error:
            entries.append({"file": path, "error": str(error)})
    ok = [e for e in entries if "error" not in e]

    def count(predicate):
        return sum(1 for e in ok if predicate(e))

    geometry = count(lambda e: e["bars"] + e["meshes"] + e["tendons"] > 0)
    types = count(lambda e: e["barTypes"] + e["meshTypes"] + e["tendonTypes"] > 0)
    psets = count(lambda e: e["reinforcementPsets"])
    useful = count(lambda e: e["usefulProperties"])
    concrete = count(lambda e: e["concrete"])
    anything = count(lambda e: e["bars"] + e["meshes"] + e["tendons"] > 0 or e["usefulProperties"])
    summary = {
        "folder": folder,
        "files": len(ok),
        "unreadable": len(entries) - len(ok),
        "withConcrete": concrete,
        "withBarsMeshesOrTendons": geometry,
        "withTheirTypes": types,
        "withReinforcementPsets": psets,
        "withUsefulNumericProperties": useful,
        "withAnythingReadable": anything,
        "namedReinforcedConcrete": count(lambda e: e["reinforcedByName"]),
        "namedReinforcedWithNothingReadable": count(
            lambda e: e["reinforcedByName"] and not (e["bars"] + e["meshes"] + e["tendons"] > 0 or e["usefulProperties"])),
        "concreteWithAnythingReadable": count(
            lambda e: e["concrete"] and (e["bars"] + e["meshes"] + e["tendons"] > 0 or e["usefulProperties"])),
    }
    print(json.dumps(summary, indent=2))
    for e in ok:
        if e["bars"] + e["meshes"] + e["tendons"] > 0 or e["usefulProperties"]:
            print(
                f"  {os.path.relpath(e['file'], folder)}: {e['bars']} bars, {e['meshes']} meshes, "
                f"{e['tendons']} tendons; types {e['barTypes'] + e['meshTypes'] + e['tendonTypes']}; "
                f"properties {e['usefulProperties'] or '-'}"
            )
    if out:
        with open(out, "w") as f:
            json.dump({"summary": summary, "files": entries}, f, indent=1)


if __name__ == "__main__":
    main()
