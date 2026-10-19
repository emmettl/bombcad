"""The text work of the air solver's split (#21), driven by Scripts/split/split-solver.sh.

    python3 Scripts/split/split_solver.py inventory [swift|metal]
    python3 Scripts/split/split_solver.py check
    python3 Scripts/split/split_solver.py refresh
    python3 Scripts/split/split_solver.py split
    python3 Scripts/split/split_solver.py editors [--days N]

`BlastSolver.swift` (the GPU air solver) and `Shaders/Solver.metal` (its kernels) are cut by
subsystem, following Scripts/split/solver-split.json. The largest part of each keeps its file
and with it the file's history: the class's stored properties, its initialiser and the types they
hold stay in BlastSolver.swift, and the shared types, equation of state, reconstruction and fluxes
stay in Solver.metal. The rest goes to new files beside them: Swift members as `extension
BlastSolver` in `BlastSolver+<Subsystem>.swift`, Metal declarations as `Solver<Subsystem>.metal`.

Nothing is rewritten. Each member or declaration moves as its own lines, with the comments above
it, so kernel names, argument indices and function constants are as they were. Two things change
besides the moves:

- access: a `private` declaration used from another of the new files becomes internal, and a
  `private(set)` property set from another file becomes `internal(set)` (or settable, when the
  property is internal). Swift's `private` reaches extensions in the same file only.
- the list of shader files compiled together (`ShaderLibrary.make`) names
  the new Metal files right after Solver.metal, in the plan's order. The library is one source,
  the files joined in that order, so a part may use only what an earlier part or itself defines;
  `check` proves that for every name defined at file scope.

`inventory` prints each file's members or declarations with their keys, as the plan names them.
`check` compares the plan with the tree and stops, naming them, at a member or declaration the
plan does not place, or one it places that is not there: main has moved under the plan. A change
inside a member that keeps the inventory is carried along as it is (and reported). `refresh`
writes the plan again for the tree as it is: what it does not name goes with what is above it
(read the difference before committing it). `split` does the cut, and does nothing when it has
been done. `editors` lists who has been changing the two files: commits by day and by the plan's
parts, and the worktrees with changes to them.
"""

from __future__ import annotations

import argparse
import datetime
import json
import re
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import swift_source as ss  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
PLAN = Path(__file__).resolve().with_name("solver-split.json")
# Porting a branch's commits over the split (`--lenient`): what the plan does not name goes with
# the member or declaration above it, and what it names that is not there is passed over.
LENIENT = False
CHECK_AFFECTED = "Scripts/check-affected.py"
# Calls through which code elsewhere changes a property in place.
MUTATING = {
    "append", "appendContents", "insert", "remove", "removeAll", "removeFirst", "removeLast",
    "removeSubrange", "removeValue", "replaceSubrange", "sort", "reverse", "shuffle", "swapAt",
    "merge", "formUnion", "formIntersection", "subtract", "updateValue", "reserveCapacity",
    "popLast", "measure", "record", "reset",
}


class SplitError(RuntimeError):
    pass


def fail(message: str) -> None:
    raise SplitError(message)


# --- Swift --------------------------------------------------------------------------------------


@dataclass
class Unit:
    """A member of the class or of an extension of it in the file, or a declaration at file
    level: what moves as one piece, with the lines from just after the previous one to its end."""

    key: str
    decl: ss.Decl
    first_line: int  # 1-based, inclusive: the line after the previous unit or the body's `{`
    last_line: int
    container: str  # "class", "extension" (members) or "file" (declarations at file level)
    movable: bool
    why_fixed: str = ""


def swift_key(sf: ss.SourceFile, d: ss.Decl) -> str:
    """`advance(steps:)`, `time`, `struct Settlement`, `extension BlastSolver`."""
    if d.kind == "extension" and d.members:
        # Named by its first member, so that another extension added beside it changes nothing.
        return f"extension {d.name} from {swift_key(sf, d.members[0])}"
    if d.kind in ss.TYPE_KINDS:
        return f"{d.kind} {d.name}"
    if d.kind in ("func", "init", "subscript"):
        tokens = sf.tokens
        i = d.keyword + 1
        if d.kind == "func":
            i += 1  # the name
        while i < len(tokens) and tokens[i].text != "(":
            i += 1  # generic parameters
        labels, depth, start = [], 0, True
        j = i
        while j < len(tokens):
            t = tokens[j].text
            if t in "([":
                depth += 1
                if depth == 1 and t == "(":
                    start = True
                    j += 1
                    continue
            elif t in ")]":
                depth -= 1
                if depth == 0:
                    break
            elif t == "," and depth == 1:
                start = True
                j += 1
                continue
            if start and depth == 1:
                labels.append(tokens[j].text)
                start = False
            j += 1
        name = d.name if d.kind == "func" else d.kind
        return f"{name}({''.join(label + ':' for label in labels)})"
    return d.name


