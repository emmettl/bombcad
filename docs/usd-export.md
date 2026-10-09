# Exporting a run for rendering

A run can be written out for another program to render: Blender's Cycles, for one, which uses
the Mac's ray-tracing hardware (see [Ray tracing](ray-tracing.md)). The geometry goes into a USD
scene, the air into OpenVDB volumes, one file a frame, which the scene refers to. Both steps
planned in the [roadmap](roadmap.md#usability-in-parallel) are done.

```bash
swift run -c release BombCAD run Example.bombcad --usd Example.usda --vdb Example.volumes --frame-interval 10
```

In the app, **File ▸ Export for Rendering…** (⇧⌘E, or the toolbar's extra-actions menu) does the
same from the open project: it runs a copy of it in the background, with a frame interval, the
volumes' grids and the project's fragments chosen in a sheet, and writes the scene where the
save panel says and the volumes in a folder beside it (`Example.volumes` for `Example.usda`).

`--usd` and `--vdb` are options of the [headless run](run-comparison.md#headless-runs), and
either can be used alone; `--frame-interval` sets the milliseconds of simulated time between
frames (1 by default). Frames are taken where the run loop samples the structure, every
millisecond, so with a structure the run is the same as without the export. Without one, the
run stops only for frames, and each stop ends a time step early; see [Size and speed](#size-and-speed).

## What the file holds

USD in its text form (`.usda`), Z up, in metres, written without any USD library.

| Prim | What it is |
|---|---|
| `/Scene/Ground` | The ground plane over the domain |
| `/Scene/Blocks` | The rigid blocks and rigid imported parts, as one mesh |
| `/Scene/Charge`, `Charge_1`, … | Spheres at the charges, with their mass as `bombcad:label` |
| `/Scene/Gauge_0`, … | Spheres at the gauges, named in `bombcad:label` |
| `/Scene/Camera` | The project's saved view, in a 16:9 frame |
| `/Scene/Structure` | The body's surface, frame by frame |
| `/Scene/Fragments`, `/Scene/Tracers` | With `--fragments`, Points that follow the frames ([Fragments](fragments.md)) |
| `/Scene/Thermal` | With `--thermal`, Points at the receivers, with their fluence and peak irradiance ([Thermal radiation](thermal-radiation.md)) |
| `/Scene/Cloud` | With `--cloud`, a sphere rising after the run, on frames of its own that follow the run's ([The fireball's rise and cloud](fireball-rise.md)) |

The structure's surface is what the app draws: the outer faces of intact solid elements, each
shell and beam as a box its thickness or section across, and a small cube of rubble for each
failed element. It is extracted on the CPU from the solvers' buffers by `StructureSurface`, which
follows the renderer's shaders (`structureVertex`, `shellVertex` and `beamVertex` in
`Render.metal`). Intact solid elements share their nodes, so the solid surface is one connected
mesh; shells, beams and rubble are separate boxes. Every face is a quad facing outwards.

Per face, three primvars carry the element's state:

- `damage`, the element's damage index: 0 when sound, 1 at the point of failure. It goes on
  rising past 1 (to about 8 in the concrete building under 1,000 kg) until the element is
  removed; the app's colours stop at 1. Rubble has 1.
- `material`, an index into the mesh's `bombcad:materials` names, with `bombcad:transparent`
  marking glass.
- `rubble`, true on the lumps that stand for failed elements.

Multi-body runs include all structural surfaces in `/Scene/Structure`. They add the uniform
per-face integer `object` primvar, indexing `bombcad:objectIds` and `bombcad:objectNames`.
Those tables preserve persistent scene ownership independently of vertex and face indices.

The points and damage change every frame; the faces, and with them `material` and `rubble`, are
written only on the frames where elements fail. Time codes count frames, played
at 24 a second; `simulatedSecondsPerFrame` in the layer's `customLayerData` gives the simulated
time between them.

## The air

`--vdb` writes the air at each frame to `blast.0000.vdb`, `blast.0001.vdb`, … in a new folder,
each file holding float grids, `overpressure` and `shock` unless `--vdb-fields` names others:

| Grid | What it is | Left out below |
|---|---|---|
| `overpressure` | Pressure above ambient, in kPa (negative behind the front) | 0.5 kPa in magnitude |
| `shock` | Magnitude of the pressure gradient, in kPa/m, which picks out the fronts | 5 kPa/m |
| `peak` | The highest overpressure each cell has seen so far, in kPa | 0.5 kPa |
| `impulse` | Positive overpressure integrated over time so far, in Pa·s | 0.5 Pa·s |

```bash
swift run -c release BombCAD run street.bombcad --usd street.usda --vdb street.volumes --vdb-fields overpressure,peak,impulse
```

`overpressure` and `shock` are read from the solver's visualisation volume, the one the app
ray-marches; `peak` and `impulse` from the solver's own fields, in full precision. All are the
cell values of the coarse grid (averaged from refined patches where there are any). Voxels
are centred on the cells, in metres from the domain's corner, and solid cells are left out. Still
air below the thresholds is not written, so early frames are small; the region behind a front
that has fallen back towards ambient shows as a hole.

With `--usd` as well, the scene gains a `Volume` prim, `/Scene/Blast`, with a field for each
grid reading the frames' files through relative paths. Blender also opens
the files directly as a volume sequence. Neither grid is called `density`, the name a renderer's
default volume material usually reads, so point the material at `overpressure` or `shock`.

The files are written by a small writer of BombCAD's own (`OpenVDBWriter`), without the OpenVDB
library: version 224 of the format, a standard `Tree_float_5_4_3`, an affine transform, and
values zlib-compressed as OpenVDB's own ZIP option does. Its tests read the files back with a
parser of their own. Compatibility with OpenVDB itself was checked through the OpenVDB reader in
macOS's USD (`hioOpenVDB`, used by `usdrecord`): a fog sphere and a lettered pattern spanning
several internal nodes, compressed and not, and the street's blast at 30 and 80 ms, all rendered
where and as they should.

## Size and speed

For the 225,000-element concrete building (`ScenarioPreset.concreteBox`, medium grid, 0.25 s):

| Frame interval | Frames | `.usda` | As `.usdc` |
|---|---|---|---|
| 1 ms | 251 | 970 MB | 362 MB |
| 10 ms | 26 | 104 MB | 38 MB |

The glass façade, of shells and beams, takes 2.7 MB a frame. Writing the frames added nothing
measurable to the run (68.4 s with them, 67.9 s without).

Volumes are larger and slower to write. For the street canyon on the medium grid (8.4 million
cells, 0.17 s):

| Frames | Run | Steps | Near-façade peak | Volumes |
|---|---|---|---|---|
| None | 19.0 s | 1,527 | 3,075.9 kPa | |
| Every 10 ms | 27.7 s | 1,534 | 3,075.9 kPa | 253 MB, up to 22 MB a frame |
| Every 1 ms | 100.6 s | 1,608 | 3,044.9 kPa | 2.4 GB in 171 files |

`peak` and `impulse` fill every cell the blast has reached, so they grow with the frames rather
than following the fronts: on the same street, 35 MB at 85 ms and 45 MB at 170 ms for the two
together. Blender 5.2 reads them. For a map of the damage done, one late frame (a large
`--frame-interval`) is usually enough.

Each frame costs about half a second (reading the volume back, building the leaves, zipping).
Without a structure, each frame also stops the run: every millisecond, that ends 5% more steps
early and lowers this peak by 1%. Every 10 ms or more, the change is negligible. With a structure
the run stops every millisecond regardless, so volumes only cost time: the concrete building with
its surface and volumes every 10 ms took 95.5 s against 55 to 68 s without, and wrote 79 MB of volumes. The binary form is about a third the
size and faster to load; `usdcat`, which macOS ships, converts:

```bash
usdcat Example.usda -o Example.usdc
```

## Checking a file

macOS also ships `usdchecker`, which the tests run on a written file, and `usdrecord`, which
renders frames through the file's camera:

```bash
usdchecker Example.usda
```

```bash
usdrecord --camera Camera --frames 0,25 Example.usda frame.###.png
```

`usdrecord`'s renderer draws a volume's `density` field only. To see the blast, put a small
layer over the scene that binds one of the grids as density, and record that:

```usda
#usda 1.0
(
    subLayers = [@./Example.usda@]
)
over "Scene"
{
    over "Blast"
    {
        rel field:density = </Scene/Blast/overpressure>
    }
}
```

The files have been checked this way, with frames rendered of the concrete building under 1,000
kg, of the glass façade breaking up, and of the street's blast.

## In Blender

Checked with Blender 5.2.2 LTS, importing with File → Import → Universal Scene Description and
its defaults (the script below passes `import_volumes` and `read_mesh_attributes`, both on by
default):

- **The structure** comes in as a mesh with a Mesh Sequence Cache modifier reading the file, so
  its points and its faces follow the frames: 116,064 faces at frame 0 of the concrete building
  under 1,000 kg, 118,306 once its front wall had broken up.
- **`damage`, `material` and `rubble`** come in as face attributes (float, integer, Boolean).
  An Attribute node named `damage` feeding a colour ramp colours the structure by damage.
- **The blast** comes in as a Volume object whose file follows the frames, `blast.0000.vdb` at
  frame 0 and so on, with both grids, `overpressure` and `shock`. An Attribute node named
  `overpressure` (scaled down; it is in kPa) feeding a Principled Volume's density renders it in
  Cycles. The two OpenVDBAsset prims also come in, as empty objects that do nothing.
- **The camera** is the project's view, and the scene's frame range is set from the file, played
  at 24 frames a second.

`Scripts/check-export-in-blender.py` does this without opening Blender's window, prints what
arrived at the frames given, and can render one with Cycles:

```bash
blender -b --python Scripts/check-export-in-blender.py -- Example.usda 0,10,25 render.png 25
```

## Limitations

- **Coarse-grid values.** The volumes are the coarse grid's cells, also where refinement sharpens
  the shock; peak pressure and impulse, which the volume also holds, are not exported.
- **Frames on whole milliseconds** of simulated time. Without a structure and without `--vdb`,
  the scene is a still of one frame. Volume frames in a run without a structure end a time step
  early (above).
- **No reference reader in the tests.** The files are checked against OpenVDB and Blender by
  hand, through `usdrecord` and the script above, not in `make check`.
- **A second run.** The app keeps no frames of its runs, so exporting from the app runs the
  project again rather than writing out the run on screen.
- **Large files at fine intervals**, in text form above all; see above.
- **No materials.** Faces carry the material's name and transparency, not a shader; colours and
  glass are set up in the renderer.
