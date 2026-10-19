"""Map Sources/BlastCore for the BlastModel split: every file's imports, the types it declares
and uses, and whether it could move to a CPU-only module.

    python3 Scripts/split/import-graph.py            # print the counts
    python3 Scripts/split/import-graph.py --write    # write Scripts/split/classification.json
    python3 Scripts/split/import-graph.py --check    # fail if classification.json is stale
    python3 Scripts/split/import-graph.py --root DIR # read another checkout

It reads source only (Scripts/split/swift_source.py); nothing is compiled, so it runs anywhere and
gives the same answer on every machine. The unit of analysis is a file's top-level declaration
(a type, an extension, a function or a global), and within a type or an extension each member
declared directly in its body. A unit or member is GPU-side when it

- names a Metal, MetalKit or Metal Performance Shaders symbol (`MTL...`, `CAMetal...`, `MTK...`,
  `MPS...`), ContactSearchMetal's `MetalContactSearch`, Apple's Compression library
  (`compression_...`, `COMPRESSION_...`) or `Bundle.module` (the shaders are BlastCore's
  resources);
- is listed in Scripts/split/overrides.json, which names the units that only a Linux build of
  BlastModel showed to need Apple-only Foundation, each with its reason; or
- uses a type, function or global that stays in BlastCore, or a member that only GPU-side code
  declares (a call of `scenario.gpuBuffers()` from a plain type, say).

The last rule is applied until nothing changes. A plain type with GPU-side members still moves
when those members can be cut out of its body into an extension left in BlastCore: computed
properties, methods, subscripts, static properties, nested types, and initialisers that delegate
to `self.init` (a class's convenience initialisers), none of them overridden, inside `#if`, or
sharing a line with what stays. A stored property, an enum case or a protocol requirement that is
GPU-side keeps the whole type in BlastCore. A private member used only by what is cut goes with
it.

Each file is then one of

- `cpu`: everything in it can move, and it imports no Apple-only framework;
- `gpu`: nothing in it can move;
- `mixed`: some of it can move. A mixed file is `clean` when its GPU-side parts can be cut out
  into a new file left in BlastCore: whole top-level declarations, and members cut into
  extensions as above. A file-private top-level helper used by both sides is copied into the new
  file; one used only by the cut goes with it. A private member used across the cut is promoted
  to `package`, as other internal declarations BlastCore uses are. A mixed file that is not clean
  stays whole in BlastCore, and so does everything that uses it.

The test files in Tests/BlastCoreTests are read the same way, whole files only, so that a test
moves to Tests/BlastModelTests only when everything it uses moves too, test helpers included.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from collections import defaultdict
from dataclasses import dataclass, field
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import swift_source as ss  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
SOURCES = "Sources/BlastCore"
TESTS = "Tests/BlastCoreTests"
OUTPUT = "Scripts/split/classification.json"
OVERRIDES = "Scripts/split/overrides.json"
SEAMS = "Scripts/split/seams.json"

# Frameworks that do not exist on Linux. Units that use one stay in BlastCore by the rules above;
# the import itself is left out of the part of the file that moves.
APPLE_ONLY = {
    "Metal", "MetalKit", "MetalPerformanceShaders", "QuartzCore", "Compression", "Accelerate",
    "AppKit", "UIKit", "SwiftUI", "CoreGraphics", "CoreImage", "CoreText", "ImageIO", "ModelIO",
    "SceneKit", "CryptoKit", "os", "Darwin", "IOSurface", "ContactSearchMetal",
}
# Modules BlastModel may import: ContinuumKit 0.1.0-alpha.29's CPU modules that build on Linux,
# this package's RadialBlast, and the toolchain's own. Tests may also use SolidMechanics.
PORTABLE = {"Foundation", "FoundationXML", "simd", "RadialBlast", "SceneModel", "Numerics",
            "GeometryImport", "CompressibleFlow", "Dispatch"}
PORTABLE_TESTS = PORTABLE | {"Testing", "XCTest", "SolidMechanics", "BlastCore"}
GPU_API = re.compile(r"^(MTL|CAMetal|MTK|MPS|IOSurface)\w*$|^(compression|COMPRESSION)_\w+$")
GPU_NAMES = {"MetalContactSearch"}
CUTTABLE_KINDS = {"func", "var", "let", "subscript", "init", "typealias", "struct", "enum",
                  "class", "actor"}


def member_label(d: ss.Decl, ordinal: int) -> str:
    """`func name`, or `init #2` for a type's second initialiser."""
    label = f"{d.kind} {d.name}" if d.name else d.kind
    return label + (f" #{ordinal + 1}" if ordinal else "")