def is_stored(sf: ss.SourceFile, d: ss.Decl) -> bool:
    """Whether a `var` or `let` holds storage in each instance (which an extension cannot add)."""
    if d.kind not in ("var", "let") or "static" in d.modifiers or "class" in d.modifiers:
        return False
    if d.kind == "let" or "lazy" in d.modifiers:
        return True
    tokens = sf.tokens
    depth = 0
    for i in range(d.keyword + 1, d.end + 1):
        t = tokens[i].text
        if t in "([":
            depth += 1
        elif t in ")]":
            depth -= 1
        elif depth == 0 and t == "=":
            return True
        elif depth == 0 and t == "{":
            # Observers keep storage; anything else is a computed property's body.
            return tokens[i + 1].text in ("willSet", "didSet")
    return True


def swift_units(sf: ss.SourceFile, class_name: str) -> list[Unit]:
    units: list[Unit] = []
    previous_end = 0  # the last line of the previous unit at file level
    for d in sf.decls:
        first, last = sf.lines(d)
        if d.kind == "import":
            previous_end = last
            continue
        is_class = d.kind == "class" and d.name == class_name
        is_extension = d.kind == "extension" and d.name == class_name
        if is_class or is_extension:
            if d.conditions:
                fail(f"{d.kind} {d.name} sits under #if {d.conditions}; the split does not read that")
            body_line = sf.tokens[d.body_open].line
            prev = body_line
            for m in d.members:
                m_first, m_last = sf.lines(m)
                if m_first <= prev:
                    fail(f"{swift_key(sf, m)} shares line {m_first} with what is before it")
                if m.conditions:
                    fail(f"{swift_key(sf, m)} sits under #if; the split does not read that")
                stored = is_stored(sf, m)
                fixed = ""
                if stored:
                    fixed = "stored property"
                elif m.kind in ("init", "deinit") and is_class:
                    fixed = "initialiser of the class"
                units.append(Unit(swift_key(sf, m), m, prev + 1, m_last,
                                  "class" if is_class else "extension", not fixed, fixed))
                prev = m_last
            if is_extension:
                # The extension itself: whole, when all its members go to one file.
                units.append(Unit(swift_key(sf, d), d, previous_end + 1, last, "file", True))
            previous_end = last
            continue
        units.append(Unit(swift_key(sf, d), d, previous_end + 1, last, "file", True))
        previous_end = last
    keys: dict[str, int] = {}
    for u in units:
        keys[u.key] = keys.get(u.key, 0) + 1
    seen: dict[str, int] = {}
    for u in units:
        if keys[u.key] > 1:
            seen[u.key] = seen.get(u.key, 0) + 1
            u.key = f"{u.key}#{seen[u.key]}"
    return units


# --- Metal --------------------------------------------------------------------------------------


@dataclass
class Item:
    key: str
    names: list[str]  # what it defines at file scope (an enum's cases too)
    start: int  # character offsets of its code (comments above it not included)
    end: int
    first_line: int
    last_line: int
    uses: set[str] = field(default_factory=set)


def blank_comments(text: str) -> str:
    """`text` with comments and literals' contents replaced by spaces, offsets kept."""
    out = list(text)
    i, n = 0, len(text)
    while i < n:
        if text.startswith("//", i):
            j = text.find("\n", i)
            j = n if j < 0 else j
            for k in range(i, j):
                out[k] = " "
            i = j
        elif text.startswith("/*", i):
            j = text.find("*/", i + 2)
            j = n if j < 0 else j + 2
            for k in range(i, j):
                if out[k] != "\n":
                    out[k] = " "
            i = j
        elif text[i] in "\"'":
            quote = text[i]
            j = i + 1
            while j < n and text[j] != quote and text[j] != "\n":
                j += 2 if text[j] == "\\" else 1
            for k in range(i + 1, min(j, n)):
                out[k] = " "
            i = j + 1
        else:
            i += 1
    return "".join(out)


_IDENT = re.compile(r"[A-Za-z_]\w*")


