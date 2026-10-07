"""Run the validation suite and the benchmarks, and compare them with earlier nights.

Each night's output is kept under --history, one directory per run. A result is compared with the
last run in which the same command succeeded, as text with the wall times masked: the solvers
repeat to the last bit, so any other difference is a change in the answer. Wall times are
compared with the median of the last few nights. Exits 1 when a command fails, a result changes
or a command is much slower than usual; the next night compares against the new output, so a
change fails once.
"""

import argparse
from dataclasses import dataclass
from datetime import datetime, timezone
import difflib
import hashlib
import json
from pathlib import Path
import re
import shutil
import statistics
import subprocess
import sys
import time


ROOT = Path(__file__).resolve().parents[1]
SLOWER = 1.2  # flag a command taking this much longer than its recent median
RECENT = 7  # nights in that median
MINIMUM_HISTORY = 3  # nights needed before times are compared at all
COMMAND_TIMEOUT = 2 * 60 * 60
SPEED_REPEATS = 3  # a benchmark is run this often and its best time kept


@dataclass
class Entry:
    name: str
    arguments: list
    kind: str  # "result": output compared; "speed": only timed; "image": file compared by hash


# The benchmarks first, while the machine is cool; then the reproduction commands of
# docs/validation.md; then a snapshot of the renderer.
SUITE = [
    Entry("throughput", ["throughput"], "speed"),
    Entry("structure", ["structure"], "speed"),
    Entry("validate", ["validate"], "result"),
    Entry("slab", ["slab", "--sensitivity"], "result"),
    Entry("beam", ["beam"], "result"),
    Entry("shear", ["shear", "--layers", "24,36"], "result"),
    Entry("impact", ["impact", "--layers", "16"], "result"),
    Entry("closein", ["closein"], "result"),
    Entry("closeair", ["closeair", "--dx", "0.01"], "result"),
    Entry("chamber", ["chamber"], "result"),
    Entry("snapshot", ["snapshot", "--out", "{out}/snapshot.png", "--preset", "street"], "image"),
]


def mask_times(text):
    """Hide wall-clock times ("12.3 s"), which differ from night to night."""
    return re.sub(r"\b\d+(?:\.\d+)? s\b", "# s", text)


def file_hash(path):
    return hashlib.sha256(path.read_bytes()).hexdigest() if path.exists() else None


def previous_runs(history, name):
    """Earlier runs in which `name` succeeded, newest first."""
    runs = []
    for directory in sorted(history.glob("*/"), reverse=True):
        try:
            record = json.loads((directory / "run.json").read_text())
        except (OSError, ValueError):
            continue
        command = record.get("commands", {}).get(name)
        if command and command.get("status") == "ok":
            runs.append((directory, record, command))
    return runs


def compare_result(entry, out, previous):
    """A unified diff of this run's output against the previous one, or "" when the same."""
    if entry.kind == "speed" or not previous:
        return ""
    directory, _, command = previous[0]
    if entry.kind == "image":
        new = file_hash(out / "snapshot.png")
        return "" if new == command.get("sha256") else f"image hash {command.get('sha256')} -> {new}\n"
    old = mask_times((directory / f"{entry.name}.txt").read_text()).splitlines(keepends=True)
    new = mask_times((out / f"{entry.name}.txt").read_text()).splitlines(keepends=True)
    return "".join(difflib.unified_diff(old, new, f"{directory.name}/{entry.name}.txt", f"{entry.name}.txt"))


def compare_time(seconds, previous):
    """This run's time against the median of recent ones: (median, slower), or (None, False)."""
    times = [command["seconds"] for _, _, command in previous[:RECENT]]
    if len(times) < MINIMUM_HISTORY:
        return None, False
    median = statistics.median(times)
    return median, seconds > median * SLOWER