def member_ordinals(decl: ss.Decl) -> list[int]:
    seen: dict[tuple[str, str], int] = defaultdict(int)
    out = []
    for m in decl.members:
        out.append(seen[(m.kind, m.name)])
        seen[(m.kind, m.name)] += 1
    return out


@dataclass
class Member:
    decl: ss.Decl
    idents: set[str]
    dotted: set[str]
    roots: list[str]
    lines: tuple[int, int]
    ordinal: int = 0  # which of its type's members with this kind and name
    qualified: set = field(default_factory=set)
    cut: str | None = None  # why it is cut out into BlastCore, once it is

    @property
    def label(self) -> str:
        return member_label(self.decl, self.ordinal)


@dataclass
class Unit:
    file: "FileInfo"
    decl: ss.Decl
    ordinal: int  # which of the file's units with this kind and name
    idents: set[str]
    dotted: set[str]
    header_idents: set[str]
    members: list[Member]
    qualified: set = field(default_factory=set)
    roots: list[str] = field(default_factory=list)
    stays: list[str] = field(default_factory=list)  # why it stays, once it does

    @property
    def label(self) -> str:
        d = self.decl
        name = d.name or d.kind
        label = f"{d.kind} {name}" if d.kind != name else name
        return label + (f" #{self.ordinal + 1}" if self.ordinal else "")

    @property
    def key(self) -> str:
        return f"{self.file.name}:{self.label}"

    @property
    def private(self) -> bool:
        return self.decl.access in ("private", "fileprivate")

    @property
    def is_type(self) -> bool:
        return self.decl.kind in ss.TYPE_KINDS and self.decl.body_open is not None

    @property
    def extended(self) -> str | None:
        """The type a type declaration or an extension adds to (its first component)."""
        if self.decl.kind in ss.TYPE_KINDS:
            return self.decl.name.split(".")[0]
        return None

    def cut_members(self) -> list[Member]:
        return [m for m in self.members if m.cut]

    def moving_members(self) -> list[Member]:
        return [m for m in self.members if not m.cut]


@dataclass
class FileInfo:
    path: str  # relative to the repository
    name: str
    source: ss.SourceFile
    imports: list[dict]
    units: list[Unit] = field(default_factory=list)
    is_test: bool = False


def gpu_roots(idents: set[str], dotted: set[str]) -> list[str]:
    roots = []
    hits = sorted(n for n in idents if GPU_API.match(n) or n in GPU_NAMES)
    if hits:
        roots.append("uses " + ", ".join(hits[:6]) + (" ..." if len(hits) > 6 else ""))
    if "Bundle" in idents and "module" in dotted:
        roots.append("loads BlastCore's resources (Bundle.module)")
    return roots


def load_seams(root: Path) -> list[dict]:
    path = root / SEAMS
    return json.loads(path.read_text(encoding="utf-8"))["seams"] if path.exists() else []


def apply_seams(rel: str, text: str, seams: list[dict]) -> str:
    """`text` of the file at `rel` with the seams' edits made, or as it is where they already
    are. An edit whose old text and new text are both missing, or either occurs more than once,
    is an error: the file has changed since the seam was written."""
    for seam in seams:
        for edit in seam["edits"]:
            if edit["file"] != rel:
                continue
            new = text.count(edit["new"])
            # Already made: the new text once, and the old text nowhere outside it.
            if new == 1 and text.replace(edit["new"], "").count(edit["old"]) == 0:
                continue
            old = text.count(edit["old"])
            if old == 1 and new == 0:
                text = text.replace(edit["old"], edit["new"])
            else:
                raise SeamError(f"seam {seam['id']}: {rel} has its old text {old} times and its "
                                f"new text {new} times; expected once and never, or never and "
                                f"once")
    return text


class SeamError(RuntimeError):
    pass