def metal_items(text: str) -> list[Item]:
    clean = blank_comments(text)
    items: list[Item] = []
    n = len(clean)
    i = 0

    def line_of(offset: int) -> int:
        return text.count("\n", 0, offset) + 1

    while i < n:
        if clean[i].isspace():
            i += 1
            continue
        start = i
        if clean[i] == "#":
            # A preprocessor line, with its continuations.
            j = i
            while True:
                k = clean.find("\n", j)
                k = n if k < 0 else k
                if clean[k - 1] == "\\" and k < n:
                    j = k + 1
                    continue
                break
            end = k
        else:
            depth, j = 0, i
            end = -1
            while j < n:
                c = clean[j]
                if c in "([{":
                    depth += 1
                elif c in ")]}":
                    depth -= 1
                    if depth == 0 and c == "}":
                        k = j + 1
                        while k < n and clean[k].isspace():
                            k += 1
                        end = k + 1 if k < n and clean[k] == ";" else j + 1
                        break
                elif c == ";" and depth == 0:
                    end = j + 1
                    break
                j += 1
            if end < 0:
                fail(f"Metal source ends inside a declaration from line {line_of(start)}")
        code = clean[start:end]
        names = item_names(code)
        items.append(Item("", names, start, end, line_of(start), line_of(end - 1),
                          set(_IDENT.findall(re.sub(r"\[\[.*?\]\]", " ", code)))))
        i = end
    counts: dict[str, int] = {}
    for item in items:
        base = item.names[0] if item.names else " ".join(clean[item.start:item.end].split())[:40]
        counts[base] = counts.get(base, 0) + 1
        item.key = base if counts[base] == 1 else f"{base}#{counts[base]}"
    for k in range(1, len(items)):
        if items[k].first_line <= items[k - 1].last_line:
            fail(f"{items[k].key} shares line {items[k].first_line} with {items[k - 1].key}")
    return items


def item_names(code: str) -> list[str]:
    if code.startswith("#"):
        m = re.match(r"#\s*define\s+(\w+)", code)
        return [m.group(1)] if m else []
    code = re.sub(r"\[\[.*?\]\]", " ", code, flags=re.S)
    m = re.match(r"\s*(?:typedef\s+)?(struct|enum|union)\s+(?:class\s+)?(\w+)", code)
    if m:
        names = [m.group(2)]
        if m.group(1) == "enum":
            body = code[code.find("{") + 1:code.rfind("}")]
            names += [part.split("=")[0].strip() for part in body.split(",") if part.strip()]
        return names
    if code.startswith("using"):
        return []
    paren, equal, brace = (code.find(c) for c in "(={")
    first = min(x for x in (paren, equal, brace, len(code)) if x >= 0)
    if paren >= 0 and paren == first:
        before = _IDENT.findall(code[:paren])
        return [before[-1]] if before else []
    head = code[:first]
    head = head.split("[")[0]
    found = _IDENT.findall(head)
    return [found[-1]] if found else []


# --- The plan -----------------------------------------------------------------------------------


def load_plan() -> dict:
    return json.loads(PLAN.read_text(encoding="utf-8"))


def git(*args: str, check: bool = True) -> str:
    result = subprocess.run(["git", *args], cwd=ROOT, capture_output=True, text=True)
    if check and result.returncode != 0:
        fail(f"git {' '.join(args)}: {result.stderr.strip()}")
    return result.stdout


def blob(path: str) -> str:
    return git("hash-object", path).strip()


@dataclass
class Placement:
    """Where each unit goes: the file's name, or "" to stay."""

    side: str
    source: str
    order: list[str]  # the new files, in the plan's order
    about: dict[str, str]
    target: dict[str, str]


def placement(plan: dict, side: str, keys: list[str], optional: frozenset[str] = frozenset()
              ) -> tuple[Placement, list[str]]:
    """The plan's placement of `keys` and its disagreements with them. A key in `optional` (an
    extension's member, which moves with its extension) need not be placed."""
    part = plan[side]
    target: dict[str, str] = {}
    problems: list[str] = []
    for key in part["stays"]:
        target[key] = ""
    for name, spec in part["files"].items():
        for key in spec["moves"]:
            if key in target:
                problems.append(f"{key} is placed twice")
            target[key] = name
    present = set(keys)
    for key in target:
        if key not in present and not LENIENT:
            problems.append(f"{key}: the plan places it, but it is not in {part['source']}")
    above = ""
    for key in keys:
        if key not in target and key not in optional:
            if LENIENT:
                target[key] = above
                print(f"  {key}: not in the plan; with what is above it ({above or 'stays'})")
            else:
                problems.append(f"{key}: in {part['source']}, but the plan does not place it")
        above = target.get(key, above)
    about = {name: spec["about"] for name, spec in part["files"].items()}
    return Placement(side, part["source"], list(part["files"]), about, target), problems


def plan_keys(plan: dict, side: str) -> set[str]:
    return set(plan[side]["stays"]) | {k for spec in plan[side]["files"].values() for k in spec["moves"]}


