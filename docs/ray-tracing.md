# Ray tracing

How hard it would be to adopt hardware ray tracing on the Mac, written in October 2026 as a note
for other projects, ones that render simulations computed in advance. BombCAD does not need it:
its GPU is busy with the simulation, and its renderer already ray-marches the blast over
rasterized meshes ([Performance](performance.md#display)). Effort figures are judgements, not
measurements.

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
of work; the renderer it saves is months.

## Pitfalls

- **Rebuilding every frame** when refitting would do wastes most of the frame. But refitting
  slowly degrades the tree as things move far from where it was built, so rebuild now and then,
  or after large motion.
- **Expecting the hardware to help volumes.** It does not; plan the volume renderer separately.
- **Older Macs.** On M1 and M2, ray tracing runs in software. Cycles even turns MetalRT off by
  default there, because its own intersection code is faster without the hardware. Test on them
  if they must be supported.
- **Noise.** Any effect that needs more than one ray per pixel (soft shadows, glossy reflections,
  global illumination) needs accumulation or a denoiser before it looks right.

## Sources

- Apple, [Your guide to Metal ray tracing](https://developer.apple.com/videos/play/wwdc2023/10128/)
  (WWDC 2023): acceleration structures, ray queries in any shader, instancing, refitting.
- Apple, [`refit` on `MTLAccelerationStructureCommandEncoder`](https://developer.apple.com/documentation/metal/mtlaccelerationstructurecommandencoder/refit(sourceaccelerationstructure:descriptor:destinationaccelerationstructure:scratchbuffer:scratchbufferoffset:options:)):
  refitting is much faster than rebuilding but may lower the structure's quality.
- Blender, [Cycles: Apple M3 tuning including hardware raytracing](https://projects.blender.org/blender/blender/pulls/114296)
  and [default to MetalRT off unless the GPU is an M3 or newer](https://projects.blender.org/blender/blender/pulls/120299).
- [Mac Studio (M5 Max)](https://theapplewiki.com/wiki/Mac_Studio_(M5_Max)): third-generation
  hardware ray tracing in the M5 family's GPU.
