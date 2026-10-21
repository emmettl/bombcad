#!/usr/bin/env python3
"""A mutation fuzzer for the importers that read a user's files: the DXF and SVG floor-plan
readers, the OBJ and STL mesh reader, the ESRI ASCII elevation grid, the TIFF directory and LZW
decoder of the GeoTIFF reader, and the OpenStreetMap and GeoJSON readers.

It writes mutated copies of seed files (Fixtures/ and Samples/ by default) into a folder, then
runs the test ImporterFuzzReplayTests (Tests/BlastModelTests/ImporterFuzzTests.swift) over the
folder, from a build made beforehand. The test names each input before reading it, so a crash or
a hang is put down to its input; the driver then starts the test again after it. An input that
takes longer than --timeout seconds is a hang; a run whose processes grow past --memory-mb of
resident memory is stopped and counted as running out of memory (Linux: it reads /proc).

    Scripts/fuzz/fuzz-importers.py --work DIR [--scratch-path .build] [--sanitize address]
        [--count 2000] [--seed 1] [--timeout 20] [--memory-mb 3000] [--only dxf,svg]
        [--package DIR] [--corpus DIR]

The build must already have the tests in it: `swift build --build-tests` with the same
--scratch-path and --sanitize. The inputs, each outcome (DIR/outcomes.tsv) and the findings
(DIR/findings.json, crashes, hangs and runs out of memory, with the log's last lines) stay in
DIR; nothing is written into the repository. Mutations are deterministic for a given --seed.
"""
import argparse
import json
import os
import random
import re
import shutil
import signal
import struct
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent.parent
SEED_GLOBS = {
    "dxf": ["Fixtures/FloorPlans/*.dxf", "Samples/Plans/*.dxf"],
    "svg": ["Fixtures/FloorPlans/*.svg", "Samples/Plans/*.svg"],
    "obj": ["Samples/Importer/**/*.obj"],
    "stl": ["Samples/Importer/**/*.stl"],
    "asc": ["Samples/Terrain/*.asc", "Fixtures/SyntheticDistrict/*.asc"],
    "tif": ["Samples/Terrain/*.tif"],
    "osm": ["Fixtures/SyntheticDistrict/*.osm"],
    "geojson": ["Samples/MapBuildings/*.geojson"],
}
# Numbers that break arithmetic: extremes, non-finite spellings, integers past Int and Int32.
EXTREMES = [
    "0", "-0", "1", "-1", "1e308", "-1e308", "1e309", "-1e309", "1e-320", "nan", "NaN", "inf",
    "-inf", "infinity", "9223372036854775807", "9223372036854775808", "-9223372036854775809",
    "2147483648", "4294967296", "1e18", "1e10", "123456789", "0.1e1", "1.5", "99999999999",
    "", " ", "1e", "--1", "0x10",
]
NUMBER = re.compile(rb"-?\d+(?:\.\d+)?(?:[eE][-+]?\d+)?")


def seeds(kinds):
    found = []
    for kind in kinds:
        for pattern in SEED_GLOBS[kind]:
            for path in sorted(ROOT.glob(pattern)):
                if "blind" in path.parts:
                    continue
                found.append((kind, path.stem, path.read_bytes()))
    return found


# --- Mutators: each takes (data, rng) and returns new bytes. ---


def flip_bits(data, rng):
    b = bytearray(data)
    for _ in range(rng.randint(1, 8)):
        if b:
            b[rng.randrange(len(b))] ^= 1 << rng.randrange(8)
    return bytes(b)


def truncate(data, rng):
    return data[: rng.randrange(max(1, len(data)))]


def random_bytes(data, rng):
    b = bytearray(data)
    at = rng.randrange(len(b) + 1)
    b[at:at] = bytes(rng.randrange(256) for _ in range(rng.randint(1, 32)))
    return bytes(b)


def numeric_extreme(data, rng):
    matches = list(NUMBER.finditer(data))
    if not matches:
        return flip_bits(data, rng)
    out = data
    for m in sorted(rng.sample(matches, min(len(matches), rng.randint(1, 4))), key=lambda m: -m.start()):
        out = out[: m.start()] + rng.choice(EXTREMES).encode() + out[m.end() :]
    return out


def lines_of(data):
    return data.split(b"\n")


def delete_lines(data, rng):
    lines = lines_of(data)
    if len(lines) < 2:
        return truncate(data, rng)
    at = rng.randrange(len(lines))
    del lines[at : at + rng.randint(1, 4)]
    return b"\n".join(lines)


def duplicate_lines(data, rng):
    lines = lines_of(data)
    at = rng.randrange(len(lines))
    span = lines[at : at + rng.randint(1, 30)]
    times = rng.choice([2, 10, 100, 1000])
    lines[at:at] = span * times
    return b"\n".join(lines)[:30_000_000]


def swap_lines(data, rng):
    lines = lines_of(data)
    if len(lines) < 2:
        return data
    i, j = rng.randrange(len(lines)), rng.randrange(len(lines))
    lines[i], lines[j] = lines[j], lines[i]
    return b"\n".join(lines)


