#!/usr/bin/env python3
"""Check that no test can fail because the Mac is slow: no wall-clock bound in Tests/.

    Scripts/check-test-deadlines.py [--root DIR] [--allow FILE]

The Studio runs many test jobs at once, at load averages of 50 to 250, and a test process can
stall for a minute, so how long a step takes says nothing about whether it is right. The tests
wait for the state they are about, with the suite's hang limit as the only bound (ten minutes for
the app's, Tests/BombCADTests/Waiting.swift; two hours for the core's), and assert on causes (a
typed error, a state), not on elapsed time. Reported, in the Swift sources under Tests/:

  time-limit     a `.timeLimit(...)` trait shorter than its target's hang limit, or not a literal
  elapsed-bound  an upper bound on elapsed wall-clock time: `ContinuousClock.now - start < x`,
                 `Date().timeIntervalSince(start) < x`, `start.duration(to: .now) < x`, or a name
                 assigned from one of those on the left of `<`/`<=` (or the right of `>`/`>=`).
                 A lower bound (`took >= limit`: a deadline never comes early) is not reported:
                 a slow Mac only makes it hold the better
  deadline       a deadline made in a test: `ContinuousClock.now + x`, `.now() + x`,
                 `Date().addingTimeInterval`, `Date(timeIntervalSinceNow:)`, `.wait(timeout:)`,
                 `Task.sleep(until:)`
  long-sleep     a fixed sleep of a second or more, which is a wait for time to pass rather than
                 for a condition
  bounded-wait   a poll that gives up after a count of sleeps (`for _ in 0..<50 { sleep(10 ms) }`):
                 a deadline by another name

Comments and string literals are ignored. Exits 1 on any finding the allow-list
(Scripts/test-deadlines-allow.txt) does not name with a reason, and on allow-list lines that no
longer match anything, so the list stays current.

A name is followed from an elapsed time assigned to it, or from a call of a function in the same
file that returns one (each name a tuple it returns is taken apart into).

Limitations: a bound reached through a function in another file, a property, or a comparison
split over lines from the elapsed time it bounds is not followed; a sleep
used as a short wait for a result (`sleep(300 ms)`, then `#expect`) cannot be told from one that
checks nothing happens, and is left to review."""

import argparse
import re
import sys
from dataclasses import dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ALLOW = Path(__file__).with_name("test-deadlines-allow.txt")

# Each test target's hang limit, in minutes; a target not named takes the smallest.
HANG_LIMITS = {"BombCADTests": 10, "BlastCoreTests": 120, "BlastModelTests": 120}
DEFAULT_HANG_LIMIT = min(HANG_LIMITS.values())

ELAPSED = [
    re.compile(r"\bContinuousClock\.now\s*-(?!=)"),
    re.compile(r"\b\w+\.now\s*-(?!=)\s*\w"),
    re.compile(r"\.duration\(\s*to:\s*(?:ContinuousClock)?\.now\s*\)"),
    re.compile(r"\.timeIntervalSince\("),
    re.compile(r"\.timeIntervalSinceNow\b"),
    re.compile(r"\bCFAbsoluteTimeGetCurrent\(\)\s*-"),
    re.compile(r"\.uptimeNanoseconds\s*-"),
]
DEADLINE = [
    re.compile(r"\bContinuousClock\.now\s*\+(?!=)"),
    re.compile(r"\.now\(\)\s*\+(?!=)"),
    re.compile(r"\b\w+\.now\s*\+(?!=)"),
    re.compile(r"\.addingTimeInterval\("),
    re.compile(r"\bDate\(\s*timeIntervalSinceNow:"),
    re.compile(r"\.wait\(\s*(?:wall)?[tT]imeout:"),
    re.compile(r"\bTask\.sleep\(\s*until:"),
]
TIME_LIMIT = re.compile(r"\.timeLimit\(")
TIME_LIMIT_LITERAL = re.compile(r"\.timeLimit\(\s*\.(minutes|seconds|hours)\(\s*([\d_.]+)\s*\)\s*\)")
SLEEPS = [
    (re.compile(r"\bTask\.sleep\(\s*for:\s*\.seconds\(\s*([\d_.]+)\s*\)"), 1.0),
    (re.compile(r"\bTask\.sleep\(\s*for:\s*\.milliseconds\(\s*([\d_.]+)\s*\)"), 1e-3),
    (re.compile(r"\bTask\.sleep\(\s*nanoseconds:\s*([\d_.]+)"), 1e-9),
    (re.compile(r"\bThread\.sleep\(\s*forTimeInterval:\s*([\d_.]+)"), 1.0),
    (re.compile(r"\b(?:usleep)\(\s*([\d_.]+)"), 1e-6),
    (re.compile(r"\bsleep\(\s*([\d_.]+)\s*\)"), 1.0),
]
ASSIGNMENT = re.compile(r"\b(?:let|var)\s+(\w+)\s*(?::[^=]+)?=\s*(.+)$")
TUPLE_ASSIGNMENT = re.compile(r"\b(?:let|var)\s+\(([^)]*)\)\s*=\s*(.+)$")
FUNCTION = re.compile(r"^(\s*).*\bfunc\s+(\w+)")
COUNTED_LOOP = re.compile(r"\bfor\s+_\s+in\s+[\d_]+\s*\.\.[<.]\s*[\d_]+")
ANY_SLEEP = re.compile(r"\b(?:Task\.sleep|Thread\.sleep|usleep|sleep)\(")
REASSIGNMENT = re.compile(r"^\s*(\w+)\s*=\s*(.+)$")
# A comparison, spaced as swift-format spaces binary operators (so not a generic's angle brackets).
COMPARISON = re.compile(r"(?<=\s)(<=|>=|<|>)(?=\s)")


