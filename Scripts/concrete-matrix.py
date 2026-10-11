#!/usr/bin/env python3
"""Run every concrete validation case and write one table against the measurements.

The case matrix of docs/concrete-strategy.md (stage 0): each case's blastbench command is run,
its rows are read, and the results are set against what the tests measured, with the regime each
case lies in. Every change to the concrete model should be judged on the whole table; compare two
tables (`--compare old.json`) to see what a change moved.

    Scripts/concrete-matrix.py [--quick] [--cases slab,oa1] [--extra "--bond splitting"]
                               [--label slip] [--out DIR] [--blastbench PATH] [--compare OLD.json]

Writes DIR/matrix.md, DIR/matrix.json and each command's raw output. DIR defaults to
/Volumes/StudioData/bombcad/concrete-matrix/LABEL when that volume is mounted. The full matrix
takes some hours on one Mac; `--quick` runs the coarser mesh of each case only.
"""
import argparse
import json
import re
import statistics
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def number(text):
    return float(text) if text not in (None, "-", "") else None


# Each case: its regime, the command (full and quick), and a parser returning rows of
# (label, measured, model, unit, note).


def slab(out):
    rows = []
    for layers, peak in re.findall(r"^\s+(\d+)\s+\d+\s+rate laws\s+(\d+) mm", out, re.M):
        rows.append((f"peak, {layers} through", 108.0, float(peak), "mm", ""))
    return rows


def janney(out):
    rows = []
    for layers, moment, fails in re.findall(r"^\s+(\d+)\s+\d+\s+([\d.]+) kN m\s+\d+%\s+(\d+ mm|holds)", out, re.M):
        rows.append((f"moment, {layers} through", 41.5, float(moment), "kN m",
                     "holds" if fails == "holds" else f"fails at {fails} (test 42 mm)"))
    return rows


def oa1(out):
    return [
        (f"peak, {layers} through", 332.0, float(load), "kN", f"at {at} mm")
        for layers, load, at in re.findall(r"^\s+(\d+)\s+\d+\s+(\d+) kN\s+\d+%\s+([\d.]+) mm", out, re.M)
    ]


def pushoff(out):
    rows = []
    for block in re.split(r"\n(?=\S+: cube strength)", out):
        name = re.match(r"(\S+): cube strength", block)
        if not name:
            continue
        measured = [
            (float(slip), float(shear), float(model))
            for slip, shear, model in re.findall(
                r"^\s+([\d.]+)\s+[\d.]+\s+([\d.]+)\s+([\d.]+)\s", block, re.M)
        ]
        if measured:
            slip, shear, model = measured[-1]
            rows.append((f"{name.group(1)} shear at {slip} mm slip", shear, model, "MPa", ""))
    return rows


def saatci(out):
    rows = []
    pattern = r"^\s+(SS\w+-1)\s+\d+ kg\s+(failed|[\d.]+ / [\d.]+ mm)\s+([\d.]+) / ([-\d.]+) mm.*?\s(\d+)\s+[\d.]+ s$"
    for name, measured, peak, residual, failed in re.findall(pattern, out, re.M):
        value = None if measured == "failed" else float(measured.split(" / ")[0])
        note = f"left {residual} mm, {failed} removed" + (" (test failed)" if value is None else "")
        rows.append((f"{name} peak", value, float(peak), "mm", note))
    return rows


def ando(out):
    rows = []
    pattern = r"^\s+([AB]\d+-\d)\s+(\d) m/s\s+([-\d.]+) / ([\d.]+)(, broken)?\s+([\d.]+) / ([-\d.]+) mm\s+(\d+)"
    for name, speed, peak, _, broken, model, _, failed in re.findall(pattern, out, re.M):
        rows.append((f"{name} at {speed} m/s", number(peak), float(model), "mm",
                     f"{failed} removed" + (", broken in the test" if broken else "")))
    errors = [abs(r[2] - r[1]) / r[1] for r in rows if r[1]]
    if errors:
        rows.append(("mean error, all beams", None, 100 * statistics.mean(errors), "%", ""))
    return rows


def peterson(out):
    rows = []
    for name, damage, failed, under in re.findall(
            r"^\s+(D-[\d.]+d-\w+-1)\s+(\w+)\s+.*?\s(\d+)\s+([\d.]+) mm$", out, re.M):
        rows.append((f"{name} ({damage} in the test)", None, float(under), "mm under the load",
                     f"{failed} elements lost"))
    return rows