def load(root: Path, folder: str, is_test: bool, seams: list[dict] = ()) -> list[FileInfo]:
    files = []
    for path in sorted((root / folder).glob("*.swift")):
        text = apply_seams(path.relative_to(root).as_posix(), path.read_text(encoding="utf-8"),
                           list(seams))
        try:
            sf = ss.parse(text)
        except ss.SwiftSyntaxError as e:
            raise SystemExit(f"{path}: {e}")
        rel = path.relative_to(root).as_posix()
        imports = [
            {"module": d.name, "attributes": d.attributes, "conditions": list(d.conditions)}
            for d in sf.decls if d.kind == "import"
        ]
        info = FileInfo(rel, path.name, sf, imports, is_test=is_test)
        seen: dict[tuple[str, str], int] = defaultdict(int)
        for d in sf.decls:
            if d.kind == "import":
                continue
            names, dotted = ss.identifiers(sf, d.header, d.end)
            if d.body_open is not None and d.kind in ss.TYPE_KINDS:
                header_names, _ = ss.identifiers(sf, d.header, d.body_open)
            else:
                header_names = names
            members = []
            if d.kind in ss.TYPE_KINDS and not is_test:
                for m, n in zip(d.members, member_ordinals(d)):
                    mn, md = ss.identifiers(sf, m.header, m.end)
                    members.append(Member(m, mn, md, gpu_roots(mn, md), sf.lines(m), n,
                                          ss.qualified(sf, m.header, m.end)))
            k = (d.kind, d.name)
            info.units.append(Unit(info, d, seen[k], names, dotted, header_names, members,
                                   ss.qualified(sf, d.header, d.end)))
            seen[k] += 1
        files.append(info)
    return files


def declared_names(decl: ss.Decl) -> set[str]:
    return {m.name for m in decl.walk() if m is not decl and m.name and m.kind != "extension"}


def private_names(decl: ss.Decl) -> set[str]:
    return {m.name for m in decl.walk() if m.name and m.access in ("private", "fileprivate")}


def load_overrides(root: Path) -> dict[str, str]:
    path = root / OVERRIDES
    if not path.exists():
        return {}
    return dict(json.loads(path.read_text(encoding="utf-8")).get("stay", {}))


def stored_property(f: FileInfo, m: ss.Decl) -> bool:
    """Whether `m` (a `var` or `let` in a type's body) is an instance's stored property."""
    if m.kind not in ("var", "let") or "static" in m.modifiers or "class" in m.modifiers:
        return False
    if m.kind == "let" or "lazy" in m.modifiers:
        return True
    toks = f.source.tokens[m.keyword:m.end + 1]
    depth = 0
    for k, t in enumerate(toks):
        if t.text in "([":
            depth += 1
        elif t.text in ")]":
            depth -= 1
        elif depth == 0 and t.kind == "op" and t.text == "=":
            return True
        elif depth == 0 and t.text == "{":
            nxt = toks[k + 1].text if k + 1 < len(toks) else ""
            return nxt in ("willSet", "didSet")
    return True


