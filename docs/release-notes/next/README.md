# Release-note fragments

Each change that a user would notice adds one small file here, in the same push, instead of
editing the next release's notes: `python3 Scripts/release-notes.py add <topic>` writes the
template. Sessions working at once then never edit the same file. The release assembles them
(`python3 Scripts/release-notes.py assemble 0.6.0`) into `docs/release-notes/0.6.0.md`, grouped by
kind, and removes them.

A fragment is a first line `kind: added`, `changed`, `fixed` or `limitation`, a blank line, then
one paragraph in the notes' style: a bold lead saying what a user can now do or see, then what it
rests on and its standing, with links into the docs. Plain words; numbers with their source.
