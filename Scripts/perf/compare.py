#!/usr/bin/env python3
"""Each standard scenario's latest figure against its previous one, from Benchmarks/perf/history.jsonl.

    python3 Scripts/perf/compare.py                    # latest run against the one before (make perf-compare)
    python3 Scripts/perf/compare.py --threshold 0.05
    python3 Scripts/perf/compare.py --doc docs/performance.md   # redraw the doc's tables from the history

A scenario more than --threshold (10%) slower in wall time than its previous entry is flagged, and
the exit status is then 1. Entries are compared only when their settings hash and machine model
match; otherwise the line says what changed. Figures run outside a quiet window are marked.

With --doc, the blocks between `<!-- perf:NAME -->` and `<!-- /perf:NAME -->` are rewritten:
`headline` (the latest entry of each scenario) and `trend` (each scenario's last runs).
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
HISTORY = ROOT / "Benchmarks" / "perf" / "history.jsonl"


def load(path: Path) -> list[dict]:
    if not path.exists():
        return []
    return [json.loads(line) for line in path.read_text().splitlines() if line.strip()]


def by_scenario(entries: list[dict]) -> dict[str, list[dict]]:
    series: dict[str, list[dict]] = {}
    for e in sorted(entries, key=lambda e: (e["date"], e["run"])):
        series.setdefault(e["scenario"], []).append(e)
    return series


def factor_text(x: float | None) -> str:
    if x is None:
        return "–"
    if x < 0.1:
        return f"{x:.3f}×"
    if x < 10:
        return f"{x:.2f}×" if x < 1 else f"{x:.1f}×"
    return f"{x:,.0f}×"


def seconds_text(x: float | None) -> str:
    if x is None:
        return "–"
    if x < 0.1:
        return f"{x:.3f} s"
    if x < 1:
        return f"{x:.2f} s"
    if x < 100:
        return f"{x:.1f} s"
    return f"{x:,.0f} s"


def size_text(e: dict) -> str:
    parts = []
    if e.get("cells"):
        c = e["cells"]
        parts.append(f"{c / 1e6:.1f} M cells" if c >= 1e5 else f"{c:,.0f} cells")
    if e.get("elements"):
        parts.append(f"{e['elements']:,} elements")
    extra = e.get("extra", {})
    if extra.get("buildings"):
        parts.append(f"{extra['buildings']:,} buildings")
    if extra.get("components"):
        parts.append(f"{extra['components']:,} components")
    return ", ".join(parts) or "–"


def uses_gpu(e: dict) -> bool:
    return bool(e.get("gpu_s")) and e["gpu_s"] >= 0.05 * e["wall_s"] or bool(e.get("sim_s"))


def loaded(e: dict) -> bool:
    """Run outside a quiet window: another gpu-slot job, or (for work on the GPU) another process
    using the GPU as it started."""
    return bool(e.get("quiet_window") is False or e.get("other_gpu_jobs")
                or (e.get("gpu_users") and uses_gpu(e)))


def pick(entries: list[dict]) -> dict:
    """A scenario's figure for the doc: its latest entry run in a quiet window, else its latest."""
    return next((e for e in reversed(entries) if not loaded(e)), entries[-1])


def mark(e: dict) -> str:
    """† for a figure run outside a quiet window (another gpu-slot job, or another process using the
    GPU for GPU work); ‡ where the rounds differed by more than 5%."""
    out = ""
    if loaded(e):
        out += "†"
    if (e.get("spread") or 0) > 0.05:
        out += "‡"
    return out


def headline(series: dict[str, list[dict]], order: list[str]) -> str:
    rows = [
        "| What is simulated | Slower than real time | Wall | GPU | Simulated | Steps | Size | Peak memory | Load | Run |",
        "|---|---|---|---|---|---|---|---|---|---|",
    ]
    for sid in order:
        if sid not in series:
            continue
        e = pick(series[sid])
        cells = [
            e["title"],
            (factor_text(e.get("factor")) if e.get("sim_s") else "–") + mark(e),
            seconds_text(e.get("wall_s")),
            seconds_text(e.get("gpu_s")),
            seconds_text(e.get("sim_s")),
            f"{e['steps']:,}" if e.get("steps") else "–",
            size_text(e),
            (f"{e['peak_mem_gb']:.2f} GB" if e["peak_mem_gb"] < 1 else f"{e['peak_mem_gb']:.1f} GB")
            if e.get("peak_mem_gb") is not None else "–",
            f"{e.get('load1', 0):.1f}",
            e["date"][:16].replace("T", " "),
        ]
        rows.append("| " + " | ".join(cells) + " |")
    return "\n".join(rows)


