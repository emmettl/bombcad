"""The pre-push check sized to the change: the tests that execute what changed.

    make check-affected

It looks at what this branch changes against origin/main (committed, staged, unstaged and
untracked files) and runs one of five tiers:

- documents and Python scripts only (docs/, Markdown, images, Scripts/*.py, the reference
  calculations in Scripts/reference/ and their tables, the protective-design prototype in
  Scripts/protective/, the analytic oracles in Scripts/analytic/): lint and the scripts' tests
  and links (`ci-test`); no Swift build, no GPU.
- covered, when a test-impact map (Scripts/test-impact.py) exists for the merge base or a commit
  behind it: lint, the strict build, `ci-test`, and the Swift suites that executed a changed
  function when the map was built. A shader change counts as a change to the Swift lines that
  dispatch the kernels it can reach. Plus the suites in changed test files, those whose test files
  read a changed file by its path, those the map has no coverage for, and a few that many changes
  trip (the standing and the shader layouts).
- affected, with no usable map: the same, but choosing the suites that name a changed file's type.
- core: a change to the solvers' core (their shaders, BlastSolver and its extensions, the solvers'
  shared types, RadialBlast): the suites as for covered (or affected, without a map), and what the
  map can't speak for by the name rules, or for a shader by the suites the map lists for the Swift
  mirrors of the shader types it touches; plus `blastbench digest` in six sets (DIGEST_SETS),
  built for release here and at the merge base, compared bit for bit. A digest that differs fails
  the check and is named. The merge base's binary and digests are kept in
  /Volumes/StudioData/bombcad/digest-cache/<commit>/, so the next check on that base reuses them.
- full: the package's dependencies (Package.swift, Package.resolved), or `--full`: `make check`.

A changed file falls back to the name rules when the map doesn't know it or more than
--max-map-age commits have touched it since the map was built.

The full check still runs nightly on the mini and before every release, naming the commits since
the last green one as suspects; this only decides what a push waits for. `--dry-run` prints the
tier and the suites, with why each was chosen, and where the build and tests would run, without
running anything; `--full` forces the full check (through make: `make check-affected
ARGS=--dry-run`). `--base <commit>` compares with that commit instead of the merge base with
origin/main (to time a past commit as the branch it was).

Lint and ci-test run here. The build and tests (the strict build, the IFC converter, the swift
test run; or the full check) run under gpu-slot here, unless this Mac's line is long (--min-waiting
jobs waiting, 3 by default, or more memory declared than its budget) and the other Mac in
~/.config/bombcad/remote.json is free (Scripts/remote.py, in a second lane there if one is safe):
then there, the same steps from a copy of this worktree, their output streamed back and their exit
status returned. `--local` and `--remote` choose. The digests always run here (the cache and the
merge base's history are here), beside the steps when those went to the other Mac. Run under
gpu-slot itself, it holds a slot, so it stays here (the full check goes to `make check-anywhere`,
as before).
"""

import argparse
import fcntl
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("test_impact", Path(__file__).with_name("test-impact.py"))
impact = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(impact)
REMOTE_SPEC = importlib.util.spec_from_file_location("remote", Path(__file__).with_name("remote.py"))
remote = importlib.util.module_from_spec(REMOTE_SPEC)
REMOTE_SPEC.loader.exec_module(remote)

# Files whose change can move any result: the solvers' shaders, BlastSolver and its extensions, the
# solvers' shared types (with their `+GPU`/`+CPU` halves), RadialBlast. Tier core: their suites, and
# the digests bit for bit.
CORE = [
    re.compile(r"^Sources/Blast(Core|Model)/Shaders/"),
    re.compile(r"^Sources/Blast(Core|Model)/(BlastSolver|SolverTypes|StructureSolver|StructureTypes|"
               r"ShellSolver|Scenario|MappedStart|Refinement|StructuralBody)(\+\w+)?\.swift$"),
    re.compile(r"^Sources/RadialBlast/"),
]
# The package and its pins: the full check even with a map (a new ContinuumKit moves what the
# map's coverage can't see, its shader source among it).
ALWAYS_FULL = re.compile(r"^Package\.(swift|resolved)$")
SHADER = re.compile(r"^Sources/[^/]+/Shaders/[^/]+\.metal$")
# Documents and the Python scripts, which ci-test covers on its own.
DOCUMENT = re.compile(r"(^docs/|\.md$|\.png$|\.jpg$|\.svg$|^LICENSE$|^Scripts/(analytic/|protective/|reference/)?[^/]+\.py$|"
                      r"^Scripts/reference/tables/[^/]+\.json$)")
# Suites that changes elsewhere often trip: the standing parses the docs and options, the
# layout test guards the renderer's copies of the solver's structs.
ALWAYS = ["StandingFingerprintTests", "EvidentialStandingTests", "StandingRunTests",
          "ErrorBandTests", "RenderLayoutTests"]
# A type, after an @Suite on its own line or on the same one (`@Suite(.serialized) struct ...`).
SUITE = re.compile(r"^\s*(?:@Suite\b[^\n]*?\s(?=(?:@MainActor\s+)?(?:final\s+)?(?:struct|class)\s)|@Suite[^\n]*\n\s*)?"
                   r"(?:@MainActor\s+)?(?:final\s+)?(?:struct|class)\s+(\w+)", re.MULTILINE)
PATH_LITERAL = re.compile(r'"(?:\.\./)*((?:Sources|Samples|Scripts|docs)/[^"\\]*)"')
# A map older than this many commits (not merges) touching a changed file is too far from it to
# trust: BlastSolver.swift takes about 20 a day.
MAX_MAP_AGE = 30


def git(*arguments, check=True):
    return subprocess.run(["git", *arguments], cwd=ROOT, check=check, text=True,
                          stdout=subprocess.PIPE, stderr=subprocess.DEVNULL).stdout


