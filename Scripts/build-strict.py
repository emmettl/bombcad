"""Builds the package with its tests and fails on any compiler warning in its own code.

    python3 Scripts/build-strict.py [swift build arguments...]

SwiftPM suppresses the warnings of remote dependencies (ContinuumKit), so what is left is ours:
a warning in Sources/ or Tests/ fails the build, with each one listed once. Only files compiled
in this build can warn, so an incremental build catches what a change brings and a clean build
(`rm -rf .build`) everything. The package had none on 2026-10-12.

A warning raised inside a macro's expansion (`#expect`, say) names the expansion rather than a
file; it counts against the file and line the next line says the expanded code originates from.
"""

import os
import re
import subprocess
import sys

ANSI = re.compile(r"\x1b\[[0-9;]*m|\x1b\]8;;[^\x1b]*\x1b\\")
# The two forms swift build prints: the compiler's own, and the build system's summary.
COMPILER = re.compile(r"^(/\S+?\.swift):(\d+):(\d+): warning: (.*)$")
SUMMARY = re.compile(r"^warning: (/\S+?\.swift):(\d+):(\d+) (.*?)(: FixIt\(.*)?$")
# A warning in a macro's expansion, and the note after it that says where the expanded code is.
MACRO = re.compile(r"^macro expansion [^:]+:\d+:\d+: warning: (.*)$")
ORIGIN = re.compile(r"^`- (/\S+?\.swift):(\d+):(\d+): note: expanded code originates here")


def warnings(lines, root):
    """The distinct warnings in `lines` from files under `root`: (path from root, line, message)."""
    found = {}
    prefix = root.rstrip("/") + "/"
    lines = [ANSI.sub("", line.rstrip("\n")) for line in lines]
    for index, line in enumerate(lines):
        match = COMPILER.match(line) or SUMMARY.match(line)
        if match:
            path, number, message = match.group(1), match.group(2), match.group(4)
        elif (macro := MACRO.match(line)) and index + 1 < len(lines) and (
                origin := ORIGIN.match(lines[index + 1])):
            path, number, message = origin.group(1), origin.group(2), macro.group(1)
        else:
            continue
        if not path.startswith(prefix) or "/.build/" in path:
            continue
        message = re.sub(r"\s*\[#?\]?\S*$", "", message).strip()
        found[(path[len(prefix):], int(number), message)] = None
    return sorted(found)


def main(arguments):
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    process = subprocess.Popen(
        ["swift", "build", "--build-tests", *arguments], cwd=root, stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT, text=True, errors="replace")
    lines = []
    for line in process.stdout:
        sys.stdout.write(line)
        lines.append(line)
    code = process.wait()
    if code != 0:
        return code
    found = warnings(lines, root)
    if found:
        print("\nbuild-strict: %d warning%s in this package's code:" % (len(found), "" if len(found) == 1 else "s"))
        for path, number, message in found:
            print("  %s:%d: %s" % (path, number, message))
        return 1
    print("build-strict: no warnings")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