def run_once(binary, entry, out):
    arguments = [argument.format(out=out) for argument in entry.arguments]
    start = time.monotonic()
    try:
        completed = subprocess.run([str(binary), *arguments], cwd=ROOT, text=True, timeout=COMMAND_TIMEOUT,
                                   stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        output, status = completed.stdout, "ok" if completed.returncode == 0 else f"exit {completed.returncode}"
    except subprocess.TimeoutExpired as error:
        output, status = (error.stdout or b"").decode(errors="replace"), "timed out"
    print(output, end="", flush=True)
    return output, status, time.monotonic() - start


def run_entry(binary, entry, out):
    """Run an entry, a benchmark several times: one run straight after a long one was measured 23%
    slower, from the machine's heat, so its best time is kept."""
    outputs, times = [], []
    for _ in range(SPEED_REPEATS if entry.kind == "speed" else 1):
        output, status, seconds = run_once(binary, entry, out)
        outputs.append(output)
        times.append(seconds)
        if status != "ok":
            break
    (out / f"{entry.name}.txt").write_text("".join(outputs))
    return {"status": status, "seconds": round(min(times) if status == "ok" else sum(times), 1)}


def summarise(record, rows, diffs):
    lines = [f"## Nightly run {record['started']}", "",
             f"Commit `{record['commit'][:12]}` on {record['chip']}.", "",
             "| Command | Status | Time | Recent median | Result |", "|---|---|---|---|---|"]
    lines += rows
    for name, diff in diffs:
        lines += ["", f"<details><summary>{name} changed</summary>", "", "```diff", diff.rstrip(), "```",
                  "", "</details>"]
    return "\n".join(lines) + "\n"


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--history", type=Path, default=Path.home() / "bombcad-nightly")
    parser.add_argument("--out", type=Path, default=ROOT / "nightly-results")
    parser.add_argument("--summary", type=Path, help="also append the summary here (GITHUB_STEP_SUMMARY)")
    parser.add_argument("--only", help="comma-separated suite entries to run")
    parser.add_argument("--list", action="store_true", help="list the suite and exit")
    options = parser.parse_args()

    suite = SUITE
    if options.only:
        names = [name.strip() for name in options.only.split(",") if name.strip()]
        unknown = set(names) - {entry.name for entry in SUITE}
        if unknown:
            parser.error(f"unknown suite entries: {', '.join(sorted(unknown))}")
        suite = [entry for entry in SUITE if entry.name in names]
    if options.list:
        for entry in suite:
            print(f"{entry.name:12} {entry.kind:7} blastbench {' '.join(entry.arguments)}")
        return 0

    subprocess.run(["swift", "build", "-c", "release", "--product", "blastbench"], cwd=ROOT, check=True)
    binary = Path(subprocess.run(["swift", "build", "-c", "release", "--show-bin-path"], cwd=ROOT, check=True,
                                 text=True, stdout=subprocess.PIPE).stdout.strip()) / "blastbench"

    out = options.out.resolve()
    shutil.rmtree(out, ignore_errors=True)
    out.mkdir(parents=True)
    options.history.mkdir(parents=True, exist_ok=True)
    started = datetime.now(timezone.utc)
    record = {
        "started": started.strftime("%Y-%m-%d %H:%M UTC"),
        "commit": subprocess.run(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True,
                                 stdout=subprocess.PIPE).stdout.strip(),
        "chip": subprocess.run(["sysctl", "-n", "machdep.cpu.brand_string"], text=True,
                               stdout=subprocess.PIPE).stdout.strip(),
        "commands": {},
    }

    rows, diffs, failed = [], [], False
    for entry in suite:
        print(f"\n=== blastbench {' '.join(entry.arguments)}", flush=True)
        command = run_entry(binary, entry, out)
        if entry.kind == "image":
            command["sha256"] = file_hash(out / "snapshot.png")
        record["commands"][entry.name] = command
        previous = previous_runs(options.history, entry.name)
        if command["status"] != "ok":
            failed = True
            rows.append(f"| {entry.name} | **{command['status']}** | {command['seconds']:.0f} s | | |")
            continue
        median, slower = compare_time(command["seconds"], previous)
        diff = compare_result(entry, out, previous)
        if diff:
            diffs.append((entry.name, diff))
        failed |= slower or bool(diff)
        result = ("timed only" if entry.kind == "speed" else "first run" if not previous
                  else "**changed**" if diff else "same")
        rows.append(f"| {entry.name} | ok | {command['seconds']:.0f} s"
                    + (" **slower**" if slower else "") + " | "
                    + (f"{median:.0f} s" if median is not None else "") + f" | {result} |")

    (out / "run.json").write_text(json.dumps(record, indent=2) + "\n")
    shutil.copytree(out, options.history / f"{started.strftime('%Y%m%dT%H%M%SZ')}-{record['commit'][:7]}")
    summary = summarise(record, rows, diffs)
    (out / "summary.md").write_text(summary)
    print("\n" + summary)
    if options.summary:
        with options.summary.open("a") as stream:
            stream.write(summary)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