def trend(series: dict[str, list[dict]], order: list[str], last: int) -> str:
    runs = sorted({e["run"] for s in series.values() for e in s})[-last:]
    dates = {}
    for e in (e for s in series.values() for e in s):
        dates[e["run"]] = min(dates.get(e["run"], e["date"]), e["date"])
    dates = {r: d[:16].replace("T", " ") for r, d in dates.items()}
    commits = {e["run"]: e["commit"][:8] for s in series.values() for e in s}
    rows = ["| Scenario, wall time | " + " | ".join(f"{dates[r]} ({commits[r]})" for r in runs) + " |",
            "|---|" + "---|" * len(runs)]
    for sid in order:
        if sid not in series:
            continue
        cells = []
        for r in runs:
            e = next((e for e in series[sid] if e["run"] == r), None)
            cells.append("" if e is None else seconds_text(e.get("wall_s")) + mark(e))
        rows.append(f"| `{sid}` | " + " | ".join(cells) + " |")
    return "\n".join(rows)


def rewrite(doc: Path, blocks: dict[str, str]) -> None:
    text = doc.read_text()
    for name, body in blocks.items():
        pattern = re.compile(rf"(<!-- perf:{name} -->).*?(<!-- /perf:{name} -->)", re.S)
        if not pattern.search(text):
            print(f"{doc}: no perf:{name} block", file=sys.stderr)
            continue
        text = pattern.sub(lambda m: m.group(1) + "\n" + body + "\n" + m.group(2), text)
    doc.write_text(text)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--history", type=Path, default=HISTORY)
    parser.add_argument("--threshold", type=float, default=0.10)
    parser.add_argument("--doc", type=Path)
    parser.add_argument("--trend-runs", type=int, default=6)
    args = parser.parse_args()

    entries = load(args.history)
    if not entries:
        print(f"no entries in {args.history}")
        return 0
    series = by_scenario(entries)
    # The list's own order, from the run that has most of it.
    order: list[str] = []
    for e in entries:
        if e["scenario"] not in order:
            order.append(e["scenario"])

    if args.doc:
        rewrite(args.doc, {"headline": headline(series, order),
                           "trend": trend(series, order, args.trend_runs)})
        print(f"rewrote the perf blocks of {args.doc}")
        return 0

    flagged = []
    print(f"{'scenario':26} {'previous':>10} {'latest':>10} {'change':>8}  note")
    for sid in order:
        s = series[sid]
        latest = s[-1]
        previous = next((e for e in reversed(s[:-1]) if e["run"] != latest["run"]), None)
        if previous is None:
            print(f"{sid:26} {'':>10} {seconds_text(latest['wall_s']):>10} {'':>8}  first entry")
            continue
        notes = []
        if previous["settings"] != latest["settings"]:
            notes.append("settings changed")
        if previous["machine"].get("model") != latest["machine"].get("model"):
            notes.append("other machine")
        if mark(latest) or mark(previous):
            notes.append("not quiet" if "†" in mark(latest) + mark(previous) else "rounds spread >5%")
        change = latest["wall_s"] / previous["wall_s"] - 1
        comparable = not notes or notes == ["rounds spread >5%"] or notes == ["not quiet"]
        if change > args.threshold and comparable:
            flagged.append(sid)
            notes.insert(0, f"SLOWER by more than {args.threshold:.0%}")
        print(f"{sid:26} {seconds_text(previous['wall_s']):>10} {seconds_text(latest['wall_s']):>10} "
              f"{change:+8.1%}  {previous['commit'][:8]} -> {latest['commit'][:8]}"
              + (f"; {'; '.join(notes)}" if notes else ""))
    if flagged:
        print(f"\n{len(flagged)} slower: {', '.join(flagged)}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
