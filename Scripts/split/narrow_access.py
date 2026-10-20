"""Narrows declarations' `package` access to the least that still builds, asking the compiler (#87).

    python3 Scripts/split/narrow_access.py package [--module BlastModel] [--files F ...]
        [--state FILE] [--log-dir DIR] [--scratch-path DIR] [--dry-run]
    python3 Scripts/split/narrow_access.py private --names-from LOG --files F ... [--owner BlastSolver]

Every `package` declaration in the module's sources (or in `--files`) is made internal (`public
package(set)` becomes `public internal(set)`, `package private(set)` `private(set)`), then the
package is built with its tests in a scratch path of its own, and each declaration the build's
errors point at is given `package` back: by the compiler's notes (a file and line, or, for another
module's view, a qualified name such as `BlastModel.AirSlice.Layout`), by the name an error quotes,
by the labels of a call that now meets another overload, by the type a given-back declaration
uses, and, for what nothing else explains outside the module, by the names on the error's line.
That repeats until the build is clean; giving back too much is safe, too little cannot build.
`--state` keeps what has been given back, so a run stopped part way goes on from there.

`private` does the same inside one module for what a split widened from `private` so that its new
files could share it: each of the owner's members named in the split's list (`widened <name>: used
from ...` or `set from ...`, as split_solver.py prints them) gets its `private`, or `private(set)`,
back, and keeps its wider access only where the build says another file needs it.

The edits change nothing but access modifiers. Run make format, build-strict and the digests after.
"""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_solver  # noqa: E402
import swift_source as ss  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
ERROR = re.compile(r"^(/[^:]+\.swift):(\d+):(\d+): error: (.*)$")
NOTE = re.compile(r"^(/[^:]+\.swift):(\d+):(\d+): note: (.*)$")
# A note on a declaration in another module names it by its qualified name, not its file.
MODULE_NOTE = re.compile(r"^([A-Za-z_][\w.]*):(\d+):(\d+): note: (.*)$")


@dataclass
class Edit:
    """One declaration's access change: `start`..`end` in its file becomes `narrow`."""

    path: Path
    name: str
    lines: tuple[int, int]  # from its first modifier to its name
    start: int
    end: int
    wide: str  # the text there now
    narrow: str  # the text that narrows it
    qualified: str = ""  # `Type.Inner.name` (`init` for an initialiser), as the compiler's notes name it
    kind: str = ""
    labels: str = ""  # `grid:bodies:` for a function or initialiser


def package_edits(path: Path) -> list[Edit]:
    text = path.read_text(encoding="utf-8")
    sf = ss.parse(text)
    edits = []
    for top in sf.decls:
        for d in top.walk():
            for i in range(d.header, d.keyword):
                t = sf.tokens[i]
                if t.text != "package" or t.kind != "ident":
                    continue
                setter = i + 3 < len(sf.tokens) and sf.tokens[i + 1].text == "(" and sf.tokens[i + 2].text == "set"
                if setter:
                    start, end, narrow = t.start, sf.tokens[i + 3].end, "internal(set)"
                    if not any(sf.tokens[k].text in ("public", "open") for k in range(d.header, d.keyword)):
                        continue  # `package(set)` alone would be odd; leave it
                else:
                    start, end, narrow = t.start, t.end, ""
                    if text[end:end + 1] == " ":
                        end += 1
                name_line = sf.tokens[min(d.keyword + 1, len(sf.tokens) - 1)].line
                edits.append(Edit(path, d.name or d.kind, (t.line, name_line), start, end, text[start:end],
                                  narrow, d.path, d.kind, labels_of(sf, d)))
    return edits


def private_edits(path: Path, names: dict[str, bool], owner: str) -> list[Edit]:
    """`private` (or `private(set)`, where `names` says the setter was what was widened) put back
    on `owner`'s members named in `names` that hold no `private` now."""
    text = path.read_text(encoding="utf-8")
    sf = ss.parse(text)
    edits = []
    for top in sf.decls:
        if top.kind not in ("class", "extension") or top.name != owner:
            continue
        for d in top.members:
            if d.name not in names:
                continue
            span = range(d.header, d.keyword)
            words = [sf.tokens[i].text for i in span]
            if "private" in words or "fileprivate" in words:
                continue
            name_line = sf.tokens[min(d.keyword + 1, len(sf.tokens) - 1)].line
            lines = (sf.tokens[d.header].line, name_line)
            setter = names[d.name]
            internal_set = next((i for i in span if sf.tokens[i].text == "internal"
                                 and sf.tokens[i + 1].text == "("), None)
            if setter and internal_set is not None:
                # `public internal(set)` was `public private(set)`.
                start, end = sf.tokens[internal_set].start, sf.tokens[internal_set + 3].end
                edits.append(Edit(path, d.name, lines, start, end, text[start:end], "private(set)",
                                  d.path, d.kind))
                continue
            # Before the first modifier or the keyword, after any attributes.
            at = next((i for i in span if sf.tokens[i].kind != "attr"
                       and not (i > d.header and sf.tokens[i - 1].kind == "attr" and sf.tokens[i].text == "(")),
                      d.keyword)
            if sf.tokens[at].text == "(":
                at = d.keyword
            start = sf.tokens[at].start
            edits.append(Edit(path, d.name, lines, start, start, "", "private(set) " if setter else "private ",
                              d.path, d.kind, labels_of(sf, d)))
    return edits