class Graph:
    def __init__(self, root: Path, seams: bool = True):
        self.root = root
        self.seams = load_seams(root) if seams else []
        self.sources = load(root, SOURCES, False, self.seams)
        self.tests = load(root, TESTS, True, self.seams)
        self.overrides = load_overrides(root)
        self.units = [u for f in self.sources + self.tests for u in f.units]
        # Top-level names and the units declaring them (types, functions, globals, typealiases).
        self.top: dict[str, list[Unit]] = defaultdict(list)
        # Member names (at any depth) and where they are declared: (unit, direct member or None).
        self.member_decls: dict[str, list[tuple[Unit, Member | None]]] = defaultdict(list)
        self.overridden: set[str] = set()
        for u in self.units:
            d = u.decl
            if d.kind != "extension" and d.name:
                self.top[d.name].append(u)
            for m in u.members:
                for x in m.decl.walk():
                    if x.name and x.kind != "extension":
                        self.member_decls[x.name].append((u, m))
            if not u.members:
                for name in declared_names(d):
                    self.member_decls[name].append((u, None))
            for x in d.walk():
                if "override" in x.modifiers and x.name:
                    self.overridden.add(x.name)
        keys = {u.key for u in self.units} | {f"{u.key}/{m.label}" for u in self.units
                                               for m in u.members}
        unknown = set(self.overrides) - keys
        if unknown:
            raise SystemExit("overrides.json names declarations that do not exist: " +
                             ", ".join(sorted(unknown)))
        self.blocked: dict[str, dict] = {}
        self.tests_using: dict[str, list[Unit]] = defaultdict(list)
        for f in self.tests:
            for u in f.units:
                for name in u.idents:
                    self.tests_using[name].append(u)

    # Which declarations a name can refer to, and whether they stay.

    def providers(self, u: Unit, name: str) -> list[Unit]:
        """The units that a use of top-level `name` in `u` can refer to."""
        cands = [c for c in self.top.get(name, []) if c is not u]
        local = [c for c in cands if c.file is u.file]
        if local:
            return local
        # Test files see the sources; sources never see the tests.
        return [c for c in cands if not c.private and (u.file.is_test or not c.file.is_test)]

    @staticmethod
    def member_stays(p: tuple[Unit, Member | None]) -> bool:
        unit, m = p
        return bool(unit.stays) or (m is not None and m.cut is not None)

    def reason(self, u: Unit, idents: set[str], dotted: set[str], own: set[str],
               self_type: str | None, qualified: set = frozenset()) -> str | None:
        # `Type.member`, where every declaration of that member of that type stays.
        for typ, name in sorted(qualified):
            if typ not in self.top:
                continue
            hits = [p for p in self.member_decls.get(name, []) if p[0].extended == typ]
            if hits and all(self.member_stays(p) for p in hits):
                return f"uses {typ}.{name} ({hits[0][0].file.name}), which stays"
        for name in sorted(idents - own):
            provs = self.providers(u, name)
            if provs and all(p.stays for p in provs):
                return f"uses {name} ({provs[0].file.name}), which stays"
        # Members that only staying code declares, of a type this code names or extends.
        named = {n for n in idents if n in self.top} | ({self_type} if self_type else set())
        candidates = dotted | (idents if self_type else set())
        for name in sorted(candidates - own):
            provs = self.member_decls.get(name)
            if not provs:
                continue
            # A name its own type declares means that declaration; otherwise one of a type it
            # names. Either way it is GPU-side only if every such declaration stays.
            mine = [p for p in provs if self_type and p[0].extended == self_type]
            if not mine and name not in dotted:
                continue
            hits = mine or [p for p in provs if p[0].extended in named]
            if not hits or any(not self.member_stays(p) for p in hits):
                continue
            if not mine and (any(not self.member_stays(p) for p in provs) or
                             any(not p.stays for p in self.top.get(name, []))):
                continue
            return f"uses {hits[0][0].extended}.{name} ({hits[0][0].file.name}), which stays"
        return None

    def init_first_labels(self, type_name: str) -> dict[str, list[tuple[Unit, Member]]]:
        """The initialisers of `type_name`, by the label of their first argument."""
        cache = self.__dict__.setdefault("_init_labels", {})
        if type_name not in cache:
            cache[type_name] = self._init_first_labels(type_name)
        return cache[type_name]

    def _init_first_labels(self, type_name: str) -> dict[str, list[tuple[Unit, Member]]]:
        out: dict[str, list[tuple[Unit, Member]]] = defaultdict(list)
        for u in self.units:
            if u.extended != type_name:
                continue
            for m in u.members:
                if m.decl.kind != "init":
                    continue
                toks = u.file.source.tokens
                k = m.decl.keyword
                while k < m.decl.end and toks[k].text != "(":
                    k += 1
                label = toks[k + 1].text if k + 1 <= m.decl.end else ""
                out[label].append((u, m))
        return out

    def init_reason(self, u: Unit, sf: ss.SourceFile, first: int, last: int,
                    itself: Member | None = None) -> str | None:
        """A call of an initialiser by its type and first label, `Type(label: ...)` or
        `self.init(label: ...)`, where every initialiser of that type with that label stays."""
        for typ, label in sorted(ss.init_calls(sf, first, last)):
            if typ == "self":
                typ = u.extended or ""
            if typ not in self.top:
                continue
            targets = [p for p in self.init_first_labels(typ).get(label, []) if p[1] is not itself]
            if targets and all(self.member_stays(p) for p in targets):
                return f"uses {typ}.init({label}:) ({targets[0][0].file.name}), which stays"
        return None

    def delegation(self, u: Unit, m: Member) -> str | None:
        return self.init_reason(u, u.file.source, m.decl.header, m.decl.end, m)

    def cuttable(self, u: Unit, m: Member) -> str | None:
        """Why member `m` of unit `u` cannot be cut out into an extension, or None."""
        d = m.decl
        kind = u.decl.kind
        if kind == "protocol":
            return "it is a protocol requirement"
        if d.kind not in CUTTABLE_KINDS:
            return f"it is {'an enum case' if d.kind == 'case' else 'a ' + d.kind}"
        if stored_property(u.file, d):
            return "it is a stored property"
        if d.conditions != u.decl.conditions:
            return "it sits inside #if"
        if "override" in d.modifiers or "required" in d.modifiers or "dynamic" in d.modifiers:
            return "it overrides or is required"
        extended_kinds = {p.decl.kind for p in self.top.get(u.extended or "", [])}
        if d.kind == "init":
            if "class" in extended_kinds or kind == "class":
                if "convenience" not in d.modifiers:
                    return "it is a class's designated initialiser"
            else:
                body = " ".join(t.text for t in u.file.source.tokens[d.header:d.end + 1])
                if "self . init" not in body and "self =" not in body:
                    return "an initialiser in another module's extension must delegate"
        if kind == "class" or "class" in extended_kinds:
            if d.name and d.name in self.overridden:
                return "a subclass overrides it"
        a, b = m.lines
        for other in u.members:
            if other is not m:
                oa, ob = other.lines
                if oa <= b and a <= ob:
                    return "it shares a line with another member"
        toks = u.file.source.tokens
        if u.decl.body_open is not None and toks[u.decl.body_open].line >= a:
            return "it shares a line with its type's opening brace"
        if u.decl.end >= 0 and toks[u.decl.end].line <= b:
            return "it shares a line with its type's closing brace"
        return None

    def classify(self) -> None:
        for u in self.units:
            u.roots = gpu_roots(u.idents, u.dotted) if not u.members else gpu_roots(
                u.header_idents, set())
            if u.key in self.overrides:
                u.roots.append(self.overrides[u.key])
            allowed = PORTABLE_TESTS if u.file.is_test else PORTABLE
            for imp in u.file.imports:
                if imp["module"] not in allowed and imp["module"] not in APPLE_ONLY:
                    u.roots.append(f"its file imports {imp['module']}, which BlastModel may not")
                elif u.file.is_test and imp["module"] in APPLE_ONLY:
                    u.roots.append(f"its file imports {imp['module']}")
            for m in u.members:
                key = f"{u.key}/{m.label}"
                if key in self.overrides:
                    m.roots.append(self.overrides[key])
            u.stays = list(u.roots)
        changed = True
        while changed:
            changed = False
            self.file_classes = {f.path: self.file_class(f) for f in self.sources + self.tests}
            for path, fc in self.file_classes.items():
                if fc["class"] == "mixed" and not fc["clean"] and path not in self.blocked:
                    self.blocked[path] = fc
                    changed = True
            for u in self.units:
                if u.stays:
                    continue
                if u.file.path in self.blocked:
                    u.stays = ["its file cannot be split cleanly"]
                    changed = True
                    continue
                if not u.members:
                    why = self.reason(u, u.idents, u.dotted, {u.decl.name} | declared_names(u.decl),
                                      u.extended, u.qualified) or self.init_reason(
                                          u, u.file.source, u.decl.header, u.decl.end)
                    if not why and u.file.is_test:
                        # A test helper that tests staying in BlastCoreTests use stays with them.
                        # Its name; or, for an extension (`extension Trait where Self == ...`),
                        # what it adds.
                        names = declared_names(u.decl) if u.decl.kind == "extension" else \
                            {u.decl.name}
                        users = [x for n in sorted(names) for x in self.tests_using.get(n, [])
                                 if x.stays and x.file is not u.file]
                        if users:
                            why = f"{users[0].file.name}, which stays, uses it"
                    if why:
                        u.stays = [why]
                        changed = True
                    continue
                own = set() if u.decl.kind == "extension" else {u.decl.name}
                why = self.reason(u, u.header_idents, set(), own, None)
                if why:
                    u.stays = [why]
                    changed = True
                    continue
                for m in u.moving_members():
                    why = m.roots[0] if m.roots else self.reason(
                        u, m.idents, m.dotted, declared_names(m.decl) | {m.decl.name}, u.extended,
                        m.qualified) or self.delegation(u, m)
                    if not why and m.decl.access in ("private", "fileprivate") and m.decl.name:
                        # A private member used by cut members and by nothing that moves goes too.
                        users = [x for x in u.members if x is not m and m.decl.name in x.idents]
                        if users and all(x.cut for x in users):
                            why = "only cut members use it"
                    if not why:
                        continue
                    blocker = self.cuttable(u, m)
                    if blocker:
                        u.stays = [f"its {m.label} {why[0].lower() + why[1:]}, and {blocker}"]
                    else:
                        m.cut = why
                    changed = True
                    if u.stays:
                        break
                if not u.stays and u.members and not u.moving_members() and \
                        u.decl.kind == "extension":
                    # Nothing would be left of it: the whole extension stays.
                    u.stays = [u.members[0].cut]
                    for m in u.members:
                        m.cut = None
                    changed = True

    def file_class(self, f: FileInfo) -> dict:
        if f.path in self.blocked:
            return self.blocked[f.path]
        moving = [u for u in f.units if not u.stays]
        staying = [u for u in f.units if u.stays]
        apple = [i["module"] for i in f.imports if i["module"] in APPLE_ONLY and
                 not any("canImport" in c for c in i["conditions"])]
        trimmed = [u for u in moving if u.cut_members()]
        if not staying and not apple and not trimmed:
            return {"class": "cpu", "clean": True}
        if not moving:
            return {"class": "gpu", "clean": False}
        if f.is_test:
            return {"class": "mixed", "clean": False, "cut": staying, "copies": [],
                    "moving": moving, "apple_imports": apple, "promotions": [],
                    "blockers": ["a test file moves whole or not at all"]}
        blockers: list[str] = []
        copies: list[Unit] = []
        cut = list(staying)

        def cut_idents() -> list[tuple[str, set[str]]]:
            out = [(c.label, c.idents) for c in cut]
            out += [(f"{u.label}.{m.label}", m.idents) for u in moving for m in u.cut_members()]
            return out

        # File-private top-level helpers: used only by the cut, they go with it; used by both
        # sides, they are copied.
        for u in moving:
            if not (u.private and u.decl.kind in ("func", "let", "var")):
                continue
            used_by_cut = any(u.decl.name in ids for _, ids in cut_idents())
            used_by_moving = any(u.decl.name in (x.idents if not x.members else
                                                 set().union(*(m.idents for m in
                                                               x.moving_members())))
                                 for x in moving if x is not u)
            if used_by_cut and not used_by_moving:
                cut.append(u)
            elif used_by_cut:
                copies.append(u)
        cut_ids = {id(c) for c in cut}
        moving = [u for u in moving if id(u) not in cut_ids]
        copy_names = {c.decl.name for c in copies}
        moving_private: dict[str, str] = {}
        for u in moving:
            parts = [m.decl for m in u.moving_members()] if u.members else [u.decl]
            for part in parts:
                for n in private_names(part):
                    moving_private.setdefault(n, u.label)
        promotions = []
        for label, ids in cut_idents():
            for n in sorted(ids & set(moving_private)):
                if n in copy_names:
                    continue
                promotions.append({"member": n, "of": moving_private[n], "used_by": label})
                clash = [p for p in self.member_decls.get(n, []) if p[0].file is not f
                         and p[0].extended in {moving_private[n].split(" ")[-1]}]
                if clash:
                    blockers.append(f"{label} uses private {n} of {moving_private[n]}, and "
                                    f"{clash[0][0].file.name} declares another")
        # Private initialisers the cut calls, by type and first label.
        cut_parts = [(c.decl.header, c.decl.end) for c in cut] + [
            (m.decl.header, m.decl.end) for u in moving for m in u.cut_members()]
        calls = set()
        for a, b in cut_parts:
            for typ, label in ss.init_calls(f.source, a, b):
                calls.add(label)
        for u in moving:
            for m in u.moving_members():
                d = m.decl
                if d.kind == "init" and d.access in ("private", "fileprivate"):
                    toks = f.source.tokens
                    k = d.keyword
                    while k < d.end and toks[k].text != "(":
                        k += 1
                    label = toks[k + 1].text
                    if label in calls:
                        promotions.append({"member": f"init({label}:)", "of": u.label,
                                           "used_by": "the cut"})
        lines_moving: set[int] = set()
        for u in moving:
            a, b = f.source.lines(u.decl)
            lines_moving.update(range(a, b + 1))
        for c in cut:
            a, b = f.source.lines(c.decl)
            if lines_moving & set(range(a, b + 1)):
                blockers.append(f"{c.label} shares a line with a declaration that moves")
            if c.decl.conditions:
                blockers.append(f"{c.label} sits inside #if {c.decl.conditions[0]}")
            if c.decl.kind == "extension":
                for m in c.decl.members:
                    if m.kind != "init":
                        continue
                    body = " ".join(t.text for t in f.source.tokens[m.header:m.end + 1])
                    moving_struct = any(p.decl.kind == "struct" and not p.stays
                                        for p in self.top.get(c.extended, []))
                    if moving_struct and "self . init" not in body and "self =" not in body:
                        blockers.append(f"{c.label} has an initialiser that does not delegate")
        for u in moving:
            if u.decl.conditions and any(u.decl.conditions == c.decl.conditions for c in cut):
                blockers.append(f"{u.label} shares an #if block with the cut")
        return {"class": "mixed", "clean": not blockers, "blockers": sorted(set(blockers)),
                "cut": cut, "copies": copies, "moving": moving, "apple_imports": apple,
                "promotions": promotions}

    def report(self) -> dict:
        def unit_entry(u: Unit) -> dict:
            a, b = u.file.source.lines(u.decl)
            entry = {"unit": u.label, "lines": [a, b]}
            if u.stays:
                entry["reason"] = u.stays[0]
            cut = u.cut_members()
            if cut and not u.stays:
                entry["cut_members"] = [{"member": m.label, "lines": list(m.lines),
                                         "reason": m.cut} for m in cut]
            return entry

        def file_entry(f: FileInfo) -> dict:
            fc = self.file_classes[f.path]
            declared = sorted({u.decl.name for u in f.units if u.decl.kind != "extension"
                               and u.decl.name} |
                              {f"{u.decl.name}.{x.name}" for u in f.units
                               if u.decl.kind in ss.TYPE_KINDS for x in u.decl.members
                               if x.kind in (ss.TYPE_KINDS - {"extension"}) | {"typealias"}})
            extensions = sorted({u.decl.name for u in f.units if u.decl.kind == "extension"})
            idents = set().union(*(u.idents for u in f.units)) if f.units else set()
            own = {u.decl.name for u in f.units}
            uses = sorted(n for n in idents - own if n in self.top and any(
                not p.file.is_test for p in self.top[n]))
            entry = {
                "path": f.path,
                "imports": [i["module"] if not i["attributes"] and not i["conditions"] else
                            {"module": i["module"], **({"attributes": i["attributes"]}
                                                       if i["attributes"] else {}),
                             **({"conditions": i["conditions"]} if i["conditions"] else {})}
                            for i in f.imports],
                "declares": declared,
                "extends": extensions,
                "uses": uses,
                "gpu_api": sorted(n for n in idents if GPU_API.match(n) or n in GPU_NAMES),
                "class": fc["class"],
                "moves": fc["class"] == "cpu" or (fc["class"] == "mixed" and fc["clean"]),
            }
            if f.is_test:
                entry["tests"] = count_tests(f)
            if fc["class"] == "gpu":
                reasons = []
                for u in f.units:
                    for r in u.stays:
                        if r not in reasons:
                            reasons.append(r)
                entry["reasons"] = reasons[:8]
            if fc["class"] == "mixed":
                entry["clean"] = fc["clean"]
                entry["cut"] = [unit_entry(u) for u in fc["cut"]]
                trimmed = [u for u in fc["moving"] if u.cut_members()]
                if trimmed:
                    entry["cut_members"] = [
                        {"unit": u.label, "member": m.label, "lines": list(m.lines),
                         "reason": m.cut} for u in trimmed for m in u.cut_members()]
                if fc["copies"]:
                    entry["copied"] = [unit_entry(u) for u in fc["copies"]]
                if fc["promotions"]:
                    entry["promoted"] = fc["promotions"]
                entry["kept"] = [unit_entry(u) for u in fc["moving"]]
                if fc["apple_imports"]:
                    entry["dropped_imports"] = fc["apple_imports"]
                if fc["blockers"]:
                    entry["blockers"] = fc["blockers"]
            return entry

        files = [file_entry(f) for f in self.sources]
        tests = [file_entry(f) for f in self.tests]

        def counts(entries):
            c: dict[str, int] = defaultdict(int)
            for e in entries:
                c[e["class"]] += 1
                if e["class"] == "mixed":
                    c["mixed_clean" if e["clean"] else "mixed_blocked"] += 1
                c["moves"] += e["moves"]
            return dict(sorted(c.items()))

        digest = hashlib.sha256()
        for f in self.sources + self.tests:
            digest.update(f.path.encode() + b"\0" + f.source.text.encode() + b"\0")
        return {
            "about": "Written by Scripts/split/import-graph.py --write; the rules are in "
                     "Scripts/split/blastcore_graph.py.",
            "sources": SOURCES,
            "tests_folder": TESTS,
            "input_sha256": digest.hexdigest(),
            "counts": {"sources": counts(files), "tests": counts(tests),
                       "tests_moving": sum(e["tests"] for e in tests if e["moves"]),
                       "tests_total": sum(e["tests"] for e in tests)},
            "seams": [s["id"] for s in self.seams],
            "overrides": dict(sorted(self.overrides.items())),
            "files": files,
            "test_files": tests,
        }