def swift_state(plan: dict, text: str | None = None):
    source = plan["swift"]["source"]
    text = text if text is not None else (ROOT / source).read_text(encoding="utf-8")
    sf = ss.parse(text)
    units = swift_units(sf, plan["swift"]["class"])
    # An extension's members move with it unless the plan places them on their own.
    place, problems = placement(plan, "swift", [u.key for u in units],
                                frozenset(u.key for u in units if u.container == "extension"))
    by_key = {u.key: u for u in units}
    for key, name in place.target.items():
        u = by_key.get(key)
        if u is not None and name and not u.movable and LENIENT and key not in plan_keys(plan, "swift"):
            place.target[key] = ""
        elif u is not None and name and not u.movable:
            problems.append(f"{key} cannot leave the class's body ({u.why_fixed})")
    return text, sf, units, place, problems


def metal_state(plan: dict, text: str | None = None):
    source = plan["metal"]["source"]
    text = text if text is not None else (ROOT / source).read_text(encoding="utf-8")
    items = metal_items(text)
    place, problems = placement(plan, "metal", [i.key for i in items])
    if not problems:
        problems += metal_order_problems(items, place)
    return text, items, place, problems


def metal_order_problems(items: list[Item], place: Placement) -> list[str]:
    """Names used before they are defined in the source the library joins: the parts in the
    plan's order after the part that stays, each in the source's order."""
    rank = {"": 0} | {name: k + 1 for k, name in enumerate(place.order)}
    position = {}
    for index, item in enumerate(items):
        position[item.key] = (rank[place.target[item.key]], index)
    defined = {}
    for index, item in enumerate(items):
        for name in item.names:
            defined.setdefault(name, (item.key, index))
    problems = []
    for index, item in enumerate(items):
        for name in item.uses:
            if name not in defined:
                continue
            key, at = defined[name]
            if at >= index or key == item.key:
                continue  # a use before the definition in the source: a local name, not this one
            if position[key] > position[item.key]:
                where = place.target[key] or place.source
                problems.append(f"{item.key} ({place.target[item.key] or place.source}) uses {name}, "
                                f"which would come later ({where})")
    return sorted(set(problems))


def check(plan: dict, quiet: bool = False) -> bool:
    problems = []
    notes = []
    split_done = all((ROOT / plan["swift"]["folder"] / name).exists() for name in plan["swift"]["files"])
    if split_done:
        if not quiet:
            print("the split has been done: the new files are there")
        return True
    for side in ("swift", "metal"):
        source = plan[side]["source"]
        if not (ROOT / source).exists():
            fail(f"{source} is not there; has it moved on main?")
        if blob(source) != plan[side]["base"]:
            notes.append(f"{source} has changed since the plan was made (inventory unchanged "
                         "unless reported below); the changes move with their members")
    problems += swift_state(plan)[4]
    problems += metal_state(plan)[3]
    if not quiet:
        for note in notes:
            print(f"note: {note}")
    if problems:
        print("The plan no longer describes the tree:", file=sys.stderr)
        for p in problems:
            print(f"  {p}", file=sys.stderr)
        print("Update Scripts/split/solver-split.json (`inventory` lists the keys) and run again.",
              file=sys.stderr)
        return False
    if not quiet:
        print("the plan describes the tree")
    return True


# --- The cut ------------------------------------------------------------------------------------


def lines_of(text: str) -> list[str]:
    lines = text.split("\n")
    if lines and lines[-1] == "":
        lines.pop()
    return lines


def chunk(lines: list[str], first: int, last: int, drop_marks: bool) -> list[str]:
    out = lines[first - 1:last]
    if drop_marks:
        out = [line for line in out if not line.strip().startswith("// MARK:")]
    return out


def trim_leading_blank(block: list[str]) -> list[str]:
    k = 0
    while k < len(block) and not block[k].strip():
        k += 1
    return block[k:]