def labels_of(sf: ss.SourceFile, d: ss.Decl) -> str:
    if d.kind not in ("func", "init", "subscript"):
        return ""
    key = split_solver.swift_key(sf, d)
    return key[key.index("(") + 1:-1] if "(" in key else ""


ORIGINAL: dict[Path, str] = {}
LOG_DIR: Path | None = None
STATE: Path | None = None
SCRATCH = Path('/Volumes/StudioData/bombcad/narrow-access-build')


def write(edits: list[Edit], narrowed: set[int]) -> None:
    """Each file the edits touch, from its original text with the `narrowed` edits made."""
    by_path: dict[Path, list[int]] = {}
    for k, e in enumerate(edits):
        by_path.setdefault(e.path, []).append(k)
    for path, ks in by_path.items():
        text = ORIGINAL.setdefault(path, path.read_text(encoding="utf-8"))
        for k in sorted(ks, key=lambda k: edits[k].start, reverse=True):
            if k not in narrowed:
                continue
            e = edits[k]
            if text[e.start:e.end] != e.wide:
                raise RuntimeError(f"{path}:{e.lines[0]}: expected {e.wide!r}")
            text = text[:e.start] + e.narrow + text[e.end:]
        if path.read_text(encoding="utf-8") != text:
            path.write_text(text, encoding="utf-8")


def build() -> list[str]:
    """The build's output lines on failure, else []. Its own scratch path, so the rounds do not
    disturb the checkout's build. (SwiftPM stops at the first failing compile job, so a round sees
    some of the errors, not all; whole-module builds would see all but fail on dependencies'
    outputs.)"""
    command = ["swift", "build", "--build-tests", "--disable-index-store", "--scratch-path", str(SCRATCH)]
    result = subprocess.run(command, cwd=ROOT, capture_output=True, text=True)
    if result.returncode == 0:
        return []
    return [re.sub(r"\x1b\[[0-9;]*m", "", line) for line in (result.stdout + result.stderr).split("\n")]


def needed(lines: list[str], edits: list[Edit], kind: str) -> tuple[set[int], list[str]]:
    """The edits the build's errors point at, and errors pointing at none."""
    by_place: dict[tuple[str, int], list[int]] = {}
    by_name: dict[str, list[int]] = {}
    by_qualified: dict[str, list[int]] = {}
    for k, e in enumerate(edits):
        by_qualified.setdefault(e.qualified, []).append(k)
        for line in range(e.lines[0], e.lines[1] + 1):
            by_place.setdefault((str(e.path.resolve()), line), []).append(k)
        by_name.setdefault(e.name, []).append(k)
    found: set[int] = set()
    unexplained: list[str] = []
    k = 0
    while k < len(lines):
        m = ERROR.match(lines[k])
        if not m:
            k += 1
            continue
        path, line, column, message = m.groups()
        hits: set[int] = set()
        # The error itself may sit on a narrowed declaration (a protocol's requirement).
        hits.update(by_place.get((str(Path(path).resolve()), int(line)), []) if "must be declared" in message
                    or "must be as accessible" in message or "cannot be declared" in message
                    or "must have" in message else [])
        j = k + 1
        while j < len(lines) and not ERROR.match(lines[j]):
            n = NOTE.match(lines[j])
            if n and ("declared here" in n.group(4) or "set to" in n.group(4)):
                hits.update(by_place.get((str(Path(n.group(1)).resolve()), int(n.group(2))), []))
            q = MODULE_NOTE.match(lines[j])
            if q and "declared here" in q.group(4):
                qualified = q.group(1).split(".", 1)[1] if "." in q.group(1) else q.group(1)
                hits.update(by_qualified.get(qualified, []))
            j += 1
        if not hits and ("cannot call value of non-function type" in message or "is not a function" in message):
            # A call to a narrowed function now meets a variable of the same name.
            source = Path(path).read_text(encoding="utf-8").split("\n")[int(line) - 1]
            word = re.match(r"[A-Za-z_]\w*", source[int(column) - 1:])
            if word:
                hits.update(k for k, e in enumerate(edits) if e.name == word.group(0) and e.kind == "func")
        if not hits and "incorrect argument label" in message:
            # A call that reached for a narrowed overload now meets another: give back the one
            # with the labels it has.
            have = re.search(r"have '([^']*)'", message)
            if have:
                hits.update(k for k, e in enumerate(edits) if e.labels and e.labels == have.group(1))
        if not hits and "uses an internal type" in message:
            # A declaration given back that names a type still narrowed: give back the type.
            source = Path(path).read_text(encoding="utf-8").split("\n")[int(line) - 1:int(line) + 150]
            head = []
            for text in source:
                head.append(text)
                if text.rstrip().endswith("{"):
                    break
            words = set(re.findall(r"[A-Za-z_]\w*", "\n".join(head)))
            hits.update(k for k, e in enumerate(edits)
                        if e.name in words and e.kind in ("struct", "enum", "class", "protocol", "typealias", "actor"))
        if not hits:
            name = re.search(r"'\$?([A-Za-z_]\w*)", message)
            if name and ("cannot find" in message or "inaccessible" in message or "has no member" in message
                         or "no exact matches" in message):
                hits.update(by_name.get(name.group(1), []))
        if not hits and not path.startswith(str(ROOT / "Sources" / "BlastModel")):
            # Anything else (a call that now resolves to another overload): what the line names,
            # and any function whose labels the message names. Giving back too much is safe.
            source = Path(path).read_text(encoding="utf-8").split("\n")[int(line) - 1]
            words = set(re.findall(r"[A-Za-z_]\w*", source))
            quoted = set(re.findall(r"'([A-Za-z_]\w*)'", message))
            hits.update(k for k, e in enumerate(edits)
                        if (e.name in words and e.kind in ("func", "init", "var", "let", "subscript"))
                        or (e.labels and quoted & set(e.labels.rstrip(":").split(":"))))
        if hits:
            found |= hits
        else:
            unexplained.append(f"{path}:{line}: {message}")
        k = j
    return found, unexplained


