"""The text work of the BlastModel split, driven by Scripts/split/split-blastmodel.sh.

    python3 Scripts/split/split_blastmodel.py prepare [--no-seams]
    python3 Scripts/split/split_blastmodel.py moves [--no-seams]
    python3 Scripts/split/split_blastmodel.py finish [--no-seams]

`prepare` applies the seams (Scripts/split/seams.json), checks that Scripts/split/classification.json
still describes this tree, and splits each clean mixed file in place: the larger part keeps the
file's name (and with it the file's history), the smaller part goes to a new file named
`<Name>+GPU.swift` in Sources/BlastCore or `<Name>+CPU.swift` in Sources/BlastModel. `moves`
prints the `git mv` pairs, one `source destination` per line. `finish`, after the moves, edits
the manifest, adds the imports, widens to `package` the internal declarations of BlastModel that
BlastCore uses, gives the structs BlastCore builds an explicit memberwise initialiser, points
the tests, the Makefile and the documents at the new paths, and installs the Linux simd shim.

Every step looks at the tree before it acts, so a second run changes nothing. A file the plan
names that is in neither its old place nor its new one, or a declaration the plan cuts that is
not where the plan says, stops the run with an error naming it.
"""

from __future__ import annotations

import json
import re
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import blastcore_graph as graph  # noqa: E402
import swift_source as ss  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
CORE = "Sources/BlastCore"
MODEL = "Sources/BlastModel"
CORE_TESTS = "Tests/BlastCoreTests"
MODEL_TESTS = "Tests/BlastModelTests"
SHIM_SOURCE = "Scripts/split/LinuxSIMD.swift"
SHIM = f"{MODEL}/LinuxSIMD.swift"
# Files the split adds from Scripts/split, by where they go.
INSTALLED = {
    SHIM: SHIM_SOURCE,
    f"{MODEL}/SIMDParity.swift": "Scripts/split/SIMDParity.swift",
    f"{MODEL_TESTS}/LinuxSIMDParityTests.swift": "Scripts/split/LinuxSIMDParityTests.swift",
}
EXPORTS = f"{CORE}/BlastModelExports.swift"
# ContinuumKit's first release whose CPU modules build on Linux (its tag's commit).
CK_VERSION = "0.1.0-alpha.29"
CK_REVISION = "eae6589985e5ab8e096d595f352d36447e4573eb"
CK_PRODUCTS = ["SceneModel", "GeometryImport", "CompressibleFlow", "Numerics"]


class SplitError(RuntimeError):
    pass


def fail(message: str) -> None:
    raise SplitError(message)


def read(rel: str) -> str:
    return (ROOT / rel).read_text(encoding="utf-8")


def write(rel: str, text: str) -> None:
    path = ROOT / rel
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


def exists(rel: str) -> bool:
    return (ROOT / rel).exists()


def git(*args: str) -> str:
    return subprocess.run(["git", *args], cwd=ROOT, check=True, text=True,
                          capture_output=True).stdout


def load_plan() -> dict:
    path = ROOT / graph.OUTPUT
    if not path.exists():
        fail(f"{graph.OUTPUT} is missing; run Scripts/split/import-graph.py --write")
    return json.loads(path.read_text(encoding="utf-8"))


def name_of(path: str) -> str:
    return path.rsplit("/", 1)[1]


def stem(path: str) -> str:
    return name_of(path)[:-len(".swift")]


# Line spans of declarations, with the comments directly above them.

def span(sf: ss.SourceFile, decl: ss.Decl, lines: list[str]) -> tuple[int, int]:
    """1-based first and last line of `decl`, with the comment lines directly above it."""
    first, last = sf.lines(decl)
    while first > 1:
        above = lines[first - 2].strip()
        if above.startswith(("///", "//", "/*", "*", "*/")) and above:
            first -= 1
        else:
            break
    return first, last


def find_unit(sf: ss.SourceFile, label: str, path: str) -> ss.Decl:
    seen: dict[tuple[str, str], int] = {}
    for d in sf.decls:
        if d.kind == "import":
            continue
        k = (d.kind, d.name)
        n = seen.get(k, 0)
        seen[k] = n + 1
        name = d.name or d.kind
        lab = (f"{d.kind} {name}" if d.kind != name else name) + (f" #{n + 1}" if n else "")
        if lab == label:
            return d
    fail(f"{path}: the plan cuts `{label}`, which is not in the file; has it changed on main?")
    raise AssertionError


def find_member(sf: ss.SourceFile, unit: ss.Decl, label: str, path: str) -> ss.Decl:
    for m, n in zip(unit.members, graph.member_ordinals(unit)):
        if graph.member_label(m, n) == label:
            return m
    fail(f"{path}: the plan cuts `{label}` from `{unit.kind} {unit.name}`, which has no such "
         f"member; has it changed on main?")
    raise AssertionError


def cut_lines(lines: list[str], removed: set[int], start: int) -> list[str]:
    """Lines after line `start` (1-based) without those in `removed`. Where a cut leaves two
    blank lines together, or a blank line just inside a brace, one blank line goes too; the
    other lines are left as they are."""
    out: list[str] = []
    k = start + 1
    n = len(lines)
    while k <= n:
        if k not in removed:
            out.append(lines[k - 1])
            k += 1
            continue
        while k <= n and k in removed:
            k += 1
        nxt = lines[k - 1] if k <= n else ""
        if out and not out[-1].strip() and (not nxt.strip() or nxt.strip().startswith("}")):
            out.pop()
        elif out and out[-1].rstrip().endswith("{") and not nxt.strip() and k <= n:
            k += 1
    return out


