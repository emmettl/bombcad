# Exporting a run for rendering

A run can be written out as a USD scene, to be rendered by another program: Blender's Cycles,
for one, which uses the Mac's ray-tracing hardware (see [Ray tracing](ray-tracing.md)). This is
the first of the two steps planned in the [roadmap](roadmap.md#usability-in-parallel): the
geometry. The blast itself, as volumes, is the second and is not done.

```bash
swift run -c release BombCAD run Example.bombcad --usd Example.usda
```

`--usd` is an option of the [headless run](run-comparison.md#headless-runs); `--frame-interval`
sets the milliseconds of simulated time between frames (1 by default). The run is the same as
without it: frames are taken at the structural samples, every millisecond, where the run loop
stops anyway.

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

The structure's surface is what the app draws: the outer faces of intact solid elements, each
shell and beam as a box its thickness or section across, and a small cube of rubble for each
failed element. It is extracted on the CPU from the solvers' buffers by `StructureSurface`, which
follows the renderer's shaders (`structureVertex`, `shellVertex` and `beamVertex` in
`Render.metal`). Intact solid elements share their nodes, so the solid surface is one connected
mesh; shells, beams and rubble are separate boxes. Every face is a quad facing outwards.

Per face, two primvars carry the element's state: `damage`, from 0 (sound) to 1 (failing; 1 for
rubble), and `material`, an index into the mesh's `bombcad:materials` names, with
`bombcad:transparent` marking glass. The points change every frame; the faces, and with them
`material`, are written only on the frames where elements fail. Time codes count frames, played
at 24 a second; `simulatedSecondsPerFrame` in the layer's `customLayerData` gives the simulated
time between them.

## Size and speed

For the 225,000-element concrete building (`ScenarioPreset.concreteBox`, medium grid, 0.25 s):

| Frame interval | Frames | `.usda` | As `.usdc` |
|---|---|---|---|
| 1 ms | 251 | 970 MB | 362 MB |
| 10 ms | 26 | 104 MB | 38 MB |

The glass façade, of shells and beams, takes 2.7 MB a frame. Writing the frames added nothing
measurable to the run (68.4 s with them, 67.9 s without). The binary form is about a third the
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

The files have been checked this way, with frames rendered of the concrete building under 1,000
kg and of the glass façade breaking up. They have not yet been opened in Blender. Its USD
import is expected to bring in a mesh whose points and faces change over time, and primvars as
attributes, so that `damage` can drive a material through an Attribute node; both are still to
be tried.

## Limitations

- **No blast.** The air is not exported; that is the roadmap's second step, as OpenVDB volumes.
- **Frames on whole milliseconds** of simulated time, the structural sampling interval. A run
  without a structure is exported as a still scene of one frame.
- **Headless only.** The app keeps no frames of its runs, so there is no Export command in the
  app; a project saved from the app is exported with `BombCAD run`.
- **Large files at fine intervals**, in text form above all; see above.
- **No materials.** Faces carry the material's name and transparency, not a shader; colours and
  glass are set up in the renderer.
