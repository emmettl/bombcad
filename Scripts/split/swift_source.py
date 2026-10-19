"""A small reader of Swift source for the BlastModel split: tokens and declarations, no compiler.

It is shared by Scripts/split/import-graph.py, which classifies the files of Sources/BlastCore, and
Scripts/split/split_blastmodel.py, which moves them. It reads just enough of the language for that
job:

- comments are dropped, and string literals reduced to one token each, except that the code in a
  string's interpolations (`\\(...)`) is read as code;
- braces are matched, and each `{` is known as either a type's body (`struct`, `class`, `enum`,
  `actor`, `protocol`, `extension`) or anything else (a function, an accessor, a closure);
- a declaration is any `struct`, `class`, `enum`, `actor`, `protocol`, `extension`, `func`,
  `init`, `subscript`, `var`, `let`, `typealias`, `case`, `operator` or `precedencegroup` met
  directly in a file or in a type's body, with the attributes and modifiers in front of it.

Declarations inside a function's body are local and are not reported. Generic angle brackets
are not matched; nothing here needs them. Regex literals are not read and do not occur in
BombCAD's sources.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field

TYPE_KINDS = {"struct", "class", "enum", "actor", "protocol", "extension"}
DECL_KINDS = TYPE_KINDS | {
    "func", "init", "deinit", "subscript", "var", "let", "typealias", "associatedtype", "case",
    "operator", "precedencegroup", "import", "macro",
}
ACCESS = {"public", "open", "package", "internal", "fileprivate", "private"}
MODIFIERS = ACCESS | {
    "static", "class", "final", "override", "mutating", "nonmutating", "lazy", "weak", "unowned",
    "convenience", "required", "dynamic", "optional", "indirect", "nonisolated", "isolated",
    "consuming", "borrowing", "distributed", "prefix", "postfix", "infix", "__consuming",
}
# After `class`, these mean that `class` is a modifier (`class func`), not a class declaration.
_CLASS_MODIFIES = {"func", "var", "let", "subscript", "override", "final"} | ACCESS | {
    "required", "convenience", "dynamic", "nonisolated", "static"}

_IDENT = re.compile(r"[^\W\d]\w*")
_NUMBER = re.compile(r"0[xX][0-9a-fA-F_]*(?:\.[0-9a-fA-F_]+)?(?:[pP][-+]?[0-9_]+)?|"
                     r"0[bB][01_]+|0[oO][0-7_]+|[0-9][0-9_]*(?:\.[0-9][0-9_]*)?(?:[eE][-+]?[0-9_]+)?")
_OPERATOR_CHARS = set("/=-+!*%<>&|^~?.")


@dataclass
class Token:
    kind: str  # ident, number, string, punct, op, attr, directive, pound
    text: str
    start: int  # offset of the token's first character in the source
    end: int  # offset just after its last character
    line: int  # 1-based


class SwiftSyntaxError(ValueError):
    pass


def tokenize(source: str) -> list[Token]:
    """The tokens of `source`, comments dropped, each string literal one `string` token followed
    by the tokens of the code in its interpolations."""
    tokens: list[Token] = []
    line_starts = [0]
    for i, ch in enumerate(source):
        if ch == "\n":
            line_starts.append(i + 1)

    def line_of(offset: int) -> int:
        lo, hi = 0, len(line_starts) - 1
        while lo < hi:
            mid = (lo + hi + 1) // 2
            if line_starts[mid] <= offset:
                lo = mid
            else:
                hi = mid - 1
        return lo + 1

    def emit(kind: str, start: int, end: int) -> None:
        tokens.append(Token(kind, source[start:end], start, end, line_of(start)))

    def skip_block_comment(i: int) -> int:
        depth = 0
        n = len(source)
        while i < n:
            if source.startswith("/*", i):
                depth += 1
                i += 2
            elif source.startswith("*/", i):
                depth -= 1
                i += 2
                if depth == 0:
                    return i
            else:
                i += 1
        raise SwiftSyntaxError(f"unterminated block comment at line {line_of(i)}")

    def scan_string(i: int) -> int:
        """Scans the string literal starting at `i` (at its leading `#`s or quote); returns the
        offset after it. Interpolated code is scanned into `tokens` after the string token."""
        start = i
        hashes = 0
        while source[i] == "#":
            hashes += 1
            i += 1
        multiline = source.startswith('"""', i)
        i += 3 if multiline else 1
        close = ('"""' if multiline else '"') + "#" * hashes
        escape = "\\" + "#" * hashes
        interpolations: list[tuple[int, int]] = []
        n = len(source)
        while i < n:
            if source.startswith(close, i):
                i += len(close)
                break
            if source.startswith(escape, i):
                j = i + len(escape)
                if j < n and source[j] == "(":
                    # Interpolated code: find the matching parenthesis, skipping nested strings.
                    depth = 0
                    k = j
                    while k < n:
                        c = source[k]
                        if c == "(":
                            depth += 1
                        elif c == ")":
                            depth -= 1
                            if depth == 0:
                                break
                        elif c == '"' or (c == "#" and source.startswith('"', k + 1)):
                            k = _skip_nested_string(source, k)
                            continue
                        k += 1
                    interpolations.append((j + 1, k))
                    i = k + 1
                    continue
                i = j + 1
                continue
            if not multiline and source[i] == "\n":
                raise SwiftSyntaxError(f"unterminated string at line {line_of(start)}")
            i += 1
        else:
            raise SwiftSyntaxError(f"unterminated string at line {line_of(start)}")
        emit("string", start, i)
        for a, b in interpolations:
            scan(a, b)
        return i

    def scan(i: int, stop: int) -> None:
        while i < stop:
            ch = source[i]
            if ch in " \t\r\n":
                i += 1
            elif source.startswith("//", i):
                j = source.find("\n", i)
                i = stop if j < 0 or j > stop else j
            elif source.startswith("/*", i):
                i = skip_block_comment(i)
            elif ch == '"' or (ch == "#" and re.match(r"#+\"", source[i:i + 8])):
                i = scan_string(i)
            elif ch == "`":
                j = source.index("`", i + 1)
                emit("ident", i + 1, j)
                tokens[-1].start, tokens[-1].end = i, j + 1
                i = j + 1
            elif ch == "@":
                m = _IDENT.match(source, i + 1)
                if not m:
                    raise SwiftSyntaxError(f"stray @ at line {line_of(i)}")
                emit("attr", i, m.end())
                i = m.end()
            elif ch == "#":
                m = _IDENT.match(source, i + 1)
                if not m:
                    raise SwiftSyntaxError(f"stray # at line {line_of(i)}")
                word = m.group(0)
                emit("directive" if word in ("if", "elseif", "else", "endif") else "pound", i,
                     m.end())
                i = m.end()
            elif ch == "$":
                m = re.compile(r"\$[A-Za-z0-9_]*").match(source, i)
                emit("ident", i, m.end())
                i = m.end()
            elif ch.isdigit():
                m = _NUMBER.match(source, i)
                emit("number", i, m.end())
                i = m.end()
            elif ch.isalpha() or ch == "_":
                m = _IDENT.match(source, i)
                emit("ident", i, m.end())
                i = m.end()
            elif ch in "{}()[],:;\\":
                emit("punct", i, i + 1)
                i += 1
            elif ch in _OPERATOR_CHARS:
                j = i
                if ch == ".":
                    # A lone dot is member access; dots join an operator only after another dot.
                    j = i + 1
                    while j < stop and source[j] == ".":
                        j += 1
                    if j - i == 1:
                        emit("punct", i, i + 1)
                        i += 1
                        continue
                while j < stop and source[j] in _OPERATOR_CHARS and not source.startswith(
                        "//", j) and not source.startswith("/*", j):
                    j += 1
                emit("op", i, j)
                i = j
            else:
                raise SwiftSyntaxError(f"unexpected character {ch!r} at line {line_of(i)}")

    scan(0, len(source))
    tokens.sort(key=lambda t: t.start)
    return tokens