def tidy(lines: list[str]) -> str:
    """Joins lines, with no run of blank lines longer than one and none at either end."""
    out: list[str] = []
    for line in lines:
        if not line.strip() and (not out or not out[-1].strip()):
            continue
        out.append(line.rstrip())
    while out and not out[-1].strip():
        out.pop()
    return "\n".join(out) + "\n"


def prelude_end(sf: ss.SourceFile) -> int:
    """The last line of the imports and comments at the top of the file (0 if none)."""
    units = [d for d in sf.decls if d.kind != "import"]
    if not units:
        return len(sf.text.splitlines())
    lines = sf.text.splitlines()
    first, _ = span(sf, units[0], lines)
    return first - 1


def add_import(prelude: list[str], module: str, testable: bool = False) -> list[str]:
    """`prelude` with `import module` among its plain imports, in order (or among its
    `@testable` imports when `testable`)."""
    statement = f"@testable import {module}" if testable else f"import {module}"
    if any(line.strip() == statement for line in prelude):
        return prelude
    pattern = re.compile(r"^@testable import (\w+)$" if testable else r"^import (\w+)$")
    idx = [k for k, line in enumerate(prelude) if pattern.match(line)]
    if idx:
        for k in idx:
            if pattern.match(prelude[k]).group(1) > module:
                return prelude[:k] + [statement] + prelude[k:]
        return prelude[:idx[-1] + 1] + [statement] + prelude[idx[-1] + 1:]
    # No such imports yet: after the plain imports, separated by a blank line.
    plain = [k for k, line in enumerate(prelude) if re.match(r"^import \w+$", line)]
    at = plain[-1] + 1 if plain else len(prelude)
    insert = [statement] if not testable else ["", statement]
    return prelude[:at] + insert + prelude[at:]


def drop_imports(prelude: list[str], modules: list[str]) -> list[str]:
    return [line for line in prelude if not any(line.strip() == f"import {m}" for m in modules)]


def extension_header(sf: ss.SourceFile, unit: ss.Decl) -> str:
    """`extension Name [where ...] {` for members cut from `unit`, keeping the access and the
    global actor its members had."""
    toks = sf.tokens
    attrs = [a for a in unit.attributes if a in ("@MainActor",)]
    access = ""
    if unit.kind == "extension" and unit.access:
        access = unit.access + " "
    where = ""
    if unit.kind == "extension" and unit.body_open is not None:
        k = unit.keyword
        while k < unit.body_open and toks[k].text != "where":
            k += 1
        if k < unit.body_open:
            where = " " + sf.text[toks[k].start:toks[unit.body_open - 1].end]
    return " ".join(attrs + [f"{access}extension {unit.name}{where} {{"])


def split_text(path: str, text: str, entry: dict) -> tuple[str, str]:
    """The parts of mixed file `path` that move to BlastModel and that stay in BlastCore."""
    sf = ss.parse(text)
    lines = text.splitlines()
    removed: set[int] = set()  # 1-based lines that leave the moving part
    pieces: list[tuple[int, str]] = []  # (first line, text) of the staying part, in order

    def block(first: int, last: int) -> str:
        return "\n".join(lines[first - 1:last])

    for c in entry.get("cut", []):
        d = find_unit(sf, c["unit"], path)
        a, b = span(sf, d, lines)
        removed.update(range(a, b + 1))
        pieces.append((a, block(a, b)))
    for c in entry.get("copied", []):
        d = find_unit(sf, c["unit"], path)
        a, b = span(sf, d, lines)
        pieces.append((a, block(a, b)))
    by_unit: dict[str, list[dict]] = {}
    for c in entry.get("cut_members", []):
        by_unit.setdefault(c["unit"], []).append(c)
    for label, cuts in by_unit.items():
        unit = find_unit(sf, label, path)
        bodies = []
        first_line = None
        for c in cuts:
            m = find_member(sf, unit, c["member"], path)
            a, b = span(sf, m, lines)
            removed.update(range(a, b + 1))
            bodies.append(block(a, b))
            first_line = a if first_line is None else first_line
        pieces.append((first_line, extension_header(sf, unit) + "\n" + "\n\n".join(bodies) +
                       "\n}"))
    # Private members the cut uses are widened to `package` in the part that moves.
    widen: list[tuple[int, int, str]] = []
    for p in entry.get("promoted", []):
        for d in [find_unit(sf, p["of"], path)]:
            for m in d.walk():
                if p["member"].startswith("init(") and m.kind == "init" and \
                        m.access in ("private", "fileprivate") and \
                        init_labels(sf, m)[:1] == [p["member"][5:-2]]:
                    tok = next(t for t in sf.tokens[m.header:m.keyword + 1]
                               if t.text in ("private", "fileprivate"))
                    widen.append((tok.start, tok.end, "package"))
                elif m.name == p["member"] and m.access in ("private", "fileprivate"):
                    tok = next(t for t in sf.tokens[m.header:m.keyword + 1]
                               if t.text in ("private", "fileprivate"))
                    widen.append((tok.start, tok.end, "package"))
    moving_text = text
    for start, end, new in sorted(set(widen), reverse=True):
        moving_text = moving_text[:start] + new + moving_text[end:]
    moving_lines = moving_text.splitlines()
    end = prelude_end(sf)
    prelude = lines[:end]
    model_prelude = drop_imports(moving_lines[:end], entry.get("dropped_imports", []))
    body = cut_lines(moving_lines, removed, end)
    model = tidy(model_prelude + [""] + body)
    core_prelude = add_import([line for line in prelude], "BlastModel")
    pieces.sort(key=lambda p: p[0])
    core = tidy(core_prelude + [""] + "\n\n".join(text for _, text in pieces).splitlines())
    return model, core


