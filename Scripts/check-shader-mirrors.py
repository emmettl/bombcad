#!/usr/bin/env python3
"""Check that the GPU's structs are laid out alike on both sides: each Swift struct uploaded to a
Metal buffer against the shader struct that reads it, and each shader struct copied into a second
shader file against its original.

    Scripts/check-shader-mirrors.py [--list] [--root DIR] [--allow FILE]

Layouts are computed by the languages' rules, not by a compiler. Metal (the Metal Shading Language
Specification, table 2.2 and section 2.6): `float3`, `int3` and `uint3` take 16 bytes aligned to
16, `packed_float3` 12 aligned to 4, `half` 2, `bool` 1; a struct is aligned to its largest member
and padded to a multiple of that. Swift (MemoryLayout): fields in declaration order, each at the
next multiple of its alignment after the previous field's size; `SIMD3<Float>` takes 16 bytes
aligned to 16; `Bool` 1; a struct's stride is its size rounded up to its alignment. Each side is
reduced to its scalars (offset, size and kind: float, signed or unsigned integer, half, bool), so
`packed_float3 velocity` and `vx, vy, vz` compare equal while a `float` read as a `uint` does not.

Pairs are found by identical names, by a doc comment above a Swift struct that names one shader
struct in backticks ("Layout matches `ShellElement` in `Shell.metal`"), and by `pair` lines in the
allow-list (Scripts/shader-mirrors-allow.txt). A Swift struct used with `MemoryLayout<...>`,
`bindMemory(to:)` or `assumingMemoryBound(to:)` that pairs with nothing is reported too, so a new
buffer type is either paired or listed with a reason.

Reported: a pair whose Metal size differs from the Swift stride, or whose scalars sit at different
offsets or differ in kind; a shader struct copied into two files whose layouts or members differ;
a shader `static_assert(sizeof(...) == N)` this script's own layout disagrees with (a parser bug);
a buffer stride kept as a Swift constant (`size` lines) that differs from the shader's struct; and
types the parser cannot lay out. Exits 1 on any finding the allow-list does not name with a reason,
and on allow-list lines that no longer match anything.

Limitations: the shader source ContinuumKit compiles in (`MetalContactSearch`) lives in another
package and is not read; buffers filled as raw floats rather than through a Swift struct are only
checked where a `size` line names their stride; preprocessor conditionals are ignored."""

import argparse
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ALLOW = Path(__file__).with_name("shader-mirrors-allow.txt")


# --- Layouts -------------------------------------------------------------------------------------


@dataclass
class Leaf:
    offset: int
    size: int
    kind: str
    path: str


@dataclass
class Layout:
    size: int  # Metal: sizeof, padded. Swift: MemoryLayout.size, unpadded.
    align: int
    leaves: list

    @property
    def stride(self):
        return align_up(max(self.size, 1), self.align)


class Unresolved(Exception):
    pass


def align_up(value, align):
    return (value + align - 1) // align * align


def shifted(layout, offset, prefix):
    return [Leaf(offset + l.offset, l.size, l.kind, prefix + l.path) for l in layout.leaves]


def scalar(size, kind):
    return Layout(size, size, [Leaf(0, size, kind, "")])


def vector(element, count, size, align):
    leaves = [Leaf(i * element.size, element.size, element.leaves[0].kind, f".{'xyzw'[i] if count <= 4 else i}")
              for i in range(count)]
    return Layout(size, align, leaves)


def array(element, count, stride=None):
    stride = element.stride if stride is None else stride
    leaves = []
    for i in range(count):
        leaves += shifted(element, i * stride, f"[{i}]")
    return Layout(stride * (count - 1) + element.size if count else 0, element.align, leaves)


def struct_layout(members, padded):
    """`members`: (name, Layout) in declaration order. C rules when `padded` (Metal): size rounded
    up to the alignment. Swift's when not: the size stops at the last field's end."""
    offset, align, leaves = 0, 1, []
    for name, layout in members:
        offset = align_up(offset, layout.align)
        leaves += shifted(layout, offset, name)
        offset += layout.size
        align = max(align, layout.align)
    return Layout(align_up(offset, align) if padded else offset, align, leaves)


# --- Source text ---------------------------------------------------------------------------------


