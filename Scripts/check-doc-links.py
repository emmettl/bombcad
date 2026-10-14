#!/usr/bin/env python3
"""Check the Markdown documents' relative links: each file a link names exists, and each anchor
is a heading in it (GitHub's slugs). External links are not fetched.

    Scripts/check-doc-links.py [files...]   (README.md and docs/**/*.md by default)

Exits 1 and lists every broken link."""
import re
import sys
import unicodedata
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LINK = re.compile(r"(?<!!)\[[^\]]*\]\(([^)\s]+)(?:\s+\"[^\"]*\")?\)")
HEADING = re.compile(r"^(#{1,6})\s+(.*?)\s*#*\s*$")
FENCE = re.compile(r"^\s*(```|~~~)")


def slug(text):
    """GitHub's anchor for a heading: lower case, inline markup and punctuation dropped, spaces
    as hyphens; letters and digits of any script kept."""
    text = re.sub(r"`([^`]*)`", r"\1", text)
    text = re.sub(r"\[([^\]]*)\]\([^)]*\)", r"\1", text)
    text = re.sub(r"<[^>]+>", "", text)
    text = text.replace("*", "")
    out = []
    for ch in text.lower():
        cat = unicodedata.category(ch)
        if ch in " -":
            out.append("-" if ch == " " else ch)
        elif ch == "_" or cat[0] in "LN" or cat == "Mn":
            out.append(ch)
    return "".join(out)


def anchors(path, cache={}):
    if path not in cache:
        found, counts, fenced = set(), {}, False
        for line in path.read_text(encoding="utf-8").splitlines():
            if FENCE.match(line):
                fenced = not fenced
                continue
            match = HEADING.match(line) if not fenced else None
            if match:
                base = slug(match.group(2))
                n = counts.get(base, 0)
                counts[base] = n + 1
                found.add(base if n == 0 else f"{base}-{n}")
            # Explicit anchors: <a id="..."> or <a name="...">.
            for explicit in re.findall(r"<a\s+(?:id|name)=\"([^\"]+)\"", line):
                found.add(explicit)
        cache[path] = found
    return cache[path]


def links(path):
    fenced = False
    for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if FENCE.match(line):
            fenced = not fenced
            continue
        if fenced:
            continue
        line = re.sub(r"`[^`]*`", "", line)
        for target in LINK.findall(line):
            yield number, target


def main():
    files = [Path(f).resolve() for f in sys.argv[1:]] or [ROOT / "README.md", *sorted((ROOT / "docs").rglob("*.md"))]
    broken = []
    for path in files:
        for number, target in links(path):
            if re.match(r"^[a-z][a-z0-9+.-]*:", target) or target.startswith("//"):
                continue
            name, _, anchor = target.partition("#")
            destination = (path.parent / name).resolve() if name else path
            where = f"{path.relative_to(ROOT)}:{number}"
            if not destination.exists():
                broken.append(f"{where}: {target} (no such file)")
            elif anchor and destination.suffix == ".md" and anchor not in anchors(destination):
                broken.append(f"{where}: {target} (no such heading)")
    for line in broken:
        print(line)
    if broken:
        print(f"{len(broken)} broken link(s)", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
