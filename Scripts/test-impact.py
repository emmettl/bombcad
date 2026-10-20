"""The test-impact map: which Swift Testing suites execute which source functions.

    ~/.local/bin/gpu-slot --mem 10 python3 Scripts/test-impact.py build   # on the Studio
    python3 Scripts/test-impact.py build                                  # on the mini, nightly
    python3 Scripts/test-impact.py show Sources/BlastCore/Footing.swift   # who covers a file
    python3 Scripts/test-impact.py fetch                                  # copy the mini's maps here
    python3 Scripts/test-impact.py list                                   # maps kept here

`build` compiles the package and its tests with coverage (`swift build --build-tests
--enable-code-coverage`, in a scratch folder of its own, so a worktree's own build is untouched),
lists the tests, and runs each top-level suite in a process of its own (`swift test --skip-build
--filter`), a few at once, each writing its raw profile through LLVM_PROFILE_FILE. Swift's
coverage counts per process, not per test, so a process per suite is the finest practical grain:
one per test would be about 2,000 processes. Each suite's profile is merged (`llvm-profdata`) and
exported (`llvm-cov export`), and the map records, per suite, the functions of Sources/ it ran
(each function by its file and line extent). The map is generated, never committed: it goes to
<out>/<commit>.json, keyed by the commit it was built at, which must be clean.

`Scripts/check-affected.py` reads the newest map whose commit is an ancestor of the branch's merge
base, and runs the suites that executed a changed function (docs/continuous-integration.md). The
helpers it uses (line translation between commits, the shader library's declarations) are here.
"""

import argparse
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import platform
import re
import shutil
import signal
import socket
import subprocess
import sys
import threading
import time

ROOT = Path(__file__).resolve().parents[1]
STUDIO_DATA = Path("/Volumes/StudioData/bombcad")
FORMAT = 1
# Maps kept where they are built and where they are fetched to: the nightly writes one a night, and
# check-affected wants the newest behind a branch's merge base, so three nights' are plenty.
KEEP_MAPS = 3


def default_out():
    return STUDIO_DATA / "test-impact" if STUDIO_DATA.is_dir() else Path.home() / "bombcad-test-impact"


def default_scratch():
    """A build folder of its own: the coverage flags would rebuild a worktree's .build from scratch."""
    return default_out() / "build"


def git(*arguments, root=ROOT, check=True):
    return subprocess.run(["git", *arguments], cwd=root, check=check, text=True,
                          stdout=subprocess.PIPE, stderr=subprocess.DEVNULL).stdout


# MARK: - Building the map


def unit_of(identifier):
    """The top-level suite of a test identifier ("Module.Suite/test()"), or the test itself when it
    has no suite."""
    return identifier.split("/", 1)[0]


def list_units(scratch):
    # The instrumented bundle writes a profile wherever it is loaded; listing's isn't wanted.
    environment = dict(os.environ, LLVM_PROFILE_FILE=os.devnull)
    output = subprocess.run(["swift", "test", "list", "--skip-build", "--scratch-path", str(scratch)], cwd=ROOT,
                            env=environment, check=True, text=True, stdout=subprocess.PIPE,
                            stderr=subprocess.DEVNULL).stdout
    units = {}
    for line in output.splitlines():
        line = line.strip()
        if re.match(r"^\w+\.\S", line):
            units.setdefault(unit_of(line), []).append(line)
    return units


def bundle_binary(scratch, module):
    """The test bundle's executable for a test target. SwiftPM 6.4 builds one bundle per target;
    older toolchains one per package."""
    debug = Path(subprocess.run(["swift", "build", "--show-bin-path", "--scratch-path", str(scratch)], cwd=ROOT,
                                check=True, text=True, stdout=subprocess.PIPE,
                                stderr=subprocess.DEVNULL).stdout.strip())
    for name in (module, "BombCADPackageTests"):
        binary = debug / f"{name}.xctest" / "Contents" / "MacOS" / name
        if binary.exists():
            return binary
    raise FileNotFoundError(f"no test bundle for {module} under {debug}")


