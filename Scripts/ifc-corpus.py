#!/usr/bin/env python3
"""Run BombCAD's IFC importer over a corpus of IFC files, headless, and tabulate the results.

    swift build --build-tests
    python3 Scripts/ifc-corpus.py run CORPUS_DIR OUT_DIR [--jobs 4] [--timeout 900]
    python3 Scripts/ifc-corpus.py summary OUT_DIR [--markdown table.md]

`run` imports each *.ifc file under CORPUS_DIR (not *.ifc_, which are known to time out) in a
process of its own, through the IFCCorpusTests test, as an envelope and as a structure of shells
and beams; each file's row is OUT_DIR/rows/<hash>.json. A file that crashes the importer or runs
past the timeout gets a row saying so. Files with a row already are skipped, so a run resumes.
CPU only: the conversion, sampling and meshing use no GPU.
"""

import argparse
import collections
import concurrent.futures
import hashlib
import json
import os
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
HELPER = pathlib.Path(
    "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/libexec/swift/pm/"
    "swiftpm-testing-helper")


def bundle():
    for configuration in ["Debug", "Release"]:
        path = ROOT / f".build/out/Products/{configuration}/BombCADTests.xctest/Contents/MacOS/BombCADTests"
        if path.exists():
            return path
    sys.exit("Build the tests first: swift build --build-tests")


def row_path(out, file):
    return out / "rows" / (hashlib.sha1(str(file).encode()).hexdigest()[:16] + ".json")


def run_one(file, out, timeout):
    target = row_path(out, file)
    scratch = target.with_suffix(".jsonl")
    scratch.unlink(missing_ok=True)
    platform = pathlib.Path("/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer")
    env = dict(os.environ, BOMBCAD_IFC_CORPUS_FILE=str(file), BOMBCAD_IFC_CORPUS_OUT=str(scratch),
               DYLD_FRAMEWORK_PATH=str(platform / "Library/Frameworks"),
               DYLD_LIBRARY_PATH=str(platform / "usr/lib"))
    test = bundle()
    command = [str(HELPER), "--test-bundle-path", str(test), "--filter", "IFCCorpusTests", str(test),
               "--testing-library", "swift-testing"]
    try:
        result = subprocess.run(command, cwd=ROOT, env=env, capture_output=True, text=True, timeout=timeout)
        failure = None if result.returncode == 0 else f"exit {result.returncode}: " + result.stdout[-800:]
    except subprocess.TimeoutExpired:
        failure = f"timed out after {timeout} s"
    row = None
    if scratch.exists() and scratch.read_text().strip():
        row = json.loads(scratch.read_text().strip().splitlines()[-1])
        scratch.unlink()
    if row is None:
        row = {"file": str(file), "bytes": file.stat().st_size, "stage": "crashed", "error": failure}
    elif failure and row.get("stage") != "done":
        row["error"] = (row.get("error") or "") + f" ({failure.splitlines()[0]})"
    target.write_text(json.dumps(row))
    return row


def run(args):
    corpus = pathlib.Path(args.corpus)
    out = pathlib.Path(args.out)
    (out / "rows").mkdir(parents=True, exist_ok=True)
    files = sorted(p for p in corpus.rglob("*") if p.is_file() and p.suffix.lower() == ".ifc")
    todo = [f for f in files if not row_path(out, f).exists()]
    print(f"{len(files)} files, {len(todo)} to run", flush=True)
    with concurrent.futures.ThreadPoolExecutor(args.jobs) as pool:
        for n, row in enumerate(pool.map(lambda f: run_one(f, out, args.timeout), todo), 1):
            print(f"[{n}/{len(todo)}] {row.get('stage'):9} {pathlib.Path(row['file']).name}"
                  + (f": {row['error'][:120]}" if row.get("error") else ""), flush=True)