def narrow(edits: list[Edit], kind: str, dry_run: bool) -> None:
    print(f"{len(edits)} declarations to try narrower")
    if dry_run:
        for e in edits:
            print(f"  {e.path.relative_to(ROOT)}:{e.lines[0]} {e.name}")
        return
    for e in edits:
        ORIGINAL.setdefault(e.path, e.path.read_text(encoding="utf-8"))
    trying = set(range(len(edits)))
    # What earlier runs had to give back, so that a run stopped part way goes on from there.
    ident = [f"{e.path.relative_to(ROOT)}:{e.start}:{e.qualified}" for e in edits]
    if STATE and STATE.exists():
        kept = set(STATE.read_text(encoding="utf-8").split("\n"))
        trying -= {k for k in trying if ident[k] in kept}
        print(f"  {len(edits) - len(trying)} given back already (from {STATE})")
    write(edits, trying)
    for round_ in range(1, 200):
        order = sorted(trying)
        lines = build()
        if LOG_DIR:
            (LOG_DIR / f"round-{round_}.log").write_text("\n".join(lines), encoding="utf-8")
        if not lines:
            break
        ks, unexplained = needed(lines, [edits[k] for k in order], kind)
        found = {order[k] for k in ks}
        if not found:
            print("the build fails where no narrowed declaration explains it:", file=sys.stderr)
            for u in unexplained[:40]:
                print(f"  {u}", file=sys.stderr)
            write(edits, set())
            sys.exit(1)
        trying -= found
        if STATE:
            STATE.write_text("\n".join(ident[k] for k in range(len(edits)) if k not in trying), encoding="utf-8")
        print(f"  round {round_}: {len(found)} given back, {len(trying)} still narrowed", flush=True)
        write(edits, trying)
    else:
        print("no clean build after 200 rounds; giving everything back", file=sys.stderr)
        write(edits, set())
        sys.exit(1)
    print(f"narrowed {len(trying)}, kept {len(edits) - len(trying)} as they were")
    for k in sorted(trying):
        e = edits[k]
        print(f"  narrowed {e.path.relative_to(ROOT)}:{e.lines[0]} {e.name}")


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("kind", choices=["package", "private"])
    parser.add_argument("--names-from", type=Path,
                        help="private: the split's list of what it widened (`widened <name>: used|set from ...`)")
    parser.add_argument("--owner", default="BlastSolver", help="private: the type whose members it narrows")
    parser.add_argument("--module", default="BlastModel")
    parser.add_argument("--files", nargs="*")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--log-dir", type=Path, help="keep each round's build output here")
    parser.add_argument("--state", type=Path, help="what has been given back, kept between runs")
    parser.add_argument("--scratch-path", type=Path, help="where the rounds build (default /Volumes/StudioData/bombcad/narrow-access-build)")
    args = parser.parse_args(argv)
    global LOG_DIR, SCRATCH, STATE
    LOG_DIR = args.log_dir
    STATE = args.state
    if args.scratch_path:
        SCRATCH = args.scratch_path
    if LOG_DIR:
        LOG_DIR.mkdir(parents=True, exist_ok=True)
    if args.files:
        paths = [ROOT / f for f in args.files]
    else:
        paths = sorted((ROOT / "Sources" / args.module).glob("*.swift"))
    edits: list[Edit] = []
    if args.kind == "package":
        for p in paths:
            edits += package_edits(p)
    else:
        if not args.names_from or not args.files:
            parser.error("private takes --names-from and --files")
        names: dict[str, bool] = {}
        for line in args.names_from.read_text(encoding="utf-8").split("\n"):
            m = re.match(r"\s*widened (\w+): (used|set) from", line)
            if m:
                names[m.group(1)] = m.group(2) == "set"
        for p in paths:
            edits += private_edits(p, names, args.owner)
    narrow(edits, args.kind, args.dry_run)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