def keeps_name(name: str, model: str, core: str) -> bool:
    """Whether the part moving to BlastModel keeps the file's name: the part declaring the type
    the file is named after, or else the larger part."""
    def declares(text: str) -> bool:
        return any(d.name == name and d.kind in ss.TYPE_KINDS - {"extension"}
                   for d in ss.parse(text).decls)
    if declares(model) != declares(core):
        return declares(model)
    return part_lines(model) >= part_lines(core)


def part_lines(text: str) -> int:
    return sum(1 for line in text.splitlines() if line.strip())


def layout(plan: dict) -> list[dict]:
    """Where each source file and test file goes: kind (`move`, `split` or `stay`), the
    file's path before and after, and for a split which part keeps the name."""
    out = []
    for e in plan["files"]:
        path = e["path"]
        dest = f"{MODEL}/{name_of(path)}"
        if not e["moves"]:
            out.append({"kind": "stay", "path": path})
        elif e["class"] == "cpu":
            out.append({"kind": "move", "path": path, "dest": dest})
        else:
            out.append({"kind": "split", "path": path, "dest": dest, "entry": e,
                        "gpu_file": f"{CORE}/{stem(path)}+GPU.swift",
                        "cpu_file": f"{MODEL}/{stem(path)}+CPU.swift"})
    for e in plan["test_files"]:
        path = e["path"]
        if e["moves"]:
            out.append({"kind": "move", "path": path, "dest": f"{MODEL_TESTS}/{name_of(path)}",
                        "test": True})
    return out


# prepare

def apply_seams(use_seams: bool) -> None:
    if not use_seams:
        return
    for seam in graph.load_seams(ROOT):
        for edit in seam["edits"]:
            rel = edit["file"]
            if not exists(rel):
                # Moved by an earlier run, which made the edit first (and may have widened the
                # access in it since).
                if exists(f"{MODEL}/{name_of(rel)}"):
                    continue
                fail(f"seam {seam['id']}: {edit['file']} is missing")
            text = read(rel)
            new = graph.apply_seams(edit["file"], text, [{"id": seam["id"], "edits": [edit]}])
            if new != text:
                write(rel, new)
                print(f"seam {seam['id']}: edited {rel}")


def started(items: list[dict]) -> bool:
    for item in items:
        if item["kind"] in ("move", "split") and exists(item["dest"]):
            return True
        if item["kind"] == "split" and (exists(item["gpu_file"]) or exists(item["cpu_file"])):
            return True
    return exists(MODEL)


def prepare(use_seams: bool) -> None:
    plan = load_plan()
    wanted = [s["id"] for s in graph.load_seams(ROOT)] if use_seams else []
    if plan.get("seams", []) != wanted:
        fail(f"{graph.OUTPUT} was written with the seams {plan.get('seams', [])}, and this run "
             f"would use {wanted}; rewrite it with Scripts/split/import-graph.py --write"
             f"{' --no-seams' if not use_seams else ''}")
    items = layout(plan)
    if not started(items):
        dirty = git("status", "--porcelain", "--untracked-files=no")
        if dirty.strip():
            fail("the working tree has uncommitted changes; commit or stash them first")
    if not started(items):
        apply_seams(use_seams)
        try:
            fresh = graph.build(ROOT, use_seams)
        except graph.SeamError as e:
            fail(str(e))
        if graph.plan(fresh) != graph.plan(plan):
            a, b = graph.plan(plan), graph.plan(fresh)
            lines = []
            for kind in ("files", "tests"):
                for path in sorted(set(a[kind]) | set(b[kind])):
                    if a[kind].get(path) != b[kind].get(path):
                        lines.append(f"  {path}: recorded {a[kind].get(path)}, now "
                                     f"{b[kind].get(path)}")
            fail(f"{graph.OUTPUT} no longer describes this tree:\n" + "\n".join(lines[:40]) +
                 ("\n  ..." if len(lines) > 40 else "") +
                 "\nRun Scripts/split/import-graph.py --write, review the change, commit it and "
                 "run this again.")
    else:
        apply_seams(use_seams)
    for item in items:
        src = item["path"]
        if item["kind"] == "stay":
            if not exists(src):
                fail(f"{src}: the plan keeps it in BlastCore, but it is not there")
            continue
        if item["kind"] == "move":
            if exists(src) == exists(item["dest"]):
                fail(f"{src}: expected it here or at {item['dest']}, " +
                     ("and it is in both" if exists(src) else "and it is in neither"))
            continue
        # A split: done when the new part exists; otherwise the file must still be whole.
        if exists(item["gpu_file"]) or exists(item["cpu_file"]):
            if not (exists(src) or exists(item["dest"])):
                fail(f"{src}: split, but the part that keeps its name is missing")
            continue
        if not exists(src):
            fail(f"{src}: the plan splits it, but it is not there (has it moved on main?)")
        model, core = split_text(src, read(src), item["entry"])
        if keeps_name(stem(src), model, core):
            write(src, model)
            write(item["gpu_file"], core)
            print(f"split {src}: GPU-side part to {item['gpu_file']}")
        else:
            write(src, core)
            write(item["cpu_file"], model)
            item["kind"] = "split-stays"
            print(f"split {src}: CPU-side part to {item['cpu_file']}")


def moves() -> None:
    for item in layout(load_plan()):
        if item["kind"] == "move":
            print(item["path"], item["dest"])
        elif item["kind"] == "split":
            # The part that keeps the name moves only when it is the CPU part.
            if exists(item["gpu_file"]) or (exists(item["dest"]) and not exists(item["path"])):
                print(item["path"], item["dest"])


