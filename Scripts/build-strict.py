"""Builds the package with its tests and fails on any compiler warning in its own code.

    python3 Scripts/build-strict.py [swift build arguments...]

SwiftPM suppresses the warnings of remote dependencies (ContinuumKit), so what is left is ours:
a warning in Sources/ or Tests/ fails the build, with each one listed once. Only files compiled
in this build can warn, so an incremental build catches what a change brings and a clean build
(`rm -rf .build`) everything. The package had none on 2026-10-12.
"""

import os
import re
import subprocess
import sys

ANSI = re.compile(r"\x1b\[[0-9;]*m|\x1b\]8;;[^\x1b]*\x1b\\")
# The two forms swift build prints: the compiler's own, and the build system's summary.
COMPILER = re.compile(r"^(/\S+?\.swift):(\d+):(\d+): warning: (.*)$")
SUMMARY = re.compile(r"^warning: (/\S+?\.swift):(\d+):(\d+) (.*?)(: FixIt\(.*)?$")


def warnings(lines, root):
    """The distinct warnings in `lines` from files under `root`: (path from root, line, message)."""
    found = {}
    prefix = root.rstrip("/") + "/"
    for line in lines:
        line = ANSI.sub("", line.rstrip("\n"))
        match = COMPILER.match(line) or SUMMARY.match(line)
        if not match:
            continue
        path, number, _, message = match.group(1), match.group(2), match.group(3), match.group(4)
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
