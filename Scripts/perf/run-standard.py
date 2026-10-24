#!/usr/bin/env python3
"""The standard performance list: a fixed set of scenarios, timed on the recommended settings.

    python3 Scripts/perf/run-standard.py                 # wait for a quiet window, run, append
    python3 Scripts/perf/run-standard.py --now           # run whatever the load, record it
    python3 Scripts/perf/run-standard.py --only air-1m,structure-alone --rounds 1 --no-append
    python3 Scripts/perf/run-standard.py --list

`make perf` runs it. Each scenario runs `--rounds` times (2), the rounds interleaved, every run in
`gpu-slot --mem <GB>`, with the release binaries of this checkout (built first unless
`--no-build`). The lower wall time of the rounds is kept; both are recorded. Results go to
`--out` (a directory on StudioData by default) as results.csv and results.json with each run's
log, and one line per scenario is appended to Benchmarks/perf/history.jsonl, which
Scripts/perf/compare.py reads (`make perf-compare`) and docs/performance.md's tables are drawn from.

Definitions, as docs/performance.md's: the wall time is the bench's own timed span (the solve,
without building the scene or writing images), the process's wall time is recorded beside it;
"slower than real time" is that wall time over the simulated time; GPU time is the process's
accumulatedGPUTime from ioreg (AGXDeviceUserClient), read while it runs and held open a moment
as it exits (linger.c); peak memory is /usr/bin/time -l's peak memory footprint, which counts
the Metal buffers on this unified memory.

Scenario ids are stable: never rename one, add a new id instead, so the series lines up. A
scenario's settings hash covers its command line and environment; compare.py compares only
like with like.

Run on the Studio in a quiet window (no other gpu-slot holder, no other process using more than 5% of
the GPU, load under 8, swap not growing),
not on the mini: weekly, and after anything that touches the solver's speed.
"""

from __future__ import annotations

import argparse
import csv
import datetime as dt
import hashlib
import importlib.util
import json
import os
import platform
import re
import subprocess
import sys
import threading
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable

ROOT = Path(__file__).resolve().parents[2]
HISTORY = ROOT / "Benchmarks" / "perf" / "history.jsonl"
DATA = Path(os.environ.get("BOMBCAD_DATA", "/Volumes/StudioData/bombcad"))
SLOTS = DATA / "gpu-slots"
GPU_SLOT = Path.home() / ".local" / "bin" / "gpu-slot"
FIELD_MODEL = DATA / "ml" / "field-unet-fp-strict" / "app" / "field-unet-fp-strict.bcfw"
BEIRUT = DATA / "data" / "Beirut2020"
RELEASE = ROOT / ".build" / "release"

# Beirut 2020's district (docs/beirut-2020.md, "The recipe"): OSM footprints, the DEM and GHSL
# heights, on 4 m cells under a 320 m top; the 4 m run's saved loads for the quick estimate's drag.
BEIRUT_FILES = [BEIRUT / "OSM" / "beirut-port-buildings.osm",
                BEIRUT / "DEM" / "Copernicus_DSM_COG_10_N33_00_E035_00_DEM.tif",
                BEIRUT / "GHSL" / "GHS_BUILT_H_ANBH_E2018_GLOBE_R2023A_4326_3ss_V1_0_R6_C22.tif"]
BEIRUT_ARGS = ["--osm", str(BEIRUT_FILES[0]), "--dem", str(BEIRUT_FILES[1]), "--ground-radius", "100",
               "--sea", "1", "--heights", str(BEIRUT_FILES[2]), "--centre", "35.519042,33.901425",
               "--dx", "4", "--height", "320"]
BEIRUT_LOADS = DATA / "beirut" / "mix" / "loads-500000"
DRAG_ARGS = ["--radius", "2500", "--loads", str(BEIRUT_LOADS), "--mass", "500000", "--moves", "",
             "--drag", "0,5,10,15,20,30,40,60,80,100", "--parts", "damage", "--preview-draws", "20"]

# Every scenario's environment: the shared settle cache (settled bodies are reused, as in the
# app), and the GPU command buffers at their default length.
BASE_ENV = {"BOMBCAD_SETTLE_CACHE": str(DATA / "settle-cache")}
# The recommended air (SolverConfiguration.recommended) in the benches that start from the
# balloon (makeAirSolver pins `balloonStart`): the mapped start and the fireball's cooling.
RECOMMENDED = ["--mapped", "--radiate"]


# ---------------------------------------------------------------------------------------------
# Parsing the benches' output


def _num(text: str) -> float:
    return float(text.replace(",", ""))


def _seconds(pattern: str, text: str) -> float | None:
    found = re.findall(pattern, text)
    return _num(found[-1]) if found else None


THROUGHPUT_ROW = re.compile(
    r"^\s*([\d.]+) m\s+([\d.]+) M\s+([\d.]+) GB\s+(\d+)\s+(\d+)\s+(\d+)x\s+(\d+)\s+(\d+)%\s+([\d.]+) s",
    re.M)


