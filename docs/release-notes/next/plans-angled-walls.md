kind: added

**Floor plans with walls at an angle, curved walls, and plans drawn turned.** The DXF plan
importer now raises walls at an angle to the plan, and the chords of curved ones (arcs and
polylines' bulges), as walls turned in plan: each a shell in its own plane, upright, tied to the
walls and slabs it meets. A plan drawn turned is first turned square to its walls, so that they
lie square to the air's cells. The IFC import does the same for whole walls turned in plan, with
**Pitched roofs and angled walls as shells in their own planes** on. The example house drawn
turned by 17° reads as drawn square; with a curved bay in its front wall, the bay's six chords
share their corners and, under a 20 kg charge, hold (13 to 119 mm) where the flat leaf beside them
breaks. The seams of mitred corners are read as joints, not walls. Windows in walls at an angle
are left open, and the floors over them are the outline's rectangle; see [From architectural
plans](../../using-the-app.md#from-architectural-plans).