@dataclass
class Finding:
    path: str
    line: int
    kind: str
    code: str
    message: str

    @property
    def key(self):
        return (self.path, self.kind, self.code)

    def __str__(self):
        return f"{self.path}:{self.line}: {self.kind}: {self.message}\n    {self.code}"


def blank(text):
    """`text` with comments and string literals (interpolations and all) turned to spaces, lines
    kept, so that a pattern is matched in code only."""
    out = list(text)
    stack = []  # "s" a string, "t" a multi-line string, an int: an interpolation's open parentheses
    i, n = 0, len(text)

    def wipe(start, end):
        for k in range(start, min(end, n)):
            if out[k] != "\n":
                out[k] = " "

    while i < n:
        top = stack[-1] if stack else None
        if top in ("s", "t"):
            if text.startswith("\\(", i):
                wipe(i, i + 2)
                stack.append(1)
                i += 2
            elif text[i] == "\\":
                wipe(i, i + 2)
                i += 2
            elif top == "t" and text.startswith('"""', i):
                stack.pop()
                i += 3
            elif top == "s" and text[i] == '"':
                stack.pop()
                i += 1
            elif top == "s" and text[i] == "\n":
                stack.pop()  # an unterminated string: recover at the line's end
                i += 1
            else:
                wipe(i, i + 1)
                i += 1
            continue
        inside = any(entry in ("s", "t") for entry in stack)
        if text.startswith("//", i):
            end = text.find("\n", i)
            end = n if end < 0 else end
            wipe(i, end)
            i = end
        elif text.startswith("/*", i):
            end = text.find("*/", i + 2)
            end = n if end < 0 else end + 2
            wipe(i, end)
            i = end
        elif text.startswith('"""', i):
            stack.append("t")
            i += 3
        elif text[i] == '"':
            stack.append("s")
            i += 1
        else:
            if isinstance(top, int):
                if text[i] == "(":
                    stack[-1] += 1
                elif text[i] == ")":
                    stack[-1] -= 1
                    if stack[-1] == 0:
                        stack.pop()
                        wipe(i, i + 1)
                        i += 1
                        continue
            if inside:
                wipe(i, i + 1)
            i += 1
    return "".join(out)


def operand(code, start, step):
    """The operand of a comparison, from `start` towards one end of the line (`step` -1 or 1):
    up to an unmatched bracket, a comma, `&&`, `||`, `{`, `=` or `?`."""
    depth = 0
    i = start
    stops = ",{?"
    while 0 <= i < len(code):
        c = code[i]
        opening, closing = ("([", ")]") if step > 0 else (")]", "([")
        if c in opening:
            depth += 1
        elif c in closing:
            if depth == 0:
                break
            depth -= 1
        elif depth == 0:
            pair = code[i - 1 : i + 1] if step < 0 else code[i : i + 2]
            if c in stops or pair in ("&&", "||"):
                break
            if c == "=" and code[i - 1 : i] not in "=!<>" and code[i + 1 : i + 2] != "=":
                break
        i += step
    return code[i + 1 : start + 1] if step < 0 else code[start:i]


def mentions(text, names):
    return any(p.search(text) for p in ELAPSED) or any(re.search(rf"\b{re.escape(n)}\b", text) for n in names)


def hang_limit(path):
    for part in Path(path).parts:
        if part in HANG_LIMITS:
            return HANG_LIMITS[part]
    return DEFAULT_HANG_LIMIT


def elapsed_functions(code_lines):
    """The functions whose returns give an elapsed time: a `return` with one, in the lines after
    `func name` indented further than it."""
    found, current = set(), None
    for code in code_lines:
        m = FUNCTION.match(code)
        if m:
            current = (m.group(2), len(m.group(1)))
            continue
        if current and code.strip() and len(code) - len(code.lstrip()) <= current[1]:
            current = None
        if current and re.search(r"\breturn\b", code) and any(p.search(code) for p in ELAPSED):
            found.add(current[0])
    return found