def parse_throughput(text: str, run_dir: Path) -> dict:
    """`blastbench throughput`: one row per cell size (the scenarios here give one)."""
    rows = THROUGHPUT_ROW.findall(text)
    if not rows:
        raise ValueError("no throughput row")
    cell, cells, memory, rate, _, _, steps, swept, wall = rows[-1]
    event = re.search(r"([\d.]+) ms event", text)
    elements = re.findall(r"structure: (\d+) elements", text)
    return {
        "wall_s": float(wall), "steps": int(steps), "sim_s": float(event.group(1)) / 1000,
        "cells": round(float(cells) * 1e6), "elements": int(elements[-1]) if elements else None,
        "swept": int(swept) / 100, "solver_gb": float(memory), "cell_m": float(cell),
    }


def parse_structure(text: str, run_dir: Path) -> dict:
    """`blastbench structure`: 4,000 steps timed after 200 to warm up."""
    m = re.search(r"Structure: (\d+) hexahedral elements.*time step ([\d.]+) µs.*?(\d+) MB", text)
    rate = re.search(r"([\d.]+) steps/s", text)
    if not (m and rate):
        raise ValueError("no structure line")
    steps = 4000
    wall = steps / float(rate.group(1))
    return {
        "wall_s": wall, "steps": steps, "sim_s": steps * float(m.group(2)) * 1e-6,
        "elements": int(m.group(1)), "solver_gb": int(m.group(3)) / 1000,
    }


def parse_snapshot(text: str, run_dir: Path) -> dict:
    """`blastbench snapshot`: the solve's span ("Simulated in"), its steps and size."""
    wall = _seconds(r"Simulated in ([\d.]+) s", text)
    wrote = re.findall(r"t = ([\d.]+) ms after (\d+) steps", text)
    air = re.search(r"Air: (\d+) cells", text)
    structure = re.findall(r"Structure: (\d+) elements intact, (\d+) failed", text)
    if wall is None or not wrote:
        raise ValueError("no snapshot timing")
    out = {"wall_s": wall, "sim_s": float(wrote[-1][0]) / 1000, "steps": int(wrote[-1][1])}
    if air:
        out["cells"] = int(air.group(1))
    if structure:
        out["elements"] = int(structure[-1][0]) + int(structure[-1][1])
    frozen = re.search(r"frozen at ([\d.]+) ms", text)
    if frozen:
        out["air_frozen_s"] = float(frozen.group(1)) / 1000
    return out


def parse_district(text: str, run_dir: Path) -> dict:
    """`scenebench district-compare`: the run's span, steps and cells, the step buffers' GPU time,
    and the end-of-run damage judgement as the app makes it (a row of its own)."""
    ran = re.findall(r"Ran to ([\d.]+) s in (\d+) steps, ([\d.]+) s", text)
    cells = re.search(r"(\d+) cells, (\d+) components", text)
    if not ran:
        raise ValueError("no district run")
    sim, steps, wall = ran[-1]
    report = next(run_dir.glob("**/comparison.json"), None)
    if report:
        wall = json.loads(report.read_text()).get("wallS", wall)
    run = {"wall_s": float(wall), "steps": int(steps), "sim_s": float(sim)}
    if cells:
        run.update(cells=int(cells.group(1)), components=int(cells.group(2)))
    gpu = re.findall(r"Step buffers' GPU time ([\d.]+) s", text)
    if gpu:
        run["step_gpu_s"] = float(gpu[-1])
    rows = {"": run}
    judged = re.search(r"Judged (\d+) buildings from (\d+) components, as the app does, in ([\d.]+) s", text)
    if judged:
        rows["judgement"] = {"wall_s": float(judged.group(3)), "buildings": int(judged.group(1)),
                             "components": int(judged.group(2))}
    return {"rows": rows}