def demangle(names):
    if not names:
        return {}
    completed = subprocess.run(["xcrun", "swift-demangle", "--simplified", "--compact"], input="\n".join(names),
                               text=True, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    lines = completed.stdout.splitlines()
    if completed.returncode or len(lines) != len(names):
        return {name: name for name in names}
    return dict(zip(names, lines))


def short_name(demangled):
    """`encodeRemask(_:fine:allocate:)` from `BlastCore.BlastSolver.encodeRemask(_: ..., fine: ...) -> ()`."""
    name = demangled.split(";")[-1]
    name = re.sub(r"\s*->.*$", "", name)
    name = re.sub(r"^(static |private |closure #\d+ (in|@\S+ in) )+", "", name)
    return name[:120]


def export_functions(profdata, binary, sources):
    """{file: {(start, end): (count, name)}} for the functions of `sources` in `binary`."""
    completed = subprocess.run(
        ["xcrun", "llvm-cov", "export", "-skip-expansions", "-skip-branches", "-instr-profile", str(profdata),
         str(binary), *sources], text=True, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    if completed.returncode:
        raise RuntimeError(f"llvm-cov export failed for {profdata}")
    data = json.loads(completed.stdout)["data"][0]
    functions = {}
    for function in data.get("functions", []):
        regions = function.get("regions") or []
        filenames = function.get("filenames") or []
        if not regions or not filenames:
            continue
        own = regions[0][5]
        path = filenames[own]
        lines = [region for region in regions if region[5] == own and region[7] == 0] or regions[:1]
        start, end = min(region[0] for region in lines), max(region[2] for region in lines)
        record = functions.setdefault(path, {})
        count, name = record.get((start, end), (0, function["name"]))
        record[(start, end)] = (count + function.get("count", 0), name)
    return functions


class Peak:
    """The largest total resident memory of this process's descendants, sampled."""

    def __init__(self, interval=10):
        self.interval, self.peak, self.stop = interval, 0, threading.Event()
        self.thread = threading.Thread(target=self.run, daemon=True)

    def run(self):
        me = os.getpid()
        while not self.stop.wait(self.interval):
            try:
                table = subprocess.run(["ps", "-axo", "pid=,ppid=,rss="], text=True, stdout=subprocess.PIPE).stdout
            except OSError:
                continue
            children, rss = {}, {}
            for line in table.splitlines():
                parts = line.split()
                if len(parts) == 3:
                    pid, ppid, kilobytes = map(int, parts)
                    children.setdefault(ppid, []).append(pid)
                    rss[pid] = kilobytes
            total, stack = 0, list(children.get(me, []))
            while stack:
                pid = stack.pop()
                total += rss.get(pid, 0)
                stack.extend(children.get(pid, []))
            self.peak = max(self.peak, total)

    def __enter__(self):
        self.thread.start()
        return self

    def __exit__(self, *_):
        self.stop.set()


def run_unit(unit, scratch, work, timeout):
    """Runs one suite with its own raw profiles; returns (status, seconds, profraws)."""
    raw = work / "raw" / safe(unit)
    shutil.rmtree(raw, ignore_errors=True)
    raw.mkdir(parents=True)
    environment = dict(os.environ, LLVM_PROFILE_FILE=str(raw / "%p-%m.profraw"))
    pattern = "^" + re.escape(unit) + "(/|$)"
    log = work / "logs" / f"{safe(unit)}.log"
    start = time.monotonic()
    with log.open("w") as stream:
        process = subprocess.Popen(
            ["swift", "test", "--skip-build", "--experimental-skip-acquiring-lock", "--scratch-path", str(scratch),
             "--filter", pattern], cwd=ROOT, env=environment, stdout=stream, stderr=subprocess.STDOUT,
            start_new_session=True)
        try:
            code = process.wait(timeout=timeout)
            status = "passed" if code == 0 else f"exit {code}"
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)  # this run's own process group only
            process.wait()
            status = "timed out"
    return status, time.monotonic() - start, sorted(raw.glob("*.profraw"))


def skipped_tests(log):
    """Tests Swift Testing reported skipped (release-only ones, those wanting a fixture): their code
    is not in the suite's coverage."""
    try:
        text = log.read_text(errors="replace")
    except OSError:
        return 0
    return len(re.findall(r"^\S+ Test .*\bskipped(:.*)?\.?$", text, re.MULTILINE))


def safe(unit):
    return re.sub(r"[^A-Za-z0-9_.-]", "_", unit)


def assemble(table, results, names):
    """The map's function table ({file: [[start, end, name]]}, sorted by extent) and its suites,
    each executed function given as its index in that table.
    `table` is {file: {(start, end): mangled}}, `results` {unit: record with "files": {file: [(start,
    end)]} or None}, `names` {mangled: demangled}."""
    functions, index = {}, {}
    for path in sorted(table):
        extents = sorted(table[path])
        functions[path] = [[start, end, short_name(names.get(table[path][(start, end)], ""))]
                           for start, end in extents]
        index[path] = {extent: position for position, extent in enumerate(extents)}
    suites = {}
    for unit in sorted(results):
        record = dict(results[unit])
        if record["files"] is not None:
            record["files"] = {path: sorted({index[path][tuple(extent)] for extent in extents})
                               for path, extents in sorted(record["files"].items())}
        suites[unit] = record
    return functions, suites


def build(options):
    out = options.out
    out.mkdir(parents=True, exist_ok=True)
    dirty = git("status", "--porcelain", "--untracked-files=all", "--", "Sources", "Tests", "Package.swift",
                "Package.resolved").strip()
    if dirty and not options.allow_dirty:
        print("test-impact: the checkout has uncommitted changes in Sources/, Tests/ or the package; a map is "
              "keyed by a commit (--allow-dirty writes <commit>-dirty.json, which check-affected ignores)")
        return 2
    commit = git("rev-parse", "HEAD").strip()
    name = commit + ("-dirty" if dirty else "")
    scratch = options.scratch
    started = time.monotonic()
    if not options.skip_compile:
        print(f"test-impact: building with coverage in {scratch}", flush=True)
        subprocess.run(["swift", "build", "--build-tests", "--enable-code-coverage", "--scratch-path",
                        str(scratch)], cwd=ROOT, check=True)
    compile_seconds = time.monotonic() - started
    if options.compile_only:
        return 0
    if "GPU_SLOT_MEM" not in os.environ and Path(options.gpu_slot).exists() and not options.no_slot:
        # The suites run on the GPU: hold a slot for them, not for the compile above.
        command = [options.gpu_slot, "--mem", str(options.mem), sys.executable, __file__, "build",
                   "--skip-compile", "--out", str(out), "--scratch", str(scratch), "--jobs", str(options.jobs),
                   "--timeout", str(options.timeout), "--compile-seconds", f"{compile_seconds:.0f}"]
        command += ["--only", options.only] if options.only else []
        command += ["--allow-dirty"] if options.allow_dirty else []
        print("+", " ".join(command), flush=True)
        return subprocess.run(command, cwd=ROOT).returncode
    compile_seconds = options.compile_seconds or compile_seconds

    # The IFC suites run only with the pinned converter, which `make test` and check-affected
    # prepare first: without it they skip, and would map as covering almost nothing.
    if subprocess.run([sys.executable, str(ROOT / "Scripts/prepare-ifc-converter.py")], cwd=ROOT).returncode:
        print("test-impact: the IFC converter could not be prepared; the suites that need it will have no "
              "coverage", flush=True)
    units = list_units(scratch)
    if options.only:
        wanted = re.compile(options.only)
        units = {unit: tests for unit, tests in units.items() if wanted.search(unit)}
    work = out / f"work-{commit[:12]}"
    (work / "logs").mkdir(parents=True, exist_ok=True)
    sources = sorted(str(ROOT / path) for path in git("ls-files", "Sources").split() if path.endswith(".swift"))
    binaries = {module: bundle_binary(scratch, module) for module in {unit.split(".", 1)[0] for unit in units}}
    # Longest first, by the last map's times, so the slowest suite doesn't start last.
    previous = newest_map(out)
    seconds = {unit: record.get("seconds", 0) for unit, record in (previous or {}).get("suites", {}).items()}
    order = sorted(units, key=lambda unit: -seconds.get(unit, 60))
    table, results, lock = {}, {}, threading.Lock()

    def one(unit):
        try:
            measure(unit)
        except Exception as error:  # one suite's failure leaves it unmapped, not the map unbuilt
            with lock:
                results[unit] = {"tests": len(units[unit]), "seconds": 0, "status": f"error: {error}",
                                 "files": None}
            print(f"test-impact: {unit}: {error}", flush=True)

    def measure(unit):
        status, elapsed, raws = run_unit(unit, scratch, work, options.timeout)
        record = {"tests": len(units[unit]), "seconds": round(elapsed, 1), "status": status,
                  "skipped": skipped_tests(work / "logs" / f"{safe(unit)}.log")}
        # Only a suite that passed is known to have run all of its tests to the end (a crash
        # writes no profile for that process; a failure may stop a test early).
        if raws and status == "passed":
            profdata = work / "raw" / f"{safe(unit)}.profdata"
            subprocess.run(["xcrun", "llvm-profdata", "merge", "-sparse", "-o", str(profdata), *map(str, raws)],
                           check=True)
            functions = export_functions(profdata, binaries[unit.split(".", 1)[0]], sources)
            executed = {}
            with lock:
                for path, record_functions in functions.items():
                    relative = Path(path).resolve().relative_to(ROOT).as_posix() if Path(path).is_relative_to(
                        ROOT) else None
                    if not relative:
                        continue
                    entries = table.setdefault(relative, {})
                    for extent, (count, mangled) in record_functions.items():
                        entries.setdefault(extent, mangled)
                        if count > 0:
                            executed.setdefault(relative, []).append(extent)
            record["files"] = executed
        else:
            record["files"] = None  # no coverage: check-affected always runs this suite
        if not options.keep:
            shutil.rmtree(work / "raw" / safe(unit), ignore_errors=True)
            (work / "raw" / f"{safe(unit)}.profdata").unlink(missing_ok=True)
        with lock:
            results[unit] = record
            done = len(results)
        print(f"test-impact: [{done}/{len(units)}] {unit}: {status}, {elapsed:.0f} s", flush=True)

    run_started = time.monotonic()
    with Peak() as peak, ThreadPoolExecutor(max_workers=options.jobs) as pool:
        list(pool.map(one, order))
    run_seconds = time.monotonic() - run_started

    # Kept until the map is written: what the suites took an hour to measure.
    (work / "results.json").write_text(json.dumps(
        {"table": {path: [[*extent, mangled] for extent, mangled in entries.items()]
                   for path, entries in table.items()}, "results": results}))
    names = demangle(sorted({mangled for entries in table.values() for mangled in entries.values()}))
    functions, suites = assemble(table, results, names)
    document = {
        "format": FORMAT,
        "commit": commit,
        "dirty": bool(dirty),
        "built": datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC"),
        "host": socket.gethostname(),
        "chip": subprocess.run(["sysctl", "-n", "machdep.cpu.brand_string"], text=True,
                               stdout=subprocess.PIPE).stdout.strip(),
        "toolchain": subprocess.run(["swift", "--version"], text=True, stdout=subprocess.PIPE,
                                    stderr=subprocess.STDOUT).stdout.strip().splitlines()[-2:],
        "jobs": options.jobs,
        "compileSeconds": round(compile_seconds),
        "runSeconds": round(run_seconds),
        "peakMemoryGB": round(peak.peak / 1048576, 1),
        "partial": bool(options.only),
        "functions": functions,
        "suites": suites,
    }
    target = out / f"{name}{'-partial' if options.only else ''}.json"
    temporary = target.with_suffix(".tmp")
    temporary.write_text(json.dumps(document, separators=(",", ":")) + "\n")
    temporary.replace(target)
    if not options.keep:
        shutil.rmtree(work / "raw", ignore_errors=True)
        (work / "results.json").unlink(missing_ok=True)
    if not options.only:
        prune(out, options.keep_maps)
        # The suites' logs are kept for the newest map only.
        for old in out.glob("work-*"):
            if old != work:
                shutil.rmtree(old, ignore_errors=True)
    failed = [unit for unit, record in suites.items() if record["status"] != "passed"]
    print(f"test-impact: wrote {target} ({target.stat().st_size / 1e6:.1f} MB): {len(suites)} suites, "
          f"compile {compile_seconds:.0f} s, suites {run_seconds:.0f} s with {options.jobs} at once, "
          f"peak {document['peakMemoryGB']} GB")
    if failed:
        print(f"test-impact: {len(failed)} suite(s) did not pass, so have no coverage (check-affected always "
              f"runs them): {', '.join(failed[:20])}")
    return 0


# MARK: - Reading maps


def map_files(directory):
    """Complete maps of clean commits: <40 hex>.json."""
    return sorted(path for path in Path(directory).glob("*.json") if re.fullmatch(r"[0-9a-f]{40}\.json", path.name))


def newest_map(directory, base=None, root=ROOT):
    """The newest map whose commit is `base` or an ancestor of it (any commit when `base` is None),
    with "distance": commits from it to `base`."""
    best = None
    for path in map_files(directory):
        commit = path.stem
        if base is None:
            distance = -path.stat().st_mtime
        else:
            if subprocess.run(["git", "merge-base", "--is-ancestor", commit, base], cwd=root,
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode:
                continue
            distance = int(git("rev-list", "--count", f"{commit}..{base}", root=root).strip() or 0)
        if best is None or distance < best[0]:
            best = (distance, path)
    if best is None:
        return None
    document = json.loads(best[1].read_text())
    if document.get("format") != FORMAT:
        return None
    document["distance"] = best[0] if base is not None else None
    document["path"] = str(best[1])
    return document


# MARK: - Changed lines


HUNK = re.compile(r"^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@")


def hunks(diff_text):
    """[(old_start, old_count, new_start, new_count)] from a -U0 diff of one file."""
    found = []
    for line in diff_text.splitlines():
        match = HUNK.match(line)
        if match:
            old, old_count, new, new_count = match.groups()
            found.append((int(old), 1 if old_count is None else int(old_count),
                          int(new), 1 if new_count is None else int(new_count)))
    return found


def touched_old_lines(file_hunks, old_text=None, new_text=None):
    """The old-side lines a change touches: the lines it replaces or deletes, and for an insertion
    the lines on either side of it (an insertion between two lines of a function is in it).

    Given both sides' text (Swift), lines that are only a `//` comment or blank count for nothing:
    a hunk of nothing else is no change, and a hunk replacing a comment with code is an insertion
    where the comment was. (Not for shaders: their comments are anchors for BuildProbe's edits.)"""
    old_lines = old_text.splitlines() if old_text is not None else None
    new_lines = new_text.splitlines() if new_text is not None else None

    def quiet(lines, start, count):
        return [number for number in range(start, start + count)
                if 0 < number <= len(lines) and QUIET.match(lines[number - 1])]

    lines = set()
    for old, old_count, new, new_count in file_hunks:
        replaced = set(range(old, old + old_count))
        if old_lines is not None and new_lines is not None:
            inserted_quiet = len(quiet(new_lines, new, new_count)) == new_count
            replaced -= set(quiet(old_lines, old, old_count))
            if not replaced and inserted_quiet:
                continue  # comments and blank lines only
            if not replaced and old_count:
                lines.update((old - 1, old + old_count))
                continue
        if old_count:
            lines.update(replaced)
        else:
            lines.update((old, old + 1))
    return lines


QUIET = re.compile(r"^\s*(//.*)?$")


def translate(lines, file_hunks):
    """Lines of the new side of `file_hunks` (a diff from the map's commit) as lines of its old side.
    A line the diff changed maps to the old lines it replaced, or both neighbours of an insertion."""
    result = set()
    for line in lines:
        offset, mapped = 0, None
        for old, old_count, new, new_count in file_hunks:
            if new_count and new <= line < new + new_count:
                mapped = set(range(old, old + old_count)) if old_count else {old, old + 1}
                break
            new_next = new + new_count if new_count else new + 1
            if line < new_next:
                break
            offset = (old + old_count if old_count else old + 1) - new_next
        result |= mapped if mapped is not None else {line + offset}
    return result


# MARK: - The shaders


TOKEN = re.compile(r"[A-Za-z_]\w*")


def strip_comments(text):
    """Comments and string literals blanked, newlines kept, so line numbers stay."""
    def blank(match):
        return re.sub(r"[^\n]", " ", match.group(0))
    return re.sub(r"//[^\n]*|/\*.*?\*/|\"(?:\\.|[^\"\\\n])*\"", blank, text, flags=re.DOTALL)


def metal_declarations(text):
    """The top-level declarations of a Metal file: [{start, end, name, kind, references}], lines
    1-based. Each declaration's lines run from the end of the one before, so comments above it are
    its own. Kinds: "kernel" (kernel, vertex or fragment function), "function", "type",
    "value" (constants, macros) and "directive" (#include, #pragma, #if: no name)."""
    clean = strip_comments(text)
    declarations, depth, begin, line, position = [], 0, 0, 1, 0
    head = ""
    length = len(clean)
    last_line = 0

    def close(end_position, end_line):
        nonlocal begin, last_line
        body = clean[begin:end_position]
        if body.strip():
            declarations.append(describe(body, last_line + 1, end_line))
            last_line = end_line
        begin = end_position

    while position < length:
        character = clean[position]
        if character == "\n":
            line += 1
        elif depth == 0 and character == "#" and clean[begin:position].strip() == "":
            # A preprocessor line, with its continuations.
            stop = position
            while True:
                newline = clean.find("\n", stop)
                if newline == -1:
                    newline = length
                if clean[stop:newline].rstrip().endswith("\\") and newline < length:
                    stop = newline + 1
                    line += 1
                    continue
                break
            close(newline, line)
            position = newline
            continue
        elif character == "{":
            if depth == 0:
                head = clean[begin:position]
            depth += 1
        elif character == "}":
            depth -= 1
            # A function ends at its brace; a type or an initialised value at its semicolon.
            if depth == 0 and not (TYPE_HEAD.match(head.strip()) or "=" in head):
                close(position + 1, line)
        elif character == ";" and depth == 0:
            close(position + 1, line)
        position += 1
    if clean[begin:].strip():
        declarations.append(describe(clean[begin:], last_line + 1, line))
    elif declarations:
        declarations[-1]["end"] = line
    return declarations


TYPE_HEAD = re.compile(r"(template\s*<[^>]*>\s*)?(struct|enum|union|class|typedef|using)\b")


def describe(body, start, end):
    head = body.split("{", 1)[0]
    stripped = re.sub(r"\[\[.*?\]\]", " ", head, flags=re.DOTALL).strip()
    references = set(TOKEN.findall(body))
    if stripped.startswith("#"):
        match = re.match(r"#\s*define\s+([A-Za-z_]\w*)", stripped)
        return {"start": start, "end": end, "name": match.group(1) if match else None,
                "kind": "value" if match else "directive", "references": references}
    words = TOKEN.findall(stripped)
    if TYPE_HEAD.match(stripped):
        if words[:2] == ["using", "namespace"]:
            return {"start": start, "end": end, "name": None, "kind": "directive", "references": references}
        if words and words[0] == "using":
            name = words[1] if len(words) > 1 else None
        elif words and words[0] == "typedef":
            name = words[-1]
        else:
            keyword = next(i for i, word in enumerate(words) if word in ("struct", "enum", "union", "class",
                                                                         "typedef", "using"))
            rest = [word for word in words[keyword + 1:] if word != "class"]
            name = rest[0] if rest else None
        return {"start": start, "end": end, "name": name, "kind": "type", "references": references}
    paren = stripped.find("(")
    if paren > 0 and "=" not in stripped[:paren]:
        before = TOKEN.findall(stripped[:paren])
        name = before[-1] if before else None
        kind = "kernel" if set(before) & {"kernel", "vertex", "fragment"} else "function"
        return {"start": start, "end": end, "name": name, "kind": kind, "references": references}
    names = TOKEN.findall(stripped.split("=", 1)[0])
    return {"start": start, "end": end, "name": names[-1] if names else None, "kind": "value",
            "references": references}


def affected_kernels(library, changed):
    """Kernels of `library` ({path: declarations}) that a change can reach, from the declarations
    `changed` ({path: [index]}): the changed ones, and whatever names a changed one, transitively.
    A changed directive or nameless declaration counts as its whole file changed."""
    work, seen = [], set()
    for path, indices in changed.items():
        declarations = library[path]
        for index in indices:
            if declarations[index]["name"] is None:
                work.extend((path, other) for other in range(len(declarations)))
            work.append((path, index))
    names = set()
    while work:
        key = work.pop()
        if key in seen:
            continue
        seen.add(key)
        path, index = key
        name = library[path][index]["name"]
        # A kernel is an entry point that no shader code calls: a local of the same name
        # elsewhere (`int sweep`) is not a use of it.
        if name is None or name in names or library[path][index]["kind"] == "kernel":
            continue
        names.add(name)
        for other_path, declarations in library.items():
            for other, declaration in enumerate(declarations):
                if name in declaration["references"] and (other_path, other) not in seen:
                    work.append((other_path, other))
    return sorted({library[path][index]["name"] for path, index in seen
                   if library[path][index]["kind"] == "kernel"})


DISPATCH = re.compile(r"PipelineState\(|[dD]ispatch|pipeline:|[eE]ncode")


def kernel_sites(kernels, swift_files):
    """For each kernel, the Swift lines that dispatch it ({kernel: {path: {line}}}): where its name's
    literal is assigned to a property (`fluxPipeline = try pipeline("flux")`) or a field
    (`sweep: try pipeline("sweep")`), the lines that use that name; otherwise the literal's own line,
    whose function both makes and dispatches the pipeline. `swift_files` is {path: text}."""
    code = {path: [line.split("//", 1)[0] for line in text.splitlines()] for path, text in swift_files.items()}
    sites = {}
    for kernel in kernels:
        literal = f'"{kernel}"'
        found = {}
        for path, lines in code.items():
            for number, line in enumerate(lines, 1):
                if literal not in line:
                    continue
                name = None
                for text in (line, (lines[number - 2] if number > 1 else "") + " " + line):
                    field = re.search(r"(\w+):\s*(?:try[?!]?\s+)?[\w.]*pipeline\(\s*" + re.escape(literal), text)
                    assigned = re.search(r"(?:^|[^\w.])(?:self\.)?(\w+)\s*=\s*\{?\s*(?:try[?!]?\s+)?[\w.]*[pP]ipeline\("
                                         r"[^=]*" + re.escape(literal), text)
                    if field:
                        name = field.group(1)
                    elif assigned and not re.search(r"\b(let|var)\s+" + assigned.group(1) + r"\b", text):
                        name = assigned.group(1)
                    if name:
                        break
                uses = {}
                if name:
                    # Its uses in the same file, or else anywhere in the module (a solver's
                    # extensions live in several files).
                    module = Path(path).parent
                    use = re.compile(r"\b" + re.escape(name) + r"\b")
                    assignment = re.compile(r"\b(var|let)\s+" + re.escape(name) + r"\b|\b" + re.escape(name)
                                            + r"\s*[:=]\s*\{?\s*(try|nil|MTLComputePipelineState)")
                    member = re.compile(r"\." + re.escape(name) + r"\b")

                    def hits(where, pattern):
                        return {other for other, text in enumerate(code[where], 1)
                                if pattern.search(text) and not assignment.search(text)
                                and (where, other) != (path, number)
                                and (pattern is use or DISPATCH.search(text))}
                    if hits(path, use):
                        uses[path] = hits(path, use)
                    else:
                        # Another type's property, dispatched as `rubble.areas`.
                        for other_path in code:
                            if Path(other_path).parent == module and hits(other_path, member):
                                uses[other_path] = hits(other_path, member)
                if not uses:
                    uses = {path: {number}}
                for use_path, use_lines in uses.items():
                    found.setdefault(use_path, set()).update(use_lines)
        sites[kernel] = found
    return sites


def shader_loaders(path, swift_files):
    """The Swift lines that compile a shader file into a library: where its stem appears as a literal
    in a file that loads `.metal` resources."""
    stem = Path(path).stem
    found = {}
    for swift, text in swift_files.items():
        if '"metal"' not in text and ".metal" not in text:
            continue
        for number, line in enumerate(text.splitlines(), 1):
            if f'"{stem}"' in line:
                found.setdefault(swift, set()).add(number)
    return found


# MARK: - Commands


def show(options):
    document = json.loads(Path(options.map).read_text()) if options.map else newest_map(options.out)
    if not document:
        print("test-impact: no map")
        return 1
    print(f"map {document['commit'][:12]} built {document['built']} on {document['host']}: "
          f"{len(document['suites'])} suites, {document['runSeconds']} s of suites, "
          f"compile {document['compileSeconds']} s, peak {document['peakMemoryGB']} GB")
    for path in options.files:
        covering = sorted(unit for unit, record in document["suites"].items()
                          if record["files"] is not None and path in record["files"])
        print(f"{path}: {len(covering)} suites")
        for unit in covering:
            print(f"  {unit} ({len(document['suites'][unit]['files'][path])} functions)")
    return 0


def fetch(options):
    """Copies the maps built on the CI Mac (its ~/bombcad-test-impact) here, and keeps the newest
    --keep-maps of them."""
    try:
        settings = json.loads((Path.home() / ".config/bombcad/remote.json").read_text())
    except (OSError, ValueError):
        print("test-impact: no remote host configured (~/.config/bombcad/remote.json)")
        return 1
    host = settings.get("host")
    options.out.mkdir(parents=True, exist_ok=True)
    command = ["rsync", "-a", "--include=*.json", "--exclude=*", "-e",
               "ssh -o BatchMode=yes -o ConnectTimeout=8", f"{host}:bombcad-test-impact/", f"{options.out}/"]
    try:
        status = subprocess.run(command, timeout=options.timeout, stdout=subprocess.DEVNULL,
                                stderr=subprocess.DEVNULL).returncode
    except subprocess.TimeoutExpired:
        return 1
    prune(options.out, options.keep_maps)
    return status


def prune(directory, keep):
    """Keeps the newest `keep` maps."""
    files = sorted(map_files(directory), key=lambda path: path.stat().st_mtime)
    for path in files[:-keep] if keep else []:
        path.unlink()


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    commands = parser.add_subparsers(dest="command", required=True)
    build_parser = commands.add_parser("build", help="build a map at HEAD")
    build_parser.add_argument("--out", type=Path, default=default_out())
    build_parser.add_argument("--scratch", type=Path, default=None)
    build_parser.add_argument("--jobs", type=int, default=4, help="suites run at once")
    build_parser.add_argument("--timeout", type=int, default=90 * 60, help="seconds a suite may take")
    build_parser.add_argument("--only", help="a regular expression: only the suites it finds (a partial map)")
    build_parser.add_argument("--mem", type=int, default=10, help="GB declared to gpu-slot for the suites")
    build_parser.add_argument("--gpu-slot", default=str(Path.home() / ".local/bin/gpu-slot"))
    build_parser.add_argument("--no-slot", action="store_true", help="run the suites without gpu-slot")
    build_parser.add_argument("--allow-dirty", action="store_true")
    build_parser.add_argument("--keep", action="store_true", help="keep the raw profiles")
    build_parser.add_argument("--keep-maps", type=int, default=KEEP_MAPS, help="maps kept in --out")
    build_parser.add_argument("--skip-compile", action="store_true", help=argparse.SUPPRESS)
    build_parser.add_argument("--compile-only", action="store_true", help=argparse.SUPPRESS)
    build_parser.add_argument("--compile-seconds", type=float, default=0, help=argparse.SUPPRESS)
    show_parser = commands.add_parser("show", help="the suites that cover files")
    show_parser.add_argument("files", nargs="*")
    show_parser.add_argument("--map")
    show_parser.add_argument("--out", type=Path, default=default_out())
    fetch_parser = commands.add_parser("fetch", help="copy the CI Mac's maps here")
    fetch_parser.add_argument("--out", type=Path, default=default_out())
    fetch_parser.add_argument("--timeout", type=int, default=60)
    fetch_parser.add_argument("--keep-maps", type=int, default=KEEP_MAPS, help="maps kept in --out")
    list_parser = commands.add_parser("list", help="the maps kept here")
    list_parser.add_argument("--out", type=Path, default=default_out())
    options = parser.parse_args()
    if options.command == "build":
        options.scratch = options.scratch or options.out / "build"
        return build(options)
    if options.command == "show":
        return show(options)
    if options.command == "fetch":
        return fetch(options)
    for path in map_files(options.out):
        document = json.loads(path.read_text())
        print(f"{path.stem[:12]}  {document['built']}  {document['host']}  {len(document['suites'])} suites")
    return 0


if __name__ == "__main__":
    sys.exit(main())
