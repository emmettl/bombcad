# A house from a floor plan

The worked example of [From architectural plans](../../docs/using-the-app.md#from-architectural-plans):
a floor plan drawn in 2D, raised into a building in FreeCAD, exported as IFC and imported into
BombCAD. Drawn for BombCAD and released under [CC0 1.0](https://creativecommons.org/publicdomain/zero/1.0/), except the plans cut from
real buildings (below), which keep their sources' licence.

The house is 8 × 6 m over its outer faces, two storeys of 2.9 m. Its outer walls are cavity
walls 280 mm thick: 102.5 mm facing brick, 50 mm mineral wool, a 27.5 mm air gap and 100 mm
aggregate concrete block. A 100 mm block partition divides it. There is a door at the front and
five windows of 1.2 × 1.2 m. It has a 150 mm ground-bearing slab, a 200 mm first floor and a
200 mm flat roof, all of C30/37 concrete.

- [house-plan.dxf](house-plan.dxf) is the plan, as an architect's 2D drawing would give it:
  ASCII DXF, lines in millimetres, one layer for each kind of thing. WALL-EXT and WALL-INT
  carry the walls' centrelines, DOOR the door's width along its wall, and WINDOW-GF and
  WINDOW-FF each storey's windows. [make-house-plan.py](make-house-plan.py) writes it.
- [make-house-ifc.py](make-house-ifc.py) is a FreeCAD 1.1 script that does by machine what the
  guide does by hand. It raises each storey's walls over the plan's lines with the BIM
  workbench's Arch tools, cuts the windows and the door into them, lays the slabs, groups them
  by storey and exports IFC 4. Run it with
  `/Applications/FreeCAD.app/Contents/Resources/bin/freecadcmd make-house-ifc.py` from this
  folder.
- [house.ifc](house.ifc) is what it writes. [house.FCStd](house.FCStd) is the FreeCAD document,
  to open and edit in FreeCAD's window.

FreeCAD 1.1 exports a wall's multi-material without its layers and calls every wall movable, and
its development branch does the same. The script therefore adds each wall's layers to the IFC
after export, as an IfcMaterialLayerSetUsage, with the IfcOpenShell that FreeCAD ships. Bonsai
(Blender's IFC add-on) writes layered walls this way itself.

## The plan read in BombCAD

BombCAD also reads a DXF plan itself (**Import Model…** with the DXF), without FreeCAD: the
walls from their centrelines or their two faces, the openings from what is drawn in them or from
the gaps between walls, and the storeys by repeating the plan. `house-plan.dxf` is read this way
in `FloorPlanTests`, alongside the IFC route.

## Plans cut from real buildings

To judge the plan reader on drawings it was not written for, two plans are cut from real IFC
buildings by [cut-plan-from-ifc.py](cut-plan-from-ifc.py), as an architect's plan is drawn: each
element sliced 1 m above its storey's floor, the walls drawn by both faces, and each IFC class on
a layer of its own (IFCWALL, IFCWINDOW, IFCDOOR, ...). The cuts are the only change; the lines are
the building's own, in metres. Run it with BombCAD's pinned IfcConvert
(`python3 Scripts/prepare-ifc-converter.py` fetches it):
`python3 cut-plan-from-ifc.py BUILDING.ifc OUT.dxf [--storey NAME] [--height 1.0]`.

- [duplex-level-1.dxf](duplex-level-1.dxf) and [duplex-level-2.dxf](duplex-level-2.dxf): the
  ground and first floors of the Duplex Apartment,
  [Samples/Importer/Buildings/duplex-apartment.ifc](../Importer/Buildings/duplex-apartment.ifc).
  Source: BSI (2020) "Duplex Apartment Test Files," buildingSMART International,
  <https://github.com/buildingsmart-community/Community-Sample-Test-Files>, under
  [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/); see
  [its notice](../Importer/Buildings/NOTICE-Duplex.md).
- [small-house.dxf](small-house.dxf): the small house of
  [Samples/Importer/Buildings/building-architecture.ifc](../Importer/Buildings/building-architecture.ifc),
  buildingSMART International Ltd., Simple-Scene Building-Architecture, from the
  [buildingSMART Certification datasets](https://github.com/buildingSMART/Certification-datasets),
  under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).

These derived plans keep their sources' licence, not CC0, and their attribution implies no
endorsement.