def access_edits(sf: ss.SourceFile, units: list[Unit], home: dict[int, str], overrides: dict
                 ) -> tuple[list[tuple[int, int, str]], list[str]]:
    """Text edits (start, end, replacement) that widen what other files now use, and a report."""
    tokens = sf.tokens
    # Each token's file after the cut: the unit it is in, an extension's members after the
    # extension (they may be placed on their own).
    file_of: list[str | None] = [None] * len(tokens)
    for u in sorted(units, key=lambda u: u.container != "file"):
        for t in range(u.decl.header, u.decl.end + 1):
            file_of[t] = home[id(u)]
    edits, report = [], []
    decls = [u.decl for u in units if u.container != "file" or u.decl.kind != "extension"]
    for d in decls:
        mods = [i for i in range(d.header, d.keyword) if tokens[i].text in ("private", "fileprivate")]
        if not mods:
            continue
        here = file_of[d.keyword]
        name = d.name
        if not name:
            continue
        elsewhere = [i for i, t in enumerate(tokens)
                     if t.kind == "ident" and t.text == name and file_of[i] is not None and file_of[i] != here]
        for i in mods:
            setter = i + 3 < len(tokens) and tokens[i + 1].text == "(" and tokens[i + 2].text == "set"
            if setter:
                writes = [k for k in elsewhere if writes_at(tokens, k)]
                if not writes and name not in overrides.get("set", []):
                    continue
                public = any(tokens[k].text in ("public", "open") for k in range(d.header, d.keyword))
                start, end = tokens[i].start, tokens[i + 3].end
                if public:
                    edits.append((start, end, "internal(set)"))
                else:
                    end = skip_space(sf.text, end)
                    edits.append((start, end, ""))
                report.append(f"{name}: set from {', '.join(sorted({file_of[k] or '?' for k in writes})) or 'elsewhere'}")
            else:
                if not elsewhere and name not in overrides.get("access", []):
                    continue
                edits.append((tokens[i].start, skip_space(sf.text, tokens[i].end), ""))
                users = sorted({file_of[k] or "" for k in elsewhere})
                report.append(f"{name}: used from {', '.join(u or 'the core' for u in users)}")
    return edits, report


def skip_space(text: str, end: int) -> int:
    while end < len(text) and text[end] == " ":
        end += 1
    return end


def writes_at(tokens: list[ss.Token], k: int) -> bool:
    """Whether the identifier at `k` is set or changed in place there."""
    if k > 0 and tokens[k - 1].text == "&":
        return True
    j = k + 1
    last_member = None
    while j < len(tokens):
        t = tokens[j].text
        if t == "[":
            depth = 0
            while j < len(tokens):
                if tokens[j].text == "[":
                    depth += 1
                elif tokens[j].text == "]":
                    depth -= 1
                    if depth == 0:
                        break
                j += 1
            j += 1
        elif t in ("?", "!"):
            j += 1
        elif t in (".", "?.", "!.") and j + 1 < len(tokens) and tokens[j + 1].kind == "ident":
            last_member = tokens[j + 1].text
            j += 2
        else:
            break
    if j >= len(tokens):
        return False
    t = tokens[j]
    if t.kind == "op" and t.text.endswith("=") and t.text not in ("==", "!=", "<=", ">=", "===", "!=="):
        return True
    return t.text == "(" and last_member in MUTATING


def apply_edits(text: str, edits: list[tuple[int, int, str]]) -> str:
    for start, end, replacement in sorted(edits, reverse=True):
        text = text[:start] + replacement + text[end:]
    return text


def split_swift(plan: dict) -> dict[str, str]:
    text, sf, units, place, problems = swift_state(plan)
    if problems:
        fail("; ".join(problems))
    folder = plan["swift"]["folder"]
    by_key = {u.key: u for u in units}
    # Where each unit ends up. An extension's members follow it unless placed on their own.
    home: dict[int, str] = {}
    extension_target = {}
    for u in units:
        if u.container == "file" and u.decl.kind == "extension":
            extension_target[id(u.decl)] = place.target[u.key]
    for u in units:
        if u.container == "extension":
            own = place.target.get(u.key, "")
            parent = extension_target.get(id(u.decl.parent), "")
            if parent and own and own != parent:
                fail(f"{u.key} is placed in {own}, but its extension goes to {parent}")
            home[id(u)] = own or parent
        else:
            home[id(u)] = place.target[u.key]
    edits, report = access_edits(sf, units, home, plan["swift"].get("widen", {}))
    # Apply the access edits to the whole text first; lines are not changed by them.
    widened = apply_edits(text, edits)
    if widened.count("\n") != text.count("\n"):
        fail("an access edit changed the lines; the split would cut in the wrong places")
    lines = lines_of(widened)
    imports = [line for line in lines if line.startswith("import ")]
    moved_lines: set[int] = set()
    outputs: dict[str, list[str]] = {name: [] for name in place.order}
    extension_whole: set[str] = set()
    members: dict[str, list[list[str]]] = {name: [] for name in place.order}
    file_level: dict[str, list[list[str]]] = {name: [] for name in place.order}
    for u in units:
        name = home[id(u)]
        if not name:
            continue
        if u.container == "extension" and extension_target.get(id(u.decl.parent)) == name:
            continue  # moves inside its whole extension
        block = chunk(lines, u.first_line, u.last_line, drop_marks=u.container != "file")
        moved_lines.update(range(u.first_line, u.last_line + 1))
        if u.container == "file":
            file_level[name].append(block)
            if u.decl.kind == "extension":
                extension_whole.add(name)
        else:
            members[name].append(block)
    result: dict[str, str] = {}
    for name in place.order:
        out = imports + [""]
        out += [f"// {line}" if line else "//" for line in wrap(place.about[name], 97)]
        if members[name]:
            out.append(f"extension {plan['swift']['class']} {{")
            for k, block in enumerate(members[name]):
                out += trim_leading_blank(block) if k == 0 else block
            out.append("}")
        for block in file_level[name]:
            out.append("")
            out += trim_leading_blank(block)
        result[f"{folder}/{name}"] = "\n".join(collapse_blank(out)) + "\n"
    kept = [line for number, line in enumerate(lines, start=1) if number not in moved_lines]
    result[plan["swift"]["source"]] = "\n".join(collapse_blank(kept)) + "\n"
    for line in report:
        print(f"  widened {line}")
    return result