# finish

def model_dependencies() -> list[str]:
    modules: set[str] = set()
    for path in sorted((ROOT / MODEL).glob("*.swift")):
        for d in ss.parse(path.read_text(encoding="utf-8")).decls:
            if d.kind == "import" and not d.conditions:
                modules.add(d.name)
    unknown = modules - graph.PORTABLE
    if unknown:
        fail(f"{MODEL} imports {', '.join(sorted(unknown))}, which BlastModel may not depend on")
    return sorted(modules & set(CK_PRODUCTS)), "RadialBlast" in modules


def edit_manifest() -> None:
    text = read("Package.swift")
    original = text
    m = re.search(r'exact: "0\.1\.0-alpha\.(\d+)"', text)
    if not m:
        fail("Package.swift: ContinuumKit's exact pin was not found")
    if int(m.group(1)) < 29:
        text = text.replace(m.group(0), f'exact: "{CK_VERSION}"')
    if 'name: "BlastModel"' not in text:
        products, radial = model_dependencies()
        deps = (['"RadialBlast"'] if radial else []) + [
            f'.product(name: "{p}", package: "continuumkit")' for p in products]
        target = (
            "        // The model without the GPU: scenarios, structures, materials and the calculations\n"
            "        // that run on the CPU. It imports no Metal, so it also builds and is tested on Linux\n"
            "        // (Scripts/split/, .github/workflows/linux-blastmodel.yml).\n"
            "        .target(\n"
            '            name: "BlastModel",\n'
            "            dependencies: [\n" +
            "".join(f"                {d},\n" for d in deps) +
            "            ]),\n")
        anchor = "        // Shaders are copied verbatim"
        if anchor not in text:
            fail("Package.swift: the comment above BlastCore's target was not found")
        text = text.replace(anchor, target + anchor, 1)
        text = re.sub(r'(name: "BlastCore",\n\s+dependencies: \[\n)(\s+)"RadialBlast",',
                      r'\1\2"BlastModel", "RadialBlast",', text, count=1)
        if '"BlastModel", "RadialBlast"' not in text:
            fail("Package.swift: BlastCore's dependency list was not found")
        tests = (
            "        .testTarget(\n"
            '            name: "BlastModelTests",\n'
            "            dependencies: [\n"
            '                "BlastModel", "RadialBlast", .product(name: "SolidMechanics", '
            'package: "continuumkit"),\n'
            "            ]),\n")
        anchor = "        // ContinuumKit's SolidMechanics is the reference"
        if anchor not in text:
            fail("Package.swift: the comment above BlastCoreTests was not found")
        text = text.replace(anchor, tests + anchor, 1)
        text = re.sub(r'(name: "BlastCoreTests",\n\s+dependencies: \[\n\s+)"BlastCore",',
                      r'\1"BlastCore", "BlastModel",', text, count=1)
        text = re.sub(r'(name: "BombCADTests",\n\s+dependencies: \[\n\s+)"BombCAD", "BlastCore",',
                      r'\1"BombCAD", "BlastCore", "BlastModel",', text, count=1)
    if "#if os(Linux)" not in text:
        text = text.rstrip("\n") + "\n\n" + (
            "// Metal, AppKit and SwiftUI do not exist on Linux, and ContinuumKit leaves its Metal and\n"
            "// AppKit products out there, so on Linux the package is BlastModel, its tests and\n"
            "// RadialBlast. The Mac builds everything as before. RadialBlast imports simd, which on\n"
            "// Linux is ContinuumKit's stand-in: depending on Numerics, which depends on it there,\n"
            "// makes sure it is built first.\n"
            "#if os(Linux)\n"
            '    let linuxTargets: Set<String> = ["RadialBlast", "BlastModel", "BlastModelTests"]\n'
            "    package.targets.removeAll { !linuxTargets.contains($0.name) }\n"
            "    package.products.removeAll()\n"
            '    for target in package.targets where target.name == "RadialBlast" {\n'
            '        target.dependencies.append(.product(name: "Numerics", package: "continuumkit"))\n'
            "    }\n"
            "#endif\n")
    if text != original:
        write("Package.swift", text)
        print("edited Package.swift")
    resolved = read("Package.resolved")
    m = re.search(r'"version" : "0\.1\.0-alpha\.(\d+)"', resolved)
    if m and int(m.group(1)) < 29:
        resolved = re.sub(r'"revision" : "[0-9a-f]{40}"', f'"revision" : "{CK_REVISION}"', resolved)
        resolved = resolved.replace(m.group(0), f'"version" : "{CK_VERSION}"')
        write("Package.resolved", resolved)
        print(f"edited Package.resolved: ContinuumKit {CK_VERSION} (run `swift package resolve` "
              f"to refresh its originHash)")


def install_files() -> None:
    for dest, source in INSTALLED.items():
        text = read(source)
        if not exists(dest):
            write(dest, text)
            print(f"installed {dest}")
        elif read(dest) != text:
            fail(f"{dest} differs from {source}; reconcile them by hand")
    exports = ("// BlastCore re-exports the model, so that targets importing BlastCore see the types that\n"
               "// moved to BlastModel without importing it themselves.\n"
               "@_exported import BlastModel\n")
    if not exists(EXPORTS):
        write(EXPORTS, exports)
        print(f"wrote {EXPORTS}")


def parse_folder(folder: str, skip: tuple[str, ...] = ()) -> dict[str, ss.SourceFile]:
    out = {}
    for path in sorted((ROOT / folder).glob("*.swift")):
        rel = path.relative_to(ROOT).as_posix()
        if rel in skip or rel in INSTALLED:
            continue
        out[rel] = ss.parse(path.read_text(encoding="utf-8"))
    return out