def chiquito(out):
    rows = []
    for name, measured, model, peak in re.findall(
            r"^(P\d|S\d):.*?\n.*?\n\s+permanent \(mm\)\s+(\S+)\s+(\d+) \(peak (\d+)\)", out, re.M):
        rows.append((f"{name} left down", number(measured), float(model), "mm", f"peak {peak}"))
    for name, measured, model in re.findall(r"^(P\d|S\d):[^\n]*\n(?:.*\n){0,8}?\s+perforated\s+(\w+)\s+(\w+)", out, re.M):
        rows.append((f"{name} holed", None, None, "", f"test {measured}, model {model}"))
    return rows


def hupfauf(out):
    rows = []
    for block in re.split(r"\n(?=SN\d+:)", out):
        name = re.match(r"(SN\d+):", block)
        if not name:
            continue
        # The bench prints the fit and the model's speed run together: "71.0145.4".
        tip = re.search(r"tip velocity \(m/s\)\s+([\d.]+), ([\d.]+)\s+(\d+\.\d)(\d+\.\d) \(largest", block)
        breach = re.search(r"breach\s+(\w+)\s+(\w+)", block)
        if tip:
            rows.append((f"{name.group(1)} far face's speed", float(tip.group(3)), float(tip.group(4)), "m/s", "against the fit"))
        if breach:
            rows.append((f"{name.group(1)} holed", None, None, "", f"test {breach.group(1)}, model {breach.group(2)}"))
    return rows


def wu(out):
    rows = []
    for name, peak, model, hole, model_hole in re.findall(
            r"^\s+([SD]\d)\s+.*?\s([\d.]+|-)/([\d.]+)\s+\S+\s+\S+\s+\S+\s+\S+\s+\S+\s+(\S+)/([\d.]+)", out, re.M):
        rows.append((f"{name} peak", number(peak), float(model), "mm", f"hole {hole} / {model_hole} cm"))
    return rows


def wang(out):
    rows = []
    for block in re.split(r"\n(?=Slab )", out):
        name = re.match(r"Slab (\w+)", block)
        centre = re.search(r"^\s+D3\s+([\d.]+)/([\d.]+)", block, re.M)
        if name and centre:
            rows.append((f"{name.group(1)} centre peak", float(centre.group(1)), float(centre.group(2)), "mm",
                         "dominated by the supports"))
    return rows


def chamber(out):
    match = re.search(r"peak (\d+) mm, (-?\d+) mm at the end", out)
    if not match:
        return []
    return [("roof edge left up", 95.0, float(match.group(2)), "mm", f"peak {match.group(1)} (paper's model 87)")]


def tie(out):
    rows = []
    expected = re.search(r"pull ([\d.]+) kN \(beta 0.4\)", out)
    for size, cracks, load in re.findall(r"([\d.]+) mm elements: (\d+) cracks.*?pull ([\d.]+) kN", out):
        rows.append((f"pull, {size} mm elements", float(expected.group(1)) if expected else None, float(load),
                     "kN", f"{cracks} cracks; Model Code, beta 0.4"))
    return rows


