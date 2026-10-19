kind: added

**Buildings from architectural floor plans, by way of IFC.** A new guide,
[From architectural plans](../../using-the-app.md#from-architectural-plans), takes a 2D plan
through FreeCAD's BIM workbench to IFC and into BombCAD as shells and panes. Its worked example,
a two-storey house with cavity walls, is in `Samples/Plans`: the plan as DXF, the FreeCAD script
that raises it, and the IFC. Two importer fixes came from it. A wall's material layers are now
read by what each layer is made of, where the IFC names the layer by its place ("Outer leaf").
Before, such walls fell back to the default material. A cavity wall's second leaf, whose stiffness
is still left out, now keeps its mass on the leaf that is meshed. FreeCAD 1.1 writes walls
without their layers, so the example adds them after export with IfcOpenShell.