def merge_base():
    return git("merge-base", "HEAD", "origin/main").strip()


def is_core(path):
    return any(pattern.search(path) for pattern in CORE)


def changed_files(base=None):
    base = base or merge_base()
    tracked = git("diff", "--name-only", base).split()
    untracked = git("ls-files", "--others", "--exclude-standard").split()
    return sorted(set(tracked) | set(untracked))


def tier(files):
    """The tier by the name rules alone (no map): documents, affected, core or full."""
    if not files:
        return "documents"
    if any(ALWAYS_FULL.search(path) for path in files):
        return "full"
    if any(is_core(path) for path in files):
        return "core"
    if all(DOCUMENT.search(path) for path in files):
        return "documents"
    return "affected"


def suites_in(text):
    return [name for name in SUITE.findall(text) if name.endswith("Tests")]


def test_files(tests_root=ROOT / "Tests"):
    """{relative path: text} of the Swift test files."""
    found = {}
    for test in sorted(tests_root.rglob("*.swift")):
        relative = test.relative_to(ROOT).as_posix() if test.is_relative_to(ROOT) else str(test)
        found[relative] = test.read_text(errors="replace")
    return found


def named_suites(path, tests):
    """The name rule for one changed file: a test file's own suites; for a source file, the suites
    of any test file that names its stem (its type, by this project's one-type-per-file habit)."""
    found = set()
    if path in tests:
        found.update(suites_in(tests[path]))
    if path.startswith("Sources/") and path.endswith(".swift"):
        # An extension's file (`BlastSolver+Stepping.swift`) goes by the type it extends.
        stem = re.compile(rf"\b{re.escape(Path(path).stem.split('+')[0])}\b")
        for text in tests.values():
            if stem.search(text):
                found.update(suites_in(text))
    return found


def reading_suites(path, tests):
    """Suites whose test file reads `path` by name: a path literal that is it or a folder above it
    ("Samples/Importer"), or, for a file that isn't Swift, its file name ("Render.metal")."""
    found = set()
    name = Path(path).name
    for text in tests.values():
        literals = {literal.rstrip("/") for literal in PATH_LITERAL.findall(text)}
        if any(path == literal or path.startswith(literal + "/") for literal in literals) or (
                not path.endswith(".swift") and f'"{name}"' in text or f"/{name}\"" in text):
            found.update(suites_in(text))
    return found


def affected_suites(files, tests_root=ROOT / "Tests"):
    """The name rules over all changed files, with the ALWAYS suites."""
    tests = test_files(tests_root)
    found = set(ALWAYS)
    for path in files:
        found |= named_suites(path, tests) | reading_suites(path, tests)
    return sorted(found)


# MARK: - Selection by coverage


class Selection:
    def __init__(self):
        self.full = []  # reasons for the full check (the package)
        self.reasons = {}  # suite: [why]
        self.notes = []  # per changed file, what was made of it

    def add(self, suite, why):
        reasons = self.reasons.setdefault(suite, [])
        if why not in reasons:
            reasons.append(why)


def bare(unit):
    """`BlastCoreTests.FootingSlopeTests` → `FootingSlopeTests`."""
    return unit.split(".", 1)[1] if "." in unit else unit


class Repository:
    """What selection needs from git, at the merge base `base`, for the map at `mapped`."""

    def __init__(self, base, mapped, tests):
        self.base, self.mapped, self.tests = base, mapped, tests
        self._swift, self._libraries, self._mirrors = None, {}, None

    def touched(self, path):
        """Lines of `path` at the base that the branch changes; None when it is new on the branch."""
        if not exists(self.base, path):
            return None
        if not (ROOT / path).exists():
            return set(range(1, self.show(self.base, path).count("\n") + 2))
        file_hunks = impact.hunks(git("diff", "-U0", self.base, "--", path))
        if path.endswith(".swift"):
            return impact.touched_old_lines(file_hunks, self.show(self.base, path),
                                            (ROOT / path).read_text(errors="replace"))
        return impact.touched_old_lines(file_hunks)

    def show(self, commit, path):
        return git("show", f"{commit}:{path}", check=False)

    def to_map(self, path, lines):
        """`lines` at the base as lines at the map's commit; None when the map's commit lacks the file."""
        if not exists(self.mapped, path):
            return None
        if self.mapped == self.base:
            return set(lines)
        return impact.translate(lines, impact.hunks(git("diff", "-U0", self.mapped, self.base, "--", path)))

    def age(self, path):
        """Commits since the map's that touched `path`."""
        if self.mapped == self.base:
            return 0
        return int(git("rev-list", "--count", "--no-merges", f"{self.mapped}..{self.base}", "--", path).strip() or 0)

    def swift_files(self):
        """{path: text} of Sources/**/*.swift at the base."""
        if self._swift is None:
            paths = [path for path in git("ls-tree", "-r", "--name-only", self.base, "Sources").split()
                     if path.endswith(".swift")]
            self._swift = dict(zip(paths, cat_files(self.base, paths)))
        return self._swift

    def library(self, shader):
        """The declarations of every shader beside `shader` at the base: {path: declarations}."""
        folder = str(Path(shader).parent)
        if folder not in self._libraries:
            paths = [path for path in git("ls-tree", "-r", "--name-only", self.base, folder).split()
                     if path.endswith(".metal")]
            self._libraries[folder] = {path: impact.metal_declarations(text)
                                       for path, text in zip(paths, cat_files(self.base, paths))}
        return self._libraries[folder]

    def head_declarations(self, shader):
        """A shader's declarations in the working tree (for one new on the branch)."""
        return impact.metal_declarations((ROOT / shader).read_text(errors="replace"))

    def mirrors(self):
        """{shader struct: {Swift file at the base declaring the struct that mirrors it}}, by
        check-shader-mirrors' pairs (names, doc comments, the allow-list) in the working tree."""
        if self._mirrors is None:
            declared = {}
            for path, text in self.swift_files().items():
                for name in re.findall(r"\bstruct\s+(\w+)", text):
                    declared.setdefault(name, set()).add(path)
            self._mirrors = {}
            for swift_name, metal_name in shader_mirror_pairs():
                for path in declared.get(swift_name.split(".")[-1], ()):
                    self._mirrors.setdefault(metal_name, set()).add(path)
        return self._mirrors


