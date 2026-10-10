# Ray tracing

How hard it would be to adopt hardware ray tracing on the Mac, written in October 2026 as a note
for other projects, ones that render simulations computed in advance. BombCAD's renderer does not
need it: its GPU is busy with the simulation, and the renderer already ray-marches the blast over
rasterized meshes ([Performance](performance.md#display)). It does use it for one thing, the
thermal radiation's receivers' view of the fireball, and marches the fireball's cells in the same
kernels ([below](#in-bombcad-the-fireballs-radiation)).
Effort figures are judgements, not measurements, except in that section.

## Short answer

- Ray-traced shadows or ambient occlusion in an existing raster renderer: days.
- Animated meshes, rigid debris, reflections and glass: a few weeks.
- A full path tracer with materials, volumes and denoising: months, a project in itself.
- For precomputed simulations, exporting the results and rendering them in Blender's Cycles,
  which uses the Mac's ray-tracing hardware, is likely the cheapest route to good images. Build
  your own only if the ray tracing has to be interactive inside your own app.

## What Metal offers

Metal builds an **acceleration structure**, a search tree over triangles (or custom primitives
through intersection functions), and any shader (compute, vertex or fragment) can fire rays at it
and ask what each one hits first. From the M3 on, that search runs in dedicated hardware; on M1
and M2 the same code runs in software, several times slower. The M5's GPU has the third
generation of the hardware.

The hardware only speeds up rays against **geometry**. Volumes (smoke, a fireball, a pressure or
density field) are still ray-marched in ordinary shader code. Hardware rays can help only by
skipping empty space, given boxes around the occupied regions.

## Effort, step by step

| Step | What it involves | Effort |
|---|---|---|
| Shadows or ambient occlusion in a raster renderer | One acceleration structure built from the meshes; a shadow or occlusion ray per pixel from the fragment shader | Days; a few hundred lines |
| Animated precomputed geometry | Per frame, **refit** the structure when only vertices move (fast), **rebuild** when the mesh changes (elements fail, pieces break off) | About a week, mostly tuning when to refit and when to rebuild |
| Rigid debris | One structure per piece shape, placed by a transform per frame (instancing): cheap even with thousands of pieces | A few days more |
| Reflections, glass, soft shadows | Several rays per pixel, so noise: accumulate frames while the view is still, or denoise | One to three weeks |
| Full path tracing | Sampling, materials, light transport, denoising, and lit volumes handled separately from the hardware | Months |

## Why precomputed simulations are the easy case

- **No contention.** The simulation is finished, so the whole GPU is free for rendering. The
  trade-off in BombCAD, where every millisecond of rendering is taken from the solver, does not
  arise.
- **Frames can be slow.** For a video rather than an interactive viewer, a frame can take seconds
  and gather many samples per pixel. That removes the hardest part of real-time ray tracing,
  which is getting a clean image from very few rays.

## The shortcut: export to Blender

Write the results out in standard formats and let an existing renderer do the work:

- animated meshes as **Alembic** or **USD** (per-frame vertex positions; a changing mesh is
  supported by both);
- volumes as **OpenVDB** grids.

Blender's Cycles renderer uses the hardware (MetalRT) by default on M3 and newer since Blender
4.0, and already handles materials, smoke and fire, motion blur and denoising. An exporter is days
of work; the renderer it saves is months. BombCAD now has both, the geometry and the volumes:
see [Exporting a run for rendering](usd-export.md).

## In BombCAD: the fireball's radiation

The [thermal radiation](thermal-radiation.md) asks, each frame, whether about half a million
segments from the receivers to the fireball are clear of the blocks and the structure's starting
outline. `MetalThermalVisibility` answers in one compute dispatch:

- **Bounding boxes, no intersection functions.** The scene is axis-aligned boxes, so each goes into
  one primitive acceleration structure as a bounding-box primitive, enlarged by a millimetre. The
  kernel runs an inline `intersection_query`: the hardware returns each candidate box, and the
  CPU's own slab test, operation for operation, decides. There is no intersection function table
  to build, and the ground, the plane z = 0, is a comparison rather than geometry.
- **The same answer as the CPU.** The kernel is compiled in safe math mode (no fused or reordered
  arithmetic), so the test is the CPU's arithmetic. On every scene tried, the irradiance agrees
  with the CPU's to the bit, which keeps a result the same whichever Mac, GPU or CPU worked it out.
  The tests allow float tolerance, since nothing guarantees this on other GPUs.
- **A busy GPU.** The blast or another app can keep the GPU from the rays for a while. If a frame
  has not come back within a few times the usual wait (4 to 50 ms), the CPU tests it as well and
  the first answer is taken, as RoomCAD's wave solver moves to the CPU.
- **What it saves.** On the street canyon (10,456 receivers, 128 directions each, about 500,000
  rays a frame), the GPU takes about 0.2 ms a frame, against 0.9 ms on all of an M4 Max's CPU cores.
  That is a small share of a frame: laying out the rays and summing them stay on the CPU, so the
  receivers take 5 ms of the cores' time a frame instead of 12. Copying the rays is a real cost
  at this size. Rays went from 48 to 28 bytes, packed as seven floats, and are copied to the GPU
  across the cores; before that, the GPU's answer took longer to arrive than the CPU's.

### The fireball as a volume

The volume model ([Thermal radiation](thermal-radiation.md#the-model)) follows each receiver's
rays through the fireball's luminous cells, gathering what they emit and absorb. As above, the
hardware cannot help with the volume itself; `MetalThermalMarch` uses it only for what is in the
way, and does the rest in ordinary shader code:

- **One threadgroup a receiver.** Its 64 threads share out the receiver's directions, each
  working out the receiver's cones from the fireball's tiles, which costs nothing beside the
  march, and add their sums in order at the end, so the answer is the same from run to run.
  Nothing is laid out or copied per ray: the receivers go to the GPU once, and each frame only the
  cells (16 bytes each, a few megabytes) and up to 16 tiles.
- **The nearest occluder, in the visibility's structure.** The same acceleration structure of
  boxes serves: the ray is cut where it leaves the cells' box, and each candidate box the hardware
  offers is tested exactly; one that is crossed shortens the ray
  (`commit_bounding_box_intersection`), which lets the hardware skip farther boxes. A scene with
  nothing in it but the ground gets a stand-in box far below it, since the kernel must be given a
  structure.
- **Skipping empty space.** The ray walks the cells it crosses (Amanatides and Woo) and steps
  finely only through those next to luminous gas, taking the gas there trilinearly from eight
  cells; it stops once the gas behind lets through less than 10⁻⁴.
- **No race with the CPU.** The CPU's march, the same algorithm, is about thirty times slower (540 ms a frame on the street's receivers against 18 ms); where the
  visibility test hands a slow frame to the CPU, the march waits for the GPU, and moves to the CPU
  only if the GPU fails. The two agree to a thousandth of the highest irradiance, not to the bit:
  their exponentials and order of summing differ.
- **What it costs.** On the street's 10,456 receivers, 128 directions each, the afterburning
  fireball takes the GPU 12 ms a frame on average over the run, and a whole frame, cells to
  irradiance, 29 ms, against 136 ms on the CPU's cores for the opaque shape, whose rays only the
  visibility test sends to the GPU.

## Pitfalls

- **Rebuilding every frame** when refitting would do wastes most of the frame. But refitting
  slowly degrades the tree as things move far from where it was built, so rebuild now and then,
  or after large motion.
- **Expecting the hardware to help volumes.** It does not; plan the volume renderer separately.
- **Older Macs.** On M1 and M2, ray tracing runs in software. Cycles even turns MetalRT off by
  default there, because its own intersection code is faster without the hardware. Test on them
  if they must be supported.
- **Short dispatches cost their copies.** A test that takes the hardware a fraction of a
  millisecond can lose to the CPU once the inputs are copied over and the command buffer
  scheduled; keep what crosses small, or make it on the GPU.
- **Noise.** Any effect that needs more than one ray per pixel (soft shadows, glossy reflections,
  global illumination) needs accumulation or a denoiser before it looks right.

## Sources

- Apple, [`intersection_query` in the Metal Shading Language
  Specification](https://developer.apple.com/metal/Metal-Shading-Language-Specification.pdf),
  section 6.18: ray queries with bounding-box candidates handled in the shader.

- Apple, [Your guide to Metal ray tracing](https://developer.apple.com/videos/play/wwdc2023/10128/)
  (WWDC 2023): acceleration structures, ray queries in any shader, instancing, refitting.
- Apple, [`refit` on `MTLAccelerationStructureCommandEncoder`](https://developer.apple.com/documentation/metal/mtlaccelerationstructurecommandencoder/refit(sourceaccelerationstructure:descriptor:destinationaccelerationstructure:scratchbuffer:scratchbufferoffset:options:)):
  refitting is much faster than rebuilding but may lower the structure's quality.
- Blender, [Cycles: Apple M3 tuning including hardware raytracing](https://projects.blender.org/blender/blender/pulls/114296)
  and [default to MetalRT off unless the GPU is an M3 or newer](https://projects.blender.org/blender/blender/pulls/120299).
- [Mac Studio (M5 Max)](https://theapplewiki.com/wiki/Mac_Studio_(M5_Max)): third-generation
  hardware ray tracing in the M5 family's GPU.
