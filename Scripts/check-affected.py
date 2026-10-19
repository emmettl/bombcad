"""The pre-push check sized to the change: the tests that execute what changed.

    ~/.local/bin/gpu-slot make check-affected

It looks at what this branch changes against origin/main (committed, staged, unstaged and
untracked files) and runs one of four tiers:

- documents and Python scripts only (docs/, Markdown, images, Scripts/*.py, the reference
  calculations in Scripts/reference/ and their tables, the analytic oracles in
  Scripts/analytic/): lint and the scripts' tests and links (`ci-test`); no Swift build, no GPU.
- covered, when a test-impact map (Scripts/test-impact.py) exists for the merge base or a commit
  behind it: lint, the strict build, `ci-test`, and the Swift suites that executed a changed
  function when the map was built. A shader change counts as a change to the Swift lines that
  dispatch the kernels it can reach. Plus the suites in changed test files, those whose test files
  read a changed file by its path, those the map has no coverage for, and a few that many changes
  trip (the standing and the shader layouts).
- affected, with no usable map: the same, but choosing the suites that name a changed file's type.
- full: the package's dependencies (Package.swift, Package.resolved), and, without a usable map
  for them, the core (shaders, the solvers' shared types): `make check-anywhere`.

A changed file falls back to the name rules (and a core file to the full check) when the map
doesn't know it or more than --max-map-age commits have touched it since the map was built.

The full check still runs nightly on the mini and before every release; this only decides what a
push waits for. `--dry-run` prints the tier and the suites, with why each was chosen, without
running anything; `--full` forces the full check (through make: `make check-affected ARGS=--dry-run`).
"""

import argparse
import importlib.util
from pathlib import Path
import re
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("test_impact", Path(__file__).with_name("test-impact.py"))
impact = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(impact)