def blank_comments(text, swift=False):
    """`text` with comments (and, for Swift, string literals) replaced by spaces, newlines kept, so
    offsets and line numbers still point into the original."""
    out, i, n = list(text), 0, len(text)

    def blank(start, end):
        for k in range(start, end):
            if out[k] != "\n":
                out[k] = " "

    while i < n:
        if text.startswith("//", i):
            end = text.find("\n", i)
            end = n if end < 0 else end
            blank(i, end)
            i = end
        elif text.startswith("/*", i):
            depth, j = 1, i + 2
            while j < n and depth:
                if text.startswith("/*", j) and swift:
                    depth, j = depth + 1, j + 2
                elif text.startswith("*/", j):
                    depth, j = depth - 1, j + 2
                else:
                    j += 1
            blank(i, j)
            i = j
        elif text.startswith('"""', i) and swift:
            end = text.find('"""', i + 3)
            end = n if end < 0 else end + 3
            blank(i + 3, end - 3)
            i = end
        elif text[i] == '"':
            j = i + 1
            while j < n and text[j] not in '"\n':
                j += 2 if text[j] == "\\" else 1
            blank(i + 1, min(j, n))
            i = j + 1
        else:
            i += 1
    return "".join(out)


def matching_brace(text, start):
    """Index of the `}` closing the `{` at `start`."""
    depth = 0
    for i in range(start, len(text)):
        if text[i] == "{":
            depth += 1
        elif text[i] == "}":
            depth -= 1
            if depth == 0:
                return i
    raise Unresolved("unbalanced braces")


def split_top(text, separator=","):
    """`text` split at `separator` outside brackets of any kind."""
    parts, depth, start = [], 0, 0
    for i, ch in enumerate(text):
        if ch in "([{<":
            depth += 1
        elif ch in ")]}>":
            depth -= 1
        elif ch == separator and depth == 0:
            parts.append(text[start:i])
            start = i + 1
    parts.append(text[start:])
    return [p.strip() for p in parts if p.strip()]


def line_of(text, index):
    return text.count("\n", 0, index) + 1


def evaluate(expression, constants):
    """An array length: an integer, a named constant or simple arithmetic of them."""
    expression = re.sub(r"\b([A-Za-z_]\w*)\b",
                        lambda m: str(constants[m.group(1)]) if m.group(1) in constants else m.group(1),
                        expression)
    expression = re.sub(r"(\d+)[uUlL]+\b", r"\1", expression)
    if not re.fullmatch(r"[\d\s+\-*/()]+", expression):
        raise Unresolved(f"array length `{expression.strip()}`")
    return int(eval(expression, {"__builtins__": {}}))  # digits and operators only, checked above


# --- Metal ---------------------------------------------------------------------------------------

METAL_SCALARS = {
    "bool": (1, "bool"), "char": (1, "i"), "uchar": (1, "u"), "int8_t": (1, "i"), "uint8_t": (1, "u"),
    "short": (2, "i"), "ushort": (2, "u"), "int16_t": (2, "i"), "uint16_t": (2, "u"),
    "half": (2, "f"), "bfloat": (2, "bf"),
    "int": (4, "i"), "uint": (4, "u"), "int32_t": (4, "i"), "uint32_t": (4, "u"), "float": (4, "f"),
    "long": (8, "i"), "ulong": (8, "u"), "int64_t": (8, "i"), "uint64_t": (8, "u"),
    "atomic_int": (4, "i"), "atomic_uint": (4, "u"), "atomic_float": (4, "f"), "atomic_bool": (1, "bool"),
}
METAL_QUALIFIERS = {"const", "device", "constant", "thread", "threadgroup", "volatile", "metal", "struct"}


@dataclass(eq=False)
class MetalStruct:
    name: str
    path: str
    line: int
    members: list  # (type, declarator) as written, spacing normalised
    library: str


def metal_constants(text):
    constants = {}
    for m in re.finditer(r"#define\s+(\w+)\s+\(?(\d+)[uU]?\)?\s*$", text, re.M):
        constants[m.group(1)] = int(m.group(2))
    for m in re.finditer(r"\bconstant\s+(?:constexpr\s+)?(?:static\s+)?(?:const\s+)?\w+\s+(\w+)\s*=\s*(\d+)[uU]?\s*;",
                         text):
        constants[m.group(1)] = int(m.group(2))
    for m in re.finditer(r"\bconstexpr\s+(?:constant\s+)?\w+\s+(\w+)\s*=\s*(\d+)[uU]?\s*;", text):
        constants[m.group(1)] = int(m.group(2))
    return constants


def parse_metal(text, path, library):
    """The structs declared at file scope in a shader source."""
    clean = blank_comments(text)
    structs, depth, i = [], 0, 0
    pattern = re.compile(r"\b(?:typedef\s+)?struct\s+(\w+)\s*\{")
    while i < len(clean):
        ch = clean[i]
        if ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
        elif depth == 0 and ch == "s":
            m = pattern.match(clean, i) if clean.startswith("struct", i) else None
            if m and (i == 0 or not (clean[i - 1].isalnum() or clean[i - 1] == "_")):
                brace = m.end() - 1
                end = matching_brace(clean, brace)
                members = []
                for decl in clean[brace + 1:end].split(";"):
                    decl = re.sub(r"\[\[[^\]]*\]\]", "", decl)
                    decl = " ".join(decl.split())
                    if not decl or "(" in decl:  # a member function's signature
                        continue
                    members.append(decl)
                structs.append(MetalStruct(m.group(1), path, line_of(clean, i), members, library))
                i = end + 1
                continue
        i += 1
    return structs