def count_tests(f: FileInfo) -> int:
    """Swift Testing `@Test` functions and XCTest `func test...()` methods."""
    toks = f.source.tokens
    xctest = any(t.text == "XCTestCase" for t in toks)
    n = 0
    for k, t in enumerate(toks):
        if t.kind == "attr" and t.text == "@Test":
            n += 1
        elif xctest and t.text == "func" and k + 1 < len(toks) and \
                toks[k + 1].text.startswith("test"):
            n += 1
    return n


def plan(report: dict) -> dict:
    """What the split acts on, without line numbers or digests: what --check compares."""
    def p(entries):
        return {e["path"]: {
            "class": e["class"], "moves": e["moves"],
            "cut": [c["unit"] for c in e.get("cut", [])],
            "cut_members": [f"{c['unit']}/{c['member']}" for c in e.get("cut_members", [])],
            "copied": [c["unit"] for c in e.get("copied", [])],
        } for e in entries}
    return {"files": p(report["files"]), "tests": p(report["test_files"]),
            "seams": report.get("seams", [])}


def build(root: Path, seams: bool = True) -> dict:
    graph = Graph(root, seams)
    graph.classify()
    return graph.report()


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="Classify Sources/BlastCore for the BlastModel split.")
    ap.add_argument("--root", type=Path, default=ROOT)
    ap.add_argument("--write", action="store_true", help=f"write {OUTPUT}")
    ap.add_argument("--check", action="store_true", help=f"fail if {OUTPUT} is out of date")
    ap.add_argument("--output", type=Path, help="the file --write and --check use")
    ap.add_argument("--no-seams", action="store_true", help=f"read the files without {SEAMS}")
    args = ap.parse_args(argv)
    root = args.root.resolve()
    if not (root / SOURCES).is_dir():
        print(f"error: {root / SOURCES} does not exist", file=sys.stderr)
        return 2
    try:
        report = build(root, not args.no_seams)
    except SeamError as e:
        print(f"error: {e}", file=sys.stderr)
        return 1
    out = args.output or root / OUTPUT
    if args.write:
        out.write_text(json.dumps(report, indent=1, ensure_ascii=False) + "\n", encoding="utf-8")
    if args.check:
        if not out.exists():
            print(f"error: {out} does not exist", file=sys.stderr)
            return 1
        a, b = plan(json.loads(out.read_text(encoding="utf-8"))), plan(report)
        if a != b:
            print(f"error: {out} is out of date for this tree:", file=sys.stderr)
            if a["seams"] != b["seams"]:
                print(f"  seams: recorded {a['seams']}, now {b['seams']}", file=sys.stderr)
            for kind in ("files", "tests"):
                for path in sorted(set(a[kind]) | set(b[kind])):
                    if a[kind].get(path) != b[kind].get(path):
                        print(f"  {path}: recorded {a[kind].get(path)}, now {b[kind].get(path)}",
                              file=sys.stderr)
            print("Run Scripts/split/import-graph.py --write, review the change and commit it.",
                  file=sys.stderr)
            return 1
    c = report["counts"]
    print(f"{SOURCES}: {len(report['files'])} files; " + ", ".join(
        f"{k} {v}" for k, v in c["sources"].items()))
    print(f"{TESTS}: {len(report['test_files'])} files; " + ", ".join(
        f"{k} {v}" for k, v in c["tests"].items()) +
        f"; tests moving {c['tests_moving']} of {c['tests_total']}")
    return 0
