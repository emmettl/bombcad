# FreeCAD script: house-plan.dxf to house.ifc, as the BIM workbench would by hand.
#
#   /Applications/FreeCAD.app/Contents/Resources/bin/freecadcmd make-house-ifc.py
#
# Reads the plan's lines by layer (make-house-plan.py describes them), raises each storey's walls
# over them with FreeCAD's Arch tools, cuts the doors and windows into their walls, lays the floors
# and the flat roof, groups everything by storey and exports IFC 4 with FreeCAD's own exporter
# (IfcOpenShell underneath). The cavity walls carry their layers as a multi-material, which the
# exporter writes as an IfcMaterialLayerSet; the slabs are C30/37 concrete.

import os

import FreeCAD
import Arch
import Draft
from FreeCAD import Placement, Rotation, Vector
from importers import exportIFC

HERE = os.path.dirname(os.path.abspath(__file__)) if "__file__" in dir() else os.getcwd()
STOREY = 2900.0  # floor to floor, mm
SLAB = 200.0  # the first floor and the roof, mm
SILL = 900.0
WINDOW_HEIGHT = 1200.0
DOOR_HEIGHT = 2100.0


def read_dxf(path):
    """The LINE entities of an ASCII DXF, by layer: {layer: [((x0, y0), (x1, y1))]}."""
    pairs = open(path).read().splitlines()
    pairs = [(pairs[i].strip(), pairs[i + 1].strip()) for i in range(0, len(pairs) - 1, 2)]
    lines, entity = {}, None
    for code, value in pairs + [("0", "EOF")]:
        if code == "0":
            if entity and entity.get("type") == "LINE":
                lines.setdefault(entity["8"], []).append(
                    ((float(entity["10"]), float(entity["20"])), (float(entity["11"]), float(entity["21"]))))
            entity = {"type": value}
        elif entity is not None:
            entity[code] = value
    return lines


doc = FreeCAD.newDocument("House")
segments = {}  # each wall's plan segment, by its object name
plan = read_dxf(os.path.join(HERE, "house-plan.dxf"))


def material(name, color):
    m = Arch.makeMaterial(name=name)
    m.Color = color
    return m


brick = material("Facing brick", (0.6, 0.3, 0.2, 0.0))
insulation = material("Mineral wool insulation", (0.9, 0.9, 0.5, 0.0))
air = material("Air cavity", (0.9, 0.9, 0.9, 0.0))
block = material("Aggregate concrete block", (0.7, 0.7, 0.7, 0.0))
concrete = material("Concrete C30/37", (0.75, 0.75, 0.75, 0.0))

cavity = Arch.makeMultiMaterial(name="Cavity wall, brick and block")
cavity.Materials = [brick, insulation, air, block]
cavity.Thicknesses = [102.5, 50.0, 27.5, 100.0]
cavity.Names = ["Outer leaf", "Insulation", "Cavity", "Inner leaf"]
partition = Arch.makeMultiMaterial(name="Block partition")
partition.Materials = [block]
partition.Thicknesses = [100.0]
partition.Names = ["Block"]


def wall_along(segment, z, layers, name):
    (x0, y0), (x1, y1) = segment
    line = Draft.make_line(Vector(x0, y0, z), Vector(x1, y1, z))
    wall = Arch.makeWall(line, width=sum(layers.Thicknesses), height=STOREY, align="Center", name=name)
    wall.Material = layers
    segments[wall.Name] = segment
    return wall


def opening(segment, z, height, preset, name, host):
    """A window or door preset standing in its wall, the width along the plan's segment."""
    (x0, y0), (x1, y1) = segment
    width = ((x1 - x0) ** 2 + (y1 - y0) ** 2) ** 0.5
    # Presets are drawn in the XY plane; stood up, their X along the wall and their Y up, and
    # pushed back by half the frame's depth so the frame sits mid-wall.
    along = Vector(x1 - x0, y1 - y0, 0).normalize()
    rotation = Rotation(along, Vector(0, 0, 1), Vector(0, 0, 0), "XZY")
    frame = 70.0
    base = Vector(x0, y0, z) + rotation.multVec(Vector(0, 0, -frame / 2))
    item = Arch.makeWindowPreset(
        preset, width=width, height=height, h1=50.0, h2=50.0, h3=0.0, w1=frame, w2=30.0, o1=0.0, o2=0.0,
        placement=Placement(base, rotation))
    item.Label = name
    item.Hosts = [host]
    if preset == "Simple door":
        item.IfcType = "Door"
    return item