def metal_declarators(decl):
    """('type', [(name, pointer, [lengths])...]) from one member declaration."""
    parts = split_top(decl)
    first = re.match(r"^(.*?)([\s*]+)(\w+)((?:\s*\[[^\]]*\])*)$", parts[0])
    if not first:
        raise Unresolved(f"member `{decl}`")
    base = first.group(1).strip()
    found = [(first.group(3), "*" in first.group(2), re.findall(r"\[([^\]]*)\]", first.group(4)))]
    for part in parts[1:]:
        m = re.match(r"^([\s*]*)(\w+)((?:\s*\[[^\]]*\])*)$", part)
        if not m:
            raise Unresolved(f"member `{decl}`")
        found.append((m.group(2), "*" in m.group(1), re.findall(r"\[([^\]]*)\]", m.group(3))))
    return base, found


def metal_type(name, lookup):
    words = [w for w in re.split(r"[\s:]+", name.replace("metal::", " ")) if w and w not in METAL_QUALIFIERS]
    if words[:1] == ["unsigned"]:
        words = ["u" + (words[1] if len(words) > 1 else "int")]
        if words[0] == "uchar" or words[0] == "uint" or words[0] == "ushort":
            pass
    name = " ".join(words)
    m = re.fullmatch(r"atomic<\s*(\w+)\s*>", name)
    if m:
        name = "atomic_" + m.group(1)
    if name in METAL_SCALARS:
        return scalar(*METAL_SCALARS[name])
    m = re.fullmatch(r"(packed_)?(bool|char|uchar|short|ushort|half|int|uint|float|long|ulong|bfloat)([234])", name)
    if m:
        element = scalar(*METAL_SCALARS[m.group(2)])
        count = int(m.group(3))
        if m.group(1):
            return vector(element, count, element.size * count, element.size)
        size = element.size * (4 if count == 3 else count)
        return vector(element, count, size, size)
    m = re.fullmatch(r"(half|float)([234])x([234])", name)
    if m:
        column = metal_type(f"{m.group(1)}{m.group(3)}", lookup)
        return array(column, int(m.group(2)))
    return lookup(name)


def metal_layout(struct, structs, constants, seen=()):
    """The layout of `struct`, nested structs looked up in its own file first, then its library."""
    if struct.name in seen:
        raise Unresolved(f"{struct.name} contains itself")

    def lookup(name):
        nested = find_metal(name, struct, structs)
        if nested is None:
            raise Unresolved(f"Metal type `{name}` in {struct.name}")
        return metal_layout(nested, structs, constants, seen + (struct.name,))

    members = []
    for decl in struct.members:
        base, declarators = metal_declarators(decl)
        for name, pointer, lengths in declarators:
            layout = Layout(8, 8, [Leaf(0, 8, "ptr", "")]) if pointer else metal_type(base, lookup)
            for length in reversed(lengths):
                layout = array(layout, evaluate(length, constants[struct.library]))
            members.append((name, layout))
    return struct_layout(members, padded=True)


def find_metal(name, near, structs):
    same = [s for s in structs if s.name == name]
    for s in same:
        if s.path == near.path:
            return s
    for s in same:
        if s.library == near.library:
            return s
    return None


# --- Swift ---------------------------------------------------------------------------------------

SWIFT_SCALARS = {
    "Float": (4, "f"), "Float32": (4, "f"), "CFloat": (4, "f"), "Double": (8, "f"), "Float64": (8, "f"),
    "CGFloat": (8, "f"), "Float16": (2, "f"),
    "Int": (8, "i"), "UInt": (8, "u"), "Int8": (1, "i"), "UInt8": (1, "u"), "Int16": (2, "i"),
    "UInt16": (2, "u"), "Int32": (4, "i"), "UInt32": (4, "u"), "Int64": (8, "i"), "UInt64": (8, "u"),
    "CInt": (4, "i"), "CUnsignedInt": (4, "u"), "Bool": (1, "bool"),
}
SWIFT_ALIASES = {
    "simd_float2": "SIMD2<Float>", "simd_float3": "SIMD3<Float>", "simd_float4": "SIMD4<Float>",
    "simd_int2": "SIMD2<Int32>", "simd_int3": "SIMD3<Int32>", "simd_int4": "SIMD4<Int32>",
    "simd_uint2": "SIMD2<UInt32>", "simd_uint3": "SIMD3<UInt32>", "simd_uint4": "SIMD4<UInt32>",
    "vector_float2": "SIMD2<Float>", "vector_float3": "SIMD3<Float>", "vector_float4": "SIMD4<Float>",
    "vector_uint4": "SIMD4<UInt32>", "simd_quatf": "SIMD4<Float>",
    "MTLPackedFloat3": "(Float, Float, Float)",
    "MTLAxisAlignedBoundingBox": "((Float, Float, Float), (Float, Float, Float))",
}
TYPE_KEYWORDS = r"struct|class|enum|extension|actor|protocol"