def _skip_nested_string(source: str, k: int) -> int:
    hashes = 0
    while source[k] == "#":
        hashes += 1
        k += 1
    multiline = source.startswith('"""', k)
    k += 3 if multiline else 1
    close = ('"""' if multiline else '"') + "#" * hashes
    escape = "\\" + "#" * hashes
    while not source.startswith(close, k):
        if source.startswith(escape, k):
            k += len(escape) + 1
        else:
            k += 1
    return k + len(close)


@dataclass
class Decl:
    kind: str
    name: str  # the declared name; the extended type for an extension; "" for init and deinit
    keyword: int  # index of the declaration's keyword token
    header: int  # index of its first attribute or modifier, or of the keyword
    modifiers: list[str]
    attributes: list[str]
    parent: "Decl | None"
    conditions: tuple[str, ...]  # the `#if` conditions it sits under, outermost first
    body_open: int | None = None  # index of the `{` of a type's or extension's body
    end: int = -1  # index of its last token
    members: list["Decl"] = field(default_factory=list)

    @property
    def access(self) -> str | None:
        return next((m for m in self.modifiers if m in ACCESS), None)

    @property
    def path(self) -> str:
        names = []
        d: Decl | None = self
        while d is not None:
            names.append(d.name or d.kind)
            d = d.parent
        return ".".join(reversed(names))

    def walk(self):
        yield self
        for m in self.members:
            yield from m.walk()