def parse_drag(text: str, run_dir: Path) -> dict:
    """`scenebench drag-time --drag …`: the drag's frames (the first apart: it lays out the
    responses kept for the rest) and the full look when the charge is let go."""
    prepared = re.search(r"Prepared (\d+) buildings, (\d+) components on the air, in ([\d.]+) s", text)
    frames = [float(f) for f in re.findall(r"^Drag frame at\s+[\d.-]+ m:.*?walls [\d.]+ s; ([\d.]+) s", text, re.M)]
    let_go = re.search(r"Let go: full look.*?walls [\d.]+ s; ([\d.]+) s", text)
    if not (prepared and frames and let_go):
        raise ValueError("no drag timing")
    size = {"buildings": int(prepared.group(1)), "components": int(prepared.group(2))}
    later = sorted(frames[1:]) or frames
    learned = re.findall(r"learned peaks ([\d.]+) s at (\d+) strips", text)
    frame = {"wall_s": later[len(later) // 2], "first_frame_s": frames[0], "frames": len(frames),
             "frame_range_s": [later[0], later[-1]], **size}
    look = {"wall_s": float(let_go.group(1)), "prepare_s": float(prepared.group(3)), **size}
    if learned:
        look["learned_peaks_s"] = float(learned[-1][0])
    return {"rows": {"frame": frame, "look": look}}


def parse_close_calls(text: str, run_dir: Path) -> dict:
    """`scenebench threshold-refine`: the time until the refined run has judged all its buildings."""
    plan = re.search(r"refining the nearest (\d+) on a near scene .*?\(\d+ buildings, ([\d.]+) million cells\), "
                     r"to ([\d.]+) s", text)
    ended = re.search(r"Ended (\w+) after ([\d.]+) s: (\d+) of (\d+) buildings refined", text)
    if not (plan and ended):
        raise ValueError("no close-call timing")
    count = int(plan.group(1))
    done = [float(t) for t, n in re.findall(r"^\s+([\d.]+) s: [\d.]+ of [\d.]+ s simulated, (\d+) of", text, re.M)
            if int(n) >= count]
    wall = done[0] if done else float(ended.group(2))
    estimate = re.search(r"Quick estimate of (\d+) buildings in ([\d.]+) s", text)
    return {"wall_s": wall, "sim_s": float(plan.group(3)), "cells": round(float(plan.group(2)) * 1e6),
            "buildings": count, "ended": ended.group(1), "refined": int(ended.group(3)),
            "estimate_s": float(estimate.group(2)) if estimate else None}


# ---------------------------------------------------------------------------------------------
# The list


@dataclass
class Scenario:
    id: str  # stable: never renamed
    title: str  # the doc's row
    tool: str  # blastbench, scenebench or BombCAD
    args: list[str]
    parse: Callable[[str, Path], dict]
    mem_gb: int  # declared to gpu-slot
    env: dict[str, str] = field(default_factory=dict)
    note: str = ""
    requires: list[Path] = field(default_factory=list)
    # A run that gives several rows (`parse` returns {"rows": {suffix: row}}): each suffix's title;
    # its id is the scenario's id, then `-suffix` (none for the suffix "").
    rows: dict[str, str] = field(default_factory=dict)

    def row_id(self, suffix: str) -> str:
        return f"{self.id}-{suffix}" if suffix else self.id

    def command(self) -> list[str]:
        return [str(RELEASE / self.tool), *self.args]

    def settings_hash(self) -> str:
        key = json.dumps({"tool": self.tool, "args": self.args, "env": self.env}, sort_keys=True)
        return hashlib.sha256(key.encode()).hexdigest()[:12]


def scenarios() -> list[Scenario]:
    thr = ["throughput", *RECOMMENDED]
    return [
        Scenario("air-1m", "Air blast, 1 M cells (0.5 m street)", "blastbench",
                 [*thr, "--dx", "0.5"], parse_throughput, 2),
        Scenario("air-8m", "Air blast, 8.4 M cells (0.25 m street)", "blastbench",
                 [*thr, "--dx", "0.25"], parse_throughput, 3),
        Scenario("air-67m", "Air blast, 67 M cells (0.125 m street)", "blastbench",
                 [*thr, "--dx", "0.125", "--full"], parse_throughput, 9),
        Scenario("air-refined-0.25x2", "Air blast, 0.25 m refined by 2 (the peaks of 0.125 m)",
                 "blastbench", [*thr, "--dx", "0.25", "--refine", "2"], parse_throughput, 4),
        Scenario("structure-alone", "225k-element concrete building, alone", "blastbench",
                 ["structure"], parse_structure, 2),
        Scenario("structure-contact", "The same, contact running", "blastbench",
                 ["structure", "--contact"], parse_structure, 2),
        Scenario("coupled-box-1m", "That building coupled to 1 M air cells", "blastbench",
                 [*thr, "--preset", "box", "--dx", "0.25", "--full"], parse_throughput, 3),
        Scenario("coupled-storeys", "160k-element three-storey building, coupled (0.25 m)",
                 "blastbench", [*thr, "--preset", "storeys", "--dx", "0.25", "--full"],
                 parse_throughput, 3),
        Scenario("collapse-frame", "23k-element frame collapsing, 3 s", "blastbench",
                 ["snapshot", *RECOMMENDED, "--preset", "frame", "--time", "3", "--no-wave",
                  "--out", "{out}/frame.png"], parse_snapshot, 3),
        Scenario("office-0.5s", "Twelve-storey office, first 0.5 s", "blastbench",
                 ["snapshot", *RECOMMENDED, "--preset", "office", "--dx", "0.5", "--time", "0.5",
                  "--no-wave", "--out", "{out}/office.png"], parse_snapshot, 6,
                 note="coupled to the air throughout; the air is frozen only after 1.2 s"),
        Scenario("beirut-4m", "Beirut, the whole district on 4 m cells, 8 s", "scenebench",
                 ["district-compare", *BEIRUT_ARGS, "--radius", "2500", "--mass", "500000", "--until", "8",
                  "--window", "0.5", "--ground", "saturated", "--observers",
                  str(BEIRUT / "Rigby2020" / "Rigby2020_ESM1_radius_time.csv"), "--out", "{out}/district"],
                 parse_district, 24, requires=BEIRUT_FILES,
                 rows={"": "Beirut, the whole district on 4 m cells, 8 s",
                       "judgement": "Beirut, the end-of-run damage judgement (the 4 m run's loads)"}),
        Scenario("beirut-near-2m", "Beirut, the near box (1.32 km radius) refined to 2 m, 3 s", "scenebench",
                 ["district-compare", *BEIRUT_ARGS, "--radius", "1320", "--mass", "500000", "--until", "3",
                  "--window", "0.5", "--ground", "saturated", "--refine", "2", "--ceiling", "auto",
                  "--refine-memory", "14", "--out", "{out}/near"],
                 parse_district, 20, requires=BEIRUT_FILES,
                 rows={"": "Beirut, the near box (1.32 km radius) refined to 2 m, 3 s",
                       "judgement": "Beirut, the end-of-run damage judgement (the near box's loads)"}),
        Scenario("beirut-quick", "Beirut quick estimate", "scenebench",
                 ["drag-time", *BEIRUT_ARGS, *DRAG_ARGS], parse_drag, 12,
                 requires=[*BEIRUT_FILES, BEIRUT_LOADS],
                 rows={"look": "Beirut quick estimate, the full look",
                       "frame": "Beirut, a drag preview frame (damage)"}),
        Scenario("beirut-quick-field", "Beirut quick estimate, learned field model", "scenebench",
                 ["drag-time", *BEIRUT_ARGS, *DRAG_ARGS, "--weights", str(FIELD_MODEL)], parse_drag, 12,
                 env={"BOMBCAD_FIELD_MODEL": str(FIELD_MODEL)},
                 requires=[*BEIRUT_FILES, BEIRUT_LOADS, FIELD_MODEL],
                 rows={"look": "Beirut quick estimate, the full look, learned field model",
                       "frame": "Beirut, a drag preview frame (damage), learned field model"}),
        Scenario("beirut-close-calls-8", "Beirut, close calls refined: the first 8 buildings", "scenebench",
                 ["threshold-refine", *BEIRUT_ARGS, "--mass", "500000", "--buildings", "8"],
                 parse_close_calls, 12, requires=BEIRUT_FILES),
    ]


# ---------------------------------------------------------------------------------------------
# The machine and the quiet window


def build_dir():
    """Scripts/build-dir.py, which links this checkout's .build to its build folder."""
    spec = importlib.util.spec_from_file_location("build_dir", ROOT / "Scripts" / "build-dir.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def sh(*command: str) -> str:
    return subprocess.run(command, capture_output=True, text=True).stdout.strip()


def machine() -> dict:
    cores = re.search(r'"gpu-core-count" = (\d+)', sh("ioreg", "-r", "-c", "AGXAccelerator", "-d1", "-w0"))
    return {
        "model": sh("sysctl", "-n", "hw.model"),
        "chip": sh("sysctl", "-n", "machdep.cpu.brand_string"),
        "gpu_cores": int(cores.group(1)) if cores else None,
        "memory_gb": round(int(sh("sysctl", "-n", "hw.memsize")) / 2**30),
        "macos": platform.mac_ver()[0],
        "host": platform.node().split(".")[0],
    }


def load_average() -> float:
    return float(sh("sysctl", "-n", "vm.loadavg").strip("{} ").split()[0])


def swap_used_mb() -> float:
    m = re.search(r"used = ([\d.]+)M", sh("sysctl", "vm.swapusage"))
    return float(m.group(1)) if m else 0.0


def slot_holders(own: set[int] | None = None) -> list[str]:
    """Who holds a gpu-slot now (a slot's .who is left behind when free, so test its lock)."""
    holders = []
    for who in sorted(SLOTS.glob("slot.*.who")):
        text = who.read_text().strip() if who.exists() else ""
        if not text:
            continue
        lock = who.with_suffix("")
        held = subprocess.run(["lockf", "-t", "0", str(lock), "true"], capture_output=True).returncode != 0
        pid = re.match(r"pid (\d+)", text)
        if held and not (own and pid and int(pid.group(1)) in own):
            holders.append(text)
    return holders


def gpu_users(seconds: float = 3, share: float = 0.05) -> dict[str, float]:
    """Processes using more than `share` of the GPU over `seconds`, gpu-slot or not: on 23 October
    2026 an iOS Simulator (SimMetalHost) took a third of it all night without holding a slot."""
    before = gpu_times()
    time.sleep(seconds)
    after = gpu_times()
    users = {}
    for pid, ns in after.items():
        used = (ns - before.get(pid, 0)) / 1e9 / seconds
        if used > share:
            name = Path(sh("ps", "-o", "comm=", "-p", str(pid)) or str(pid)).name
            users[name] = round(users.get(name, 0) + used, 2)
    return users


def conditions(own: set[int] | None = None, sample_s: float = 3) -> dict:
    return {"load1": load_average(), "swap_mb": swap_used_mb(),
            "pressure": int(sh("sysctl", "-n", "kern.memorystatus_vm_pressure_level") or 0),
            "other_gpu_jobs": slot_holders(own), "gpu_users": gpu_users(sample_s)}


def wait_for_quiet(start: str, until: str, every_s: int, max_load: float, log) -> dict:
    """From `start` (HH:MM), every `every_s`, until no other slot holder, load under `max_load` and
    swap not growing; at `until`, give up and return the conditions with quiet False."""
    def today_at(hhmm: str) -> dt.datetime:
        h, m = map(int, hhmm.split(":"))
        now = dt.datetime.now()
        at = now.replace(hour=h, minute=m, second=0, microsecond=0)
        # A start after midnight asked for in the evening means tomorrow's.
        return at + dt.timedelta(days=1) if at < now - dt.timedelta(hours=12) else at
    begin, end = today_at(start), today_at(until)
    if end < begin:
        end += dt.timedelta(days=1)
    while dt.datetime.now() < begin:
        time.sleep(min(60, max(1, (begin - dt.datetime.now()).total_seconds())))
    last_swap = swap_used_mb()
    checks = []
    while True:
        time.sleep(0 if not checks else every_s)
        c = conditions()
        growing = c["swap_mb"] > last_swap + 64
        last_swap = c["swap_mb"]
        quiet = not c["other_gpu_jobs"] and not c["gpu_users"] and c["load1"] < max_load and not growing
        checks.append({"at": dt.datetime.now().isoformat(timespec="seconds"), **c,
                       "swap_growing": growing, "quiet": quiet})
        log(f"quiet check {checks[-1]['at']}: load {c['load1']:.1f}, swap {c['swap_mb']:.0f} MB"
            f"{' growing' if growing else ''}, other GPU jobs {len(c['other_gpu_jobs'])}"
            + "".join(f", {name} using {use:.0%} of the GPU" for name, use in c["gpu_users"].items())
            + f" -> {'quiet' if quiet else 'not quiet'}")
        if quiet or dt.datetime.now() >= end:
            return {"quiet": quiet, "checks": checks}


# ---------------------------------------------------------------------------------------------
# One run


def gpu_times() -> dict[int, int]:
    """Every process's accumulated GPU time, ns, from ioreg (AppUsage precedes its creator line)."""
    out = sh("ioreg", "-r", "-c", "AGXDeviceUserClient", "-l", "-w0")
    totals: dict[int, int] = {}
    pending = 0
    for line in out.splitlines():
        if '"AppUsage"' in line:
            pending += sum(int(v) for v in re.findall(r'"accumulatedGPUTime"=(\d+)', line))
        elif '"IOUserClientCreator"' in line:
            m = re.search(r'"pid (\d+),', line)
            if m:
                pid = int(m.group(1))
                totals[pid] = totals.get(pid, 0) + pending
            pending = 0
    return totals


def descendants(root: int) -> set[int]:
    children: dict[int, list[int]] = {}
    for line in sh("ps", "-A", "-o", "pid=,ppid=").splitlines():
        pid, ppid = map(int, line.split())
        children.setdefault(ppid, []).append(pid)
    found, stack = set(), [root]
    while stack:
        for child in children.get(stack.pop(), []):
            found.add(child)
            stack.append(child)
    return found


def linger_library(out: Path) -> Path | None:
    library = out / "linger.dylib"
    if not library.exists():
        made = subprocess.run(["cc", "-dynamiclib", "-O2", "-o", str(library),
                               str(Path(__file__).with_name("linger.c"))], capture_output=True)
        if made.returncode != 0:
            return None
    return library


def run_once(s: Scenario, out: Path, round_: int, log, use_slot: bool) -> dict:
    run_dir = out / s.id
    run_dir.mkdir(parents=True, exist_ok=True)
    # Each round writes its outputs (images, reports) to a folder of its own.
    round_dir = run_dir / f"round{round_}"
    round_dir.mkdir(exist_ok=True)
    args = [a.replace("{out}", str(round_dir)) for a in s.command()]
    env = dict(os.environ, **BASE_ENV, **s.env, BOMBCAD_SOURCE_REVISION=REVISION)
    library = linger_library(out)
    if library:
        env["DYLD_INSERT_LIBRARIES"] = str(library)
        env["BOMBCAD_PERF_LINGER"] = "1.5"
    timed = ["/usr/bin/time", "-l", *args]
    command = [str(GPU_SLOT), "--mem", str(s.mem_gb), *timed] if use_slot else timed
    before = conditions(sample_s=2)
    log_path = run_dir / f"round{round_}.log"
    started = time.monotonic()
    with open(log_path, "w") as handle:
        handle.write("$ " + " ".join(command) + "\n")
        handle.flush()
        process = subprocess.Popen(command, stdout=handle, stderr=subprocess.STDOUT, env=env, cwd=ROOT)
        gpu: dict[int, int] = {}
        binary = Path(args[0]).name
        running_since = None
        stop = threading.Event()

        def sample():
            nonlocal running_since
            while not stop.is_set():
                pids = descendants(process.pid)
                if pids:
                    for pid, ns in gpu_times().items():
                        if pid in pids:
                            gpu[pid] = max(gpu.get(pid, 0), ns)
                            if running_since is None:
                                running_since = time.monotonic()
                stop.wait(0.25)
        sampler = threading.Thread(target=sample, daemon=True)
        sampler.start()
        process.wait()
        stop.set()
        sampler.join()
    text = log_path.read_text()
    result = {"scenario": s.id, "round": round_, "exit": process.returncode,
              "load1": before["load1"], "swap_mb": before["swap_mb"],
              "other_gpu_jobs": len(before["other_gpu_jobs"]), "gpu_users": before["gpu_users"],
              "started": dt.datetime.now().isoformat(timespec="seconds"),
              "slot_and_process_wall_s": round(time.monotonic() - started, 2),
              "gpu_s": round(sum(gpu.values()) / 1e9, 2) if gpu else None,
              "log": str(log_path)}
    peak = re.search(r"(\d+)\s+peak memory footprint", text)
    rss = re.search(r"(\d+)\s+maximum resident set size", text)
    real = re.findall(r"([\d.]+) real", text)
    result["peak_mem_gb"] = round(int(peak.group(1)) / 1e9, 2) if peak else (
        round(int(rss.group(1)) / 1e9, 2) if rss else None)
    result["process_wall_s"] = float(real[-1]) if real else None
    if process.returncode != 0:
        result["error"] = text[-2000:]
        log(f"  {s.id} round {round_}: exit {process.returncode}, see {log_path}")
        return {s.row_id(k): result for k in (s.rows or {"": ""})}
    try:
        parsed = s.parse(text, run_dir / f"round{round_}")
    except ValueError as error:
        result["error"] = f"parse: {error}"
        log(f"  {s.id} round {round_}: {result['error']}, see {log_path}")
        return {s.row_id(k): result for k in (s.rows or {"": ""})}
    rows = {}
    for suffix, values in (parsed["rows"] if "rows" in parsed else {"": parsed}).items():
        row = {**result, **values, "scenario": s.row_id(suffix)}
        row["factor"] = round(row["wall_s"] / row["sim_s"], 2) if row.get("sim_s") else None
        if suffix != next(iter(s.rows or {"": ""})):  # the process's GPU time and memory: first row's
            row["gpu_s"] = row["peak_mem_gb"] = None
        rows[row["scenario"]] = row
        log(f"  {row['scenario']} round {round_}: wall {row['wall_s']:.2f} s, sim {row.get('sim_s')} s, "
            f"factor {row['factor']}, GPU {row['gpu_s']} s, peak {row['peak_mem_gb']} GB, "
            f"load {row['load1']:.1f}")
    (run_dir / f"round{round_}.json").write_text(json.dumps(rows, indent=1))
    return rows


def collect(out: Path, chosen: list[Scenario], rounds: int) -> dict[str, list[dict]]:
    """The rounds of a run already made, from each run's round*.json, or, for a run made before
    those were written, from its logs and run.log's summary lines (GPU time and load)."""
    summary = {}
    for line in (out / "run.log").read_text().splitlines() if (out / "run.log").exists() else []:
        m = re.match(r"\s+(\S+) round (\d+): .*GPU (\S+) s, peak (\S+) GB, load ([\d.]+)", line)
        if m:
            gpu = None if m.group(3) == "None" else float(m.group(3))
            summary[(m.group(1), int(m.group(2)))] = (gpu, float(m.group(5)))
    results: dict[str, list[dict]] = {}
    for s in chosen:
        for round_ in range(1, rounds + 1):
            saved = out / s.id / f"round{round_}.json"
            if saved.exists():
                rows = json.loads(saved.read_text())
            else:
                log_path = out / s.id / f"round{round_}.log"
                if not log_path.exists():
                    continue
                text = log_path.read_text()
                base = {"scenario": s.id, "round": round_, "exit": 0, "log": str(log_path),
                        "started": dt.datetime.fromtimestamp(log_path.stat().st_mtime).isoformat(timespec="seconds")}
                peak = re.search(r"(\d+)\s+peak memory footprint", text)
                real = re.findall(r"([\d.]+) real", text)
                base["peak_mem_gb"] = round(int(peak.group(1)) / 1e9, 2) if peak else None
                base["process_wall_s"] = float(real[-1]) if real else None
                try:
                    parsed = s.parse(text, out / s.id / f"round{round_}")
                except ValueError as error:
                    rows = {s.id: {**base, "error": f"parse: {error}"}}
                else:
                    rows = {}
                    first = next(iter(s.rows or {"": ""}))
                    for suffix, values in (parsed["rows"] if "rows" in parsed else {"": parsed}).items():
                        row_id = s.row_id(suffix)
                        gpu, load = summary.get((row_id, round_), (None, None))
                        row = {**base, **values, "scenario": row_id, "gpu_s": gpu, "load1": load}
                        if suffix != first:
                            row["peak_mem_gb"] = None
                        row["factor"] = round(row["wall_s"] / row["sim_s"], 2) if row.get("sim_s") else None
                        rows[row_id] = row
            for row_id, row in rows.items():
                results.setdefault(row_id, []).append(row)
    return results


# ---------------------------------------------------------------------------------------------


def revision() -> str:
    rev = sh("git", "-C", str(ROOT), "rev-parse", "HEAD")
    dirty = sh("git", "-C", str(ROOT), "status", "--porcelain", "--untracked-files=no", "--", "Sources",
               "Package.swift", "Package.resolved")
    return rev + ("-dirty" if dirty else "")


REVISION = ""


def best(rounds: list[dict]) -> dict:
    good = [r for r in rounds if "wall_s" in r and "error" not in r]
    if not good:
        return rounds[-1]
    low = min(good, key=lambda r: r["wall_s"])
    walls = [r["wall_s"] for r in good]
    return {**low, "walls_s": walls,
            "spread": round(max(walls) / min(walls) - 1, 3) if len(walls) > 1 else 0.0}


def main() -> int:
    global REVISION
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--only", help="comma-separated scenario ids")
    parser.add_argument("--rounds", type=int, default=2)
    parser.add_argument("--out", type=Path)
    parser.add_argument("--now", action="store_true", help="skip the quiet-window wait")
    parser.add_argument("--wait-from", default=None, help="HH:MM to start checking (default now)")
    parser.add_argument("--wait-until", default=None,
                        help="HH:MM to give up waiting and run anyway (default five hours from the start)")
    parser.add_argument("--every", type=int, default=600, help="seconds between quiet checks")
    parser.add_argument("--max-load", type=float, default=8.0)
    parser.add_argument("--require-quiet", action="store_true", help="if no quiet window comes, don't run")
    parser.add_argument("--no-slot", action="store_true", help="don't wrap runs in gpu-slot")
    parser.add_argument("--no-build", action="store_true")
    parser.add_argument("--no-append", action="store_true", help="don't append to the history")
    parser.add_argument("--list", action="store_true")
    parser.add_argument("--collect", type=Path,
                        help="no runs: rebuild the results and the history lines from a run's folder")
    args = parser.parse_args()

    chosen = scenarios()
    if args.list:
        for s in chosen:
            print(f"{s.id:24} {s.mem_gb:3d} GB  {s.settings_hash()}  {s.title}")
        return 0
    if args.only:
        wanted = args.only.split(",")
        unknown = set(wanted) - {s.id for s in chosen}
        if unknown:
            print(f"unknown scenarios: {', '.join(sorted(unknown))}", file=sys.stderr)
            return 2
        chosen = [s for s in chosen if s.id in wanted]

    stamp = dt.datetime.now().strftime("%Y%m%d-%H%M%S")
    if args.collect:
        args.out = args.collect
        args.now = args.no_build = True
        first = re.search(r"perf run (\S+) at (\S+)", (args.collect / "run.log").read_text())
        stamp, collected_revision = first.group(1), first.group(2)
    out = args.out or DATA / "perf" / stamp
    out.mkdir(parents=True, exist_ok=True)
    log_file = open(out / ("collect.log" if args.collect else "run.log"), "a")

    def log(line: str):
        print(line, flush=True)
        log_file.write(line + "\n")
        log_file.flush()

    missing = [str(p) for s in chosen for p in s.requires if not p.exists()]
    if missing:
        log("missing inputs: " + ", ".join(missing))
        return 1

    window = {"quiet": None, "checks": []}
    if args.collect:
        checks = re.findall(r"quiet check (\S+): load ([\d.]+), swap (\d+) MB( growing)?, other GPU jobs (\d+) -> (\w+)",
                            (out / "run.log").read_text())
        window = {"quiet": bool(checks) and checks[-1][5] == "quiet",
                  "checks": [{"at": c[0], "load1": float(c[1]), "swap_mb": float(c[2]), "swap_growing": bool(c[3]),
                              "other_gpu_jobs": int(c[4]), "quiet": c[5] == "quiet"} for c in checks]}
    elif not args.now:
        begin = args.wait_from or dt.datetime.now().strftime("%H:%M")
        until = args.wait_until or (dt.datetime.now() + dt.timedelta(hours=5)).strftime("%H:%M")
        window = wait_for_quiet(begin, until, args.every, args.max_load, log)
        if not window["quiet"] and args.require_quiet:
            log("no quiet window came: not running (--require-quiet)")
            return 3
        if not window["quiet"]:
            log("no quiet window came: running anyway, the load recorded beside each figure")

    # The checkout as it is when the runs start, built then, so the binaries are its commit's.
    REVISION = collected_revision if args.collect else revision()
    if not args.collect:
        log(f"perf run {stamp} at {REVISION} into {out}")
    if not args.no_build:
        # This checkout's build folder linked first (Scripts/build-dir.py: on the Studio, off the boot
        # disk; a checkout on StudioData, as perf-wt is, keeps its own .build).
        build_dir().ensure(ROOT)
        tools = sorted({s.tool for s in chosen})
        for tool in tools:
            log(f"building {tool} (release)")
            if subprocess.run(["swift", "build", "-c", "release", "--product", tool], cwd=ROOT).returncode:
                log(f"build of {tool} failed")
                return 1
        # The build's own load falls away before the first run (up to five minutes).
        settle_until = time.monotonic() + 300
        while not args.now and load_average() >= args.max_load and time.monotonic() < settle_until:
            time.sleep(15)

    titles: dict[str, tuple[Scenario, str]] = {}
    for s in chosen:
        for suffix, title in (s.rows or {"": s.title}).items():
            titles[s.row_id(suffix)] = (s, title)
    if args.collect:
        results = collect(out, chosen, args.rounds)
    else:
        results = {row_id: [] for row_id in titles}
        for round_ in range(1, args.rounds + 1):
            for s in chosen:
                for row_id, row in run_once(s, out, round_, log, not args.no_slot).items():
                    results.setdefault(row_id, []).append(row)

    info = machine()
    date = (dt.datetime.fromtimestamp((out / "run.log").stat().st_mtime) if args.collect else dt.datetime.now()).isoformat(timespec="seconds")
    rows = []
    for row_id, rounds in results.items():
        if not rounds:
            continue
        s, title = titles.get(row_id) or next(
            (t, f"{t.title} ({row_id[len(t.id) + 1:]})") for t in chosen if row_id.startswith(t.id + "-"))
        b = best(rounds)
        rows.append({
            "run": stamp, "commit": REVISION, "date": b.get("started") or date, "machine": info,
            "quiet_window": window["quiet"], "scenario": row_id, "title": title,
            "settings": s.settings_hash(), "command": " ".join([s.tool, *s.args]),
            "env": s.env, "note": s.note,
            **{k: b.get(k) for k in (
                "load1", "swap_mb", "other_gpu_jobs", "gpu_users", "wall_s", "walls_s", "spread", "process_wall_s",
                "gpu_s", "sim_s", "factor", "steps", "cells", "elements", "peak_mem_gb", "solver_gb",
                "error")},
            "extra": {k: v for k, v in b.items() if k in (
                "swept", "air_frozen_s", "cell_m", "buildings", "components", "step_gpu_s", "first_frame_s",
                "frame_range_s", "frames", "prepare_s", "learned_peaks_s", "estimate_s", "ended", "refined",
                "cpu_only") and v is not None},
        })
    (out / "results.json").write_text(json.dumps(
        {"run": stamp, "commit": REVISION, "machine": info, "window": window,
         "rows": rows, "rounds": results}, indent=1))
    columns = ["scenario", "wall_s", "walls_s", "spread", "process_wall_s", "gpu_s", "sim_s", "factor",
               "steps", "cells", "elements", "peak_mem_gb", "load1", "swap_mb", "other_gpu_jobs", "error"]
    with open(out / "results.csv", "w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=columns, extrasaction="ignore")
        writer.writeheader()
        for row in rows:
            writer.writerow({**row, "walls_s": " ".join(f"{w:.2f}" for w in row["walls_s"] or [])})
    if not args.no_append:
        HISTORY.parent.mkdir(parents=True, exist_ok=True)
        with open(HISTORY, "a") as handle:
            for row in rows:
                if row.get("error"):
                    continue
                handle.write(json.dumps({k: v for k, v in row.items() if v not in (None, "", {})},
                                        sort_keys=False) + "\n")
        log(f"appended {sum(1 for r in rows if not r.get('error'))} lines to {HISTORY.relative_to(ROOT)}")
    failed = [r["scenario"] for r in rows if r.get("error")]
    if failed:
        log("failed: " + ", ".join(failed))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