def shader_mirror_pairs():
    """[(Swift struct, shader struct)] that check-shader-mirrors pairs; none if it can't say."""
    try:
        spec = importlib.util.spec_from_file_location("shader_mirrors", Path(__file__).with_name(
            "check-shader-mirrors.py"))
        mirrors = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mirrors)
        _, checked, _, _ = mirrors.check(ROOT, mirrors.ALLOW.read_text())
    except Exception as error:  # a parse it can't make leaves the loaders' rule
        print(f"check-affected: the shader mirrors could not be read ({error})", flush=True)
        return []
    return sorted({(swift_name, metal.name) for swift_name, metal, *_ in checked})


def exists(commit, path):
    return subprocess.run(["git", "cat-file", "-e", f"{commit}:{path}"], cwd=ROOT,
                          stderr=subprocess.DEVNULL).returncode == 0


def cat_files(commit, paths):
    if not paths:
        return []
    request = "".join(f"{commit}:{path}\n" for path in paths)
    output = subprocess.run(["git", "cat-file", "--batch"], cwd=ROOT, input=request.encode(),
                            stdout=subprocess.PIPE, check=True).stdout
    texts, position = [], 0
    for _ in paths:
        header_end = output.index(b"\n", position)
        size = int(output[position:header_end].split()[2])
        texts.append(output[header_end + 1:header_end + 1 + size].decode(errors="replace"))
        position = header_end + 1 + size + 1
    return texts


def covering(document, path, map_lines):
    """Suites that executed a function of `path` (at the map's commit) holding one of `map_lines`,
    with the functions; a line in no function (a declaration, a stored property, a type) counts as
    the whole file. Returns ({unit: [function names]}, whole_file)."""
    functions = document["functions"].get(path, [])
    hit, whole = set(), False
    for line in map_lines:
        inside = [index for index, (start, end, _) in enumerate(functions) if start <= line <= end]
        if inside:
            hit.update(inside)
        else:
            whole = True
    found = {}
    for unit, record in document["suites"].items():
        executed = (record.get("files") or {}).get(path)
        if not executed:
            continue
        if whole:
            found[unit] = ["(outside any function: the whole file)"]
        else:
            names = [functions[index][2] or f"line {functions[index][0]}" for index in sorted(hit & set(executed))]
            if names:
                found[unit] = names
    return found, whole


def whole_file(document, path):
    """Suites that executed any function of `path` when the map was built."""
    return sorted(unit for unit, record in document["suites"].items() if (record.get("files") or {}).get(path))


def legacy(path, tests, selection, why, document=None):
    """A changed file the map can't speak for: the name rules; for a core file the map still holds,
    every suite that ran any of it as well."""
    for suite in named_suites(path, tests):
        selection.add(suite, f"names {Path(path).stem.split('+')[0]} ({why})")
    if document is not None and is_core(path) and path in document["functions"]:
        for unit in whole_file(document, path):
            selection.add(bare(unit), f"ran {Path(path).name} ({why}: the whole file)")


def select_swift(document, path, base_lines, repository, selection, max_age, because=None):
    """Suites for Swift lines at the base; False when the file fell back to the name rules."""
    if path not in document["functions"]:
        legacy(path, repository.tests, selection, "not in the map", document)
        selection.notes.append(f"{path}: not in the map; by name")
        return False
    age = repository.age(path)
    if age > max_age:
        legacy(path, repository.tests, selection, f"changed in {age} commits since the map", document)
        selection.notes.append(f"{path}: {age} commits since the map (more than {max_age}); by name"
                               + (" and the whole file's coverage" if is_core(path) else ""))
        return False
    map_lines = repository.to_map(path, base_lines)
    if map_lines is None:
        legacy(path, repository.tests, selection, "not at the map's commit", document)
        return False
    found, whole = covering(document, path, map_lines)
    name = Path(path).name
    for unit, functions in found.items():
        shown = ", ".join(functions[:3]) + (f" and {len(functions) - 3} more" if len(functions) > 3 else "")
        selection.add(bare(unit), f"{because + ' → ' if because else ''}{name}: {shown}")
    if not because:
        selection.notes.append(f"{path}: {len(found)} suites" + (" (a change outside any function: the whole file)"
                                                                if whole else ""))
    return True


def changed_declarations(declarations, base_lines):
    """Indices of the declarations holding `base_lines` (a line past the last counts as the last)."""
    return sorted({index for line in base_lines for index, declaration in enumerate(declarations)
                   if declaration["start"] <= line <= declaration["end"]}
                  | ({len(declarations) - 1} if declarations and any(line > declarations[-1]["end"]
                                                                       for line in base_lines) else set()))