CASES = [
    ("slab", "Contest slab", "far field, bending", ["slab", "--layers", "4,8,16"], ["slab", "--layers", "8"], slab),
    ("janney", "Janney's beam", "quasi-static, bending", ["beam", "--layers", "12,24"], ["beam", "--layers", "12"], janney),
    ("oa1", "OA1", "quasi-static, shear", ["shear", "--layers", "12,24"], ["shear", "--layers", "12"], oa1),
    ("pushoff", "Push-off tests", "quasi-static, restrained crack", ["pushoff"], ["pushoff"], pushoff),
    ("tie", "Tie (Model Code)", "quasi-static, tension", ["tie"], ["tie", "--h", "0.02"], tie),
    ("saatci", "Saatci's beams", "impulsive, flexure and shear", ["impact", "--layers", "16"],
     ["impact", "--layers", "16", "--tests", "SS0a-1,SS1b-1"], saatci),
    ("ando", "Ando's beams", "impulsive, shear", ["impact", "--ando", "--layers", "16"],
     ["impact", "--ando", "--layers", "16", "--tests", "A24-3,A36-5,B48-5"], ando),
    ("peterson", "Peterson's beams", "impulsive, shear", ["impact", "--peterson"], ["impact", "--peterson"], peterson),
    ("chiquito", "Chiquito's slabs", "close in", ["closein", "--tests", "P1,P7,S5,P2"], ["closein", "--tests", "P7"], chiquito),
    ("hupfauf", "Hupfauf's slabs", "in contact", ["contact"], ["contact", "--tests", "SN142,SN131"], hupfauf),
    ("wu", "Wu's slabs", "close in", ["twoface", "--wu", "S8,D8,S6,D6"], ["twoface", "--wu", "S8,D8"], wu),
    ("wang", "Wang's slabs", "far field", ["twoface", "--wang", "A,B"], ["twoface", "--wang", "A"], wang),
    ("chamber", "Chamber", "confined", ["chamber"], ["chamber"], chamber),
]


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--quick", action="store_true")
    parser.add_argument("--cases", help="comma-separated keys: " + ",".join(c[0] for c in CASES))
    parser.add_argument("--extra", default="", help="flags added to every command")
    parser.add_argument("--label", default="defaults")
    parser.add_argument("--out")
    parser.add_argument("--blastbench", default=str(ROOT / ".build/release/blastbench"))
    parser.add_argument("--compare", help="an earlier matrix.json to set beside this one")
    args = parser.parse_args()

    studio = Path("/Volumes/StudioData")
    out = Path(args.out) if args.out else (
        studio / "bombcad/concrete-matrix" / args.label if studio.is_dir() else ROOT / ".build/concrete-matrix" / args.label)
    out.mkdir(parents=True, exist_ok=True)
    wanted = set(args.cases.split(",")) if args.cases else None
    old = {}
    if args.compare:
        for case in json.loads(Path(args.compare).read_text())["cases"]:
            for row in case["rows"]:
                old[(case["key"], row["label"])] = row["model"]

    report = {"label": args.label, "extra": args.extra, "quick": args.quick, "cases": []}
    for key, title, regime, full, quick, parse in CASES:
        if wanted and key not in wanted:
            continue
        command = [args.blastbench] + (quick if args.quick else full) + args.extra.split()
        start = time.time()
        result = subprocess.run(command, capture_output=True, text=True)
        text = result.stdout + result.stderr
        (out / f"{key}.txt").write_text(" ".join(command) + "\n\n" + text)
        rows = parse(text)
        if result.returncode != 0 or not rows:
            print(f"{title}: exit {result.returncode}, {len(rows)} rows read; see {out / (key + '.txt')}", file=sys.stderr)
        report["cases"].append({
            "key": key, "title": title, "regime": regime, "command": " ".join(command[1:]),
            "seconds": round(time.time() - start), "exit": result.returncode,
            "rows": [{"label": l, "measured": m, "model": v, "unit": u, "note": n} for l, m, v, u, n in rows],
        })
        print(f"{title}: {len(rows)} rows in {round(time.time() - start)} s", flush=True)

    lines = [f"# Concrete case matrix: {args.label}", "",
             f"Flags: `{args.extra or '(defaults)'}`" + (", quick" if args.quick else ""), "",
             "| Case | Regime | Quantity | Measured | Model | Model / measured |" + (" Before |" if old else "") + " Note |",
             "|---|---|---|---|---|---|" + ("---|" if old else "") + "---|"]
    for case in report["cases"]:
        for row in case["rows"]:
            m, v = row["measured"], row["model"]
            ratio = f"{100 * v / m:.0f}%" if m and v is not None else ""
            before = old.get((case["key"], row["label"]))
            cells = [case["title"], case["regime"], row["label"],
                     f"{m:g} {row['unit']}" if m is not None else "-",
                     f"{v:g} {row['unit']}" if v is not None else "-", ratio]
            if old:
                cells.append(f"{before:g}" if before is not None else "-")
            cells.append(row["note"])
            lines.append("| " + " | ".join(cells) + " |")
    (out / "matrix.md").write_text("\n".join(lines) + "\n")
    (out / "matrix.json").write_text(json.dumps(report, indent=1))
    print(f"Wrote {out / 'matrix.md'}")


if __name__ == "__main__":
    main()