@dataclass
class SwiftStruct:
    name: str  # qualified: Outer.Inner
    path: str
    line: int
    fields: list  # (name, type text) of stored properties, in order
    doc: str
    problems: list = field(default_factory=list)

    @property
    def simple(self):
        return self.name.rsplit(".", 1)[-1]


@dataclass
class SwiftSource:
    structs: list
    enums: dict  # qualified name -> case count
    aliases: dict  # name -> type text
    uses: list  # (type name as written, path, line) on buffers


def parse_swift(text, path):
    clean = blank_comments(text, swift=True)
    lines = text.split("\n")
    blocks = []  # (start, end, keyword, name)
    for m in re.finditer(rf"(?<![\w.])({TYPE_KEYWORDS})\s+([A-Za-z_][\w.]*)", clean):
        j = m.end()
        depth = 0
        while j < len(clean):  # skip generics, conformances and `where` clauses to the body
            if clean[j] in "<(":
                depth += 1
            elif clean[j] in ">)":
                depth -= 1
            elif clean[j] == "{" and depth <= 0:
                break
            elif clean[j] in ";}" or (clean[j] == "=" and depth <= 0):
                j = -1
                break
            j += 1
        if j <= 0 or j >= len(clean) or m.group(2) in ("var", "let", "func", "subscript", "init"):
            continue
        blocks.append((j, matching_brace(clean, j), m.group(1), m.group(2), m.start()))

    def qualified(index, start):
        names = [b[3] for b in blocks if b[0] < start < b[1] and b is not blocks[index]]
        return ".".join(names + [blocks[index][3]])

    structs, enums, aliases = [], {}, {}
    for k, (start, end, keyword, name, at) in enumerate(blocks):
        full = qualified(k, at)
        if keyword == "enum":
            body = depth_zero(clean[start + 1:end])
            cases = sum(len(split_top(re.sub(r"\(.*?\)|=.*", "", c))) for c in re.findall(r"\bcase\s+([^\n;]+)", body))
            enums[full] = cases
            continue
        if keyword != "struct":
            continue
        line = line_of(clean, at)
        doc, j = [], line - 2
        while j >= 0 and (lines[j].strip().startswith("//") or lines[j].strip().startswith("@")):
            doc.insert(0, lines[j].strip())
            j -= 1
        struct = SwiftStruct(full, path, line, [], " ".join(doc))
        stored_properties(clean[start + 1:end], struct)
        structs.append(struct)
    for m in re.finditer(r"\btypealias\s+(\w+)\s*=\s*", clean):
        j, depth = m.end(), 0
        while j < len(clean) and (depth or clean[j] not in "\n;"):
            depth += {"(": 1, "<": 1, ")": -1, ">": -1}.get(clean[j], 0)
            j += 1
        aliases[m.group(1)] = " ".join(clean[m.end():j].split())
    uses = []
    for m in re.finditer(r"MemoryLayout<\s*([\w.]+)\s*>|(?:bindMemory|assumingMemoryBound)\(\s*to:\s*([\w.]+)\.self",
                         clean):
        uses.append((m.group(1) or m.group(2), path, line_of(clean, m.start())))
    return SwiftSource(structs, enums, aliases, uses)


def depth_zero(body):
    """`body` with everything inside nested braces blanked to a `{}` marker."""
    out, depth = [], 0
    for ch in body:
        if ch == "{":
            if depth == 0:
                out.append("{")
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                out.append("}")
        elif depth == 0:
            out.append(ch)
    return "".join(out)


def stored_properties(body, struct):
    """The stored properties declared directly in a struct body, in order."""
    flat, depth, blocks, current = [], 0, [], []
    # Statements at the body's own depth; brace blocks attached to them kept aside, so a computed
    # property (`var x: Float { ... }`) can be told from a stored one with observers.
    statement, statements = [], []
    for ch in body:
        if ch == "{":
            if depth == 0:
                current = []
            depth += 1
            if depth > 1:
                current.append(ch)
            continue
        if ch == "}":
            depth -= 1
            if depth == 0:
                statement.append("{}")
                blocks.append("".join(current))
                statements.append(("".join(statement), blocks[:]))
                statement, blocks = [], []
            else:
                current.append(ch)
            continue
        if depth > 0:
            current.append(ch)
            continue
        statement.append(ch)
    statements.append(("".join(statement), blocks))
    # Split the depth-zero text into declarations at newlines and semicolons outside brackets.
    for text, attached in statements:
        pieces, start, level = [], 0, 0
        for i, ch in enumerate(text):
            if ch in "([<":
                level += 1
            elif ch in ")]>":
                level = max(level - 1, 0)
            elif ch in "\n;" and level == 0:
                pieces.append(text[start:i])
                start = i + 1
        pieces.append(text[start:])
        merged = []
        for piece in pieces:
            # A line that continues the previous declaration (`= ...`, `,` or an operator).
            if merged and (piece.strip().startswith(("=", ",", ".", "+", "-", "*", "?", ":"))
                           or merged[-1].rstrip().endswith(("=", ",", ":"))):
                merged[-1] += " " + piece
            else:
                merged.append(piece)
        for k, piece in enumerate(merged):
            last = k == len(merged) - 1
            declaration(piece, attached if last else [], struct)