def select_shader(document, path, base_lines, repository, selection, max_age):
    library = repository.library(path)
    if path not in library:
        # New on this branch: the Swift that loads and dispatches it is new or changed too, and
        # chosen as such; here, the mirrors of the types it uses, and a suite compiling the library.
        declarations = repository.head_declarations(path)
        shader_fallback(document, path, declarations, range(len(declarations)), repository, selection,
                        "new on this branch")
        sibling = next(iter(sorted(library)), None)
        if sibling:
            compiling_suite(document, sibling, repository, selection, max_age, Path(path).name)
        return
    declarations = library[path]
    changed = changed_declarations(declarations, base_lines)
    age = repository.age(path)
    if age > max_age:
        shader_fallback(document, path, declarations, changed, repository, selection,
                        f"changed in {age} commits since the map (more than {max_age})")
        compiling_suite(document, path, repository, selection, max_age)
        return
    kernels = impact.affected_kernels(library, {path: changed})
    names = [declarations[index]["name"] or "a directive" for index in changed]
    swift = repository.swift_files()
    sites = impact.kernel_sites(kernels, swift)
    lines_by_file, unfound = {}, []
    for kernel in kernels:
        if not sites[kernel]:
            unfound.append(kernel)
        for swift_path, lines in sites[kernel].items():
            lines_by_file.setdefault(swift_path, set()).update(lines)
    shown = ", ".join(kernels[:6]) + (f" and {len(kernels) - 6} more" if len(kernels) > 6 else "")
    selection.notes.append(f"{path}: {', '.join(names[:4])}{' …' if len(names) > 4 else ''} → "
                           f"{len(kernels)} kernel(s){': ' + shown if kernels else ''}")
    for swift_path, lines in sorted(lines_by_file.items()):
        select_swift(document, swift_path, lines, repository, selection, max_age,
                     because=f"{Path(path).name} kernels")
    if unfound:
        shader_fallback(document, path, declarations, changed, repository, selection,
                        f"kernel {', '.join(unfound[:3])} dispatched from no Swift line found by name")
    compiling_suite(document, path, repository, selection, max_age)


def compiling_suite(document, path, repository, selection, max_age, shown=None):
    """The library is compiled as one: one quick suite that compiles it catches a shader that no
    longer compiles, whatever kernels the change reaches. (The digests compile the solvers' library
    too.)"""
    loaders = impact.shader_loaders(path, repository.swift_files())
    candidates = []
    for swift_path, lines in loaders.items():
        if swift_path in document["functions"] and repository.age(swift_path) <= max_age:
            mapped = repository.to_map(swift_path, lines) or set()
            found, _ = covering(document, swift_path, mapped)
            candidates += [(document["suites"][unit].get("seconds", 0), unit) for unit in found
                           if document["suites"][unit].get("status") == "passed"]
    if candidates:
        selection.add(bare(min(candidates)[1]), f"compiles {shown or Path(path).name}")
    elif loaders:
        selection.notes.append(f"{path}: no mapped suite compiles it")


def shader_fallback(document, path, declarations, changed, repository, selection, why):
    """A shader change the kernel lookup can't follow: the suites the map lists for the Swift
    mirrors of the shader types the changed declarations are or name; without any, those of the
    Swift that loads the library."""
    names = set()
    for index in changed:
        declaration = declarations[index]
        if declaration["name"]:
            names.add(declaration["name"])
        names |= declaration["references"]
    mirrors = repository.mirrors()
    files, how = sorted({swift for name in names for swift in mirrors.get(name, ())}), "mirrors it"
    if not files:
        files, how = sorted(impact.shader_loaders(path, repository.swift_files())), "loads it"
    for swift_path in files:
        units = whole_file(document, swift_path)
        for unit in units:
            selection.add(bare(unit), f"{Path(path).name} ({why}): ran {Path(swift_path).name}, which {how}")
        if not units:
            for suite in named_suites(swift_path, repository.tests):
                selection.add(suite, f"{Path(path).name} ({why}): names {Path(swift_path).stem}, which {how}")
    selection.notes.append(f"{path}: {why}; the suites of the Swift that {how}: "
                           f"{', '.join(Path(swift_path).name for swift_path in files) or 'none found'}")


def select_by_map(files, document, repository, max_age=MAX_MAP_AGE):
    selection = Selection()
    tests = repository.tests
    mapped = {bare(unit) for unit, record in document["suites"].items() if record.get("files") is not None}
    for path in files:
        if ALWAYS_FULL.search(path):
            selection.full.append(f"{path}: the package's dependencies")
            continue
        for suite in reading_suites(path, tests):
            selection.add(suite, f"reads {path}")
        if path in tests:
            for suite in suites_in(tests[path]):
                selection.add(suite, "changed test file")
            continue
        if DOCUMENT.search(path):
            continue
        is_swift = path.startswith("Sources/") and path.endswith(".swift")
        if not (is_swift or SHADER.search(path)):
            legacy(path, tests, selection, "not code the map covers")
            selection.notes.append(f"{path}: not code the map covers; by name")
            continue
        lines = repository.touched(path)
        if lines is None and is_swift:
            legacy(path, tests, selection, "new on this branch")
            selection.notes.append(f"{path}: new on this branch; by name")
            continue
        if is_swift:
            select_swift(document, path, lines, repository, selection, max_age)
        else:
            select_shader(document, path, lines or set(), repository, selection, max_age)
    if selection.reasons:
        # Suites the map has no coverage for: new since it was built, or timed out building it.
        for text in tests.values():
            for suite in suites_in(text):
                if suite not in mapped and suite not in selection.reasons:
                    selection.add(suite, "not in the map")
    for suite in ALWAYS:
        selection.add(suite, "always")
    return selection


def estimate(document, suites):
    """The selected suites' share of the map's suite-seconds."""
    seconds = {bare(unit): record.get("seconds", 0) for unit, record in document["suites"].items()}
    total = sum(seconds.values()) or 1
    return sum(seconds.get(suite, 0) for suite in suites) / total