def collapse_blank(lines: list[str]) -> list[str]:
    """No two blank lines together, and none just inside a closing brace."""
    out: list[str] = []
    for line in lines:
        if not line.strip() and out and not out[-1].strip():
            continue
        if line.strip() == "}" and out and not out[-1].strip():
            out.pop()
        out.append(line)
    while out and not out[-1].strip():
        out.pop()
    return out


def wrap(text: str, width: int) -> list[str]:
    out, line = [], ""
    for word in text.split():
        if line and len(line) + 1 + len(word) > width:
            out.append(line)
            line = word
        else:
            line = f"{line} {word}".strip()
    if line:
        out.append(line)
    return out


def split_metal(plan: dict) -> dict[str, str]:
    text, items, place, problems = metal_state(plan)
    if problems:
        fail("; ".join(problems))
    lines = lines_of(text)
    folder = plan["metal"]["folder"]
    previous = 0
    blocks: dict[str, list[list[str]]] = {name: [] for name in place.order}
    moved: set[int] = set()
    for item in items:
        first = previous + 1
        previous = item.last_line
        name = place.target[item.key]
        if not name:
            continue
        blocks[name].append(lines[first - 1:item.last_line])
        moved.update(range(first, item.last_line + 1))
    result = {}
    for name in place.order:
        out = [f"// {line}" if line else "//" for line in wrap(place.about[name], 97)]
        for k, block in enumerate(blocks[name]):
            out += [""] + trim_leading_blank(block) if k == 0 else block
        result[f"{folder}/{name}"] = "\n".join(collapse_blank(out)) + "\n"
    kept = [line for number, line in enumerate(lines, start=1) if number not in moved]
    result[plan["metal"]["source"]] = "\n".join(collapse_blank(kept)) + "\n"
    return result


def shader_library() -> str:
    """The file that lists the shaders compiled together (`ShaderLibrary.make`)."""
    found = [path for path in git("ls-files", "Sources").split()
             if path.endswith(".swift") and re.search(r'let files = \[\s*"Solver",',
                                                      (ROOT / path).read_text(encoding="utf-8"))]
    if len(found) != 1:
        fail(f"ShaderLibrary's list of shader files, starting with \"Solver\", is in {len(found)} files")
    return found[0]


def library_edit(plan: dict, text: str) -> str:
    """ShaderLibrary's list of files with the new Metal files right after Solver."""
    names = [Path(name).stem for name in plan["metal"]["files"]]
    if all(f'"{n}"' in text for n in names):
        return text
    anchor = re.search(r'let files = \[\s*"Solver",', text)
    if not anchor:
        fail("ShaderLibrary's file list does not start with \"Solver\"")
    insert = "".join(f' "{n}",' for n in names)
    return text[:anchor.end()] + insert + text[anchor.end():]


def affected_edit(text: str) -> str:
    """check-affected's core files: the new BlastSolver files are as core as the old one."""
    if r"BlastSolver(\+\w+)?" in text:
        return text
    if "(BlastSolver|" not in text:
        fail(f"{CHECK_AFFECTED}: the core files' pattern no longer names BlastSolver")
    return text.replace("(BlastSolver|", r"(BlastSolver(\+\w+)?|", 1)


