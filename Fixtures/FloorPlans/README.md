# Floor plan corpus

Small plans that each try one thing offices' drawings hold, with the answer expected of the plan
importer (`FloorPlan`, `DXFDrawing`), written by [make-corpus.py](../../Scripts/plans/make-corpus.py)
and judged by `FloorPlanCorpusTests`, `scenebench plan-check` and
[check-corpus.py](../../Scripts/plans/check-corpus.py). Drawn for BombCAD and released under
[CC0 1.0](https://creativecommons.org/publicdomain/zero/1.0/).

Each plan (`.dxf` or `.svg`) has a JSON beside it: how to read it (its layers' roles, or "guess";
the storeys layers keep to; units where the file gives none; the drawing's scale) and what reading
it should give: walls by thickness, the plan's size, doors, windows and gaps, walls at an angle,
the turn, walls per storey, the notes it should and should not raise. The answers come from the
plans' own geometry, not from the importer.

The DXFs are written with ezdxf as a CAD program writes them (R2010, with handles, tables, blocks
with attributes, hatches and dimensions); regenerate them with ezdxf in a venv outside the
repository:

    python3 -m venv /path/to/venv && /path/to/venv/bin/pip install ezdxf
    /path/to/venv/bin/python Scripts/plans/make-corpus.py

## What it covers

Walls by both faces and by centrelines; L, T and X junctions; partitions just over and under the
50 mm limit; doors (with their leaf and swing) and windows as blocks, turned, and openings left
as gaps, with jambs and without; arcs and bulges; units in mm, cm, m and inches, and none; hatching
and dimensions on the wall layer and on their own; text and furniture blocks, on their own layers
and on the wall layer; corner gaps of 0.5 to 5 mm and a face drawn twice; two storeys on layers;
national-grid coordinates; a plan turned 17°; DXFs cut off or out of step; SVGs at 1:100 in mm, in
pixels with transforms, with symbols placed by `<use>`, and malformed.

## Judgement calls

- **Hatching is not read.** A plan whose walls are drawn only as hatching, with no outline lines,
  has no walls to find (`hatch-only-walls`, recorded as a limitation). Most plans outline walls
  and hatch them as well, and a hatch's boundary is often a room's.
- **Blocks on a wall layer are not walls** (furniture, symbols, columns), and the notes count them.
- **Dimensions are not read** wherever they are: their lines live in blocks DXF never inserts.
- **Open ends close.** Two faces of a wall that stop together, a wall's thickness apart, with
  nothing across them are closed there; lines that stop up to 6 mm short of each other meet.