def declaration(piece, attached, struct):
    piece = re.sub(r"@\w+(\([^)]*\))?", " ", piece)
    m = re.match(r"^\s*((?:\w+(?:\([^)]*\))?\s+)*?)(var|let)\s+(.*)$", piece, re.S)
    if not m:
        return
    modifiers = m.group(1).split()
    if any(w in ("static", "class", "lazy") for w in modifiers):
        return
    rest = m.group(3).replace("{}", " {} ").strip()
    computed = rest.endswith("{}")
    if computed:
        rest = rest[:-2].strip()
        observers = attached and re.search(r"\b(willSet|didSet)\b", attached[-1])
        if "=" not in rest and not observers:
            return  # a computed property
    pending = []
    for binding in split_top(rest):
        b = re.match(r"^(\w+)\s*(?::\s*([^=]+?))?\s*(?:=\s*(.*))?$", binding, re.S)
        if not b:
            struct.problems.append(f"property `{binding.strip()}`")
            continue
        name, type_text, value = b.group(1), b.group(2), b.group(3)
        if type_text is None and value is not None:
            type_text = inferred(value.strip())
            if type_text is None:
                struct.problems.append(f"`{name}` has no type annotation to lay out")
                continue
        if type_text is None:
            pending.append(name)
            continue
        for waiting in pending:
            struct.fields.append((waiting, type_text.strip()))
        pending = []
        struct.fields.append((name, " ".join(type_text.split())))
    for waiting in pending:
        struct.problems.append(f"`{waiting}` has no type")


def inferred(value):
    if re.fullmatch(r"-?\d[\d_]*", value):
        return "Int"
    if re.fullmatch(r"-?[\d_]*\.\d[\d_]*(e-?\d+)?|-?\d+e-?\d+", value):
        return "Double"
    if value in ("true", "false"):
        return "Bool"
    m = re.match(r"^([A-Z]\w*(?:\.[A-Z]\w*)*(?:<[^>]*>)?)(?:\(|\.(?:zero|one)\b)", value)
    return m.group(1) if m else None


class SwiftTypes:
    def __init__(self, sources):
        self.structs, self.enums, self.aliases = {}, {}, dict(SWIFT_ALIASES)
        for source in sources:
            for s in source.structs:
                self.structs.setdefault(s.name, s)
            self.enums.update(source.enums)
            for name, text in source.aliases.items():
                self.aliases.setdefault(name, text)
        self.memo = {}

    def resolve(self, name, context=None, path=None):
        """Swift structs a name written in `context` (a qualified struct name) may mean."""
        if context:
            scope = context.split(".")
            while scope:
                candidate = ".".join(scope + [name])
                if candidate in self.structs:
                    return [self.structs[candidate]]
                scope.pop()
        found = [s for n, s in self.structs.items() if n == name or n.endswith("." + name)]
        if len(found) > 1 and path:  # a nested type named from elsewhere in its own file
            found = [s for s in found if s.path == path] or found
        if len(found) > 1 and name in self.structs:
            found = [self.structs[name]]
        return found

    def layout(self, struct, seen=()):
        if struct.name in self.memo:
            return self.memo[struct.name]
        if struct.name in seen:
            raise Unresolved(f"{struct.name} contains itself")
        if struct.problems:
            raise Unresolved(f"{struct.name}: " + "; ".join(struct.problems))
        members = [(name, self.type_layout(t, struct, seen + (struct.name,))) for name, t in struct.fields]
        layout = struct_layout(members, padded=False)
        self.memo[struct.name] = layout
        return layout

    def type_layout(self, text, struct, seen):
        text = text.strip()
        text = re.sub(r"^(?:Swift|simd)\.", "", text)
        if text in self.aliases:
            return self.type_layout(self.aliases[text], struct, seen)
        if text in SWIFT_SCALARS:
            return scalar(*SWIFT_SCALARS[text])
        m = re.fullmatch(r"SIMD(2|3|4|8|16)<\s*(\w+)\s*>", text)
        if m and m.group(2) in SWIFT_SCALARS:
            element = scalar(*SWIFT_SCALARS[m.group(2)])
            count = int(m.group(1))
            size = element.size * (4 if count == 3 else count)
            return vector(element, count, size, min(size, 16))
        m = re.fullmatch(r"simd_(float|double)([234])x([234])", text)
        if m:
            column = self.type_layout(f"SIMD{m.group(3)}<{'Float' if m.group(1) == 'float' else 'Double'}>",
                                      struct, seen)
            return array(column, int(m.group(2)))
        if text.startswith("(") and text.endswith(")"):
            members = []
            for k, part in enumerate(split_top(text[1:-1])):
                label = re.match(r"^(\w+)\s*:\s*(.*)$", part, re.S)
                name, part = (label.group(1), label.group(2)) if label else (f".{k}", part)
                members.append((name, self.type_layout(part, struct, seen)))
            return struct_layout(members, padded=False)
        if text.endswith("?") or text.startswith("["):
            raise Unresolved(f"`{text}` in {struct.name} is not plain data")
        nested = self.resolve(text, struct.name, struct.path)
        if len(nested) == 1:
            return self.layout(nested[0], seen)
        enum = [n for n in self.enums if n == text or n.endswith("." + text)]
        if enum:
            raise Unresolved(f"enum `{text}` in {struct.name}: Swift stores its case, not its raw value")
        raise Unresolved(f"Swift type `{text}` in {struct.name}")