def all_idents(files: dict[str, ss.SourceFile]) -> set[str]:
    return {t.text for sf in files.values() for t in sf.tokens if t.kind == "ident"}


def add_model_imports(model: dict[str, ss.SourceFile]) -> None:
    """`import BlastModel` in each BlastCore file that names a BlastModel top-level
    declaration, and `@testable import BlastModel` beside each `@testable import BlastCore`."""
    names = {d.name for sf in model.values() for d in sf.decls
             if d.kind not in ("import", "extension") and d.name}
    core = parse_folder(CORE)
    core_names = {d.name for sf in core.values() for d in sf.decls if d.kind != "import"}
    for rel, sf in core.items():
        if rel == EXPORTS:
            continue
        used = {t.text for t in sf.tokens if t.kind == "ident"} & names
        if not used - core_names and not any(
                d.kind == "extension" and d.name.split(".")[0] in names for d in sf.decls):
            continue
        text = sf.text
        end = prelude_end(sf)
        lines = text.splitlines()
        new_prelude = add_import(lines[:end], "BlastModel")
        if new_prelude != lines[:end]:
            write(rel, "\n".join(new_prelude + lines[end:]) + "\n")
    for folder in (CORE_TESTS, "Tests/BombCADTests"):
        for path in sorted((ROOT / folder).glob("*.swift")):
            text = path.read_text(encoding="utf-8")
            if "@testable import BlastCore\n" not in text or "@testable import BlastModel\n" in text:
                continue
            text = text.replace("@testable import BlastCore\n",
                                "@testable import BlastCore\n@testable import BlastModel\n", 1)
            path.write_text(text, encoding="utf-8")


def retarget_moved_tests() -> None:
    for path in sorted((ROOT / MODEL_TESTS).glob("*.swift")):
        text = path.read_text(encoding="utf-8")
        new = re.sub(r"^@testable import BlastCore$", "@testable import BlastModel", text, flags=re.M)
        new = re.sub(r"^import BlastCore$", "import BlastModel", new, flags=re.M)
        if new != text:
            path.write_text(new, encoding="utf-8")


# Widening to `package` what BlastCore uses.

PROMOTABLE = {"struct", "class", "enum", "actor", "protocol", "typealias", "func", "var", "let",
              "init", "subscript"}


def first_modifier_token(sf: ss.SourceFile, d: ss.Decl) -> int:
    """Index of the first token after `d`'s attributes."""
    toks = sf.tokens
    k = d.header
    while k < d.keyword:
        t = toks[k]
        if t.kind == "attr":
            k += 1
            if k < d.keyword and toks[k].text == "(" and toks[k].start == toks[k - 1].end:
                depth = 0
                while k < d.keyword:
                    if toks[k].text == "(":
                        depth += 1
                    elif toks[k].text == ")":
                        depth -= 1
                        if depth == 0:
                            k += 1
                            break
                    k += 1
            continue
        break
    return k


def signature_end(sf: ss.SourceFile, d: ss.Decl) -> int:
    """Index of the last token of `d`'s signature: before its body, or all of it."""
    if d.body_open is not None:
        return d.body_open - 1
    return d.end


def default_argument_idents(sf: ss.SourceFile, d: ss.Decl, last: int) -> set[str]:
    """The identifiers in `d`'s default argument values, which a client module evaluates."""
    if d.kind not in ("func", "init", "subscript"):
        return set()
    toks = sf.tokens
    out: set[str] = set()
    depth = 0
    inside = False
    for t in toks[d.keyword:last + 1]:
        if t.text in "([":
            depth += 1
        elif t.text in ")]":
            depth -= 1
            if depth == 0:
                break
        if depth == 1 and t.text == ",":
            inside = False
        elif depth == 1 and t.kind == "op" and t.text == "=":
            inside = True
        elif inside and t.kind == "ident":
            out.add(t.text)
    return out