def host_for(segment, walls):
    """The wall whose centreline the opening's segment lies on."""
    (x0, y0), (x1, y1) = segment
    mid = Vector((x0 + x1) / 2, (y0 + y1) / 2, 0)
    best, distance = None, None
    for wall in walls:
        (a0, b0), (a1, b1) = segments[wall.Name]
        d = mid.distanceToLineSegment(Vector(a0, b0, 0), Vector(a1, b1, 0)).Length
        if distance is None or d < distance:
            best, distance = wall, d
    return best


def slab(z, name):
    """A slab over the inside of the inner leaves, bearing on them."""
    inner = 280.0
    rect = Draft.make_rectangle(8000 - 2 * inner, 6000 - 2 * inner, Placement(Vector(inner, inner, z), Rotation()), face=True)
    s = Arch.makeStructure(rect, height=SLAB, name=name)
    s.IfcType = "Slab"
    s.Material = concrete
    return s


storeys = []
for level, (name, windows) in enumerate((("Ground floor", "WINDOW-GF"), ("First floor", "WINDOW-FF"))):
    z = level * STOREY
    walls = [wall_along(s, z, cavity, f"{name} wall {i + 1}") for i, s in enumerate(plan["WALL-EXT"])]
    walls += [wall_along(s, z, partition, f"{name} partition") for s in plan["WALL-INT"]]
    items = []
    for i, s in enumerate(plan.get(windows, [])):
        items.append(opening(s, z + SILL, WINDOW_HEIGHT, "Fixed", f"{name} window {i + 1}", host_for(s, walls)))
    if level == 0:
        for i, s in enumerate(plan.get("DOOR", [])):
            items.append(opening(s, z, DOOR_HEIGHT, "Simple door", f"Front door {i + 1}", host_for(s, walls)))
    # The slab at the top of the storey: the first floor over the ground floor, the roof over the first.
    top = slab(z + STOREY - SLAB, "First floor slab" if level == 0 else "Roof slab")
    if level == 1:
        top.IfcType = "Roof"
    floor = Arch.makeFloor(walls + items + [top], name=name)
    floor.IfcType = "Building Storey"
    storeys.append(floor)

ground = Arch.makeStructure(None, length=8000, width=6000, height=150, name="Ground-bearing slab")
ground.Placement = Placement(Vector(4000, 3000, -150), Rotation())
ground.IfcType = "Slab"
ground.Material = concrete
storeys[0].addObject(ground)

building = Arch.makeBuilding(storeys, name="Two-storey house")
site = Arch.makeSite([building], name="Site")
doc.recompute()

empty = [o.Label for o in doc.Objects if o.isDerivedFrom("Part::Feature") and o.Shape.isNull()]
broken = [o.Label for o in doc.Objects if o.isDerivedFrom("Part::Feature") and not o.Shape.isNull() and not o.Shape.isValid()]
if empty or broken:
    print("Empty shapes:", empty, "invalid shapes:", broken)
path = os.path.join(HERE, "house.ifc")
exportIFC.export([site], path)


def add_wall_layers(path):
    """FreeCAD 1.1's exporter writes a wall's multi-material without its layers ("TODO: support
    multimaterials" in exportIFC.py) and calls every wall MOVABLE. With the IfcOpenShell FreeCAD
    ships, give each wall its layers as an IfcMaterialLayerSetUsage, in the file's units (metres),
    and make it a solid wall."""
    import ifcopenshell
    import ifcopenshell.api.material as api
    import ifcopenshell.util.element

    f = ifcopenshell.open(path)
    scale = 0.001  # the plan's millimetres to the file's metres
    sets = {}
    for layers in (cavity, partition):
        layer_set = api.add_material_set(f, name=layers.Label, set_type="IfcMaterialLayerSet")
        for mat, thickness, name in zip(layers.Materials, layers.Thicknesses, layers.Names):
            found = [m for m in f.by_type("IfcMaterial") if m.Name == mat.Label]
            ifc_material = found[0] if found else api.add_material(f, name=mat.Label)
            layer = api.add_layer(f, layer_set=layer_set, material=ifc_material, name=name)
            api.edit_layer(f, layer=layer, attributes={"LayerThickness": thickness * scale})
        sets[layers.Label] = layer_set
    for wall in f.by_type("IfcWall"):
        wall.PredefinedType = "SOLIDWALL"
        kind = partition if "partition" in wall.Name else cavity
        api.assign_material(f, products=[wall], type="IfcMaterialLayerSetUsage", material=sets[kind.Label])
        usage = ifcopenshell.util.element.get_material(wall)
        # The layers centred on the wall's axis; the outer leaf, first, outside, since the outer
        # walls run anticlockwise and the layers build to their left.
        usage.OffsetFromReferenceLine = -sum(kind.Thicknesses) * scale / 2
    f.write(path)


add_wall_layers(path)
doc.saveAs(os.path.join(HERE, "house.FCStd"))
print("Wrote house.ifc and house.FCStd")