def counted_sleep(code_lines, index):
    """Whether the counted loop at `index` sleeps itself, on its line or in the two after, rather
    than in a poll of its own (`while`), which waits on a condition however many times it loops."""
    if ANY_SLEEP.search(code_lines[index]):
        return True
    for line in code_lines[index + 1 : index + 3]:
        if re.search(r"\b(?:while|repeat)\b", line):
            return False
        if ANY_SLEEP.search(line):
            return True
    return False


def check_file(path, text):
    findings = []
    code_lines = blank(text).split("\n")
    raw_lines = text.split("\n")
    names = set()
    timers = elapsed_functions(code_lines)

    def elapsed(expression):
        return any(p.search(expression) for p in ELAPSED) or any(
            re.search(rf"\b{re.escape(name)}\s*[({{]", expression) for name in timers
        )

    for number, code in enumerate(code_lines, 1):
        shown = raw_lines[number - 1].strip()

        def report(kind, message):
            findings.append(Finding(path, number, kind, shown, message))

        for match in TIME_LIMIT.finditer(code):
            literal = TIME_LIMIT_LITERAL.match(code, match.start())
            limit = hang_limit(path)
            if not literal:
                report("time-limit", f"a time limit that is not a literal, against a hang limit of {limit} min")
                continue
            unit, value = literal.group(1), float(literal.group(2).replace("_", ""))
            minutes = value * {"seconds": 1 / 60, "minutes": 1, "hours": 60}[unit]
            if minutes < limit:
                report("time-limit", f"{value:g} {unit}, shorter than the target's hang limit of {limit} min")

        for pattern in DEADLINE:
            if pattern.search(code):
                report("deadline", "a deadline on the wall clock")
                break

        for pattern, scale in SLEEPS:
            for match in pattern.finditer(code):
                seconds = float(match.group(1).replace("_", "")) * scale
                if seconds >= 1:
                    report("long-sleep", f"a fixed sleep of {seconds:g} s")

        if COUNTED_LOOP.search(code) and counted_sleep(code_lines, number - 1):
            report("bounded-wait", "a wait that gives up after a count of sleeps")

        tuple_assigned = TUPLE_ASSIGNMENT.search(code)
        assigned = ASSIGNMENT.search(code) or REASSIGNMENT.match(code)
        if tuple_assigned and elapsed(tuple_assigned.group(2)):
            names.update(n.strip() for n in tuple_assigned.group(1).split(",") if n.strip() not in ("", "_"))
        elif assigned and elapsed(assigned.group(2)):
            names.add(assigned.group(1))

        for match in COMPARISON.finditer(code):
            op = match.group(1)
            left = operand(code, match.start() - 1, -1)
            right = operand(code, match.end(), 1)
            smaller = left if op in ("<", "<=") else right
            if mentions(smaller, names):
                report("elapsed-bound", "an upper bound on elapsed wall-clock time")
                break
    return findings


def parse_allow(text):
    """{(path, kind, code): line number}, and errors."""
    allowed, errors = {}, []
    entry = re.compile(r"^(\S+)\s+\[([\w-]+)\]\s+(.+?)\s+=>\s*(.*)$")
    for number, line in enumerate(text.split("\n"), 1):
        body = line.strip()
        if not body or body.startswith("#"):
            continue
        m = entry.match(body)
        if not m:
            errors.append(f"line {number}: `<path> [<kind>] <code> => <reason>` expected")
        elif not m.group(4).strip():
            errors.append(f"line {number}: no reason given after `=>`")
        else:
            allowed[(m.group(1), m.group(2), m.group(3))] = number
    return allowed, errors


def check(root, allow_text):
    """(findings not allowed, allow-list errors, number of files read)."""
    allowed, errors = parse_allow(allow_text)
    findings, used = [], set()
    files = sorted((root / "Tests").rglob("*.swift"))
    for file in files:
        relative = file.relative_to(root).as_posix()
        for finding in check_file(relative, file.read_text(encoding="utf-8")):
            if finding.key in allowed:
                used.add(finding.key)
            else:
                findings.append(finding)
    for key, number in sorted(allowed.items(), key=lambda item: item[1]):
        if key not in used:
            errors.append(f"line {number}: `{key[0]} [{key[1]}] {key[2]}` matches nothing; delete it")
    return findings, errors, len(files)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--root", type=Path, default=ROOT)
    parser.add_argument("--allow", type=Path)
    args = parser.parse_args(argv)
    allow = args.allow or args.root / "Scripts" / ALLOW.name
    allow_text = allow.read_text(encoding="utf-8") if allow.exists() else ""
    findings, errors, files = check(args.root, allow_text)
    for finding in findings:
        print(finding)
    for error in errors:
        print(f"{allow.name}: {error}")
    if findings or errors:
        print(
            f"\n{len(findings)} wall-clock bound(s) in tests, {len(errors)} allow-list problem(s). A test "
            "waits for its state with the hang limit as the only bound, or asserts on the cause; a "
            "deliberate exception goes in the allow-list with its reason."
        )
        return 1
    print(f"No wall-clock bounds in {files} test files.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