def reference_edits(plan: dict, texts: dict[str, str]) -> dict[str, str]:
    """Documents and comments that say a moved kernel or function is in Solver.metal or
    BlastSolver.swift: the file it is in now."""
    _, items, metal_place, _ = metal_state(plan)
    _, _, units, swift_place, _ = swift_state(plan)
    moved = {}
    for item in items:
        if metal_place.target[item.key]:
            for name in item.names:
                moved[(name, "Solver.metal")] = metal_place.target[item.key]
    for u in units:
        if swift_place.target.get(u.key) and u.decl.name and u.container != "file":
            moved.setdefault((u.decl.name, "BlastSolver.swift"), swift_place.target[u.key])
    changed = {}
    paths = git("ls-files", "Sources", "Tests", "docs", "Scripts").split()
    for path in paths:
        if not path.endswith((".swift", ".metal", ".md")) or path.startswith("Scripts/split/"):
            continue
        original = texts.get(path) or (ROOT / path).read_text(encoding="utf-8")
        new = original
        for (name, old), file in moved.items():
            for pattern, replacement in (
                    (f"`{name}` in {old}", f"`{name}` in {file}"),
                    (f"`{name}` in `{old}`", f"`{name}` in `{file}`"),
                    (f"`{name}`, in {old}", f"`{name}`, in {file}"),
                    (f"`{name}` ({old})", f"`{name}` ({file})")):
                new = new.replace(pattern, replacement)
        if new != original:
            changed[path] = new
        # What the patterns above do not catch: a moved name on a line that names the old file.
        for number, line in enumerate(new.split("\n"), start=1):
            for old in ("Solver.metal", "BlastSolver.swift"):
                if old not in line:
                    continue
                names = [n for n in re.findall(r"`(\w+)`", line) if (n, old) in moved]
                if names:
                    print(f"  to read: {path}:{number}: {', '.join(names)} named with {old}")
    return changed


def split(plan: dict) -> None:
    folder = ROOT / plan["swift"]["folder"]
    if all((folder / name).exists() for name in plan["swift"]["files"]):
        print("already split; nothing to do")
        return
    if any((folder / name).exists() for name in plan["swift"]["files"]):
        fail("some of the new Swift files are there and some are not; start from a clean branch")
    if not check(plan, quiet=True):
        fail("the plan no longer describes the tree (run `check` to see where)")
    out = split_swift(plan)
    out |= split_metal(plan)
    library_path = shader_library()
    library = (ROOT / library_path).read_text(encoding="utf-8")
    out[library_path] = library_edit(plan, out.get(library_path, library))
    affected = ROOT / CHECK_AFFECTED
    if affected.exists():
        out[CHECK_AFFECTED] = affected_edit(affected.read_text(encoding="utf-8"))
    out |= reference_edits(plan, out)
    for path, text in out.items():
        target = ROOT / path
        if target.exists() and target.read_text(encoding="utf-8") == text:
            continue
        target.write_text(text, encoding="utf-8")
        print(f"  wrote {path}")


# --- Who edits them -----------------------------------------------------------------------------


def editors(plan: dict, days: int) -> None:
    sources = [plan["swift"]["source"], plan["metal"]["source"]]
    since = (datetime.date.today() - datetime.timedelta(days=days)).isoformat()
    print(f"Commits to main touching the two files since {since}:")
    log = git("log", "origin/main", "--no-merges", f"--since={since}", "--date=format:%Y-%m-%d %H",
              "--format=%x01%h%x09%ad%x09%s", "--numstat", "--", *sources)
    by_day: dict[str, int] = {}
    by_hour: dict[str, int] = {}
    recent: list[str] = []
    for record in log.split("\x01")[1:]:
        head = record.split("\n", 1)[0]
        sha, date, subject = head.split("\t", 2)
        day, hour = date.split()
        by_day[day] = by_day.get(day, 0) + 1
        by_hour[hour] = by_hour.get(hour, 0) + 1
        recent.append(f"{sha} {date}h  {subject[:88]}")
    for day in sorted(by_day):
        print(f"  {day}: {by_day[day]}")
    print("By hour of day (CEST):")
    print("  " + "  ".join(f"{h}:{by_hour[h]}" for h in sorted(by_hour)))
    print("The latest 20:")
    for line in recent[:20]:
        print(f"  {line}")
    print("By the plan's parts (lines changed in each since then):")
    for side, source in (("swift", sources[0]), ("metal", sources[1])):
        counts = churn_by_part(plan, side, source, since)
        for part, count in sorted(counts.items(), key=lambda kv: -kv[1]):
            print(f"  {count:6}  {part or Path(source).name}")
    print("Worktrees with changes to them not on main:")
    for path, branch, files in worktree_changes(sources):
        print(f"  {path} ({branch}): {', '.join(files)}")