@dataclass
class SourceFile:
    text: str
    tokens: list[Token]
    decls: list[Decl]  # the file's top-level declarations, imports included, in order
    directives: list[tuple[int, str]]  # (token index, "#if cond" ...) at file level

    def lines(self, decl: Decl) -> tuple[int, int]:
        return self.tokens[decl.header].line, self.tokens[decl.end].line


def parse(source: str) -> SourceFile:
    tokens = tokenize(source)
    top: list[Decl] = []
    directives: list[tuple[int, str]] = []
    # Each scope: [kind, owning declaration, bracket depth, pending declaration, member list]
    scopes: list[list] = [["file", None, 0, None, top]]
    conditions: list[str] = []
    all_decls: list[Decl] = []
    n = len(tokens)
    i = 0
    while i < n:
        t = tokens[i]
        scope = scopes[-1]
        kind, owner, depth, pending, members = scope
        if t.kind == "directive":
            # The condition is the rest of the directive's line.
            j = i + 1
            while j < n and tokens[j].line == t.line:
                j += 1
            cond = " ".join(tok.text for tok in tokens[i + 1:j])
            if t.text == "#if":
                conditions.append(cond)
            elif t.text in ("#elseif", "#else"):
                if not conditions:
                    raise SwiftSyntaxError(f"{t.text} without #if at line {t.line}")
                conditions[-1] = f"!({conditions[-1]})" + (f" && {cond}" if cond else "")
            elif t.text == "#endif":
                if not conditions:
                    raise SwiftSyntaxError(f"#endif without #if at line {t.line}")
                conditions.pop()
            if kind == "file":
                directives.append((i, f"{t.text} {cond}".strip()))
            i = j
            continue
        if t.kind == "punct" and t.text in "([":
            scope[2] += 1
        elif t.kind == "punct" and t.text in ")]":
            scope[2] -= 1
        elif t.kind == "punct" and t.text == "{":
            if depth == 0 and pending is not None and pending.body_open is None and \
                    pending.kind in TYPE_KINDS:
                pending.body_open = i
                scopes.append(["type", pending, 0, None, pending.members])
            else:
                if depth == 0 and pending is not None and pending.body_open is None:
                    pending.body_open = i
                scopes.append(["other", owner, 0, None, None])
        elif t.kind == "punct" and t.text == "}":
            closed = scopes.pop()
            if not scopes:
                raise SwiftSyntaxError(f"unbalanced }} at line {t.line}")
            if closed[0] == "type":
                closed[1].end = i
        elif kind in ("file", "type") and depth == 0 and t.kind == "ident" and \
                t.text in DECL_KINDS and not (i > 0 and tokens[i - 1].text == "."):
            word = t.text
            nxt = tokens[i + 1].text if i + 1 < n else ""
            if word == "class" and nxt in _CLASS_MODIFIES:
                i += 1
                continue
            if word in ("init", "subscript", "deinit") and i > 0 and tokens[i - 1].text in (
                    "self", "super"):
                i += 1
                continue
            decl = _read_decl(tokens, i, owner, tuple(conditions))
            members.append(decl)
            all_decls.append(decl)
            scope[3] = decl
            if kind == "file":
                pass
        i += 1
    if len(scopes) != 1:
        raise SwiftSyntaxError("unbalanced braces at end of file")
    if conditions:
        raise SwiftSyntaxError("#if without #endif at end of file")
    # A declaration without a type body ends just before the next declaration's header, or at the
    # end of its enclosing scope.
    _set_ends(top, len(tokens) - 1, tokens, directives)
    return SourceFile(source, tokens, top, directives)


def _set_ends(decls: list[Decl], limit: int, tokens: list[Token],
              directives: list[tuple[int, str]]) -> None:
    for k, d in enumerate(decls):
        nxt = decls[k + 1].header - 1 if k + 1 < len(decls) else limit
        if d.parent is None:
            # Top-level declarations do not run over a file-level directive.
            for idx, _ in directives:
                if d.keyword < idx <= nxt:
                    nxt = idx - 1
                    break
        if d.kind in TYPE_KINDS and d.end >= 0:
            pass
        else:
            d.end = nxt
        inner_limit = d.end - 1 if d.kind in TYPE_KINDS else d.end
        _set_ends(d.members, inner_limit, tokens, [])


