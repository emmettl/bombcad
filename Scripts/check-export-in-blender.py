"""Imports BombCAD's USD/VDB exports into Blender and reports what arrived.

Usage: blender -b --python Scripts/check-export-in-blender.py -- <scene.usda> <frames,comma,separated> [render.png frame]

Prints a JSON report (prefixed "REPORT ") of the objects, the structure's faces and per-face
attributes and the volume's grids at each frame; with a path and a frame, also renders that frame
with Cycles, the structure coloured by damage and the blast by overpressure. See docs/usd-export.md.
"""
import json
import sys

import bpy

args = sys.argv[sys.argv.index("--") + 1:]
path, frames = args[0], [int(f) for f in args[1].split(",")]
render = args[2:4] if len(args) >= 4 else None

bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.wm.usd_import(filepath=path, import_volumes=True, read_mesh_attributes=True, set_frame_range=True)
scene = bpy.context.scene
report = {"file": path.split("/")[-1], "frame_range": [scene.frame_start, scene.frame_end],
          "fps": scene.render.fps, "objects": {}}
for obj in scene.objects:
    report["objects"][obj.name] = {"type": obj.type,
                                   "modifiers": [m.type for m in getattr(obj, "modifiers", [])]}

structure = next((o for o in scene.objects if o.type == "MESH" and o.name.startswith("Structure")), None)
volume = next((o for o in scene.objects if o.type == "VOLUME"), None)
per_frame = []
for frame in frames:
    scene.frame_set(frame)
    graph = bpy.context.evaluated_depsgraph_get()
    entry = {"frame": frame}
    if structure:
        evaluated = structure.evaluated_get(graph)
        mesh = evaluated.to_mesh()
        entry["vertices"] = len(mesh.vertices)
        entry["faces"] = len(mesh.polygons)
        zs = [v.co.z for v in mesh.vertices]
        entry["z_range"] = [round(min(zs), 3), round(max(zs), 3)] if zs else None
        for name in ("damage", "material", "rubble"):
            attribute = mesh.attributes.get(name)
            if attribute:
                values = [d.value for d in attribute.data]
                entry[name] = {"domain": attribute.domain, "type": attribute.data_type,
                               "count": len(values), "min": min(values) if values else None,
                               "max": max(values) if values else None}
            else:
                entry[name] = None
        evaluated.to_mesh_clear()
    if volume:
        evaluated = volume.evaluated_get(graph)
        grids = evaluated.data.grids
        grids.load()
        entry["volume"] = {"loaded": grids.is_loaded, "file": bpy.path.basename(grids.frame_filepath),
                           "grids": [g.name for g in grids]}
    per_frame.append(entry)
report["frames"] = per_frame
attributes = [a.name for a in structure.data.attributes] if structure else []
report["structure_attributes_at_last_frame"] = attributes
print("REPORT " + json.dumps(report))

if render:
    output, frame = render[0], int(render[1])
    scene.frame_set(frame)
    scene.render.engine = "CYCLES"
    prefs = bpy.context.preferences.addons["cycles"].preferences
    prefs.compute_device_type = "METAL"
    prefs.get_devices()
    for device in prefs.devices:
        device.use = True
    scene.cycles.device = "GPU"
    scene.cycles.samples = 32
    scene.render.resolution_x, scene.render.resolution_y = 960, 540
    scene.render.filepath = output
    camera = next((o for o in scene.objects if o.type == "CAMERA"), None)
    if camera:
        scene.camera = camera
    world = bpy.data.worlds.new("Sky")
    world.use_nodes = True
    world.node_tree.nodes["Background"].inputs["Color"].default_value = (0.55, 0.65, 0.8, 1)
    world.node_tree.nodes["Background"].inputs["Strength"].default_value = 0.6
    scene.world = world
    bpy.ops.object.light_add(type="SUN", rotation=(0.7, 0.2, 2.4))
    bpy.context.object.data.energy = 4

    if structure:
        # Colour the structure by its elements' damage, from grey through orange to red.
        material = bpy.data.materials.new("Damage")
        material.use_nodes = True
        nodes, links = material.node_tree.nodes, material.node_tree.links
        bsdf = nodes["Principled BSDF"]
        attribute = nodes.new("ShaderNodeAttribute")
        attribute.attribute_name = "damage"
        ramp = nodes.new("ShaderNodeValToRGB")
        ramp.color_ramp.elements[0].color = (0.75, 0.74, 0.7, 1)
        ramp.color_ramp.elements[1].color = (0.9, 0.1, 0.05, 1)
        ramp.color_ramp.elements.new(0.5).color = (0.95, 0.55, 0.1, 1)
        links.new(attribute.outputs["Fac"], ramp.inputs["Fac"])
        links.new(ramp.outputs["Color"], bsdf.inputs["Base Color"])
        structure.data.materials.clear()
        structure.data.materials.append(material)
    if volume:
        material = bpy.data.materials.new("Blast")
        material.use_nodes = True
        nodes, links = material.node_tree.nodes, material.node_tree.links
        nodes.remove(nodes["Principled BSDF"])
        volume_node = nodes.new("ShaderNodeVolumePrincipled")
        attribute = nodes.new("ShaderNodeAttribute")
        attribute.attribute_name = "overpressure"
        scale = nodes.new("ShaderNodeMath")
        scale.operation = "MULTIPLY"
        scale.inputs[1].default_value = 0.02
        links.new(attribute.outputs["Fac"], scale.inputs[0])
        links.new(scale.outputs["Value"], volume_node.inputs["Density"])
        volume_node.inputs["Color"].default_value = (1.0, 0.45, 0.15, 1)
        links.new(volume_node.outputs["Volume"], nodes["Material Output"].inputs["Volume"])
        volume.data.materials.clear()
        volume.data.materials.append(material)
    bpy.ops.render.render(write_still=True)
    print("RENDERED " + output)
