kind: fixed

**Corrupt plan and terrain files are refused, not crashed on.** Each of these stopped the reader
before: a DXF arc with a NaN or enormous angle, or a bulge between a vertex and its repeat; an SVG
arc whose radii overflow, or groups nested thousands deep; an ESRI grid whose `ncols` or `nrows`
is not a whole number from 2 to a billion; and a BigTIFF whose 64-bit offsets lie past a signed
64-bit integer. Blocks that insert one another many times over, and SVG `<use>` copies, past
5,000,000 pieces, and plans of tens of thousands of layers, no longer run without end. A DXF or
SVG with a NaN or infinite coordinate, and a grid's infinite cell size, corner or elevation, are
refused rather than read as walls at infinity, and a DXF number that does not parse (`1e`, `--1`)
is refused with its line, where it was read as 0. A grid whose first value is `nan` reads it as no
data instead of shifting every value by two. An SVG or .osm file in invalid UTF-8, which trapped
Linux's XML parser and which macOS's already refused, is refused before it is parsed. Found by
fuzzing the readers ([Linux](../../linux.md#sanitizers-and-importer-fuzzing-20-october-2026));
each case is a test in ImporterRobustnessTests or ElevationFileRobustnessTests.