def splice_self(data, rng):
    # A slice of the file inserted elsewhere in it: sections, blocks or elements repeated.
    if len(data) < 4:
        return data
    a = rng.randrange(len(data))
    b = min(len(data), a + rng.randint(1, 2000))
    at = rng.randrange(len(data))
    return data[:at] + data[a:b] + data[at:]


def nest_xml(data, rng):
    depth = rng.choice([50, 300, 3000, 100_000])
    tag = rng.choice([b"g", b"svg", b"a", b"switch"])
    inner = b"<line x1='0' y1='0' x2='1000' y2='0'/>"
    nested = (b"<" + tag + b">") * depth + inner + (b"</" + tag + b">") * depth
    at = data.rfind(b"</svg>")
    if at < 0:
        return data + nested
    return data[:at] + nested + data[at:]


def mutate_dxf_value(data, rng):
    # A group's value replaced, keeping the group codes on their lines.
    lines = lines_of(data)
    if len(lines) < 4:
        return data
    k = rng.randrange(1, len(lines), 2) if len(lines) > 2 else 1
    lines[k] = rng.choice(EXTREMES + ["SECTION", "ENDSEC", "BLOCK", "ENDBLK", "INSERT", "EOF", "SEQEND"]).encode()
    return b"\n".join(lines)


def mutate_dxf_code(data, rng):
    lines = lines_of(data)
    if len(lines) < 4:
        return data
    k = rng.randrange(0, len(lines) - 1, 2)
    lines[k] = rng.choice(["0", "2", "8", "10", "20", "40", "42", "50", "51", "70", "230", "-1", "999999999999999999999", "x"]).encode()
    return b"\n".join(lines)


TEXT_MUTATORS = [
    flip_bits, truncate, random_bytes, numeric_extreme, numeric_extreme, numeric_extreme, delete_lines,
    duplicate_lines, swap_lines, splice_self,
]
MUTATORS = {
    "dxf": TEXT_MUTATORS + [mutate_dxf_value, mutate_dxf_value, mutate_dxf_code],
    "svg": TEXT_MUTATORS + [nest_xml],
    "obj": TEXT_MUTATORS,
    "stl": TEXT_MUTATORS,
    "asc": TEXT_MUTATORS,
    "tif": [flip_bits, flip_bits, truncate, random_bytes, splice_self],
    "osm": TEXT_MUTATORS + [nest_xml],
    "geojson": TEXT_MUTATORS,
}