# Files whose change can move any result: the full check, without a map that covers them.
CORE = [
    re.compile(r"^Package\.(swift|resolved)$"),
    re.compile(r"^Sources/[^/]+/Shaders/"),
    re.compile(r"^Sources/BlastCore/(BlastSolver|SolverTypes|StructureSolver|StructureTypes|"
               r"ShellSolver|Scenario|MappedStart|Refinement|StructuralBody)\.swift$"),
    re.compile(r"^Sources/RadialBlast/"),
]
# The package and its pins: the full check even with a map (a new ContinuumKit moves what the
# map's coverage can't see, its shader source among it).
ALWAYS_FULL = re.compile(r"^Package\.(swift|resolved)$")
SHADER = re.compile(r"^Sources/[^/]+/Shaders/[^/]+\.metal$")
# Documents and the Python scripts, which ci-test covers on its own.
DOCUMENT = re.compile(r"(^docs/|\.md$|\.png$|\.jpg$|\.svg$|^LICENSE$|^Scripts/(analytic/|reference/)?[^/]+\.py$|"
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


def changed_files(base=None):
    base = base or merge_base()
    tracked = git("diff", "--name-only", base).split()
    untracked = git("ls-files", "--others", "--exclude-standard").split()
    return sorted(set(tracked) | set(untracked))


def tier(files):
    """The tier by the name rules alone (no map): documents, affected or full."""
    if not files:
        return "documents"
    if any(pattern.search(path) for path in files for pattern in CORE):
        return "full"
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
        stem = re.compile(rf"\b{re.escape(Path(path).stem)}\b")
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
        self.full = []  # reasons for the full check
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
        self._swift, self._libraries = None, {}

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


def legacy(path, tests, selection, why):
    """A changed file the map can't speak for: the name rules, and the full check for a core file."""
    if any(pattern.search(path) for pattern in CORE):
        selection.full.append(f"{path} {why} (core)")
        return
    for suite in named_suites(path, tests):
        selection.add(suite, f"names {Path(path).stem} ({why})")


def select_swift(document, path, base_lines, repository, selection, max_age, because=None):
    """Suites for Swift lines at the base; False when the file fell back to the name rules."""
    if path not in document["functions"]:
        legacy(path, repository.tests, selection, "not in the map")
        selection.notes.append(f"{path}: not in the map; by name")
        return False
    age = repository.age(path)
    if age > max_age:
        legacy(path, repository.tests, selection, f"changed in {age} commits since the map")
        selection.notes.append(f"{path}: {age} commits since the map (more than {max_age}); by name")
        return False
    map_lines = repository.to_map(path, base_lines)
    if map_lines is None:
        legacy(path, repository.tests, selection, "not at the map's commit")
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


def select_shader(document, path, base_lines, repository, selection, max_age):
    library = repository.library(path)
    if path not in library:
        selection.full.append(f"{path} is new on this branch")
        return
    declarations = library[path]
    changed = sorted({index for line in base_lines for index, declaration in enumerate(declarations)
                      if declaration["start"] <= line <= declaration["end"]}
                     | ({len(declarations) - 1} if any(line > declarations[-1]["end"] for line in base_lines) else set()))
    kernels = impact.affected_kernels(library, {path: changed})
    names = [declarations[index]["name"] or "a directive" for index in changed]
    swift = repository.swift_files()
    sites = impact.kernel_sites(kernels, swift)
    lines_by_file = {}
    for kernel in kernels:
        if not sites[kernel]:
            selection.full.append(f"{path}: kernel {kernel} is dispatched from no Swift line found by name")
        for swift_path, lines in sites[kernel].items():
            lines_by_file.setdefault(swift_path, set()).update(lines)
    shown = ", ".join(kernels[:6]) + (f" and {len(kernels) - 6} more" if len(kernels) > 6 else "")
    selection.notes.append(f"{path}: {', '.join(names[:4])}{' …' if len(names) > 4 else ''} → "
                           f"{len(kernels)} kernel(s){': ' + shown if kernels else ''}")
    for swift_path, lines in sorted(lines_by_file.items()):
        select_swift(document, swift_path, lines, repository, selection, max_age,
                     because=f"{Path(path).name} kernels")
    # The library is compiled as one: one quick suite that compiles it catches a shader that no
    # longer compiles, whatever kernels the change reaches.
    loaders = impact.shader_loaders(path, swift)
    candidates = []
    for swift_path, lines in loaders.items():
        if swift_path in document["functions"] and repository.age(swift_path) <= max_age:
            mapped = repository.to_map(swift_path, lines) or set()
            found, _ = covering(document, swift_path, mapped)
            candidates += [(document["suites"][unit].get("seconds", 0), unit) for unit in found
                           if document["suites"][unit].get("status") == "passed"]
    if candidates:
        selection.add(bare(min(candidates)[1]), f"compiles {Path(path).name}")
    elif loaders:
        selection.full.append(f"{path}: no mapped suite compiles it")


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
        if lines is None:
            legacy(path, tests, selection, "new on this branch")
            selection.notes.append(f"{path}: new on this branch; by name")
            continue
        if is_swift:
            select_swift(document, path, lines, repository, selection, max_age)
        else:
            age = repository.age(path)
            if age > max_age:
                selection.full.append(f"{path}: changed in {age} commits since the map (more than {max_age})")
                continue
            select_shader(document, path, lines, repository, selection, max_age)
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


# MARK: - Running


def run(command):
    print("+", " ".join(command), flush=True)
    return subprocess.run(command, cwd=ROOT).returncode


def plan(arguments):
    """(level, suites, lines to print)."""
    base = merge_base()
    files = changed_files(base)
    level = "full" if arguments.full else tier(files)
    lines = [f"check-affected: {len(files)} changed file(s)"]
    if arguments.full or level == "documents":
        return level, [], lines
    if not arguments.no_map:
        fetch_maps(arguments.maps)
    document = None if arguments.no_map else impact.newest_map(arguments.maps, base)
    if document is None:
        lines.append("  --no-map: the name rules" if arguments.no_map else
                     f"  no test-impact map at or behind the merge base in {arguments.maps}: the name rules")
        suites = affected_suites(files) if level == "affected" else []
        return level, suites, lines
    repository = Repository(base, document["commit"], test_files())
    selection = select_by_map(files, document, repository, arguments.max_map_age)
    lines.append(f"  map {document['commit'][:12]} ({document['distance']} commits behind the merge base, built "
                 f"{document['built']} on {document['host']})")
    lines += [f"  {note}" for note in selection.notes]
    if selection.full:
        lines += [f"  full check: {reason}" for reason in selection.full]
        return "full", [], lines
    suites = sorted(selection.reasons)
    share = estimate(document, suites)
    shown = "under 1%" if share < 0.01 else f"about {share:.0%}"
    lines.append(f"  {len(suites)} of {len(document['suites'])} suites, {shown} of the suites' time in the map:")
    for suite in suites:
        reasons = selection.reasons[suite]
        lines.append(f"    {suite}: {'; '.join(reasons[:2])}{' …' if len(reasons) > 2 else ''}")
    return "covered", suites, lines


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--full", action="store_true")
    parser.add_argument("--no-map", action="store_true", help="choose suites by name, as without a map")
    parser.add_argument("--maps", type=Path, default=impact.default_out(), help="where the maps are")
    parser.add_argument("--max-map-age", type=int, default=MAX_MAP_AGE,
                        help="commits touching a changed file since the map, beyond which that file goes by name")
    arguments = parser.parse_args()
    level, suites, lines = plan(arguments)
    lines[0] += f", tier: {level}"
    print("\n".join(lines))
    if level == "affected" and suites:
        print("  suites: " + ", ".join(suites))
    if arguments.dry_run:
        return 0
    if level == "full":
        return run(["make", "check-anywhere"])
    steps = [["make", "lint"], ["make", "ci-test"]]
    if level in ("affected", "covered"):
        steps.insert(1, ["make", "build-strict"])
        steps.append(["make", "ifc-converter"])
        steps.append(["swift", "test", "--filter", r"\.(" + "|".join(suites) + r")(/|$)"])
    for step in steps:
        status = run(step)
        if status:
            print(f"check-affected: FAILED at {' '.join(step)}")
            return status
    print(f"check-affected: passed ({level})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
