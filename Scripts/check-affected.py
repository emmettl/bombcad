"""The pre-push check sized to the change: the full check only where the solver's core moved.

    ~/.local/bin/gpu-slot make check-affected

It looks at what this branch changes against origin/main (committed, staged, unstaged and
untracked files) and runs one of three tiers:

- documents and Python scripts only (docs/, Markdown, images, Scripts/*.py): lint and the
  scripts' tests and links (`ci-test`); no Swift build, no GPU.
- code outside the core: lint, the strict build, `ci-test`, and the Swift tests that name a changed
  file's type or live in a changed test file, plus a few that many changes trip (the standing and
  the shader layouts).
- the core (shaders, the solvers' shared types, the package's dependencies): the full check, as
  `make check-anywhere`.

The full check still runs nightly on the mini and before every release; this only decides what a
push waits for. `--dry-run` prints the tier and the tests without running anything; `--full`
forces the full check.
"""

import argparse
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

# Files whose change can move any result: the full check.
CORE = [
    re.compile(r"^Package\.(swift|resolved)$"),
    re.compile(r"^Sources/[^/]+/Shaders/"),
    re.compile(r"^Sources/BlastCore/(BlastSolver|SolverTypes|StructureSolver|StructureTypes|"
               r"ShellSolver|Scenario|MappedStart|Refinement|StructuralBody)\.swift$"),
    re.compile(r"^Sources/RadialBlast/"),
]
# Documents and the Python scripts, which ci-test covers on its own.
DOCUMENT = re.compile(r"(^docs/|\.md$|\.png$|\.jpg$|\.svg$|^LICENSE$|^Scripts/[^/]+\.py$)")
# Suites that changes elsewhere often trip: the standing parses the docs and options, the
# layout test guards the renderer's copies of the solver's structs.
ALWAYS = ["StandingFingerprintTests", "EvidentialStandingTests", "StandingRunTests",
          "ErrorBandTests", "RenderLayoutTests"]
SUITE = re.compile(r"^\s*(?:@Suite[^\n]*\n\s*)?(?:@MainActor\s+)?(?:final\s+)?(?:struct|class)\s+(\w+)",
                   re.MULTILINE)


def git(*arguments):
    return subprocess.run(["git", *arguments], cwd=ROOT, check=True, text=True,
                          stdout=subprocess.PIPE).stdout


def changed_files():
    base = git("merge-base", "HEAD", "origin/main").strip()
    tracked = git("diff", "--name-only", base).split()
    untracked = git("ls-files", "--others", "--exclude-standard").split()
    return sorted(set(tracked) | set(untracked))


def tier(files):
    if not files:
        return "documents"
    if any(pattern.search(path) for path in files for pattern in CORE):
        return "full"
    if all(DOCUMENT.search(path) for path in files):
        return "documents"
    return "affected"


def suites_in(text):
    return [name for name in SUITE.findall(text) if name.endswith("Tests")]


def affected_suites(files, tests_root=ROOT / "Tests"):
    """Suites in changed test files, and suites in any test file that names a changed source
    file's stem (its type, by this project's one-type-per-file habit)."""
    stems = {Path(path).stem for path in files
             if path.startswith("Sources/") and path.endswith(".swift")}
    found = set(ALWAYS)
    for test in sorted(tests_root.rglob("*.swift")):
        relative = test.relative_to(ROOT).as_posix() if test.is_relative_to(ROOT) else str(test)
        text = test.read_text(errors="replace")
        if relative in files or any(re.search(rf"\b{re.escape(stem)}\b", text) for stem in stems):
            found.update(suites_in(text))
    return sorted(found)


def run(command):
    print("+", " ".join(command), flush=True)
    return subprocess.run(command, cwd=ROOT).returncode


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--full", action="store_true")
    arguments = parser.parse_args()
    files = changed_files()
    level = "full" if arguments.full else tier(files)
    suites = affected_suites(files) if level == "affected" else []
    print(f"check-affected: {len(files)} changed file(s), tier: {level}")
    if suites:
        print("  suites: " + ", ".join(suites))
    if arguments.dry_run:
        return 0
    if level == "full":
        return run(["make", "check-anywhere"])
    steps = [["make", "lint"], ["make", "ci-test"]]
    if level == "affected":
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