def fetch_maps(out):
    """Copies the CI Mac's maps here, at most hourly, quietly: a failure leaves the local ones."""
    stamp = Path(out) / ".fetched"
    try:
        if stamp.exists() and time.time() - stamp.stat().st_mtime < 3600:
            return
        Path(out).mkdir(parents=True, exist_ok=True)
        stamp.touch()
    except OSError:
        return
    subprocess.run([sys.executable, str(Path(__file__).with_name("test-impact.py")), "fetch", "--out", str(out),
                    "--timeout", "20"], cwd=ROOT, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


# MARK: - Where


GPU_SLOT = Path.home() / ".local/bin/gpu-slot"
# The Studio counts as busy with this many jobs or more waiting in gpu-slot's line.
MIN_WAITING = 3
SLOT_LINE = re.compile(r"^slot (\d+): pid (\d+) .*?\((\d+) GB\)")
WAITING_LINE = re.compile(r"^waiting: pid (\d+) since [0-9:]+: (\d+) GB ")
BUDGET_LINE = re.compile(r"^memory budget (\d+) GB")


def parse_queue(text):
    """gpu-slot --status as {"held": [GB by slot held], "waiting": [GB by job waiting], "budget": GB}."""
    queue = {"held": [], "waiting": [], "budget": None}
    for line in text.splitlines():
        if match := SLOT_LINE.match(line):
            queue["held"].append(int(match.group(3)))
        elif match := WAITING_LINE.match(line):
            queue["waiting"].append(int(match.group(2)))
        elif match := BUDGET_LINE.match(line):
            queue["budget"] = int(match.group(1))
    return queue


def read_queue(gpu_slot=GPU_SLOT):
    """This Mac's gpu-slot line, or None without gpu-slot."""
    if not Path(gpu_slot).exists():
        return None
    try:
        return parse_queue(subprocess.run([str(gpu_slot), "--status"], capture_output=True, text=True,
                                          timeout=60).stdout)
    except (OSError, subprocess.SubprocessError):
        return None


def describe_queue(queue):
    declared = sum(queue["held"]) + sum(queue["waiting"])
    return (f"{len(queue['waiting'])} waiting for gpu-slot, {declared} GB declared by the "
            f"{len(queue['held'])} held and the waiting against a budget of {queue['budget']} GB")


def studio_busy(queue, min_waiting=MIN_WAITING):
    """Whether this Mac's line is long: `min_waiting` jobs or more waiting, or the held and waiting
    jobs' declared memory past its budget (so a new job would wait for memory too)."""
    declared = sum(queue["held"]) + sum(queue["waiting"])
    return len(queue["waiting"]) >= min_waiting or (queue["budget"] is not None and declared > queue["budget"])


def decide(queue, ask_remote, settings, forced=None, in_slot=False, min_waiting=MIN_WAITING, mem=None,
           host=None):
    """Where the build and tests run: ("here" or "there", why). `queue` is parse_queue's (None
    without gpu-slot); `ask_remote()` the other Mac's state (remote.py's status, None if it didn't
    answer), asked only when this Mac is busy; `mem` the job's declared GB (None: the whole Mac)."""
    if forced == "local":
        return "here", "--local"
    if forced == "remote":
        return ("there", "--remote") if host else ("here", "--remote, but no other Mac is set in remote.json")
    if in_slot:
        return "here", ("this check already holds a gpu-slot slot here (run `make check-affected` without "
                        "gpu-slot to let it choose)")
    if queue is None:
        return "here", "there is no gpu-slot line here"
    if not studio_busy(queue, min_waiting):
        return "here", f"this Mac's line is short: {describe_queue(queue)}"
    if not host:
        return "here", f"this Mac is busy ({describe_queue(queue)}), but no other Mac is set in remote.json"
    reason = remote.refusal(ask_remote(), settings, mem)
    if reason:
        return "here", f"this Mac is busy ({describe_queue(queue)}), but {host} is not free: {reason}"
    return "there", f"this Mac is busy ({describe_queue(queue)}) and {host} is free"


# MARK: - The digests (tier core)


# `blastbench digest` hashes five air scenes (open ground, a street with and without afterburning,
# a blast wall in solids and in shells, 80 steps each) to the bit, cells, peaks and impulse, and
# two walls struck to failure on their own (solids and shells, 3,000 substeps). The sets are the
# options sessions have proved changes bit-identical with: the plain and recommended air, the
# mapped start, refinement once and twice, and cut-cell terrain with gravity, refined.
DIGEST_SETS = [
    ("plain", []),
    ("recommended", ["--recommended"]),
    ("mapped", ["--recommended", "--mapped"]),
    ("refined", ["--refine", "2"]),
    ("refined twice", ["--refine", "2", "--refine-levels", "2"]),
    ("terrain", ["--recommended", "--terrain", "hill", "--gravity", "--refine", "2"]),
]
DIGEST_MEM = 4  # GB declared to gpu-slot for the digest runs
DIGEST_LINE = re.compile(r"^(?P<case>[^:\n]+): (?P<hash>[0-9a-f]+) (?P<rest>.*)$")
DIGEST_KEEP = 8  # base binaries kept in the cache
DIGEST_TIMEOUT = 30 * 60  # seconds a set may take


def digest_cache():
    return impact.STUDIO_DATA / "digest-cache" if impact.STUDIO_DATA.is_dir() else Path.home() / "bombcad-digest-cache"


def parse_digests(text):
    """{case: (hash, the rest of its line)} from `blastbench digest`'s output."""
    found = {}
    for line in text.splitlines():
        if match := DIGEST_LINE.match(line.strip()):
            found[match.group("case")] = (match.group("hash"), match.group("rest"))
    return found


def compare_digests(base, head):
    """(differences, notes) between two runs of the sets, {set: {"status", "output"}} each."""
    differences, notes = [], []
    for name, _ in DIGEST_SETS:
        old, new = base.get(name), head.get(name)
        if not old or not new:
            differences.append(f"{name}: not run {'at the base' if not old else 'on this branch'}")
            continue
        if old["status"] or new["status"]:
            side = "at the base" if old["status"] else "on this branch"
            differences.append(f"{name}: blastbench digest exited {old['status'] or new['status']} {side}")
            continue
        old_cases, new_cases = parse_digests(old["output"]), parse_digests(new["output"])
        if not old_cases or not new_cases:
            differences.append(f"{name}: no digest printed {'at the base' if not old_cases else 'on this branch'}")
            continue
        for case in sorted(set(old_cases) | set(new_cases)):
            if case not in new_cases:
                differences.append(f"{name} / {case}: at the base ({old_cases[case][0]}), not on this branch")
            elif case not in old_cases:
                notes.append(f"{name} / {case}: new on this branch ({new_cases[case][0]}), not compared")
            elif old_cases[case] != new_cases[case]:
                if "unstable" in old_cases[case][1]:
                    notes.append(f"{name} / {case}: unstable at the base, so not repeatable: not compared")
                    continue
                (old_hash, old_rest), (new_hash, new_rest) = old_cases[case], new_cases[case]
                differences.append(f"{name} / {case}: {old_hash} at the base, {new_hash} on this branch"
                                   + (f" ({old_rest} → {new_rest})" if old_rest != new_rest else ""))
    return differences, notes


def digest_runs(pairs):
    """Runs every set with each binary, writing {set: {"status", "output", "seconds"}} as JSON:
    `pairs` is [(binary, out)]. What runs under gpu-slot."""
    failed = 0
    for binary, out in pairs:
        results = {}
        for name, arguments in DIGEST_SETS:
            started = time.monotonic()
            print(f"+ {binary} digest {' '.join(arguments)}", flush=True)
            try:
                completed = subprocess.run([str(binary), "digest", *arguments], cwd=ROOT, text=True,
                                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                           timeout=DIGEST_TIMEOUT)
                status, output = completed.returncode, completed.stdout
            except subprocess.TimeoutExpired as error:
                status, output = "timed out", (error.stdout or b"").decode(errors="replace")
            failed |= bool(status)
            results[name] = {"status": status, "output": output, "seconds": round(time.monotonic() - started, 1)}
        Path(out).write_text(json.dumps(results, indent=1) + "\n")
    return 1 if failed else 0


def bin_path(source, configuration="release"):
    return Path(subprocess.run(["swift", "build", "-c", configuration, "--show-bin-path"], cwd=source, check=True,
                               text=True, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL).stdout.strip())


class DigestCheck:
    """The digests of this branch against its merge base's. Output goes to `stream` (a file, when
    it runs beside the steps on the other Mac), else here."""

    def __init__(self, base, cache=None, stream=None, in_slot=False):
        self.base, self.cache, self.stream, self.in_slot = base, Path(cache or digest_cache()), stream, in_slot

    def say(self, text):
        print(text, file=self.stream or sys.stdout, flush=True)

    def call(self, command, cwd=ROOT):
        self.say("+ " + " ".join(str(part) for part in command))
        return subprocess.run([str(part) for part in command], cwd=cwd, stdout=self.stream,
                              stderr=subprocess.STDOUT if self.stream else None).returncode

    def build(self, source):
        """blastbench built for release in `source`: its path, or None."""
        if self.call(["swift", "build", "-c", "release", "--product", "blastbench"], cwd=source):
            return None
        return bin_path(source) / "blastbench"

    def base_folder(self):
        return self.cache / self.base

    def base_binary(self):
        """The merge base's release blastbench, built once into the cache (a clone of this
        repository at digest-cache/source, checked out at each base in turn, so its build is
        incremental) and kept with its resource bundles in digest-cache/<commit>/."""
        target = self.base_folder()
        if (target / "complete").exists():
            return target / "blastbench"
        self.cache.mkdir(parents=True, exist_ok=True)
        with open(self.cache / "build.lock", "w") as lock:
            self.say(f"digests: building the base {self.base[:12]} for release (one build at a time)")
            fcntl.flock(lock, fcntl.LOCK_EX)
            if (target / "complete").exists():
                return target / "blastbench"
            source = self.cache / "source"
            common = Path(git("rev-parse", "--git-common-dir").strip())
            common = common if common.is_absolute() else (ROOT / common).resolve()
            if not (source / ".git").exists() and self.call(
                    ["git", "clone", "--quiet", "--no-checkout", common, source]):
                return None
            for command in (["git", "-C", source, "fetch", "--quiet", common,
                             "+refs/remotes/origin/*:refs/remotes/origin/*", "+refs/heads/*:refs/remotes/local/*"],
                            ["git", "-C", source, "checkout", "--quiet", "--force", "--detach", self.base],
                            ["git", "-C", source, "clean", "-fdq"]):
                if self.call(command):
                    return None
            binary = self.build(source)
            if binary is None:
                return None
            partial = self.cache / f".{self.base}.partial"
            shutil.rmtree(partial, ignore_errors=True)
            partial.mkdir()
            shutil.copy2(binary, partial / "blastbench")
            for bundle in binary.parent.glob("*.bundle"):
                shutil.copytree(bundle, partial / bundle.name, symlinks=True)
            (partial / "complete").write_text(json.dumps({"commit": self.base, "built": time.strftime("%Y-%m-%d %H:%M"),
                                                          "host": socket.gethostname()}) + "\n")
            shutil.rmtree(target, ignore_errors=True)
            partial.rename(target)
        self.prune()
        return target / "blastbench"

    def prune(self, keep=DIGEST_KEEP):
        folders = sorted((path for path in self.cache.iterdir() if re.fullmatch(r"[0-9a-f]{40}", path.name)),
                         key=lambda path: path.stat().st_mtime)
        for old in folders[:-keep]:
            shutil.rmtree(old, ignore_errors=True)

    def base_digests_path(self):
        return self.base_folder() / f"digests-{socket.gethostname().split('.')[0]}.json"

    def describe(self):
        """What a run would do, for --dry-run."""
        folder = self.base_folder()
        built = (folder / "complete").exists()
        cached = self.base_digests_path().exists()
        return (f"digests: {len(DIGEST_SETS)} sets of blastbench digest ({', '.join(name for name, _ in DIGEST_SETS)}) "
                f"on this branch's release build against the base {self.base[:12]}'s, bit for bit, here under "
                f"gpu-slot; the base's binary {'is cached' if built else 'is to build'}"
                + (f" and its digests on this Mac too" if cached else "") + f" ({folder})")

    def run(self):
        started = time.monotonic()
        head = self.build(ROOT)
        if head is None:
            self.say("check-affected: FAILED at the release build of blastbench, for the digests")
            return 1
        base = self.base_binary()
        if base is None:
            self.say(f"check-affected: FAILED building the base {self.base[:12]} for the digests")
            return 1
        cached = self.base_digests_path()
        with tempfile.TemporaryDirectory(prefix="check-affected-digests-") as work:
            pairs = [(head, Path(work) / "head.json")]
            if not cached.exists():
                pairs.append((base, Path(work) / "base.json"))
            command = [sys.executable, str(Path(__file__).resolve()), "digest-runs",
                       *[f"--run={binary}={out}" for binary, out in pairs]]
            if not self.in_slot and GPU_SLOT.exists():
                command = [str(GPU_SLOT), "--mem", str(DIGEST_MEM), *command]
            self.call(command)
            try:
                head_results = json.loads(pairs[0][1].read_text())
                base_results = json.loads((pairs[1][1] if len(pairs) > 1 else cached).read_text())
            except (OSError, ValueError) as error:
                self.say(f"check-affected: FAILED: the digest runs left no results ({error})")
                return 1
        if len(pairs) > 1 and all(not record["status"] for record in base_results.values()):
            cached.parent.mkdir(parents=True, exist_ok=True)
            temporary = cached.with_suffix(".tmp")
            temporary.write_text(json.dumps(base_results, indent=1) + "\n")
            temporary.replace(cached)
        differences, notes = compare_digests(base_results, head_results)
        for note in notes:
            self.say(f"  digests: {note}")
        compared = sum(len(parse_digests(record["output"])) for record in head_results.values())
        if differences:
            self.say(f"check-affected: FAILED: the digests differ from the base {self.base[:12]}'s in "
                     f"{len(differences)} variant(s):")
            for difference in differences:
                self.say(f"  {difference}")
            self.say("  (a change meant to move results needs `ARGS=--full`, and the reason in its commit)")
            return 1
        self.say(f"check-affected: digests bit-identical to the base {self.base[:12]}'s: {compared} variants in "
                 f"{len(DIGEST_SETS)} sets, {time.monotonic() - started:.0f} s"
                 + (" (the base's digests from the cache)" if len(pairs) == 1 else ""))
        return 0


# MARK: - Running


def run(command, env=None):
    print("+", " ".join(command), flush=True)
    return subprocess.run(command, cwd=ROOT, env=env).returncode


def steps(suites):
    """The build and test steps, which may run on the other Mac."""
    return [["make", "build-strict"], ["make", "ifc-converter"],
            ["swift", "test", "--filter", r"\.(" + "|".join(suites) + r")(/|$)"]]


def run_steps(suites):
    for step in steps(suites):
        status = run(step)
        if status:
            print(f"check-affected: FAILED at {' '.join(step)}", flush=True)
            return status
    return 0


def run_where(where, host, settings, local, remote_command, mem, wait):
    """Runs `local` here, or `remote_command` on `host`, back here if that was taken meanwhile:
    (exit status, where it ran)."""
    started = time.time()
    if where == "there":
        status = remote.check_remote(host, settings, "check-affected-steps", wait, command=remote_command, mem=mem)
        if status != 75:
            print(f"check-affected: on {host} in {time.time() - started:.0f} s, copying and waiting included",
                  flush=True)
            return status, "there"
        print(f"check-affected: {host} was taken meanwhile; running here", flush=True)
    status = local()
    print(f"check-affected: here in {time.time() - started:.0f} s, waiting for gpu-slot included", flush=True)
    return status, "here"


def plan(arguments):
    """(level, suites, lines to print, base)."""
    base = arguments.base or merge_base()
    files = changed_files(base)
    level = "full" if arguments.full else tier(files)
    lines = [f"check-affected: {len(files)} changed file(s)"]
    if arguments.full or level in ("documents", "full"):
        if level == "full" and not arguments.full:
            lines += [f"  full check: {path}: the package's dependencies" for path in files if ALWAYS_FULL.search(path)]
        return level, [], lines, base
    if not arguments.no_map:
        fetch_maps(arguments.maps)
    document = None if arguments.no_map else impact.newest_map(arguments.maps, base)
    if document is None:
        lines.append("  --no-map: the name rules" if arguments.no_map else
                     f"  no test-impact map at or behind the merge base in {arguments.maps}: the name rules")
        return level, affected_suites(files), lines, base
    repository = Repository(base, document["commit"], test_files())
    selection = select_by_map(files, document, repository, arguments.max_map_age)
    lines.append(f"  map {document['commit'][:12]} ({document['distance']} commits behind the merge base, built "
                 f"{document['built']} on {document['host']})")
    lines += [f"  {note}" for note in selection.notes]
    if selection.full:
        lines += [f"  full check: {reason}" for reason in selection.full]
        return "full", [], lines, base
    suites = sorted(selection.reasons)
    share = estimate(document, suites)
    shown = "under 1%" if share < 0.01 else f"about {share:.0%}"
    lines.append(f"  {len(suites)} of {len(document['suites'])} suites, {shown} of the suites' time in the map:")
    for suite in suites:
        reasons = selection.reasons[suite]
        lines.append(f"    {suite}: {'; '.join(reasons[:2])}{' …' if len(reasons) > 2 else ''}")
    return ("core" if level == "core" else "covered"), suites, lines, base


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    # `check-steps`: the build and test steps alone, for the suites in --suites or
    # $CHECK_AFFECTED_SUITES; what runs under gpu-slot here, or on the other Mac.
    # `digest-runs`: the digest sets run with each --run=<binary>=<out.json>; what runs under gpu-slot.
    parser.add_argument("command", nargs="?", choices=["check-steps", "digest-runs"], help=argparse.SUPPRESS)
    parser.add_argument("--suites", help=argparse.SUPPRESS)
    parser.add_argument("--run", action="append", default=[], help=argparse.SUPPRESS)
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--full", action="store_true", help="the full check, whatever changed")
    parser.add_argument("--base", help="compare with this commit instead of the merge base with origin/main")
    parser.add_argument("--no-map", action="store_true", help="choose suites by name, as without a map")
    parser.add_argument("--maps", type=Path, default=impact.default_out(), help="where the maps are")
    parser.add_argument("--max-map-age", type=int, default=MAX_MAP_AGE,
                        help="commits touching a changed file since the map, beyond which that file goes by name")
    parser.add_argument("--digest-cache", type=Path, default=None, help="where the bases' binaries and digests are kept")
    where_group = parser.add_mutually_exclusive_group()
    where_group.add_argument("--local", action="store_true", help="run the build and tests here, under gpu-slot")
    where_group.add_argument("--remote", action="store_true",
                             help="run the build and tests on the other Mac (remote.json), waiting for it if taken")
    parser.add_argument("--min-waiting", type=int, default=MIN_WAITING,
                        help="jobs waiting for gpu-slot from which this Mac counts as busy")
    arguments = parser.parse_args()
    if arguments.command == "check-steps":
        listed = arguments.suites if arguments.suites is not None else os.environ.get("CHECK_AFFECTED_SUITES", "")
        return run_steps([suite for suite in listed.split(",") if suite])
    if arguments.command == "digest-runs":
        return digest_runs([tuple(item.rsplit("=", 1)) for item in arguments.run])
    if arguments.base:
        arguments.base = git("rev-parse", arguments.base).strip()
    level, suites, lines, base = plan(arguments)
    lines[0] += f", tier: {level}"
    print("\n".join(lines))
    if level == "affected" and suites:
        print("  suites: " + ", ".join(suites))
    settings = remote.config()
    host = os.environ.get("BOMBCAD_REMOTE_HOST") or settings["host"]
    in_slot = bool(os.environ.get("GPU_SLOT_TICKET"))
    forced = "local" if arguments.local else "remote" if arguments.remote else None
    if level == "documents":
        where, why = "here", None
    elif level == "full" and in_slot and not forced:
        where, why = "anywhere", "it already holds a gpu-slot slot here, so `make check-anywhere` chooses, as before"
    else:
        # A full check takes the other Mac whole; the build and tests declare a lane's memory.
        mem = None if level == "full" else settings["laneGB"]
        where, why = decide(read_queue(), lambda: remote.remote_status(host, settings), settings, forced, in_slot,
                            arguments.min_waiting, mem, host)
    if level == "documents":
        print("  runs here: lint and ci-test only", flush=True)
    else:
        print(f"  {'the full check' if level == 'full' else 'build and tests'} "
              f"{'on ' + host if where == 'there' else 'here or there' if where == 'anywhere' else 'here'}, "
              f"since {why}", flush=True)
    digests = DigestCheck(base, arguments.digest_cache, in_slot=in_slot) if level == "core" else None
    if digests:
        print("  " + digests.describe(), flush=True)
    if arguments.dry_run:
        return 0
    wait = 7200 if forced == "remote" else 0

    def slotted(command):  # under gpu-slot here, unless already in a slot or without one
        return command if in_slot or not GPU_SLOT.exists() else [str(GPU_SLOT), *command]

    if level == "full":
        if where == "anywhere":
            return run(["make", "check-anywhere"])
        return run_where(where, host, settings, lambda: run(slotted(["make", "check"])), ["make", "check"], None,
                         wait)[0]
    # Lint and the scripts' tests are quick, and stay here.
    for step in (["make", "lint"], ["make", "ci-test"]):
        status = run(step)
        if status:
            print(f"check-affected: FAILED at {' '.join(step)}")
            return status
    ran = "here"
    beside = None
    if digests and where == "there":
        # The steps go to the other Mac: the digests run here meanwhile, their output kept until the
        # steps are done.
        log = tempfile.TemporaryFile(mode="w+")
        digests.stream = log
        beside = {"thread": threading.Thread(target=lambda: beside.update(status=digests.run()), daemon=True),
                  "log": log, "status": 1}
        beside["thread"].start()
    if level in ("affected", "covered", "core"):
        # The suites go in the environment here, so that gpu-slot learns one command's memory.
        environment = dict(os.environ, CHECK_AFFECTED_SUITES=",".join(suites))
        status, ran = run_where(
            where, host, settings,
            lambda: run(slotted([sys.executable, "Scripts/check-affected.py", "check-steps"]), env=environment),
            ["python3", "Scripts/check-affected.py", "check-steps", "--suites", ",".join(suites)],
            settings["laneGB"], wait)
        if beside:
            beside["thread"].join()
            beside["log"].seek(0)
            print(beside["log"].read(), end="", flush=True)
            if beside["status"] and not status:
                status = beside["status"]
        if status:
            return status
    if digests and not beside:
        status = digests.run()
        if status:
            return status
    print(f"check-affected: passed ({level}{', build and tests on ' + host if ran == 'there' else ''}"
          f"{', digests bit-identical' if digests else ''})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