def widen_access(dry_run: bool = False) -> dict:
    model = parse_folder(MODEL, (SHIM,))
    core = parse_folder(CORE)
    core_idents = all_idents(core)
    # `$name` is a property wrapper's projection of `name`.
    core_idents |= {n[1:] for n in core_idents if n.startswith("$") and len(n) > 1}
    # Every declaration of BlastModel a modifier can be given, by name.
    decls: list[tuple[str, ss.SourceFile, ss.Decl]] = []
    for rel, sf in model.items():
        for top in sf.decls:
            if top.kind == "import":
                continue
            for d in top.walk():
                decls.append((rel, sf, d))
    by_name: dict[str, list[tuple[str, ss.SourceFile, ss.Decl]]] = {}
    for item in decls:
        if item[2].name:
            by_name.setdefault(item[2].name, []).append(item)

    def owner_type(d: ss.Decl) -> ss.Decl | None:
        p = d.parent
        return p if p is not None and p.kind in ss.TYPE_KINDS else None

    def eligible(d: ss.Decl) -> bool:
        if d.kind not in PROMOTABLE:
            return False
        if d.access not in (None, "internal"):
            return False
        p = owner_type(d)
        if p is not None and p.kind == "protocol":
            return False
        if p is not None and p.kind == "extension" and p.access is not None:
            return False
        if d.kind in ("var", "let") and not re.match(r"^\w+$", d.name or ""):
            return False
        return True

    promoted: dict[int, tuple[str, ss.SourceFile, ss.Decl]] = {}
    queue: list[tuple[str, ss.SourceFile, ss.Decl]] = []

    def promote(item, why: str) -> None:
        if id(item[2]) in promoted or not eligible(item[2]):
            return
        promoted[id(item[2])] = item
        queue.append(item)

    for item in decls:
        if item[2].access == "package":
            queue.append(item)
    for item in decls:
        _, _, d = item
        if d.name and d.name in core_idents:
            promote(item, "BlastCore names it")
        elif d.kind in ("init", "subscript"):
            p = owner_type(d)
            if p is not None and p.name.split(".")[-1] in core_idents:
                promote(item, "BlastCore names its type")
        elif d.kind == "func" and d.name and not re.match(r"^\w", d.name):
            # An operator only on a top-level type BlastCore names. A nested type's name proves
            # little (`CloudRise.State` is not BlastCore's own `State`s, though BlastCore names
            # `CloudRise`), and each operator widened joins the overloads every target of the
            # package sees: CloudRise.State's `+` and `*` were enough to time out the type checker
            # on a SwiftUI body in BombCAD (ThermalSection) at c09d058f. Should BlastCore need an
            # operator of a nested type, the Mac build says so.
            p = owner_type(d)
            if p is not None and "." not in p.path and p.name in core_idents:
                promote(item, "BlastCore names its type")
    # What a widened declaration's signature names must be at least as visible.
    while queue:
        rel, sf, d = queue.pop()
        last = signature_end(sf, d)
        if d.kind in ("struct", "class", "enum", "actor"):
            for m in d.members:
                if m.kind == "case":
                    names, _ = ss.identifiers(sf, m.header, m.end)
                    for n in names:
                        for item in by_name.get(n, []):
                            if item[2].kind in ss.TYPE_KINDS | {"typealias"}:
                                promote(item, "an enum case names it")
        if d.kind == "protocol":
            # Witnesses in types that conform to it.
            reqs = {m.name for m in d.members if m.name}
            for _, sf2, d2 in decls:
                if d2.kind in ss.TYPE_KINDS and d2.body_open is not None:
                    header, _ = ss.identifiers(sf2, d2.header, d2.body_open)
                    if d.name in header:
                        for m in d2.members:
                            if m.name in reqs or (m.kind in ("init", "subscript") and any(
                                    r.kind == m.kind for r in d.members)):
                                promote((None, sf2, m), "it witnesses a widened protocol")
            last = d.end
        names, _ = ss.identifiers(sf, d.header, last)
        for n in names:
            for item in by_name.get(n, []):
                if item[2].kind in ss.TYPE_KINDS | {"typealias"}:
                    promote(item, f"{d.name or d.kind}'s signature names it")
        for n in default_argument_idents(sf, d, last):
            for item in by_name.get(n, []):
                promote(item, f"a default argument of {d.name or d.kind} names it")
        p = owner_type(d)
        while p is not None:
            if p.kind != "extension":
                for item in by_name.get(p.name, []):
                    if item[2] is p:
                        promote(item, "a widened member's type")
            p = owner_type(p)
    # Edits, file by file.
    edits: dict[str, list[tuple[int, int, str]]] = {}
    for _, sf, d in promoted.values():
        rel = next(r for r, s in model.items() if s is sf)
        k = first_modifier_token(sf, d)
        toks = sf.tokens
        explicit = next((t for t in toks[k:d.keyword] if t.text == "internal"), None)
        if explicit is not None:
            edits.setdefault(rel, []).append((explicit.start, explicit.end, "package"))
        else:
            edits.setdefault(rel, []).append((toks[k].start, toks[k].start, "package "))
        for j in range(k, d.keyword):
            if toks[j].text == "internal" and j + 1 < d.keyword and toks[j + 1].text == "(":
                edits[rel].append((toks[j].start, toks[j].end, "package"))
    # `internal(set)` on declarations BlastCore names.
    for rel, sf in model.items():
        toks = sf.tokens
        for k, t in enumerate(toks[:-3]):
            if t.text == "internal" and toks[k + 1].text == "(" and toks[k + 2].text == "set":
                j = k
                while j < len(toks) and toks[j].text not in ("var", "let"):
                    j += 1
                if j + 1 < len(toks) and toks[j + 1].text in core_idents:
                    edits.setdefault(rel, []).append((t.start, t.end, "package"))
    count = 0
    for rel, items in edits.items():
        text = read(rel)
        for start, end, new in sorted(set(items), reverse=True):
            text = text[:start] + new + text[end:]
            count += 1
        if not dry_run:
            write(rel, text)
    return {"promoted": count, "files": len(edits)}