def _read_decl(tokens: list[Token], i: int, parent: Decl | None,
               conditions: tuple[str, ...]) -> Decl:
    word = tokens[i].text
    # Walk back over modifiers and attributes (with their arguments).
    j = i - 1
    modifiers: list[str] = []
    attributes: list[str] = []
    header = i
    while j >= 0:
        tok = tokens[j]
        if tok.kind == "ident" and tok.text in MODIFIERS:
            modifiers.insert(0, tok.text)
            header = j
            j -= 1
        elif tok.kind == "punct" and tok.text == ")":
            # `private(set)`, `@available(...)`: find the matching parenthesis.
            depth = 0
            k = j
            while k >= 0:
                if tokens[k].text == ")":
                    depth += 1
                elif tokens[k].text == "(":
                    depth -= 1
                    if depth == 0:
                        break
                k -= 1
            before = tokens[k - 1] if k > 0 else None
            if before is not None and (before.kind == "attr" or before.text in ACCESS):
                if before.kind == "attr":
                    attributes.insert(0, before.text)
                else:
                    modifiers.insert(0, before.text + "(set)")
                header = k - 1
                j = k - 2
            else:
                break
        elif tok.kind == "attr":
            attributes.insert(0, tok.text)
            header = j
            j -= 1
        else:
            break
    name = ""
    k = i + 1
    if word == "extension":
        parts = []
        while k < len(tokens) and tokens[k].kind == "ident":
            parts.append(tokens[k].text)
            if k + 1 < len(tokens) and tokens[k + 1].text == ".":
                k += 2
            else:
                break
        name = ".".join(parts)
    elif word in ("init", "deinit", "subscript"):
        name = ""
    elif word == "operator":
        name = tokens[i + 1].text if i + 1 < len(tokens) else ""
    elif word == "import":
        while k < len(tokens) and tokens[k].kind == "ident" and tokens[k].text in (
                "struct", "class", "enum", "protocol", "func", "var", "let", "typealias"):
            k += 1
        parts = []
        while k < len(tokens) and tokens[k].kind == "ident":
            parts.append(tokens[k].text)
            if k + 1 < len(tokens) and tokens[k + 1].text == "." and tokens[k + 1].line == \
                    tokens[i].line:
                k += 2
            else:
                break
        name = ".".join(parts)
    elif k < len(tokens):
        name = tokens[k].text
    return Decl(word, name, i, header, modifiers, attributes, parent, conditions)


def identifiers(sf: SourceFile, first: int, last: int) -> tuple[set[str], set[str]]:
    """The identifiers among tokens `first` to `last`, and those of them used after a dot."""
    names: set[str] = set()
    dotted: set[str] = set()
    toks = sf.tokens
    for k in range(first, last + 1):
        t = toks[k]
        if t.kind == "ident":
            names.add(t.text)
            if k > 0 and toks[k - 1].text == "." and toks[k - 1].kind == "punct":
                dotted.add(t.text)
    return names, dotted


def qualified(sf: SourceFile, first: int, last: int) -> set[tuple[str, str]]:
    """The `Name.member` pairs among tokens `first` to `last`."""
    toks = sf.tokens
    out = set()
    for k in range(max(first, 2), last + 1):
        if toks[k].kind == "ident" and toks[k - 1].text == "." and toks[k - 2].kind == "ident" \
                and toks[k - 1].start == toks[k - 2].end:
            out.add((toks[k - 2].text, toks[k].text))
    return out


def init_calls(sf: SourceFile, first: int, last: int) -> set[tuple[str, str]]:
    """(type, first argument label) of each `Type(label:`, `Type.init(label:` and
    `self.init(label:` (type "self") among tokens `first` to `last`."""
    toks = sf.tokens
    out = set()
    for k in range(first, min(last, len(toks) - 3) + 1):
        t = toks[k]
        if t.kind != "ident":
            continue
        j = k + 1
        if toks[j].text == "." and j + 1 < len(toks) and toks[j + 1].text == "init":
            j += 2
        elif not (t.text[:1].isupper() and toks[j].start == t.end):
            continue
        if j + 2 < len(toks) and toks[j].text == "(" and toks[j + 1].kind == "ident" and \
                toks[j + 2].text == ":":
            if t.text == "self" or t.text[:1].isupper():
                out.add((t.text, toks[j + 1].text))
    return out