def lzw_inputs(rng, count):
    """Random code streams for TIFF's LZW decoder: noise, and runs that grow the table."""
    out = []
    for n in range(count):
        size = rng.choice([1, 2, 16, 1000, 20000])
        if n % 3 == 0:
            out.append(("lzw", "noise", bytes(rng.randrange(256) for _ in range(size))))
        else:
            # Clear code (256) then codes that are always just defined: 9-bit codes, MSB first.
            bits = "100000000"
            table = 258
            for _ in range(size):
                code = rng.choice([rng.randrange(256), table - 1 if table > 258 else 65, table])
                width = 9 if table < 511 else 10 if table < 1023 else 11 if table < 2047 else 12
                bits += format(min(code, (1 << width) - 1), f"0{width}b")
                table += 1
            bits += "0" * (-len(bits) % 8)
            out.append(("lzw", "grow", int(bits, 2).to_bytes(len(bits) // 8, "big")))
    return out


def generate(args, rng, work):
    corpus = work / "corpus"
    if corpus.exists():
        shutil.rmtree(corpus)
    corpus.mkdir(parents=True)
    kinds = args.only.split(",") if args.only else list(SEED_GLOBS) + ["lzw"]
    pool = seeds([k for k in kinds if k in SEED_GLOBS])
    items = []
    # The seeds themselves first: they must all read as before.
    for kind, stem, data in pool:
        items.append((kind, f"{stem}-seed", data))
    for n in range(args.count):
        kind, stem, data = rng.choice(pool)
        mutator = rng.choice(MUTATORS[kind])
        out = data
        names = []
        for _ in range(rng.choice([1, 1, 1, 2, 3])):
            out = mutator(out, rng)
            names.append(mutator.__name__)
            mutator = rng.choice(MUTATORS[kind])
        items.append((kind, f"{stem}-{'+'.join(names)}", out))
    if "lzw" in kinds:
        items += lzw_inputs(rng, max(10, args.count // 20))
    for n, (kind, name, data) in enumerate(items):
        (corpus / f"{n:06d}-{name[:60]}.{kind}").write_bytes(data)
    return corpus, len(items)


def run(args, work, corpus, total):
    outcomes = work / "outcomes.tsv"
    progress = work / "progress.txt"
    for f in (outcomes, progress):
        if f.exists():
            f.unlink()
    findings = []
    skip = 0
    env = dict(os.environ)
    env.update(
        BLASTMODEL_FUZZ_DIR=str(corpus), BLASTMODEL_FUZZ_OUT=str(outcomes), BLASTMODEL_FUZZ_PROGRESS=str(progress)
    )
    if args.sanitize == "address":
        env["ASAN_OPTIONS"] = f"hard_rss_limit_mb={args.memory_mb}:detect_leaks=0:allocator_may_return_null=0"
    command = ["swift", "test", "--skip-build", "--scratch-path", args.scratch_path, "--filter", "ImporterFuzzReplayTests"]
    if args.sanitize:
        command += ["--sanitize", args.sanitize]

    # The swift driver starts the test runner in a process group of its own, but in the session
    # the driver was started in: the session is what is measured and stopped.
    def session(sid):
        pids = []
        for entry in os.listdir("/proc"):
            if entry.isdigit():
                try:
                    if os.getsid(int(entry)) == sid:
                        pids.append(int(entry))
                except OSError:
                    continue
        return pids

    def stop(sid):
        for pid in session(sid):
            try:
                os.kill(pid, signal.SIGKILL)
            except OSError:
                pass

    def resident_mb(sid):
        total = 0
        for entry in map(str, session(sid)):
            try:
                with open(f"/proc/{entry}/status") as status:
                    for line in status:
                        if line.startswith("VmRSS:"):
                            total += int(line.split()[1]) // 1024
            except (OSError, ValueError):
                continue
        return total

    started = time.time()
    while skip < total:
        env["BLASTMODEL_FUZZ_SKIP"] = str(skip)
        log_path = work / f"run-{skip:06d}.log"
        with open(log_path, "wb") as log:
            proc = subprocess.Popen(
                command, cwd=args.package, env=env, stdout=log, stderr=subprocess.STDOUT, start_new_session=True
            )
            current, since, hung, oom = None, time.time(), False, False
            while proc.poll() is None:
                time.sleep(0.5)
                text = progress.read_text() if progress.exists() else ""
                if text != current:
                    current, since = text, time.time()
                elif current and time.time() - since > args.timeout:
                    hung = True
                if current and resident_mb(proc.pid) > args.memory_mb:
                    oom = True
                if hung or oom:
                    stop(proc.pid)
                    proc.wait()
                    break
            # Nothing of the run outlives it.
            stop(proc.pid)
        text = progress.read_text().split() if progress.exists() else []
        index = int(text[0]) if text and int(text[0]) >= skip else None
        done = outcomes.read_text().count("\n") if outcomes.exists() else 0
        tail = log_path.read_text(errors="replace").splitlines()[-40:]
        failed = hung or oom or proc.returncode != 0
        if not failed or index is None:
            if failed:
                findings.append({"kind": "harness", "returncode": proc.returncode, "log": tail})
            break
        recorded = {line.split("\t")[0] for line in outcomes.read_text().splitlines()} if outcomes.exists() else set()
        if str(index) in recorded and not hung:
            # The crash came after the input's outcome was written: in the runner, not a reader.
            findings.append({"kind": "after-input", "index": index, "returncode": proc.returncode, "log": tail})
            skip = index + 1
            continue
        name = text[1]
        joined = "\n".join(tail)
        kind = (
            "oom" if oom or "rss limit" in joined or "out of memory" in joined.lower() else "hang" if hung else "crash"
        )
        findings.append({"kind": kind, "index": index, "input": name, "returncode": proc.returncode, "log": tail})
        print(f"{kind}: {name}", flush=True)
        skip = index + 1
    elapsed = time.time() - started
    (work / "findings.json").write_text(json.dumps(findings, indent=1))
    return findings, elapsed


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--work", required=True, type=Path)
    parser.add_argument("--scratch-path", default=".build")
    parser.add_argument("--sanitize", default=None, choices=[None, "address"])
    parser.add_argument("--count", type=int, default=2000)
    parser.add_argument("--seed", type=int, default=1)
    parser.add_argument("--timeout", type=float, default=20)
    parser.add_argument("--memory-mb", type=int, default=3000)
    parser.add_argument("--only", default="")
    parser.add_argument("--corpus", type=Path, help="replay this folder instead of generating one")
    parser.add_argument("--package", type=Path, default=ROOT, help="the package to test (the repository)")
    args = parser.parse_args()
    args.work.mkdir(parents=True, exist_ok=True)
    rng = random.Random(args.seed)
    if args.corpus:
        corpus, total = args.corpus, len(list(args.corpus.iterdir()))
    else:
        corpus, total = generate(args, rng, args.work)
    print(f"{total} inputs in {corpus}", flush=True)
    findings, elapsed = run(args, args.work, corpus, total)
    outcomes = (args.work / "outcomes.tsv").read_text().splitlines() if (args.work / "outcomes.tsv").exists() else []
    slow = sorted((float(l.split("\t")[2]), l.split("\t")[1]) for l in outcomes)[-5:]
    print(f"{len(outcomes)} outcomes in {elapsed:.0f} s; {len(findings)} findings")
    for f in findings:
        print(f"  {f['kind']}: {f.get('input', '')}")
    print("slowest:", ", ".join(f"{name} {s:.1f} s" for s, name in slow))
    nonfinite = [l for l in outcomes if "finite false" in l]
    print(f"{len(nonfinite)} outcomes read with non-finite values")
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main())