# --- Checking ------------------------------------------------------------------------------------


@dataclass
class Finding:
    key: str
    message: str


@dataclass
class Allow:
    pairs: list = field(default_factory=list)  # (swift, metal, line)
    unpairs: list = field(default_factory=list)
    copies: list = field(default_factory=list)  # (metal, metal, line)
    sizes: list = field(default_factory=list)  # (metal, path, constant, line)
    allowed: dict = field(default_factory=dict)  # key -> line
    errors: list = field(default_factory=list)


def parse_allow(text):
    allow = Allow()
    for number, raw in enumerate(text.split("\n"), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        body, _, reason = line.partition(":")
        if body.split()[:1] == ["size"]:  # `size M = path:constant : reason`
            m = re.match(r"^size\s+(\w+)\s*=\s*(\S+?):(\w+)\s*:\s*(.*)$", line)
            if not m or not m.group(4).strip():
                allow.errors.append(f"line {number}: `size Metal = path:constant : reason` expected")
                continue
            allow.sizes.append((m.group(1), m.group(2), m.group(3), number))
            continue
        if not reason.strip():
            allow.errors.append(f"line {number}: no reason given after `:`")
            continue
        words = body.split()
        kind = words[0] if words else ""
        if kind in ("pair", "unpair", "copy"):
            m = re.match(r"^\w+\s+([\w.]+)\s*=\s*(\w+)\s*$", body)
            if not m:
                allow.errors.append(f"line {number}: `{kind} A = B : reason` expected")
                continue
            {"pair": allow.pairs, "unpair": allow.unpairs, "copy": allow.copies}[kind].append(
                (m.group(1), m.group(2), number))
        elif kind == "allow" and len(words) == 3:
            allow.allowed[f"{words[1]} {words[2]}"] = number
        else:
            allow.errors.append(f"line {number}: unknown entry `{body.strip()}`")
    return allow


def compare_leaves(left, right, left_name, right_name, limit=4):
    """Differences between two scalar lists, as messages naming each side's field."""
    a = {l.offset: l for l in left}
    b = {l.offset: l for l in right}
    problems = []
    for offset in sorted(set(a) | set(b)):
        x, y = a.get(offset), b.get(offset)
        if x and y and x.size == y.size and x.kind == y.kind:
            continue
        describe = lambda leaf: f"{leaf.path} ({leaf.kind}{8 * leaf.size})" if leaf else "nothing"
        problems.append(f"offset {offset}: {left_name} has {describe(x)}, {right_name} has {describe(y)}")
    if len(problems) > limit:
        problems = problems[:limit] + [f"... and {len(problems) - limit} more"]
    return problems


def collect(root):
    metal, swift = [], []
    for path in sorted((root / "Sources").rglob("*.metal")):
        relative = str(path.relative_to(root))
        # BlastCore's shaders are compiled together, joined into one source (ShaderLibrary in
        # StructureTypes.swift); Thermal.metal and the renderer's are compiled on their own.
        library = str(path.parent.relative_to(root)) if path.parent.name == "Shaders" else relative
        if path.name == "Thermal.metal":
            library = relative
        metal += parse_metal(path.read_text(encoding="utf-8"), relative, library)
    for base in ("Sources", "Packages"):
        for path in sorted((root / base).rglob("*.swift")) if (root / base).exists() else []:
            if ".build" in path.parts:
                continue
            swift.append(parse_swift(path.read_text(encoding="utf-8"), str(path.relative_to(root))))
    return metal, swift


def check(root, allow_text):
    """(findings, pairs, copies, allow): findings not yet filtered by the allow-list."""
    root = Path(root)
    allow = parse_allow(allow_text)
    metal, swift_sources = collect(root)
    types = SwiftTypes(swift_sources)
    constants = {}
    for path in sorted((root / "Sources").rglob("*.metal")):
        relative = str(path.relative_to(root))
        for s in metal:
            if s.path == relative:
                constants.setdefault(s.library, {}).update(metal_constants(path.read_text(encoding="utf-8")))
    findings, used_allow = [], set()
    metal_names = {s.name for s in metal}

    layouts = {}

    def m_layout(struct):
        key = (struct.name, struct.path)
        if key not in layouts:
            try:
                layouts[key] = metal_layout(struct, metal, constants)
            except Unresolved as error:
                layouts[key] = None
                findings.append(Finding(f"unresolved {struct.name}", f"{struct.path}:{struct.line}: {error}"))
        return layouts[key]

    # The shaders' own size assertions, as a check on this script's Metal rules.
    for path in sorted((root / "Sources").rglob("*.metal")):
        text = blank_comments(path.read_text(encoding="utf-8"))
        for m in re.finditer(r"static_assert\s*\(\s*sizeof\s*\(\s*(\w+)\s*\)\s*==\s*(\d+)", text):
            struct = find_metal(m.group(1), MetalStruct("", str(path.relative_to(root)), 0, [], ""), metal)
            struct = struct or next((s for s in metal if s.name == m.group(1)), None)
            layout = struct and m_layout(struct)
            if layout and layout.size != int(m.group(2)):
                findings.append(Finding(f"assert {m.group(1)}",
                                        f"{path.relative_to(root)}:{line_of(text, m.start())}: the shader asserts "
                                        f"sizeof({m.group(1)}) == {m.group(2)}, this script computes {layout.size}"))

    # Swift and Metal pairs.
    pairs = {}  # (swift qualified, metal name) -> how found
    for source in swift_sources:
        for s in source.structs:
            if s.simple in metal_names:
                pairs[(s.name, s.simple)] = "same name"
            cited = sorted(set(re.findall(r"`(\w+)`", s.doc)) & metal_names - {s.simple})
            if len(cited) == 1:
                pairs.setdefault((s.name, cited[0]), "doc comment")
            elif len(cited) > 1 and s.simple not in metal_names:
                findings.append(Finding(f"ambiguous {s.name}",
                                        f"{s.path}:{s.line}: the doc comment names {', '.join(cited)}; "
                                        f"add a `pair` line for the one it mirrors"))
    builtin = {}  # Metal vector types a Swift struct is read as
    for swift_name, metal_name, number in allow.pairs:
        found = types.resolve(swift_name)
        if metal_name not in metal_names:
            try:
                builtin[metal_name] = metal_type(metal_name, lambda name: (_ for _ in ()).throw(Unresolved(name)))
                metal_names = metal_names | {metal_name}
            except Unresolved:
                pass
        if len(found) != 1 or metal_name not in metal_names:
            allow.errors.append(f"line {number}: `pair {swift_name} = {metal_name}` names no single struct pair")
            continue
        pairs[(found[0].name, metal_name)] = "allow-list"
    for swift_name, metal_name, number in allow.unpairs:
        found = types.resolve(swift_name)
        key = (found[0].name, metal_name) if len(found) == 1 else None
        if key not in pairs:
            allow.errors.append(f"line {number}: `unpair {swift_name} = {metal_name}` matches no pair")
            continue
        del pairs[key]

    checked = []
    for (swift_name, metal_name), how in sorted(pairs.items()):
        s = types.structs[swift_name]
        candidates = [m for m in metal if m.name == metal_name] or [
            MetalStruct(metal_name, "(Metal type)", 0, [], "")]
        try:
            swift_layout = types.layout(s)
        except Unresolved as error:
            findings.append(Finding(f"unresolved {swift_name}", f"{s.path}:{s.line}: {error}"))
            continue
        for m in candidates:
            metal_layout_ = builtin[metal_name] if metal_name in builtin else m_layout(m)
            if metal_layout_ is None:
                continue
            checked.append((swift_name, m, swift_layout, metal_layout_, how))
            problems = []
            if swift_layout.stride != metal_layout_.size:
                problems.append(f"Metal size {metal_layout_.size}, Swift stride {swift_layout.stride} "
                                f"(size {swift_layout.size})")
            problems += compare_leaves(swift_layout.leaves, metal_layout_.leaves, "Swift", "Metal")
            if problems:
                findings.append(Finding(f"layout {swift_name}={metal_name}",
                                        f"{s.path}:{s.line} `{swift_name}` against {m.path}"
                                        + (f":{m.line}" if m.line else "") + " "
                                        f"`{metal_name}` ({how}):\n      " + "\n      ".join(problems)))

    # Swift structs on buffers that pair with nothing.
    paired = {swift_name for swift_name, _ in pairs}
    reported = set()
    for source in swift_sources:
        for name, path, line in source.uses:
            for s in types.resolve(name, path=path):
                if s.name in paired or s.name in reported:
                    continue
                reported.add(s.name)
                findings.append(Finding(f"unpaired {s.name}",
                                        f"{path}:{line}: `{s.name}` ({s.path}:{s.line}) is used on a buffer "
                                        f"but pairs with no shader struct"))

    # The same struct in two shader files, and declared copies.
    copies = {}
    by_name = {}
    for m in metal:
        by_name.setdefault(m.name, []).append(m)
    for name, found in by_name.items():
        for other in found[1:]:
            copies[(found[0], other)] = "same name"
    for a, b, number in allow.copies:
        left, right = by_name.get(a, []), by_name.get(b, [])
        if len(left) != 1 or len(right) != 1:
            allow.errors.append(f"line {number}: `copy {a} = {b}` names no single pair of shader structs")
            continue
        copies[(left[0], right[0])] = "allow-list"
    copy_results = []
    for (a, b), how in copies.items():
        la, lb = m_layout(a), m_layout(b)
        if la is None or lb is None:
            continue
        copy_results.append((a, b, la, lb, how))
        problems = []
        if la.size != lb.size:
            problems.append(f"sizes {la.size} and {lb.size}")
        problems += compare_leaves(la.leaves, lb.leaves, a.name, b.name)
        key = f"{a.name}={b.name}"
        where = f"{a.path}:{a.line} `{a.name}` against {b.path}:{b.line} `{b.name}` ({how})"
        if problems:
            findings.append(Finding(f"copy-layout {key}", where + ":\n      " + "\n      ".join(problems)))
        elif a.members != b.members:
            differ = [f"`{x}` / `{y}`" for x, y in zip(a.members, b.members) if x != y]
            findings.append(Finding(f"copy-members {key}",
                                    where + ": same layout, members differ: " + ", ".join(differ)))

    # Buffer strides kept as Swift constants.
    for metal_name, path, constant, number in allow.sizes:
        struct = next((m for m in metal if m.name == metal_name), None)
        file = root / path
        if struct is None or not file.exists():
            allow.errors.append(f"line {number}: `size {metal_name}` names no shader struct or no file")
            continue
        m = re.search(rf"\b{constant}\s*(?::\s*\w+\s*)?=\s*(\d+)", file.read_text(encoding="utf-8"))
        if not m:
            allow.errors.append(f"line {number}: no `{constant} = <integer>` in {path}")
            continue
        layout = m_layout(struct)
        if layout and layout.size != int(m.group(1)):
            findings.append(Finding(f"size {metal_name}",
                                    f"{path}: `{constant}` is {m.group(1)} bytes, {struct.path}:{struct.line} "
                                    f"`{metal_name}` is {layout.size}"))

    return findings, checked, copy_results, allow


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--root", type=Path, default=ROOT)
    parser.add_argument("--allow", type=Path, default=ALLOW)
    parser.add_argument("--list", action="store_true", help="print every pair and copy checked")
    args = parser.parse_args(argv)
    allow_text = args.allow.read_text(encoding="utf-8") if args.allow.exists() else ""
    findings, checked, copies, allow = check(args.root, allow_text)
    if args.list:
        for swift_name, m, sl, ml, how in checked:
            print(f"pair  {swift_name} = {m.name} ({how}): Metal {ml.size} bytes, Swift stride {sl.stride}")
        for a, b, la, lb, how in copies:
            print(f"copy  {a.name} ({a.path}) = {b.name} ({b.path}) ({how}): {la.size} and {lb.size} bytes")
    used = set()
    open_findings = []
    for finding in findings:
        if finding.key in allow.allowed:
            used.add(finding.key)
        else:
            open_findings.append(finding)
    stale = [f"line {n}: `allow {k}` matches no finding" for k, n in allow.allowed.items() if k not in used]
    errors = allow.errors + stale
    for finding in open_findings:
        print(f"{finding.key}\n    {finding.message}")
    for error in errors:
        print(f"{args.allow.name} {error}")
    print(f"{len(checked)} Swift/Metal pairs and {len(copies)} shader copies checked; "
          f"{len(open_findings)} findings, {len(findings) - len(open_findings)} allowed"
          + (f", {len(errors)} allow-list errors" if errors else ""))
    return 1 if open_findings or errors else 0


if __name__ == "__main__":
    sys.exit(main())