def churn_by_part(plan: dict, side: str, source: str, since: str) -> dict[str, int]:
    """Lines added or changed since `since`, by where the plan puts them, from today's blame."""
    blame = git("blame", "--line-porcelain", f"--since={since}", "origin/main", "--", source)
    recent = []
    boundary = False
    for line in blame.split("\n"):
        if line.startswith("boundary"):
            boundary = True
        elif line.startswith("\t"):
            recent.append(not boundary)
            boundary = False
    text = git("show", f"origin/main:{source}")
    if side == "swift":
        _, sf, units, place, _ = swift_state(plan, text)
        spans = [(u.first_line, u.last_line, place.target.get(u.key, "?")) for u in units
                 if u.container != "extension"]
    else:
        _, items, place, _ = metal_state(plan, text)
        spans = [(i.first_line, i.last_line, place.target.get(i.key, "?")) for i in items]
    counts: dict[str, int] = {}
    for first, last, part in spans:
        n = sum(1 for k in range(first - 1, min(last, len(recent))) if recent[k])
        counts[part] = counts.get(part, 0) + n
    return counts


def worktree_changes(sources: list[str]):
    """Each worktree whose branch or working tree changes `sources`: (path, branch, files)."""
    listing = git("worktree", "list", "--porcelain")
    for block in listing.strip().split("\n\n"):
        fields = dict(line.split(" ", 1) for line in block.split("\n") if " " in line)
        path = fields.get("worktree")
        branch = fields.get("branch", "").removeprefix("refs/heads/") or "detached"
        if not path or not Path(path).exists():
            continue

        def changed(*revisions: str) -> set[str]:
            result = subprocess.run(["git", "-C", path, "diff", "--name-only", *revisions, "--", *sources],
                                    capture_output=True, text=True)
            return {Path(f).name for f in result.stdout.split()}

        names = sorted(changed("origin/main...HEAD") | {f"{n} (uncommitted)" for n in changed("HEAD")})
        if names:
            last = subprocess.run(["git", "-C", path, "log", "-1", "--format=%cd", "--date=format:%m-%d %H:%M"],
                                  capture_output=True, text=True).stdout.strip()
            yield path, f"{branch}, last commit {last}", names


# --- Command line -------------------------------------------------------------------------------


def refresh(plan: dict) -> None:
    """Brings the plan up to date with the tree: what it does not name goes with what is above
    it, what it names that is gone is dropped, and the bases are the files as they are. Read the
    plan's difference before committing it."""
    global LENIENT
    LENIENT = True
    try:
        _, _, units, swift_place, _ = swift_state(plan)
        _, items, metal_place, problems = metal_state(plan)
    finally:
        LENIENT = False
    if problems:
        fail("; ".join(problems))
    for side, keys, place in (
            ("swift", [u.key for u in units if u.key in swift_place.target], swift_place),
            ("metal", [i.key for i in items], metal_place)):
        gone = plan_keys(plan, side) - set(keys)
        for key in sorted(gone):
            print(f"  {key}: no longer in {place.source}; dropped from the plan")
        plan[side]["stays"] = [k for k in keys if not place.target[k]]
        for name, spec in plan[side]["files"].items():
            spec["moves"] = [k for k in keys if place.target[k] == name]
        plan[side]["base"] = blob(place.source)
    PLAN.write_text(json.dumps(plan, indent=1, ensure_ascii=False) + "\n", encoding="utf-8")
    print(f"wrote {PLAN.relative_to(ROOT) if PLAN.is_relative_to(ROOT) else PLAN}")


def inventory(plan: dict, side: str | None) -> None:
    if side in (None, "swift"):
        _, sf, units, place, _ = swift_state(plan)
        for u in units:
            fixed = f"  [{u.why_fixed}]" if u.why_fixed else ""
            target = place.target.get(u.key, "(with its extension)" if u.container == "extension"
                                      else "(not placed)") or "stays"
            print(f"swift {u.first_line:5}-{u.last_line:<5} {u.container:9} {u.key:50} {target}{fixed}")
    if side in (None, "metal"):
        _, items, place, _ = metal_state(plan)
        for i in items:
            target = place.target.get(i.key, "(not placed)") or "stays"
            print(f"metal {i.first_line:5}-{i.last_line:<5} {i.key:40} {target}")


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("command", choices=["inventory", "check", "refresh", "split", "editors"])
    parser.add_argument("side", nargs="?", choices=["swift", "metal"])
    parser.add_argument("--days", type=int, default=7)
    parser.add_argument("--root", type=Path, help="the checkout to work on (default: this one)")
    parser.add_argument("--lenient", action="store_true",
                        help="place what the plan does not name with what is above it (porting a branch)")
    args = parser.parse_args(argv)
    global ROOT, LENIENT
    if args.root:
        ROOT = args.root.resolve()
    LENIENT = args.lenient
    plan = load_plan()
    try:
        if args.command == "inventory":
            inventory(plan, args.side)
        elif args.command == "check":
            return 0 if check(plan) else 1
        elif args.command == "refresh":
            refresh(plan)
        elif args.command == "split":
            split(plan)
        else:
            editors(plan, args.days)
    except SplitError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