def memberwise_inits(dry_run: bool = False) -> list[str]:
    """An explicit `package` memberwise initialiser, in an extension beside it, for each struct
    that BlastCore builds with its implicit one (internal, so not visible to another module)."""
    model = parse_folder(MODEL, (SHIM,))
    core = parse_folder(CORE)
    called: set[str] = set()
    for sf in core.values():
        toks = sf.tokens
        for k, t in enumerate(toks[:-1]):
            if t.kind == "ident" and toks[k + 1].text == "(" and toks[k + 1].start == t.end:
                called.add(t.text)
            if t.kind == "ident" and toks[k + 1].text == "." and k + 2 < len(toks) and \
                    toks[k + 2].text == "init":
                called.add(t.text)
    # Initialisers declared in extensions, by type: their argument labels.
    existing: dict[str, list[list[str]]] = {}
    for sf in model.values():
        for top in sf.decls:
            if top.kind == "extension":
                for m in top.members:
                    if m.kind == "init":
                        existing.setdefault(top.name.split(".")[-1], []).append(
                            init_labels(sf, m))
    added = []
    for rel, sf in model.items():
        inserts: list[tuple[int, str]] = []  # (offset of the struct's closing brace, text)
        for top in sf.decls:
            for d in top.walk():
                if d.kind == "class" and d.name in called and d.body_open is not None and \
                        not any(m.kind == "init" for m in d.members) and \
                        d.access not in ("private", "fileprivate") and all(
                            graph.stored_property(_Shim(sf), m) is False or has_default(sf, m)
                            for m in d.members if m.kind in ("var", "let")):
                    # A class with only defaulted properties: its implicit init() is internal.
                    close = sf.tokens[d.end]
                    line_start = sf.text.rfind("\n", 0, close.start) + 1
                    pad = sf.text[line_start:close.start] + "    "
                    inserts.append((line_start, f"\n{pad}/// Written out so that BlastCore can "
                                                f"make one.\n{pad}package init() {{}}\n"))
                    added.append(f"{rel}: {graph_path(d)}")
                    continue
                if d.kind != "struct" or d.name not in called:
                    continue
                if any(m.kind == "init" for m in d.members):
                    continue
                if d.access in ("private", "fileprivate"):
                    continue
                stored = [m for m in d.members if m.kind in ("var", "let") and
                          "static" not in m.modifiers and graph.stored_property(_Shim(sf), m)]
                if any(m.access in ("private", "fileprivate") for m in stored):
                    continue  # its memberwise initialiser is private: BlastCore cannot use it
                labels = [m.name for m in stored if not (m.kind == "let" and has_default(sf, m))]
                if labels in existing.get(d.name, []):
                    continue

                params, assigns = [], []
                for m in d.members:
                    if m.kind not in ("var", "let") or "static" in m.modifiers:
                        continue
                    if not graph.stored_property(_Shim(sf), m):
                        continue
                    if m.attributes:
                        added.append(f"{rel}: {d.name}.{m.name} has {m.attributes[0]}; write its "
                                     f"memberwise initialiser by hand")
                        params = None
                        break
                    toks = sf.tokens[m.keyword:m.end + 1]
                    text = sf.text[toks[0].start:toks[-1].end]
                    mm = re.match(r"(var|let)\s+(\w+)\s*:\s*(.+?)(\s*=\s*(.+))?$", text, re.S)
                    if mm:
                        kind, name, typ, _, default = mm.groups()
                    else:
                        mm = re.match(r"(var|let)\s+(\w+)\s*=\s*(.+)$", text, re.S)
                        typ = inferred_type(mm.group(3)) if mm else None
                        if typ is None:
                            fail(f"{rel}: {graph_path(d)}.{m.name} has no written type that the "
                                 f"split can infer, and BlastCore builds {d.name} with its "
                                 f"memberwise initialiser; give the property a type")
                        kind, name, default = mm.group(1), mm.group(2), mm.group(3)
                    if kind == "let" and default is not None:
                        continue
                    if "{" in typ:
                        params = None
                        added.append(f"{rel}: {d.name}.{name} has observers; write by hand")
                        break
                    typ = typ.strip()
                    if default is None and kind == "var" and typ.endswith("?"):
                        default = "nil"
                    params.append(f"{name}: {typ}" + (f" = {default.strip()}" if default else ""))
                    assigns.append(f"        self.{name} = {name}")
                if params is None:
                    continue
                # Inside the struct, where it takes the implicit initialiser's place: one in an
                # extension of the same module would redeclare it.
                close = sf.tokens[d.end]
                line_start = sf.text.rfind("\n", 0, close.start) + 1
                pad = sf.text[line_start:close.start] + "    "
                body = (f"\n{pad}/// The memberwise initialiser, written out so that BlastCore can "
                        f"use it.\n{pad}package init(" +
                        (f"\n" + "".join(f"{pad}    {p},\n" for p in params[:-1]) +
                         f"{pad}    {params[-1]}\n{pad}" if params else "") + ") {\n" +
                        "".join(f"{pad}    {a.strip()}\n" for a in assigns) + f"{pad}}}\n")
                inserts.append((line_start, body))
                added.append(f"{rel}: {graph_path(d)}")
        if inserts and not dry_run:
            text = sf.text
            for at, body in sorted(inserts, reverse=True):
                text = text[:at].rstrip("\n") + "\n" + body + text[at:]
            write(rel, text)
    return added


def graph_path(d: ss.Decl) -> str:
    names = []
    while d is not None:
        names.append(d.name)
        d = d.parent
    return ".".join(reversed(names))


def inferred_type(value: str) -> str | None:
    """The type Swift infers for a stored property's initial `value`, where that is plain from
    the text: a literal, `Type(...)`, `[Element](...)` or `Type.member`."""
    v = value.strip()
    if re.fullmatch(r"-?(0x[0-9a-fA-F_]+|\d[\d_]*)", v):
        return "Int"
    if re.fullmatch(r"-?\d[\d_]*(\.\d[\d_]*)?([eE][-+]?\d+)?", v):
        return "Double"
    if v in ("true", "false"):
        return "Bool"
    if re.fullmatch(r'"[^"\\]*"', v):
        return "String"
    m = re.fullmatch(r"((?:\[[\w<>.,: \[\]?]+\])|(?:[A-Z][\w]*(?:\.[A-Z]\w*)*(?:<[\w<>., \[\]:?]+>)?))"
                     r"(?:\.init)?\(.*\)", v, re.S)
    if m and "(" not in m.group(1):
        return m.group(1)
    m = re.fullmatch(r"([A-Z]\w*(?:<[\w<>., ]+>)?)\.[a-z]\w*", v)
    if m:
        return m.group(1)
    return None


