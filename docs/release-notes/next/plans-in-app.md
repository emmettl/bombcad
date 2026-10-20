kind: added

**Buildings from DXF floor plans, in the app.** **Import Model…** now takes an ASCII DXF plan and
raises it into a building without a BIM program: walls drawn by both faces (read as the regions
their lines enclose) or by centrelines, joined at corners and junctions; doors and windows from
blocks, groups of lines or gaps; the storeys by repeating the plan, with each layer on every
storey or one; and flat floors and roof, seated inside the outer walls as a BIM model lays them
(or over the whole outline). A sheet maps the drawing's layers to walls (each with a construction
such as a brick-and-block cavity wall), doors, windows and floor outlines, asks for the units
where the drawing does not say, and previews what was found. The building then goes through the
same review as an IFC import, as shells and panes or rigid obstacles. Walls at an angle and
curved walls are read too (the next entry); [From architectural
plans](../../using-the-app.md#from-architectural-plans) describes both this route and the IFC one. On the example
house it gives the same building as the FreeCAD route, and under a 20 kg charge the same front
load and the same broken front wall; on plans cut from buildingSMART's Duplex Apartment it finds
the outer walls whole and every door and window the cut shows.
