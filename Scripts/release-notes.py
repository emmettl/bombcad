"""Release-note fragments: one small file per change in docs/release-notes/next/, assembled at
release time, so sessions never edit the same notes file.

    python3 Scripts/release-notes.py add <topic>        write next/<topic>.md from the template
    python3 Scripts/release-notes.py assemble 0.6.0     append them to 0.6.0.md by kind, remove them
    python3 Scripts/release-notes.py check              every fragment well formed (ci-test)
"""

import argparse
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
NEXT = ROOT / "docs/release-notes/next"
KINDS = {"added": "New", "changed": "Changed", "fixed": "Fixed", "limitation": "Known limitations"}
TEMPLATE = "kind: added\n\n**What a user can now do or see:** what it rests on, and its standing.\n"


def fragments(folder=NEXT):
    return sorted(p for p in folder.glob("*.md") if p.name != "README.md")


def parse(path):
    text = path.read_text()
    first, _, body = text.partition("\n")
    match = re.fullmatch(r"kind:\s*(\w+)\s*", first)
    if not match or match.group(1) not in KINDS:
        raise ValueError(f"{path.name}: the first line must be 'kind: ' and one of {', '.join(KINDS)}")
    body = body.strip()
    if not body:
        raise ValueError(f"{path.name}: no paragraph after the kind line")
    return match.group(1), body


def assembled(parts):
    """The grouped section to append: kinds in a fixed order, fragments by file name within."""
    sections = []
    for kind, heading in KINDS.items():
        bodies = [body for k, body in parts if k == kind]
        if bodies:
            sections.append(f"## {heading}\n\n" + "\n\n".join(bodies))
    return "\n\n".join(sections) + "\n"


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="command", required=True)
    add = sub.add_parser("add")
    add.add_argument("topic")
    assemble = sub.add_parser("assemble")
    assemble.add_argument("version")
    sub.add_parser("check")
    arguments = parser.parse_args(argv)
    if arguments.command == "add":
        slug = re.sub(r"[^a-z0-9]+", "-", arguments.topic.lower()).strip("-")
        path = NEXT / f"{slug}.md"
        if path.exists():
            raise SystemExit(f"{path.relative_to(ROOT)} already exists")
        path.write_text(TEMPLATE)
        print(path.relative_to(ROOT))
        return 0
    parts = [(path, *parse(path)) for path in fragments()]
    if arguments.command == "check":
        print(f"{len(parts)} fragment(s) well formed")
        return 0
    notes = ROOT / f"docs/release-notes/{arguments.version}.md"
    if not parts:
        print("No fragments to assemble.")
        return 0
    existing = notes.read_text() if notes.exists() else f"# BombCAD {arguments.version}\n"
    notes.write_text(existing.rstrip("\n") + "\n\n" + assembled([(k, b) for _, k, b in parts]))
    for path, _, _ in parts:
        path.unlink()
    print(f"{len(parts)} fragment(s) assembled into {notes.relative_to(ROOT)}; check the wording, then commit")
    return 0


if __name__ == "__main__":
    sys.exit(main())