def init_labels(sf: ss.SourceFile, d: ss.Decl) -> list[str]:
    """The argument labels of initialiser `d` (`_` where there is none)."""
    toks = sf.tokens
    labels = []
    depth = 0
    start = True
    for k in range(d.keyword, (d.body_open or d.end) + 1):
        t = toks[k]
        if t.text in "([":
            depth += 1
            if depth == 1:
                start = True
                continue
        elif t.text in ")]":
            depth -= 1
            if depth == 0:
                break
        if depth == 1 and t.text == ",":
            start = True
        elif depth == 1 and start and t.kind == "ident":
            labels.append(t.text)
            start = False
    return labels


def has_default(sf: ss.SourceFile, m: ss.Decl) -> bool:
    depth = 0
    for t in sf.tokens[m.keyword:m.end + 1]:
        if t.text in "([{":
            depth += 1
        elif t.text in ")]}":
            depth -= 1
        elif depth == 0 and t.kind == "op" and t.text == "=":
            return True
    return False


class _Shim:
    """Adapts a parsed file to graph.stored_property, which takes a FileInfo."""

    def __init__(self, sf: ss.SourceFile):
        self.source = sf


def subclass_check() -> None:
    model = parse_folder(MODEL, (SHIM,))
    classes = {d.name for sf in model.values() for d in sf.decls if d.kind == "class"}
    for rel, sf in parse_folder(CORE).items():
        for d in sf.decls:
            if d.kind == "class" and d.body_open is not None:
                header, _ = ss.identifiers(sf, d.keyword + 2, d.body_open)
                hit = header & classes
                if hit:
                    fail(f"{rel}: {d.name} subclasses {', '.join(hit)} from BlastModel, which "
                         f"needs `open`; the split does not handle that")


def rewrite_paths(moved: dict[str, str]) -> None:
    """Points the Makefile, check-affected.py, the shader allow-list and the Moore glass
    tabulator at the files' new places. The documents only mention source paths in prose (no
    Markdown link points into Sources/BlastCore), so they are left for a person to reword."""
    targets = [ROOT / "Scripts/shader-mirrors-allow.txt", ROOT / "Scripts/moore-glass/tabulate.py"]
    for path in targets:
        if not path.exists():
            continue
        text = path.read_text(encoding="utf-8")
        new = text
        for old, dest in moved.items():
            new = re.sub(re.escape(old) + r"(?![\w+])", dest, new)
        if new != text:
            path.write_text(new, encoding="utf-8")
            print(f"pointed {path.relative_to(ROOT)} at the new paths")
    make = read("Makefile")
    new = make.replace("swift test --filter 'BlastCoreTests\\.'",
                       "swift test --filter '(BlastModelTests|BlastCoreTests)\\.'")
    if new != make:
        write("Makefile", new)
        print("Makefile: test-core runs BlastModelTests too")
    affected = read("Scripts/check-affected.py")
    new = affected.replace('re.compile(r"^Sources/BlastCore/(BlastSolver',
                           're.compile(r"^Sources/Blast(Core|Model)/(BlastSolver')
    if new != affected:
        write("Scripts/check-affected.py", new)
        print("Scripts/check-affected.py: the core's files in either module")


def finish(use_seams: bool) -> None:
    plan = load_plan()
    items = layout(plan)
    moved: dict[str, str] = {}
    for item in items:
        if item["kind"] == "move":
            if exists(item["path"]) or not exists(item["dest"]):
                fail(f"{item['path']}: not yet moved to {item['dest']}; run "
                     f"Scripts/split/split-blastmodel.sh")
            moved[item["path"]] = item["dest"]
        elif item["kind"] == "split" and exists(item["gpu_file"]):
            moved[item["path"]] = item["dest"]
    install_files()
    edit_manifest()
    model = parse_folder(MODEL, (SHIM,))
    add_model_imports(model)
    retarget_moved_tests()
    subclass_check()
    # The initialisers first: widening then reaches the types their parameters name.
    for line in memberwise_inits():
        print(f"memberwise initialiser: {line}")
    result = widen_access()
    print(f"widened {result['promoted']} declarations to package in {result['files']} files")
    rewrite_paths({k: v for k, v in moved.items() if not k.startswith("Tests/")})
    git("add", "-A", MODEL, CORE, MODEL_TESTS, CORE_TESTS, "Tests/BombCADTests", "Package.swift",
        "Package.resolved")
    format_changed()


def format_changed() -> None:
    """Formats the Swift files the split changed as `make format` would: `package ` and the
    written-out initialisers lengthen lines past the house limit. Line breaks and spaces only."""
    changed = [line[3:].split(" -> ")[-1] for line in git("status", "--porcelain").splitlines()]
    files = sorted(p for p in changed if p.endswith(".swift") and exists(p) and
                   not p.startswith("Scripts/"))
    if not files:
        return
    try:
        subprocess.run(["swift", "format", "format", "--in-place", *files], cwd=ROOT, check=True,
                       capture_output=True, text=True)
    except (OSError, subprocess.CalledProcessError) as e:
        fail(f"swift format could not run ({e}); run `make format` before committing")
    git("add", *files)
    print(f"formatted {len(files)} Swift files")


def main(argv: list[str]) -> int:
    if not argv or argv[0] not in ("prepare", "moves", "finish"):
        print(__doc__, file=sys.stderr)
        return 2
    use_seams = "--no-seams" not in argv
    try:
        if argv[0] == "prepare":
            prepare(use_seams)
        elif argv[0] == "moves":
            moves()
        else:
            finish(use_seams)
    except SplitError as e:
        print(f"error: {e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