def summary(args):
    out = pathlib.Path(args.out)
    rows = [json.loads(p.read_text()) for p in sorted((out / "rows").glob("*.json"))]
    corpus = os.path.commonpath([r["file"] for r in rows]) if rows else ""
    stages = collections.Counter(r.get("stage") for r in rows)
    lines = [f"# IFC corpus: {len(rows)} files", "", "Stages reached: "
             + ", ".join(f"{k} {v}" for k, v in stages.most_common()), ""]
    errors = collections.Counter()
    for r in rows:
        if r.get("error"):
            errors[r["error"].split(":")[0].split(".")[0][:100]] += 1
    lines += ["## Why files stopped", ""] + [f"- {v} × {k}" for k, v in errors.most_common()] + [""]
    for title, key in [("Envelope errors", "envelopeError"), ("Structure errors", "structureError")]:
        counted = collections.Counter(r[key].split(".")[0][:100] for r in rows if r.get(key))
        lines += [f"## {title}", ""] + [f"- {v} × {k}" for k, v in counted.most_common()] + [""]
    reasons = collections.Counter()
    failures = collections.Counter()
    unsupported = collections.Counter()
    roles = collections.Counter()
    for r in rows:
        reasons.update(r.get("rigidReasons", {}))
        failures.update(f.split("]: ", 1)[-1][:100] for f in r.get("failures", []))
        unsupported.update(r.get("unsupportedClasses", {}))
        roles.update(r.get("roles", {}))
    stood = [r for r in rows if r.get("gravityReaction") is not None or r.get("gravityError")]
    if stood:
        lines += ["## Under gravity (0.3 s, damped)", "", "| file | shells/beams | peak displacement (mm) | reaction / weight | eroded |",
                  "|---|---|---|---|---|"]
        for r in sorted(stood, key=lambda r: r["file"]):
            name = os.path.relpath(r["file"], corpus) if corpus else r["file"]
            if r.get("gravityError"):
                lines.append(f"| {name} | {r.get('shells')}/{r.get('beams')} | error: {r['gravityError'][:80]} | | |")
            else:
                lines.append(f"| {name} | {r.get('shells')}/{r.get('beams')} | {r['gravityDisplacement'] * 1000:.2f} "
                             f"| {r['gravityReaction']:.3f} | {r['gravityEroded']} |")
        lines.append("")
    lines += ["## Roles over the corpus", ""] + [f"- {k}: {v}" for k, v in roles.most_common()] + [""]
    lines += ["## Kept rigid, why", ""] + [f"- {v} × {k}" for k, v in reasons.most_common(30)] + [""]
    lines += ["## Element meshes excluded as invalid, why", ""] + [
        f"- {v} × {k}" for k, v in failures.most_common(20)] + [""]
    lines += ["## Unsupported classes left out (leaf elements)", ""] + [
        f"- {k}: {v}" for k, v in unsupported.most_common(30)] + [""]
    lines += ["## Files", "",
              "| file | schema | MB | stage | supported | chosen | converted | excluded | envelope solids/openings | shells/beams/rigid | ties | supports | smallest element (m) |",
              "|---|---|---|---|---|---|---|---|---|---|---|---|---|"]
    for r in sorted(rows, key=lambda r: r["file"]):
        name = os.path.relpath(r["file"], corpus) if corpus else r["file"]
        ro = r.get("roles", {})
        env = r.get("envelopeError") and "error" or (f"{r.get('envelopeSolids', 0)}/{r.get('envelopeOpenings', 0)}" if r.get("stage") in ("structure", "done") else "")
        structure = "error" if r.get("structureError") else (f"{ro.get('shell', 0)}/{ro.get('beam', 0)}/{ro.get('rigid', 0)}" if ro else "")
        small = r.get("smallestElement")
        lines.append(
            f"| {name} | {r.get('schema') or ''} | {r['bytes'] / 1e6:.2f} | {r.get('stage')} | {r.get('supported', '')} | {r.get('chosen', '')} "
            f"| {r.get('converted', '')} | {len(r.get('failures', []))} | {env} | {structure} | {r.get('connections', '')} "
            f"| {len(r.get('supports', []))} | {'' if small is None else f'{small:.3f}'} |")
    text = "\n".join(lines) + "\n"
    if args.markdown:
        pathlib.Path(args.markdown).write_text(text)
    print(text)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    r = commands.add_parser("run")
    r.add_argument("corpus")
    r.add_argument("out")
    r.add_argument("--jobs", type=int, default=4)
    r.add_argument("--timeout", type=int, default=900)
    s = commands.add_parser("summary")
    s.add_argument("out")
    s.add_argument("--markdown")
    args = parser.parse_args()
    run(args) if args.command == "run" else summary(args)


if __name__ == "__main__":
    main()
