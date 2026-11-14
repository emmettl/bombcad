# Hillside blast: a quarry face as a spectacle (experiment)

**Standing: illustrative.** Like the crater's growth ([docs/cratering.md](cratering.md), "How it
grows"), this is for the eye. The fracture pattern is a Voronoi tessellation chosen by eye; the
firings are a stylised row at even spacing and time, with no charge masses, hole layouts or
loadings of any kind; each firing only gives nearby blocks a velocity by the law below. Nothing
here says anything about real fragmentation, flyrock reach or safe distances, and no code path
offers it as a blast-design aid. It is an experiment, reachable only from the `hillsideblast`
command, and it changes nothing in the solver or any existing result.

emmettl/bombcad-work#122.

The same window's second scene, a cut through a ridge (File ▸ New Ridge Cut), is written up in
[ridge-cut.md](ridge-cut.md).

## The experiment, 8 November 2026

The question: can BombCAD show a hillside of about 100,000 rock blocks blasted, in real time or
near it, and does it look like anything? Run: `hillsideblast simulate --blocks 110000 --seconds 20
--out NAME`, then `hillsideblast render --blocks 110000 --poses NAME --out NAME --clip --stills
…` (outputs under `$BOMBCAD_DATA/hillside-blast/`).

**The scene.** A heightfield hillside with a steep face; in front of a new, excavated face the
rock between the old surface and the new one is cut into jittered Voronoi cells (about 108,000
blocks, mean edge 1 m, a spread of sizes from a density field and boulders that exclude other
sites, with clip planes along both surfaces). Each block is a clump of spheres (1 to 24, about 5
on average) inscribed in its polyhedron, so it is rigid and can interlock, drawn as its own
polyhedron with fresh and weathered faces. The skin of blocks against the new face (about 16,500
of them) never lets go, so the final face is rough, and the rest fires on its own time.

**Firings and the law.** One row of 16 firing points along the face, staggered 0.1 s apart so a
ripple runs along it. A block at distance r from its nearest firing lets go at that firing's time
plus r / 200 m/s, with a speed v = 15 (3 / max(r, 3)) m/s, jittered by 0.7 to 1.2 and at least 0.25 m/s, along a
direction with 0.33 to 0.55 added upward before normalising. For the 0.22 s before it lets go it
drifts at a tenth of that speed, which is the swell. All of it chosen by eye, stated so the look can
be reproduced; none of it is a load.

**The solver.** `BlockSimulation`, a small Metal contact solver for clumps: hash grid, spring
dashpot with mass-scaled stiffness, Coulomb friction regularised by a tangential viscous term,
heightfield ground, held blocks immovable until fired, sleeping once still with a body-level
creep damper for the supported and slow.

**First measurement: the project's own rigid-body code does not scale to this.** The reference
`RigidBodyWorld` (`hillsideblast rigid-scaling`) is CPU, single-thread sequential impulses: at
10,000 boxes in contact on terrain one step of 1/240 s takes 6.5 s (120 ms at 1,000, 680 ms at
3,000; an exponent of 1.6 to 1.9 between those), so 100,000 would take minutes a step by
extrapolation; it was not run. That route was stopped there. The
brief's fallback (rigid bodies for the big blocks and particles for the rest) turned out not to be
needed: clumps on the GPU keep every block rigid.

**Frame times.** One animation frame of 1/30 s is 8 substeps at 240 Hz. M4 Max Studio, GPU time of
the whole step:

| Blocks | Spheres | Frame median | Frame p90 | Against real time (median, p90) |
|---:|---:|---:|---:|---|
| 10,059 | 50 k | 3.1 ms | 3.8 ms | 11x, 9x |
| 31,641 | 156 k | 9.6 ms | 11.6 ms | 3.5x, 2.9x |
| 108,015 | 530 k | 41 ms | 47 ms | 0.8x, 0.7x |
| 108,015 (4 substeps, 120 Hz) | 530 k | 29 ms | 32 ms | 1.2x, 1.0x, but settles more slowly (70,500 awake at 8 s, against 35,500) |
| 326,003 | 1.6 M | 319 ms | 359 ms | 0.1x |
| 1,054,232 | 4.7 M | 599 ms | 2,110 ms | under 0.1x, and erratic |

Each row is one clean 8 s run (two at 108,015, which agreed), counting only the frames with more
than 5% of the blocks awake. Past 108,000 the cost grows faster than the count: at 326,000 the grid
is 25 M cells, cleared every substep, which was not tuned. Drawing the 5.2 M triangles is not the limit: 3.1
ms at 1080p with no dust, 8.3 ms at 3840 x 2160 supersampled with the dust ray-marched at 1080p;
the dust solve itself is 17 ms a frame at a 1 m grid (5 to 6 ms at 1.5 m, measured with less
care). Memory: 79 MB of solver buffers, 221 MB of blocks' mesh, about 390 MB of dust fields at 1 m
(computed from their formats), and a 3.5 MB/frame pose cache for replay (2.1 GB for 20 s at 30
frames a second).

**Stable.** The pile settles without explosions: no NaNs, and in the last second of a 20 s run the
median block moved 0.000 m, the 99th percentile 2.2 cm and the worst 14 cm; 8 of 108,015 moved more
than 10 cm. It is not fully at rest: 25,178 blocks were still awake at 20 s, creeping at about 2
cm/s at most for the 99th percentile, too little to see at this distance (2 cm is a fraction of a
pixel). Contacts are soft: from the stiffness, a block should sink about a quarter of a metre at
20 m/s and about 1 cm under a pile (estimated, not measured), which reads fine at this distance.

**Not bit-reproducible.** The hash grid's lists are built in the order the GPU's threads arrive, so
two runs of the same scene differ: at 20 s the same block sits a median of 0.28 m apart (99th
percentile 3.3 m), while the pile as a whole agrees (mean height 6.072 m and 6.073 m). A feature
that needs a repeatable result would have to sort the grid. It also moves frame times by a few per
cent between runs (p90 45 to 49 ms over a whole 20 s event).

**Interactive?** Not fully. Physics plus dust plus drawing adds up to about 66 to 72 ms per 1/30 s frame at
108,000 blocks while the rock moves (41 to 47 + 17 + 8), so about 14 frames a second live; this
was added up from the parts, not run as one live loop, and nothing here has a live window. A
cached replay of the poses draws at 3 to 8 ms, so it could scrub freely, though no scrubbing was
built. The dust is a forward solve and cannot be scrubbed without stored fields (17 MB a frame for
density at 1 m, 10 GB for 20 s, so keyframes and a coarser field). Changing the firing order means
running the physics again: about 18 s of GPU time for a 20 s event at 240 Hz. So: a precomputed event you can replay, with live re-firing near
real time, not a scene that responds at 60 Hz.

**The look, frankly.** Better than I expected from a short experiment, not yet beautiful:
the swell of the face (a few frames before it lets go) reads, the ripple running along the row
is clear, the rock tumbling down reads as rock, the settled pile is convincing from afar and the
dust columns billow and drift. What is wrong: the dust is soft and a little blurry
(a 1 m grid and noise erosion, no real turbulence); blocks are convex Voronoi cells, so the broken
rock has a "rock crystal" sameness up close; there is no contact audio, no spall or small rock
sliding on the pile (the sub-metre fraction is missing), no flash, and beyond the ends of the
broken strip the terrain's own face is a smooth striped texture. A frame that looks like a photograph would need
more resolution in blocks and dust than this, and an art pass.

**Dust.** The collapse's passive cloud (docs/whole-event.md, "Dust, stage 1") is not reused: it
rides the compressible air solver and draws its source from element work, neither of which runs at
interactive cost or at this scale of contact. A simple incompressible smoke box at 1 m (GPU,
stable-fluids with buoyancy, wind and vorticity confinement, fed by the firings and by moving
blocks) and a ray march with detail noise is what is rendered.

**What it would take to go from this to a real explorer scene:** a real rock-breaking source of
blocks (tessellating an actual scene's terrain or structure and choosing a pattern), a proper
contact solver stage (tangential history for real static friction, an upgrade to
convex-convex or SDF contact for big blocks), the interactive frame budget (fewer substeps and a
bigger sleeping fraction; the physics is the current limit, 41 to 47 ms at 108,000 blocks), a dust
keyframe cache for scrubbing, and scene authoring (where the firings go, what breaks). In short: a
new subsystem, with an art pass, for a feature whose standing stays "for the eye" and whose use
is spectacle. The decision is the user's; nothing here
changes defaults or results.

## Art pass, 8 November 2026

On the user's word of 8 November: one art pass on the look. Same standing (illustrative, a stylised
row of firings, no real blast designs). The renderer grew; the solver only got clamps. Run: `hillsideblast
render --blocks 110000 --poses art/poses --out art --dust-h 1.0 --clip --bitrate 9000000 --stills
3.0,4.2,6.5,19.9` from `simulate --blocks 110000 --seconds 20 --out art/poses`.

**What changed.**
- **Rock.** Voronoi cells bedded (an anisotropic metric with a slight tilt) so the rock splits flatter,
  with each polygon's surface tessellated and displaced by noise in world position (so neighbours stay
  matched until they part, 21 M triangles), per-block warp, normal mapping from noise, weathered and
  fresh faces with beds and lichen.
- **Small debris and fines.** About 1.2 million decorative stones: chips that leave their blocks,
  ballistic over a per-frame top-down height of the scene, and gravel on the ground. None is a body.
- **Swell.** A coherent drift of the held blocks out and up, up to about 2 m near a firing over 0.45 to
  0.75 s before release, instead of a tenth of the launch. It reads: at 2.1 s, 37,000 blocks have moved
  a median of 1.2 m before letting go. First firing moved to 1.8 s so the calm face is seen first.
- **Dust.** MacCormack advection, stronger vorticity, and a march that cuts the field with a baked 3-D
  Worley-Perlin volume, sampled with a warp, at 0.6 m steps through the cloud with empty-space skipping,
  and a Henyey-Greenstein phase. The dust shadows the scene.
- **The untouched face.** Render-only bedded blocks over all steep ground and past the strip, and the
  ground carried on past the grid and a skirt beyond it, so the long lens sees no edge and no smooth wall.
- **Light and camera.** Sun about 15° above the horizon raking along the face, 8192 shadow map,
  screen-space AO, cool sky fill and warm sun, a graded, vignetted tonemap, and a slow 20-second dolly at
  a long lens, oblique to the face so it runs away across the frame.

**Solver changes (for the eye).** Inertia floored at half the largest axis, spin capped at 14 rad/s and
speed at 45 m/s, and the overlap a contact sees capped at 35% of the radius: bedded blocks are flatter
and were otherwise spinning up without limit (one reached 55 km/s in the first bedded run, as stray rocks
launched straight up). Stability afterwards: in the last second of the 20 s run, median movement 0,
99th percentile 2.3 cm, worst 26 cm, 8 blocks moved more than 10 cm.

**Times.** Physics for the new scene: 36 ms median and 54 ms p90 over a 20 s event. The clip renders at
1920 x 1080 from 3840 x 2160 at 54 s for 601 frames, about 90 ms per frame: 53 ms median to draw (the
21 M triangles, shadows, AO, the dust march), 18 ms for the dust solve, and the encode. The clip is 23
MB at 9 Mb/s.

**The look, frankly.** Stopped after eight rounds, because further rounds had stopped helping, not because
it is finished. The low light, the billowing dust and the broken rock at a few seconds in (the 4.2 s
frame) are good. What still looks wrong: the settled pile and the broken rock are one colour and one
kind of lump; the face beyond the strip is a flatter texture than the blocks, and a seam shows at the
strip's end; a low sheet of dust lies across the pile for a few seconds around 8 to 10 s and reads as
a layer rather than a cloud. Past this, a better source of rock shapes and colour, not more shader
work, is what would move it.

**A correction to the section above.** `final/clip.mp4` from the first experiment was frozen on its
last frame for its whole 20 s (rendered after the stills, with the forward-only dust and poses
already at the end); nobody watched it, and it was reported as a clip. The physics, the settling
numbers and the stills were real. The draw times quoted above (3.1 and 8.3 ms) were measured on that
frozen frame, so they are for a settled scene with little dust. This section's numbers come from a run
in order, whose frames were checked.

## Stage 2: the rock, and a window to play with it, 8 November 2026

On the user's word of 8 November (emmettl/bombcad-work#123). Same standing: illustrative, a stylised
row of firings for the eye, not a blast-design aid; it says nothing about real fragmentation, flyrock
reach or safe distances. Experimental command only; nothing in the shipped app changes.

**The rock.** `Fracture.swift`: a bedding family and three joint families (two steep, one shallow
that makes wedges), at irregular spacing, each plane present only in patches and more often where the
rock is more broken. They cut about 36,000 coarse Voronoi cells into 91,208 slabs and wedges with
large blocks among fines. The shader colours by the same bed coordinate the fracture uses, and tells
weathered skin, old joint faces (iron-stained) and fresh breaks apart. A strip's end is ragged rather
than straight; the terrain under the render-only rock is pulled in behind it, which removed the striped
wall. The camera is closer and low; the floor still fills about a quarter to a third of the frame. The swell is a coherent drift
of up to 3.4 m over 0.8 to 1.25 s before release.

**The window.** Run it from a checkout (the build takes about two minutes):

    swift run -c release hillsideblast play --blocks 110000

Drag to orbit, shift-drag to pan, scroll to zoom. The timeline scrubs; Play plays; Order, Ripple and
Firings change the stylised pattern; Fire again re-runs it, and the old event stays on show until the
new one is ready. The first event is computed at start-up (about 24 s), with progress in the window.

**How scrubbing works.**
- *Poses* are cached whole: 16 bytes a block a frame (position in floats, orientation smallest-three in
  10:10:10:2), 836 MB for 20 s at 30 frames a second. Scrubbing is exact.
- *Dust* only runs forward. It is a 1.5 m field in the window (the film's is 1 m), with a stored field
  every second, made as playback first passes that second: 28 MB each, 599 MB for the whole event. A
  scrub restores the nearest stored field at or before the frame and replays forward at up to four dust
  steps a drawn frame, so the dust can be a moment behind the rock right after a jump and catches up.
  A jump past anything played yet replays from the last stored field, which can take a couple of seconds.
- *Chips and gravel* are not rewound: on a jump backward the chips reset and fly again from there.
- **Memory:** poses 836 MB, dust keyframes up to 599 MB once the whole event has been played, dust
  fields 168 MB. The footprint measured 3.2 GB after the first fire and 4.1 GB after a refire, in both
  cases with few keyframes stored yet, so allow about 600 MB more once every second has been played.

**Measured live loop**, this time a real one (`play --self-test`, which runs the same session object
the window draws, on a scripted sequence), 91,208 blocks at 1600 x 900:

| | Offscreen, no vsync | The window's own path |
|---|---|---|
| Playing | 13 ms median, 20 ms p90 (77 fps, 50 fps) | 25 ms main-thread work a frame, 27 ms p90 (a ceiling of 40 fps) |
| Scrubbing to a random frame and orbiting, every frame | 40 ms (25 fps) | 40 ms work (25 fps) |
| While refiring | drawing held to 15 frames a second | drew at the timer's 30 frames a second (25 ms of work); with its display link the window holds to 15 |

The window column comes from a real NSWindow with real drawables, but behind other windows and paced
by a 60 Hz timer (so as not to put a window over the user's screen, and because the view's own display
link stops when occluded). That timer gave 33 ms frame intervals, which is what an interval of 25 ms of
work beside a 16.7 ms tick comes to, so the frame rate on the glass has not been measured: the honest
number is the work per frame. Refire takes **22 to 24 s** (the physics, with drawing throttled): not
the 18 s hoped for; the rock now has 91,000 blocks at 5.9 spheres each and physics is 35 to 55 ms a
frame. The dust is made on first playback, not in that time.

**Stability:** no NaNs, but it is not clean. Some blocks are thrown up to the 45 m/s speed cap by
contact (26 of 600 frames have one at the cap), which is a contact fault, not a launch: the launch
law gives at most about 18 m/s. The pile is calm but less settled than stage 1's: in the last second
of the 20 s event the median block moved 0, the 99th percentile 2.9 cm and the worst 1.27 m, and 82 of
91,208 moved more than 10 cm.

**The look, frankly.** A big step. The slabs and wedges look like broken rock at last, the colour by bed
reads, the swell reads as a slab pulling away at the left end, and the closer low camera is a real
composition. At 3 to 4 s it is close to beautiful. What is still wrong: a sheet of dust across the pile
around 10 s is too flat and too sharply cut off; the settled pile lacks fine material (the gravel doesn't
collect on it); the ragged end is not fully seamless; the live window's coarser dust is smoother, and one
frame of it showed a small white patch under the cloud that I did not trace.

## Stage 3: the contact fault, the dust tied to the event, and the face's ends, 10 November 2026

On the user's word of 10 November (emmettl/bombcad-work#124). Same standing: illustrative, a stylised
row of firings for the eye, not a blast-design aid. Experimental command only.

**1. The contact fault.** Traced with `simulate --trace`, which records every block's speed each frame.
- *Thrown to the 45 m/s cap.* Every such block was still held (state 0) the frame before, moving at
  the swell's 7 m/s, and reached 30–45 m/s in the frame it let go. The swell moved held blocks
  kinematically, as immovable bodies. Neighbours whose swell directions converged were driven deep
  into one another with no contact force between them, and when they were released the stored overlap
  burst them apart. Fix: the swell is dynamic. A block wakes when its swell begins and is pushed along
  the swell's velocity profile, so contact keeps swelling blocks apart. Its launch is the stated
  launch less the swell it already has.
- *Late creep.* After that, 59 blocks still moved more than 10 cm in the last second. Their histories
  showed ringing in place, not sliding: ±3–6 cm a frame, sleep and wake again. Each block of six
  spheres touches its neighbours at 20 to 55 sphere pairs, and the sum of those explicit springs and
  dashpots is past the explicit limit even when each is stable alone. Fix: each body's update is
  linearly implicit in its own summed contact stiffness and damping (backward Euler on that sum). Free
  flight is unchanged. The stage 2 overlap cap, a symptom of the first fault, is gone.
- **Before and after** (20 s event at 240 Hz): frames with a block at the 45 m/s cap 26 → 0 (frames
  over 30 m/s 39 → 0, fastest 45.0 → 28.7 m/s, which the launch law allows); last second's worst move
  1.44 m → 0.07 m, 99th percentile 2.8 cm → 0, blocks over 10 cm 77 → 0. The 45 m/s cap is still in
  the code and never reached.

**2. Fines on the pile.** A shading, not bodies: grit and dust gather on the upward faces of rock that
has moved, in patches, building up as the dust settles over 6 s. The decorative chips also include
small fines that leave their blocks over three seconds and settle.

**3. The dust, and why it felt separate from the blast.**
- *What disconnected it.* Each firing's dust was injected as a ball around a point inside the rock,
  4.5 m behind the face, and the dust field treated the original hillside as solid. So the plume was
  born inside the rock, pushed out through the face, and could never fill the space the rock left
  or move with the slump. The rest came from any block moving faster than 2.5 m/s in the air, as a
  trail, so a cloud appeared where blocks flew rather than where they struck. Buoyancy grew with the
  dust's amount, so the densest settled dust kept lifting into a low flat sheet.
- *What changed.* The field's solid is now the ground after the blast. Each firing's puff is born on
  the face in front of it at its own time, so the ripple runs through the dust. Each block on the face
  lets go with a small puff that takes its velocity. Blocks lift dust where they strike the floor or
  the pile, in proportion to the change in their velocity. New dust carries the velocity it was born
  with in proportion to its share of the cell. A heat channel (cooling in about 1.6 s) drives the rise,
  not the amount of dust, so the plumes lift and then drift. The flat sheet is gone. The play window
  shares all of this and its field is 1.5 m.

**4. The floor.** No stones are strewn before the event; what lies on the floor comes from the rock.
The default camera is lower on the floor and higher on the face.

**5. The face's ends.** The flat planes at the left end and the seam at the strip's end were the
heightfield's own smooth face, seen where nothing covered it. A skin of held, unbroken blocks of the
same rock now runs along the old face for 165 m past each end of the strip. Each skin block's outer
face is set in by a random share of its size, so the face steps. The terrain grid is wider to carry it.
Seams remain at about 165 m past each end, out of the default frame.

**6. Frame-time readout.** The window shows the frame interval (ms and fps) and the work in each frame,
live, top left. The window self-test (behind other windows, timer-paced, 118,477 blocks): playing
33 ms median interval, 28 ms main-thread work (a ceiling of 35 fps); scrubbing 50 ms (47 ms work).
First fire 15 s, refire 16–17 s. Footprint 3.8 GB after the first fire, 5.0 GB after a refire. The rate
on glass is left to the readout; I did not put a window over the user's screen.

**Render:** 59 ms median to draw a 4K-internal frame, 22 ms for the dust solve; 601 frames in order.

## A look pass on stage 3, 10 November 2026

On the user's word of 10 November: re-rendered from the stage 3 poses, nothing re-simulated.
- **Dust lit through:** its light is an octave sum of attenuations (multiple scattering
  approximated), with a warm ground bounce and stronger sky fill. Undersides read pale and glowing
  rather than dark and smoky, and the self-shadowing still shapes the billows.
- **Rock variety:** each block takes its own shade (darker, redder or greyer), its own surface
  roughness and scale, and paler chipped flecks on fresh breaks. Bigger blocks shed a few larger
  decorative spalls (0.3–0.7 m) onto the pile, for a spread of sizes.
- **Floor:** paler haul-road patches, darker damp hollows, faint tracks and grit, and a gentler bump
  that no longer reads as rippled sand.
- **The window's dust:** it shares the shading, so it now matches the clip's colour and light. Its
  field stays 1.5 m: at 1.2 m it cost 51 ms of work a frame (15 fps) against 27 ms (30 fps), so it
  remains a little softer than the clip's 1 m.

Window self-test after the pass: playing 33 ms interval, 27 ms of work; scrubbing 66 ms; first fire 16 s;
footprint 3.9 GB (4.9 GB after a refire). Clip: 56 ms median to draw, 22 ms for the dust.

## The Quarry Face scene, stage 1, 10 November 2026

On the user's word of 10 November (emmettl/bombcad-work#125): the experiment as a scene in the app,
**File ▸ New Quarry Face (Experimental)…** Same standing: illustrative, stylised firing patterns, no
link to the blast solver's loads, and no fragmentation, reach or safety outputs. The window says so,
and it is not a blast-design aid.

**What a user can do.**
- Open the window; it lays out the built-in hillside, breaks the rock and fires it.
- Drag along a face on the map to choose the strip; the rock behind it breaks and fires.
- Open a terrain file instead (GeoTIFF or ESRI ASCII, read by the app's own `ElevationGrid`
  reader). A crop up to 1.2 km across at 2 m is taken round the file's middle; then you drag a strip.
- Set the order (left to right, right to left, centre out, edges in, scattered), the ripple (20 to
  400 ms between firings) and the number of firings (6 to 30), and fire again; progress is shown and
  the old event stays on view until the new one is ready.
- Orbit, pan and zoom; play and scrub the 20 s event; a readout shows the frame time.

**Where it lives** (CLAUDE.md, "Where code goes").
- BlastModel, `Sources/BlastModel/Quarry/`: the layout on any terrain, the fracture, the blocks and
  their spheres, the firing patterns, the launch law and the packed pose cache. Tested in
  `QuarryFaceTests`, which run on Linux.
- BlastCore: the contact solver and the dust field, each Metal file compiled on its own.
- BlastRender: the renderer and `QuarrySession`, which fires in the background and replays.
- BombCAD: the window and its menu item. `hillsideblast` is now a thin command over the same code.

**On any terrain.** The strip gives the frame: x along it, y into the hill (the higher side). The
old face's line is found at each x as the steepest rise within 40 m of the strip, smoothed. The new
face is the old face's shape moved `depth` (26 m) into the hill along the strip, with rounded ends:
the ground keeps the old face's share of its rise, counted from the new face. A strip with no face
under it (less than 2,000 m³ cut) is refused, with a message.

**Memory.** At 117,000 blocks, measured with the window's own session (`hillsideblast play
--self-test`):
- the pose cache is 264 MB, from 1,086 MB: every other frame stored, interpolated between, 10 bytes
  a moving block (16-bit positions over the domain, 6 mm; smallest-three orientation), and the held
  skin not stored;
- the dust fields are 157 MB at 1.5 m;
- dust kept for scrubbing goes to disk, 24 MB a second of event, written as playback first passes
  each second, under the user's Caches folder and removed when the window closes or reopens;
- the process footprint is 3.0 GB after the first fire and 2.9 GB after a refire, against 3.9 to
  5.0 GB before.

So the budget beside the app's own runs is about 3 GB of memory and up to 0.5 GB of disk for a 20 s
event.

**Measured** (the same session as the window, behind other windows, timer-paced): playing 33 ms
interval, 27 ms of work a frame; scrubbing and orbiting every frame 67 ms (53 ms of work, a little
more than before, for the interpolation and the reads from disk); first fire 16 s, refire 16 s.

**A fix found on the way.** At small block counts (8,000 to 30,000, so blocks up to 5.6 m) a few
large blocks were thrown to the speed cap. Their contact spheres started below the excavated ground,
because the clip planes follow a curved new face only approximately, and were pushed out as soon as
the block woke. Spheres are now kept inscribed above the ground too. At 8,000 blocks, frames at the
cap went from 1 to 0 and blocks over 10 cm in the last second from 104 to 1. The 117,000-block scene
is unchanged in its numbers: no frame at the cap, and none over 10 cm in the last second.

**Tests.**
- `QuarryFaceTests` (BlastModel): blocks fill the cut and repeat with the seed; a strip on a turned
  and moved copy of the hill finds the same face; flat ground and a short strip are refused; every
  firing order fires each point once at the stagger; the launch law's bound; the pose cache's round
  trip (6 mm, a tenth of a degree, interpolated).
- `QuarrySimulationTests` (BlastCore, GPU): 20,000 blocks fired for 12 s. Nothing faster than the
  launch law allows, the last second's 99th percentile under 1 cm, and fewer than one block in a
  thousand over 10 cm.
- `QuarryFaceSceneTests` (BombCAD): the window's model opens on the built-in hillside, breaks
  12,000 blocks, fires in the background, settles, scrubs back and draws.

**Where it stopped.**
- The window has not been looked at on a screen, so as not to cover the user's. Its 3-D view is the
  same session that `hillsideblast play` draws, but the SwiftUI controls around it are unchecked.
- Terrain files are cropped round their middle, and there is no choosing where. The open project's
  own terrain is not offered.
- Dragging is on a 2-D map, not in the 3-D view.
- A dragged strip regenerates in about 5 to 10 s at 100,000 blocks, plus the firing.

## Fire and watch at once, 12 November 2026

On the user's word of 12 November (emmettl/bombcad-work#126). Same standing: illustrative,
stylised firing patterns, not a blast-design aid. The look is unchanged; this is about waiting.

**What changed.**
- *The event plays as it is simulated.* Each firing is a `QuarryRun` (BlastCore) on its own
  thread, storing every frame into the packed pose cache as it goes. The cache can be read while
  it fills: any frame up to the last stored keyframe can be decoded (`available`). The solver is not
  bit-reproducible, so what is shown is this one run, kept as it is computed, not a second
  simulation.
- *When it starts.* Once 9 frames (0.3 s of the event) are stored and the new dust field is
  made, the window swaps to the new event. Until then the old event stays on view, and a refire
  asked for during a stream replaces it.
- *How playback follows.* At real time while the solver keeps more than 0.4 s ahead. Otherwise it
  slows to the solver's own rate, a little below it while the gap is short, so the gap grows back.
  While drawing takes longer than a frame of the event, it shows every frame once rather than
  skipping frames to keep real time: slower and smooth. It never goes past the last stored frame,
  and never backward. The readout says "Simulating 45%, playing at 0.52× real time to keep up"
  while it does. The timeline scrubs over what is stored, with a bar under it for how much that
  is, and over the whole event once done.
- *Sharing the GPU.* The solver's frame of 8 substeps was one command buffer of about 40–55 ms at
  the busiest part. The window's render, chips and dust each wait for the GPU, so they queued
  behind it: 100–280 ms a drawn frame. Now each substep is its own command buffer, with only one on
  the GPU at a time. The same kernels run in the same order (`advance(substeps:buffers:)`, default
  one buffer, so `hillsideblast simulate` is as it was). While an event is simulated, the window
  draws at 30 frames a second, the event's own rate.
- *A moved strip.* The render-only dressing past the strip is built beside the rock (it needs only
  the layout). The solver starts as soon as the blocks exist. The renderer and dust are made while
  it runs, off the main thread (they were made on it before). Progress names each stage and its
  share. The old event stays on view, drawn at 15 frames a second, until the new one starts.
- *Smaller things.* The quarry's Metal is compiled once a process, not on every refire. The run's
  thread and the session's background work drain an autorelease pool. Without that, each solver
  stayed alive until its thread ended: 1.3 to 2.9 GB of Metal allocated in the first streaming
  runs, against 0.8 to 0.9 GB with it. The firing settings now carry over to a new strip; before,
  a new strip fired with the defaults while the controls showed your choice.

**Measured** with `hillsideblast play --self-test NAME --offscreen`. It is the same session the
window uses, with nothing on screen, paced to the rate the window would draw at. Built-in hillside,
108,720 blocks, M4 Max Studio. Another agent's render shared the GPU during the baseline.

| | Before (stage 1 code, today) | After |
|---|---:|---:|
| Fire again → first frame of the new event | 16.6 s (the whole physics) | 0.12–0.18 s |
| Fire again → rock first moves on view | about 17.4 s | 0.8–1.0 s (the event's own calm lead-in: the swell starts at 0.77 s) |
| Strip released → first frame | about 22 s (5.2 s to break the rock, then the physics) | 3.0–3.1 s |
| Strip released → rock first moves | about 23 s | 3.8–3.9 s |
| Window opened → first frame | about 17 s (5.2 + 12.1) | 3.2 s |
| Rock broken (100,000 asked, about 108,800 made) | 3.5 s, then 1.3 s of dressing | 2.8–3.0 s with the dressing beside it |
| Whole 20 s event simulated | 12–17 s | 13–14 s, while being watched |

**Playing while it simulates** (work on the main thread a drawn frame, by event second):
- 0 to 1 s: 33–36 ms;
- 1 to 5 s, the busiest part: 49–63 ms (16 to 20 frames a second on screen), every frame shown,
  playback at 0.47–0.65× real time;
- 6 s on: 26 ms, at real time, the solver by then 2 to 9 s ahead.

The whole of each followed event: median 22 ms, p90 55 ms, worst 122–126 ms. No hold of more than
0.1 s and no step backward in three followed events. The solver itself ran at 9.5–9.9 ms a frame
median and 56–57 ms p90. Before the split command buffers and the one-frame-a-draw rule, the
busiest seconds drew at 5 to 14 frames a second, 100–280 ms each, while playback held real time by
skipping frames.

**Playing a finished event** is as before: 21–22 ms of work a frame. Scrubbing and orbiting every
frame: 44 ms.

**Memory** (footprint): 2.9 GB after the first event, 2.6–3.2 GB after a refire. Peak 3.4 GB
while a moved strip's scene is built beside the old one, which is freed when the new one starts.
Before: 2.9 GB and 3.1 GB. Dust kept on disk reaches 511 MB once a whole event has been played.

**Checked.**
- Frames from the self-test's own files: the first motion of each event, mid-event during the
  refire and the moved strip, and the end of a followed event (a settled pile, dust drifting).
- The window was captured offscreen (`BOMBCAD_INTERFACE_REVIEW=dir swift test --filter
  QuarryFaceReview`): preparing, following ("Simulating 20%, playing as it is computed"), "Starting…"
  after Fire again, and done.
- Tests: `QuarryRunTests` (BlastCore) and `QuarryFaceSceneTests` (BombCAD: shown before it is all
  simulated; a refire keeps the old event until the new one starts). The cache filling while read
  is in `QuarryFaceTests` (BlastModel, Linux).

**Where it stopped.**
- The busiest seconds play at about half speed. Physics (about 50 ms a frame there) and drawing (about
  20 ms of GPU) do not fit in 33 ms on this GPU. Making them fit would mean a cheaper solver
  (fewer substeps, a grid not cleared every substep) or a cheaper draw while streaming. Neither
  was tried, so as not to change the look.
- Rock generation, about 2.8 s at 100,000 blocks on the CPU, is now most of a moved strip's wait.
  Breaking the first firings' rock first was not done. The solver takes all its blocks when it
  starts, and blocks meet across the whole strip, so the solver would have to take blocks while
  running.
- The frame rate on screen is still not measured on the glass. The numbers are work per frame
  offscreen, and the window's controls were checked offscreen only. The bar under the timeline
  advances with the view's own frames, so it reads 0 in an offscreen capture.

## Stage 2b: rock shapes and colour, 12 November 2026

On the user's word of 12 November (emmettl/bombcad-work#127). Same standing: illustrative, stylised
firing patterns, not a blast-design aid; the beds and their kinds below are stylised, chosen by eye,
and are not any real quarry's geology. The art pass's own verdict was that further shader rounds had
stopped helping and a better source of shapes and colour was needed, so this stage changes what the
generator makes and what each face carries, and then the shading that reads it.

**Beds of four kinds** (`QuarryRock`, BlastModel). Each bed of the bedding family is limestone (42%
of beds), shale (24%), sandstone (22%) or ironstone (12%), from an integer hash of the bed's index
that the shader repeats, so colour and breakage agree. Each kind breaks its own way in
`QuarryFracture`: bedding planes between two limestone beds are mostly closed (massive rock), planes
against shale are always open, shale beds split again along partings about 0.55 m apart, sandstone
beds take close steep joints about 1.25 m apart (elongated pieces), and the joint sets cut shale
more often and limestone less. Some corners of the harder rock are knocked off as small fresh
breaks (not on the weathered outer face, so the face is whole before the blast). The coarse Voronoi
share went from 0.33 to 0.23 of the blocks so that the count stays where it was: 116,105 blocks and
552,403 spheres at `--blocks 110000`, against 117,345 and 554,332.

**Weathered and fresh** (a per-face flag at fracture time). Each block's depth below the old surface
is found when it is made, and each face's own depth from it (deeper along open joints, with an
irregular front); rock within about 7 m of the old surface is weathered. Five bits of weathering and
six of a random value ride in each vertex's `body` above the block's index (which keeps 21 bits).
The shader reads them: a fresh break deep in the rock is pale and cool in its bed's colour, one in
the weathered rock is buff or brown, old joint and parting faces are stained more the nearer the
surface they were, and the old outer face carries the bed's patina streaked down the face. So the
standing face is banded, and the pile is a mix of pale grey, buff, brown and dark pieces rather than
one colour. The outer faces of the strip, the held skin and the dressing stand back by their bed's
weathering (shale under ledges of the harder beds), so the bands are in relief too.

**Fines on the pile.** The top-down height the chips land on now also records what is there: blocks
of the pile at rest (released and slower than 1.5 m/s), the ground, or anything else. From it a
compute pass builds a surface of fines a little below the mean top of the blocks at rest nearby,
filling the hollows between them, with an apron at the pile's foot; only where the pile is (a block on
its own gets none), gathering from 3 s to 8 s, and relaxed to an angle of repose so it never stands
in a wall. It is drawn as a grid over the top-down map and shaded as broken stones and grit at three
sizes, darker than the blocks' faces. After a jump in the window it is rebuilt from that frame alone
(and left out while the rock is still in the air). A picture of fines, not bodies, like the chips.

**The dust sheet.** The low sheet across the pile around 8 to 10 s was cold dust thrown up by the
impacts, settling at 0.05 m/s onto the ground and lying there. Cold dust within about 3 m of the
ground now falls out with an e-folding time of about two seconds, fading to none by 9 m up; warm dust
rises first, and the plumes high up are untouched, as are the sources tied to the firings and the
impacts. In the frames at 8, 9 and 10 s the flat bright lens is gone.

**Two things found on the way.**
- *The spots on every face.* The rock was covered in dark blotches under the low sun (visible in
  every earlier close view). They were the normal mapping: a bump strong enough to turn patches of a
  face away from a sun 15° up. It is gentler now, and the faces read as fracture planes.
- *The smooth wall past the strip's right end.* The held skin there is mostly clipped away on the
  steep face by the tangent planes of the floor in front of each cell, so the terrain's own surface
  showed. The dressing now runs over the skin's span as well; the face past the end is rock.

**Measured.**
- *Shapes and sizes* (the generator's report, broken rock only): by Zingg's classes, equant 6% → 5%,
  disc 32% → 26%, rod 17% → 20%, blade 46% → 49%; sizes (cube root of volume) 10% 0.44 → 0.45 m,
  median 0.88 → 0.83 m, 90% 1.45 → 1.42 m, largest 2.87 → 3.09 m. Each kind differs (shale 56% blades,
  sandstone 27% rods), but taken together the spread of shapes and sizes moved little; what changed
  most is which pieces are which colour.
- *Stability* (the 20 s event at 240 Hz): no NaNs; in the last second the median and 99th percentile
  block moved 0, the worst 2 cm, none over 10 cm (the same as the event before). The fastest block
  reached 30.2 m/s against 27.5 m/s before: in both events the fastest is a block driven down over
  four frames from about 7 m/s, under the rock coming down on it, not one thrown up; there are more
  small slabs now. The GPU test's bound, which this crossed at 28.2 m/s at 20,000 blocks, is now
  1.2 speed0 + 14 m/s (32 m/s), with the reason in the test; the stage 2 fault threw blocks to 45 m/s.
- *Physics*: 45.9 ms median, 63.5 ms p90 a frame while more than 5% are awake, against 54.5 and 72.7
  ms for the event before.
- *Frame cost*, the window's own session offscreen (`play --self-test NAME --offscreen`, 1600 x 900),
  today's main (with fire and watch) against this stage, two runs each, medians of the work a frame:
  playing a stored event 20.1–20.4 → 20.4–20.6 ms; following a firing as it is simulated 22.6–24.4
  → 22.7–22.8 ms; scrubbing and orbiting every frame 44.7–45.0 → 46.7 ms (the fines are rebuilt
  after each jump); a firing simulated in 14.9–15.3 → 14.4 s. The film: 55.0 → 44.1 ms median to draw
  a 4K-internal frame (16.3 M triangles against 18.4 M), dust step 22.6 → 18.8 ms.
- *Memory*, same runs: poses 264 → 278 MB (more of the rock moves), dust fields 157 → 162 MB (a
  clearance field), the fines about 20 MB of textures and grid, Metal allocated 851 → 824 MB. The
  process footprint is higher and I did not trace why: 3.05 → 3.52 GB after the first fire, 2.72 →
  3.83 GB after a refire, 3.46 → 3.60 GB after a moved strip (peak 3.25 → 3.92 GB), the same in both
  runs. Against the stage 1 main, before fire and watch, it was lower (2.98 → 2.86 GB after the
  first fire), so it comes from the two together; it stays inside the 3–5 GB the scene was given.

**Run:** `hillsideblast simulate --blocks 110000 --seconds 20 --out quarry-rock/poses`, then `render
--blocks 110000 --poses quarry-rock/poses --out quarry-rock/after --clip --bitrate 9000000 --stills
1.0,3.5,6.5,8.0,9.0,10.0,19.9`, and the close view with `--eye 50,-38,5 --eye-end 50,-38,5 --target
75,0,3 --target-end 75,0,3 --fov 30`. The before images are the stage 1 scene's code on its own poses
(`quarry/poses`), at the same cameras and times. Before and after cannot share poses: the new rock is
a different set of blocks.

**The look, frankly.** The calm face is the biggest step: banded beds in colour and relief, jointed,
with dark shale under pale ledges. In the pile the pieces are of different rock, and the close view
reads as broken rock with grit between, where before it was one buff colour with spots. What is still
wrong: from the default camera the fines read only as a darker matrix between the blocks, and up
close in shadow the gravel looks a little like terrazzo; the upper slope is carpeted with the
decorative chips, all the same small polyhedra, which now stand out against the varied blocks; the
ironstone and oxidised faces are still a little too orange; the faces keep soft dappled shadows from
their large-scale relief; a band of smooth terrain still shows at the foot of the face just past the
strip's right end, and the left end at the frame's edge is still a smooth wall; and the shape spread,
by the numbers, hardly widened. A dust sheet like the old one was not seen again, but the dust change
could not be shown on the old poses (the new rock is a different set of blocks).

## Placing the strip, choosing the ground, and clips, 12 November 2026

Proposed to the user on 12 November and in the direction they approved (emmettl/bombcad-work#128),
done while they were away. Same standing: illustrative, stylised firing patterns, not a
blast-design aid. The look and the event are unchanged; this is about handling the window.

**The strip in the 3-D view.** *Place strip* (top right of the view) turns on placing: the event
goes back to its first frame and pauses, so the face shows as it stood before the blast, which is
the ground a strip is laid on. The strip is drawn over the view: the old face's line along it at half
the face's height, the line of the new face `depth` (26 m) behind it, dashed, and a handle at each
end. Under the cursor a ring marks the face point a drag would start from (grey, crossed, where
nothing near is steep enough). Drag along the face to lay a new strip, or drag a handle to move one
end; on release the rock is broken and fired as from the map, which stays as it was. Option-drag
orbits and shift-drag pans while placing. How it works (`QuarryStripGuide`, BlastModel):
- the ground under the cursor is the old surface along the view ray (`QuarrySession.groundPoint`), so
  a point hidden behind a bulge of the face picks the bulge, as you see it;
- it snaps to the face line: of the ground within 25 m steeper than a rise of 0.8 m in 2 m (about
  22°), the nearest point, then the steepest point across the face there;
- the lines are found as the layout finds the face (the steepest rise within 40 m across the strip,
  smoothed), at every 3 m; the overlay is a few Core Animation layers above the Metal view, so it is
  redrawn at once with each mouse event, not at the next frame, and follows the camera each frame.

**An opened terrain's area.** Opening a GeoTIFF or ESRI ASCII grid now shows an overview of the whole
file (a shaded relief up to 560 pixels across, gaps in grey) with a square to drag to the area to
break, 300 m to 1.2 km across, taken at 2 m. *Choose area…* brings the same file's overview back. The
ground then starts with a strip along its steepest face (the steepest ground over 8 m at least 60 m
in from the edges, followed out along its line in steps), broken at once; where nothing is steep
enough it asks for a strip to be dragged. A fix on the way: the crop was placed by its offset from
the file's corner without the corner itself, so any file whose corner is not at (0, 0), which is
nearly every survey, was refused as outside it.

**The project's own terrain.** Each project window says what its terrain is while it is open
(`QuarryProjectTerrains`); a flat one is not offered. *Project's terrain* (a menu when several are
open) breaks it the same way, in the project's own coordinates.

**Clips.** *Record Clip…* writes an H.264 .mp4 at 1920 × 1080 and 30 frames a second, to a place you
choose: the view as it stands, held still or turned slowly (0.6 rad, eased) round what it looks at;
from the event's start or from the time shown; 2 to 20 s of the event; at real time, half or quarter
speed. Progress shows in the sidebar, with Cancel (which leaves no file); the window keeps playing,
drawing at 15 frames a second. `QuarryClipRecorder` (BlastRender) has its own renderer and dust, so
the window is not disturbed, and runs the dust and chips from the event's start to the clip's first.
It reads the stored event and waits for frames not yet simulated; if the event stops (a refire), the
clip ends there. The clip writer is the one `hillsideblast render --clip` used, moved to BlastRender.

*Slow motion* draws the moments between the stored frames: `QuarryPoseCache.decode(at:)` takes a
fractional frame, between stored frames as it already interpolated (positions linearly, orientations
normalised), and the dust and chips step at the finer rate (120 steps a second at quarter speed). So
that the dust is the same at any rate, the two sources that happen once (the puff as a block lets go,
the spray of an impact) are scaled by the rate over 30, and what velocity and density keep each step
(0.995 and 0.9992 in 1/30 s) is the same per second; at 30 frames a second all of it is the numbers
as they were, so the window and `hillsideblast` are unchanged. Interpolated motion is linear between
stored frames 1/15 s apart, which shows as slightly straight paths at quarter speed in fast tumbling.

**Measured** (release build, M4 Max Studio, the window's own session offscreen with its 100,000
blocks, about 108,400 made; `BOMBCAD_INTERFACE_REVIEW=dir swift test -c release -Xswiftc
-enable-testing --filter QuarryFaceReviewTests/handling`):
- *Strip drag:* from each mouse event's timestamp to the overlay committed with it, 0.34 ms
  median, 0.45 ms p90, 1.24 ms worst over 60 events (picking, snapping, the lines and the
  projection; a debug build, 2.9 ms median). The display adds up to one refresh on top; not measured
  on the glass. Strip released → its event on view: 2.1 s, as before.
- *Clips:* the whole 20 s event at real time from this view, 600 frames (20 s of movie) in 15.6 s, 24.7 ms a frame median; the busiest 4 s (2–6 s) at
  quarter speed on a slow orbit, 480 frames (16 s of movie) in 14.3 s, of which 1.6 s ran the dust up to 2 s, 26.9 ms a frame median. That is faster than real time at 1080p: about 27 ms a
  movie frame, of which about 14 ms is the draw on the GPU and 5 ms the dust step. The window was
  offscreen and not drawing meanwhile; on screen it draws at 15 frames a second beside the clip,
  which will slow it somewhat (not measured). While recording,
  Metal allocated rises from 1,524 MB to at most 2,279 MB (its own renderer and dust, 0.75 GB), freed when it ends. Files at 14 Mb/s: about 1.7 MB a second.
- Frames were taken from both files themselves at five times each (2%, 20%, 40%, 60% and 98% of the
  way): the calm face, the rock going and the dust rising, the settled pile, and in the orbit the
  camera turning; none blank or frozen.

**Tests.** `QuarryStripGuideTests` (BlastModel, Linux): snapping from the floor and the top, none on
the flat; the lines along the face and the new face's line 26 m in; a first strip along the built-in
face, none on the flat; the crop kept inside the file and read from the place chosen in a projected
file far from the origin; the overview's size and gaps; poses between frames. `QuarryFaceHandlingTests`
(BombCAD, GPU, offscreen): a strip dragged along the face in the 3-D view lands on the face line and
is broken, an end dragged moves only that end, the overlay leaves with placing; an area chosen on an
overview and a project's terrain each start a strip on the face; a half-speed clip has its frames and
length, moves, and Cancel leaves nothing.

**Where it stopped.**
- The 3-D view stretched the renderer's 16:9 frame over the view, whatever its shape (since stage 1),
  so in the default window the rock was squeezed sideways by about a quarter; the clip, at 16:9, was
  not. Fixed since: see "The view at its own shape" below.
- Placing has not been tried by hand on a screen: the drags were synthesised offscreen.
- The strip is laid on the ground as it was before any blast; strips do not build on each other.
- A clip is of the window's quality (its mesh, 1.5 m dust, no supersampling), not the film's.

## The view at its own shape, 12 November 2026

The window's 3-D view now draws its frame at the view's own shape (emmettl/bombcad-work#130). Before,
the renderer drew 1600 x 900 at 16:9 and the frame was stretched over the view; the default window's
view is about 1.24 wide to 1 high, so the rock was drawn at 0.70 of its width.

- *Projection.* It takes the view's width over height. A view narrower than 16:9 keeps a 16:9
  frame's width of field and shows more above and below (in the default window the vertical field
  is 44.8° for the camera's 32°), so the view always holds all that a clip from the same camera
  shows, and the default framing, made for 16:9, still has the strip's ends in it. A wider view
  keeps the vertical field and shows more to the sides. Clips are unchanged: 1920 x 1080 at the
  camera's own field.
- *Frame size.* The frame has the view's shape and as many pixels as 1600 x 900 (1,440,000), or the
  view's own if it has fewer, in multiples of 8 (`QuarrySession.frameSize`). So a frame costs the
  same at any shape. On a 2x display the default window's view is 2038 x 1647 pixels and the frame
  1328 x 1072, scaled up to it as the 1600 x 900 frame was before.
- *Resizing.* The projection follows the view at once. The frame's targets (scene colour and depth,
  dust, the frame itself; the shadow, height maps and geometry are kept) are made again only once
  the size the view asks for has held 0.25 s (`QuarrySession.fit`). Until then the frame keeps its size
  and is stretched back to the view's shape, so proportions stay right and nothing is allocated each
  frame of a live resize or a sidebar drag.
- *Picking.* The strip's overlay and picking use the view's own shape and field, the same projection
  the frame is drawn with; they no longer allow for a stretch. No shader changed.

**Measured** (release build, M4 Max Studio, offscreen, the window's own session of 108,449 blocks,
`BOMBCAD_INTERFACE_REVIEW=dir swift test -c release -Xswiftc -enable-testing --filter
QuarryFaceReviewTests/viewShapes`):
- *How wide the rock is drawn,* judged against the 16:9 frame from the same camera (the horizontal
  scale that best matches the two, by correlation of their luma): 1.000 now at the default window
  and at a wide one (2400 x 860, view 2.45 to 1), calm, at 4 s and settled, correlation 0.986 to
  0.997. The old stretched frame scored 0.695 in the default window and 1.380 in the wide one, its
  shape over 16:9.
- *GPU a frame* in the default window, medians of 40 taken in turn: calm 12.96 ms now (1328 x
  1072) against 13.40 ms before (1600 x 900); at 4 s with the dust rising, 13.60 against 13.77 ms.

**Tests.** `QuarryFaceHandlingTests` "The view draws at its own shape" (BombCAD, GPU, offscreen), at
the default window and a wide one: a new size is taken only once it has held; the frame has the
view's shape within 2% and no more than 1,440,000 pixels; the projection the frame was drawn with is
the overlay's, so a point of the face lands where it is drawn (within 0.5 point) and the ground under
it is the point itself (within 1.5 m); the frame matches the 16:9 frame at horizontal scale 1 (within
0.03) and the old stretched one at the view's shape over 16:9. The existing drag test runs in the
default window, which is not 16:9.

## Stage 3b: what stage 2b left, and the footprint, 12 November 2026

On the user's word of 12 November (emmettl/bombcad-work#129), after stage 2b's stills. Same
standing: illustrative, stylised firing patterns and stylised beds, not a blast-design aid. This
works through stage 2b's own list of what still looked wrong, and traces the footprint rise it left
untraced.

**The footprint.** Traced in the window's own session offscreen (`play --self-test NAME
--offscreen`), with `footprint`, `vmmap` and `heap` taken at the self-test's milestones and
`footprint` sampled every second. After the first fire the process held about 3.5 GB in four parts
of roughly 0.6 GB each: Metal's mapped buffers (0.58 GB, the meshes, poses, chips and fields the GPU
reads), its private textures and buffers (0.61 GB), the heap (0.85 GB), and 0.62 to 1.24 GB that
`footprint` calls "owned physical footprint (unmapped)", untagged, in 128 KB pieces.
- *The meshes on the CPU as well as the GPU (waste, cut).* The heap held the blocks' and the
  dressing's vertex and index arrays, 0.63 GB (two 256 MB vertex arrays at their grown capacity and
  two 64 MB index arrays), long after the renderer had copied them into Metal buffers. The session's
  face, the renderer's and the dust field's all held them. Each now keeps the face without its
  meshes (`QuarryFace.withoutMesh()`): the solver, the dust and the session read only the layout,
  the blocks and their spheres. The window's clip recorder (stage 3a, landed beside this) makes a
  renderer from the session's face, so the meshes on the GPU are shared by every renderer of the
  same rock (`QuarryMeshBuffers`, found by the face's `meshID`) rather than uploaded again. The
  pose cache (0.29 GB) is most of what is left in the heap's large part, and is what streaming
  needs.
- *The unmapped pieces (the driver's, not cut).* 618 MB in 4,945 pieces of 128 KB from the first
  frame, the same in every run, before and after; about 13 s into the first event it doubles to 1.24
  GB (9,890 pieces), and it drops back to 0.62 GB and doubles again now and then (during a moved
  strip, for one). That doubling is 0.62 GB of the rise between "first fire started" and "after
  first fire" in every self-test (the pose cache and the dust kept on disk fill the rest). It is not
  in the heap and not in Metal's allocated size. A small program made memory of exactly this kind,
  in 128 KB pieces, by drawing triangles: about 11 bytes a vertex drawn in one pass (71 MB for 6 M
  vertices, 139 MB for 12 M, 274 MB for 24 M), whatever the vertex's outputs, kept afterwards, and
  not added to by a second pass or a second command buffer. So it is the GPU driver's per-triangle
  working memory for tiling, sized by the most geometry drawn at once (an inference: the driver does
  not name it). Cutting the chips' and blocks' triangles (below) did not move it: 618 MB looks like
  a size it grows in, not one this scene's triangles fill, and I did not find what makes it take a
  second one. Not traced further.
- *Why the rise came with stage 2b and fire and watch together* is therefore not established: the
  copies of the meshes were held before either, and the driver's doubling is in every run I made.

The window's self-test, built-in hillside, four runs interleaved on a quiet GPU (stage 2b's code
from today's main, then this stage's, twice), footprint as the self-test reads it:

| | Before | After |
|---|---:|---:|
| First fire started | 2.17, 2.17 GB | 2.11, 2.11 GB |
| After the first fire | 3.52, 2.90 GB | 3.03, 3.09 GB |
| After a refire | 3.83, 3.83 GB | 2.93, 3.42 GB |
| After a moved strip | 3.61, 3.61 GB | 2.93, 2.99 GB |
| Peak | 3.91, 3.92 GB | 3.57, 3.57 GB |
| Metal allocated | 824 MB | 807 MB |
| Poses | 278 MB | 296 MB (more of the rock moves) |

The 2.90 GB before and the 3.42 GB after are the driver's 0.62 GB caught halved or doubled at that
moment; the rest of each column is steady. So the cut is about 0.5 to 0.6 GB at every point and 0.35
GB at the peak, which comes with the driver's doubling during the first event. The scene's budget
beside the app's runs is about 3 to 3.6 GB; the streaming is as it was.

**What stage 2b's list said, and what changed.**
- *The smooth wall past both ends of the strip.* Traced with a debug render that painted the terrain
  magenta and the dressing blue: past both ends most of the lower face was the terrain's own
  surface. Two causes. The 3 m skirt of terrain that carries the hillside past the view's edge was
  drawn over the main 1 m grid as well, and on a steep face its chords stood in front of the face's
  foot; it is now left out where the main grid is. And each dressing cell was clipped by the
  ground's tangent planes at points around it in plan, which on a steep face reached the floor in
  front and cut the lower face's cells away (the same fault stage 2b found in the held skin). The
  cells are now clipped at the surface point each was put under, and at points around it along the
  surface itself; a neighbour's plane the cell's site stands well outside of (across a hollow) is
  left out. The steep terrain behind the rock is set back along its normal rather than straight
  down, and drawn as dark as a deep crack where a gap still shows it. In the frames at 1.0 s the
  left edge and the panel at the right end's foot are rock.
- *The gravel.* From the default camera it read only as dark gaps: its stones were darker than the
  blocks by design, and the surface lay 0.35 m below the blocks' mean top, in their shade under a
  sun 15 degrees up. Its mean colour is now about as light as the blocks' faces in shade, and it
  lies 0.2 m below their top once gathered. Up close it looked like terrazzo: flat-tinted discs of
  one tone each. The stones are now packed angular cells with grit in the gaps, each mottled, darker
  into the crevices between them, and domed and tilted its own way, so each has a lit side and a
  shaded one under the sky as well as the sun.
- *The decorative chips.* Every one was the same icosahedron, turned only about the vertical, and
  coloured from a random bed. They are now 32 convex stones, each the hull of 5 to 8 points in an
  ellipsoid running from chunky to slab, rod and flake (`QuarryChipShapes`, BlastModel, tested on
  Linux), turned any way and tumbling in the air, lying flat side down once landed, and coloured
  from the bed of the block they broke from.
- *Ironstone and weathered faces too orange.* Ironstone is now a dark purplish brown, rusty only
  where weathered; sandstone's and limestone's weathered colours are less saturated, and the iron
  staining on old joints and the reddest blocks' tint are weaker.
- *The block shapes' spread.* Each pair of coarse cells now meets in the metric of the bed between
  them (flatter in shale, 2.4; isotropic in limestone, 1.0; 1.6 in sandstone; 1.3 in ironstone,
  against 1.7 for all), so neighbours still share a face and cells never overlap. Limestone is cut
  less (joints 0.7 to 0.45 of the families' persistence, closed bedding between limestone beds 0.4
  to 0.25 of it), shale's joints less (1.35 to 0.7) so its partings leave plates, and sandstone
  takes close joints 0.9 m apart (from 1.25) and a cross set 1.4 m apart at right angles in plan.
  Coarse cells 0.23 to 0.17 of the blocks, for the same count. With the larger coarse cells a few
  pieces hung below the excavated floor or stood out of the old face, where the surfaces' tangent
  planes clip a cell only roughly (the quarry test at 3,000 blocks found them); pieces whose middle
  lies more than a quarter of their size under the floor or out of the face are left out, 52 of
  about 116,300 at `--blocks 110000`.

The generator's report at `--blocks 110000`, the old parameters against the new (the broken rock
only; the shape measure is stage 2b's, the principal lengths of each piece's corners):

| | Before | After |
|---|---|---|
| Blocks, spheres | 116,105, 552,403 (4.76 a block) | 116,276, 528,460 (4.54) |
| Zingg's classes | equant 5%, disc 26%, rod 20%, blade 49% | equant 13%, disc 29%, rod 20%, blade 39% |
| b/a (10%, median, 90%) | 0.33, 0.57, 0.81 | 0.38, 0.63, 0.84 |
| c/b (10%, median, 90%) | 0.27, 0.52, 0.79 | 0.26, 0.57, 0.82 |
| Limestone | 14,224 pieces, equant 8%, blade 40% | 9,356 pieces, equant 22%, blade 28% |
| Sandstone | 42,849 pieces, equant 6%, rod 27%, blade 48% | 68,396 pieces, equant 15%, rod 24%, blade 34% |
| Shale | 29,152 pieces, disc 29%, blade 57% | 15,626 pieces, disc 34%, blade 61% |
| Sizes (cube root of volume, 10%, median, 90%, 99%, largest) | 0.45, 0.83, 1.42, 2.00, 3.09 m | 0.47, 0.74, 1.40, 2.10, 3.37 m |

(The "before" shape spread is from this stage's report with the old parameters, which gives stage
2b's classes exactly: 116,852 blocks, the ironstone metric being new.) So the spread did widen, but
not by much: the classes are more even (blades 49 to 39%, equant 5 to 13%) and the sizes wider at
both ends, while rods did not gain and shale makes more blades, not fewer. Most of the change is
that limestone breaks into fewer, larger, blockier pieces and sandstone into many small blocky ones;
sandstone is now more than half the pieces (it was 37%), so by count the pile is more buff than it
was. Further widening would need different breakage, not other numbers in this one (for rods,
columns that break along the joints' intersection; for discs, shale that parts before it joints).

**Not done.** The faces' soft dappled shadows from their large-scale relief (stage 2b's list) are as
they were. The chips on the upper slope are still a carpet; they no longer look alike.

**Measured.**
- *Frame cost*, the same self-test runs, medians of the work a frame: playing a stored event 20.4,
  20.2 to 17.8, 17.7 ms; following the first firing as it is simulated 24.9, 23.5 to 20.5, 20.3 ms;
  following a refire 23.5, 23.6 to 20.5, 20.2 ms; scrubbing and orbiting every frame 47.3, 46.7 to
  44.4, 44.3 ms; a firing simulated in 14.4 to 15.2 s, to 13.8 to 14.3 s. Cheaper because the chips
  draw up to 12 triangles where they drew 20 (at most 7.7 M a pass in the window, from 12.7 M) and
  the blocks' meshes are 5.3 M triangles from 6.0 M (more small pieces, meshed more coarsely); the
  dressing is 1.62 M from 1.42 M. An earlier pair of runs, made while another agent's check shared
  the GPU, gave 62 to 64 ms scrubbing for both, so the scrubbing numbers above are the quiet ones.
- *The film*: 44.1 to 37.8 ms median to draw a 4K-internal frame (14.6 M block triangles against
  16.3 M), dust step 18.8 to 18.6 ms; physics 45.9 to 44.0 ms median and 63.5 to 59.7 ms p90 a frame
  while more than 5% are awake.
- *Stability*, the 20 s event at 240 Hz: no NaNs; over the last second the median and 99th
  percentile block moved 0, the worst 2.1 cm (1.6 cm before, both from the poses at 19 and 20 s),
  none over 10 cm; the fastest block 29.7 m/s (30.3 m/s before), within the GPU test's bound.
- *Checked by eye*: the stills at every time above and the close view, before and after, and frames
  taken from the clip file itself at 1.0, 2.5, 4.0, 8.0, 12.0 and 17.0 s (it plays in order: the
  calm face, the ripple, the pile and the drifting dust); a debug render with the terrain magenta
  for the ends.

**Run:** `hillsideblast simulate --blocks 110000 --seconds 20 --out look2/poses`, then `render
--blocks 110000 --poses look2/poses --out look2/after --clip --bitrate 9000000 --stills
1.0,3.5,6.5,8.0,9.0,10.0,19.9`, and the close view with `--eye 50,-38,5 --eye-end 50,-38,5 --target
75,0,3 --target-end 75,0,3 --fov 30`. The before images are stage 2b's (`quarry-rock/after`,
`quarry-rock/after-close`), at the same cameras and times; before and after cannot share poses, as
the new rock is a different set of blocks.

**The look, frankly.** The ends are the clearest gain: at 1.0 s the face is rock from the left edge
to the far right, with no smooth wall or panel. The chips are stones of different shapes and
colours, and the close view no longer has a field of identical little polyhedra. The gravel now
shows as gravel in the front of the pile and at its foot, and up close reads as crushed stone rather
than terrazzo, though its stones are rounder than broken rock should be (domed cells, more like
river gravel). The pile is chunkier and the limestone blocks larger. Ironstone and the weathered
faces are brown rather than orange. What is still wrong: from the default camera most of the fines
between the blocks in the middle of the pile are still in shadow and read as dark gaps; the chips on
the upper slope are still a carpet, only a varied one; the faces still carry soft dappled shadows
from their relief; the held skin of rounded limestone blocks along the new face reads a little like
loaves; the shape spread widened only modestly, and the pile is now mostly sandstone by count; and
the driver's memory doubling, about 0.6 GB, is untraced.

## Stage 3c: close-up rock, and rock that is whole until it breaks, 12 November 2026

On the user's word of 12 November (emmettl/bombcad-work#136), with a second part added the same day
from the user's first run of the window: "the rock is very clearly prefragmented". Same standing:
illustrative, stylised beds and breakage, not a blast-design aid. Both scenes; the ridge cut's side of
it is in [ridge-cut.md](ridge-cut.md#stage-3c-close-up-rock-12-november-2026).

**Why the pieces near the camera were shards.** Traced in the ridge cut's Pull back opening (window
quality, from the stored stage 1 poses) with a debug render that painted the blocks orange, the chips
green, the dressing blue and the terrain purple, and a second that coloured each block by its least
width over the cube root of its volume (red when thin), with back faces and normals turned from the
eye flagged in their own colours.
- *It was the chips.* At 2.2 and 2.6 s nearly everything thin and bright near the camera was green: a
  carpet of the decorative chips over the whole crest. Two faults together. A chip leaves its block
  once the block is released and its delay is up, and is then put on top of the scene's top-down
  height; so the chips of every block down through the cut, still buried under the rest, appeared on
  the surface at once, covering the crest within a second of the first firing. And the chips were
  sized without regard to their block (up to 0.5 m in radius, the larger spalls 0.3 to 0.7 m) and
  shaped down to a fifth as thick as long: on the ridge's small pieces (0.57 m median) many were as
  large as their block and thin, and tumbling close to the lens they read as sheets.
- *Not the fracture.* Only 2.3% of the ridge's blocks are less than 0.4 as thick as their size, none
  under 0.1; the thin-block colouring showed almost no red near the camera. The fracture is unchanged.
- *Not back faces or normals.* Only a few specks of back face or of normals turned from the eye
  showed (on the old meshes; the new outer surface made more for a while, below).
- *A part of it was the light.* The weathered outer faces' bump (0.45) turned patches of every
  upward face away from a sun 18° up, so the crest was spotted dark blue all over (sky light only),
  which broke the rock into flecks.

**Why the unbroken rock looked broken.** Each block's outer face was clipped by tangent planes of the
old surface around the cell and then stood back by its bed's weathering *and a random amount of its
own* (up to 18% of the cell's size). So neighbouring blocks' outer faces were at different depths and
angles, and every cell's outline showed as a step, a gap or a groove: a full Voronoi crack network on
the face and the crest before anything fired. The blocks' own tint, warmth and roughness (each block a
little its own) and the rounding of every edge drew the same network again in colour and shade.

**What changed.**
- *One outer surface* (`QuarryFace`, BlastModel). The outer faces of the blocks are now laid on one
  continuous surface: the old ground stood back by its bed's own weathering (eased over a third of a
  bed across each boundary, so ledges over shale are slopes, not folds) and a fixed share of the cell
  size. Each point of an outer face is moved along the surface's normal onto it, with the surface's
  own normal; the displacement and relief that shape it are functions of position alone, so where two
  blocks meet their outer faces meet. Edges along it are not rounded. The cells themselves are cut by
  the same recess (no random part); the strip's with tangent planes taken along the surface from the
  point the cell lies under (in plan, a steep face's planes came from the floor or the brow and cut
  its outer cells away), the held skin's at points around it in plan as before (along the surface it
  kept 13 to 18% more blocks at the tests' small counts, all bodies to simulate). Corners are moved along the normal rather than along their own edges: along
  the edges they would meet exactly, but where an edge leans from the normal a small step in depth
  carried the corner across its own face and one outer triangle in fourteen turned inside out (along
  the normal, one in about 200 at the window's mesh of the face and one in 900 at the film's mesh of
  the ridge).
- *Unbroken until it moves* (`QuarryRender.metal`). While a block is held and has moved less than a
  few centimetres from where it was made (position, and rotation times its size), it takes no tint of
  its own, its side faces show the weathered skin's colour and bump rather than a fresh break, and the
  rarer reddish blocks are not reddened; from 2 to 20 cm of movement its own look comes in. So a
  block shows as a separate piece as the swell starts to lift it, and the crack network appears as the
  rock breaks. It reads the release and the movement the solver already writes in the poses; nothing
  in the launch or the swell (emmettl/bombcad-work#134) changed.
- *The chips.* A chip waits until its block is within a metre of the top of the scene (the top-down
  height it lands on) before it leaves, so buried blocks shed none until they come up, if ever. Its
  size is held to 0.13 of its block's (a spall's to 0.2). The 32 shapes are chunkier: the slab and
  flake kinds 0.34 to 0.58 as thick as long, from 0.18 to 0.4, and a hull of a few points that lies
  nearly in a plane is thrown out (one was 0.11 as thick as long), so none is under 0.3
  (`QuarryChipShapes`, and its test).
- *The weathered faces' bump* is 0.2 where it was 0.45, which took the blue spots away.

**Measured.**
- *The generator* at `--blocks 110000` (the face): 116,276 blocks before, 116,967 after; sizes and
  shapes of the broken rock as before (median 0.74 to 0.75 m; Zingg's classes the same to a percent).
  Ridge cut: 96,987 blocks before, 96,386 after, sizes and shapes unchanged. Meshing 0.4 s, as before
  (the outer surface's normals by forward differences, each point brought back to the surface once).
  At the window's tests' 12,000 blocks the face makes 29,601 against 26,124 (the larger cells keep
  more of their pieces with no random recess).
- *Stability*, the 20 s event at 240 Hz on the new rock: no NaNs; over the last second the median and
  99th percentile block moved 0, the worst 7.0 cm (face) and 9.9 cm (ridge), none over 10 cm.
- *Frame cost and memory*, the window's own session offscreen (`play --self-test NAME --offscreen`,
  the window's 100,000 blocks), main's build and this one interleaved, two runs each, medians of the
  work a frame, measured on a version that kept the larger held skin (120,904 blocks at the face, so
  if anything an upper bound). The Studio was heavily loaded by other sessions' checks throughout (load average about
  100), so every figure is about half again the quiet ones above, and the runs' spread is wider than
  any change: the face playing a stored event 30.2, 30.2 to 28.0, 34.8 ms; following the first firing
  36.9, 38.1 to 39.8, 43.9 ms; scrubbing and orbiting 72.5, 71.5 to 71.8, 73.5 ms; the ridge cut
  playing 29.9, 29.8 to 27.8, 29.9 ms, following 34.7, 44.0 to 33.1, 46.0 ms, scrubbing 65.2, 64.1 to
  61.8, 67.3 ms. Metal allocated 785 to 795 MB at the face (its larger held skin: 15.0 M triangles at
  the film's mesh against 14.6 M) and 858 to 855 MB on the ridge; peak footprint 3.47 and 3.67 to 3.52
  and 3.52 GB at the face, 3.86 and 3.81 to 3.86 and 3.84 GB on the ridge. The chips are the same
  number; the shader does a little more for held blocks (the skin's colour on their side faces).
- *Checked by eye*, in clips made by the window's Record Clip from stored poses (`hillsideblast clip`,
  frames taken from the files themselves), before on main's code and rock (`look2/poses`,
  `ridge/final/poses`), after on this code and its rock (`rock-closeup/after-*-poses`, and again on
  main with the ridge's new heave, emmettl/bombcad-work#134, in `final/` from `final-*-poses`; both
  with the larger held skin, whose outer faces lie on the same surface; the face at 1 s again with the
  skin as landed, in `skin/`, looks the same): the face from
  the default view at 1, 3.5, 6.5 and 19.9 s, the face close (focus 75,0,3, yaw -0.58, 46 m, 30°) at
  the same times, the ridge from its default view at 1, 2.6, 4.5, 12 and 19.9 s and the Pull back at
  0.5 to 11.9 s. Before and after cannot share poses: the new rock is a different set of blocks. Files
  under `$BOMBCAD_DATA/hillside-blast/rock-closeup/`: `before/`, `after/`, `final/`, the debug renders
  `debug1/` (blocks, chips, dressing, terrain), `debug2/` (thin blocks) and `debug-kinds-try4/`
  (outer, side and joint faces), and the self-test logs beside them.

**The look, frankly.**
- *The unbroken face* (1 s) is the biggest change: from the default view it is banded rock with a
  few joints, and the pile's front blocks along the floor are separate stones, where before it was a
  wall of loose blocks. Up close it still shows thin dark lines along many cell edges, fewer and
  finer than before: where three cells meet, their side faces' shallow seams still catch a shadow,
  and the strip's shale ledges still show their blocks.
- *The broken rock and pile* (3.5 s on) look as they did; the pile reads as stones.
- *Chips* now come off the top of the rock as it breaks, small and chunky, rather than covering it.
- *What is still wrong.* A seam of shade still shows round many unbroken cells in close views in low
  sun; a fully seamless face would need a render-only skin drawn over held blocks and swapped out
  block by block on release, which was not tried. The held skin past the strip's ends is a little
  smoother and paler than the dressing beyond it. The left end of the ridge's crest in its default
  view is the render-only dressing (emmettl/bombcad-work#135's), which still shows its cells.

## The dust from the first motion, and rubble that rides the rock, 12 November 2026

From the user's first hands-on run of the app (emmettl/bombcad-work#137): "the smoke only appears
long after the rocks have started to fall and does look disconnected", and in the ridge cut "the
small rubble clearly disappears vertically down ... and not connected with the mass of rock going
somewhere". Same standing: illustrative, stylised firing patterns, not a blast-design aid.

**How it was measured.** The window's own session offscreen (`hillsideblast play --self-test NAME
--offscreen [--ridge]`), with two new options: `--shots-at t,t,...` saves the frame at each event
time it passes while following each event (the first fire, the refire and the moved strip), and the
same frame again without its dust; `--chip-trace` reads the chips back every frame. The rock first
moving on view is the first shot whose dustless frame differs from the calm first one (1% of pixels
by more than 12 levels); the dust first showing, the first whose frame differs from its dustless
twin (1% by more than 8). Shots every 0.2 s of event, so times are to ±0.2 s. Wall seconds come from
a second run with neither option (`series.csv`). Built-in ground, 100,000 blocks asked.

**The dust: what was found.**
- *Not the window's stepping.* The dust is stepped once per event frame shown, in order, with that
  frame's poses (`QuarrySession.update`), and at the same event time it is the same in the window as
  in the film: rendered from the same stored poses and camera, dust first shows at 1.8 s on the face
  and 2.2 s on the ridge at both the window's 1.5 m cells and the film's 1 m. Nothing waits on the
  solver's front, and the coarser grid shows the plumes as early.
- *The cause, shared.* Each block heaves for 0.8 to 1.25 s before it lets go (the swell of stage 2),
  and every source of dust began only at the letting go: the firings' puffs at their time, the puff
  as a block lets go, and trails and blows once blocks are fast. So the face moved on view at 0.8 to
  1.0 s and the first dust came at 1.8 s; on the ridge, from this view, the rock moved at 1.2 to
  2.0 s and the dust came 0.4 to 0.6 s later, and 1.0 to 1.4 s later with the ridge's longer,
  bigger heave of stage 3a (docs/ridge-cut.md), which landed while this was made.
- *Why the window made it worse.* While it follows the solver it plays at the solver's rate:
  median 0.5 to 0.75 of real time over each event, 0.15 to 0.3 at the busiest seconds, which are
  these. So the gap that lasts 0.4 to 0.8 s in the film lasted 1.5 to 3.3 s on screen.

**The dust: what changed** (`QuarryDustField`). Each exposed block puffs dust as its swell begins,
fading over the first 35% of the swell, in proportion to the swell's speed and the block's size
squared, carried with the block's own velocity, a little out and 2.5 m/s up, and warm, so it rises
off the heaving rock and the ripple of the heave shows in the dust ahead of the firings' plumes. A
ridge's puff is twice a face's (its dust thins fast and the view is further off). The swell is read
from the launch law (`QuarryLaunch`), so it follows the swell if that changes. Tried and not kept:
dust through the whole swell, growing to the release (at the rate kept, invisible on the ridge; at
twice it, a curtain across the face hiding the rock), and five times stronger early puffs (the face
hidden by 2.2 s).

| Rock on view → first dust | Before, event / on screen | After, event / on screen |
|---|---:|---:|
| Quarry Face, first fire | 0.8 s / 2.9 s | 0 / 0 |
| Quarry Face, Fire again (centre out) | 0.8 s / 3.3 s | 0 / 0 |
| Quarry Face, moved strip | 0.8 s / 2.9 s | 0 / 0 |
| Ridge cut, first fire | 0.6 s / 1.6 s | 0.2 s / 0.8 s |
| Ridge cut, Fire again | 0.6 s / 2.8 s | 0.2 s / 0.7 s |
| Ridge cut, moved cut | 0.4 s / 1.5 s | 0 / 0 |
| Ridge cut with stage 3a's heave, first fire | 1.0 s / 1.3 s | 0 / 0 |
| the same, Fire again | 1.4 s / 1.6 s | 0.2 s / 0.3 s |
| the same, moved cut | 1.2 s / 2.7 s | 0 / 0 |

How much of the frame the dust covers later is about as before on the face (21% of pixels at 3.2 s
before, 21% after) and more on the ridge (25% before, 32% after), where the heave's puffs add to
the firings' plumes.

**The rubble: what it was.** The decorative chips (render-only stones that leave their blocks and
are stepped beside the dust, `chipUpdate`), shown by colouring them by state in the window's frames:
in the ridge cut at 3 s they lay on the heaving mass, at 4 s a curtain of them was falling into the
notch. A chip that landed lay where it landed, with no velocity, on the top-down height of the scene
(blocks and ground). When the block under it went on (sliding down the flank, or thrown), the chip
was left in the air where the rock had been and fell straight down, into the notch or the pile, out
of sight. The window draws that height only every sixth frame, so chips also came to rest in the air
on rock that had gone and dropped from there. Of the chips in the air while following an event,
those falling straight down from rest (faster than 3 m/s down, slower than 0.5 m/s across) were 29
to 71% on the ridge and 51 to 88% on the face in the second to fourth seconds; chips that landed
again had fallen up to 13 m straight down, none of it across.

**The rubble: what changed** (`QuarryRender.metal`, `QuarryRenderer`). The top-down height now also
records which block is on top (its colour target is RGBA, 6 MB more). A chip landing on a block
rides it: its place in the block's frame is kept and it moves and turns with the block, so rubble on
the moving rock goes down the flank with it. It is thrown off with the block's velocity when the
block moves faster than 6 m/s, and slides off with the block's motion when, at a freshly drawn
height, nothing is under it. It lands only on the ground or on a block still close enough to be the
one under it, so it falls on through a stale height rather than resting in the air. A chip on the
ground that rock runs over stays under it, covered, rather than being lifted onto the rock.

| Chips in the air falling straight down from rest, seconds 2 / 3 / 4 | Before | After |
|---|---|---|
| Quarry Face, first fire | 55 / 79 / 88% | 0.2 / 0.4 / 0.8% |
| Quarry Face, Fire again | 51 / 79 / 88% | 0.2 / 0.4 / 1.0% |
| Ridge cut, first fire | 29 / 67 / 71% | 0.0 / 0.1 / 0.4% |
| Ridge cut, Fire again | 57 / 75 / 75% | 0.1 / 0.1 / 0.7% |
| Ridge cut with stage 3a's heave, first fire | 1.5 / 9.7 / 61% | 0.0 / 0.1 / 0.1% |
| the same, Fire again | 3.2 / 45 / 87% | 0.0 / 0.2 / 0.1% |

Chips that land again had fallen 0.4 to 4 m, travelling 0.2 to 2 m across. In the frames the
curtain in the notch is gone and the rubble lies on the rock; on the face the haze of falling chips
over the pile at 4 s is gone.

**Shared with the film and clips.** The dust and the chips are the same code in the window, in
clips and in `hillsideblast render`, so both films change. Stills from the same stored poses at 1.0,
1.4, 1.8, 2.2, 2.6, 3.0, 4.0 and 6.0 s, before and after, for both scenes, were looked at: the dust
starts with the heave (on the face from 1.0 s, a thin veil off the top; on the ridge, puffs rising
from the cracks of the heaving crest), and the ridge's notch is clear of the falling curtain.

**Cost.** On the face, as before (medians while following, the dust and chips' step then the draw:
11.9 and 32.9 ms before, 11.3 and 25.6 after, on a GPU shared with other work). On the ridge
somewhat more: in the quietest pair of runs (stage 3a's heave, nothing else on the GPU) 7.6 and
13.5 ms before, 10.1 and 18.4 after following the first fire, 8.6 and 17.3 against 10.0 and 20.8
following a refire; the noisier pair before stage 3a gave 7.1 and 23.8 against 10.5 and 28.8. So
about 2.5 ms more for the step and 3 to 5 ms more for the draw while the ridge fires, most likely the
march through the heave's extra dust (the ridge's puff is twice the face's; halving it would give
some back). Memory as before; Metal allocated 6 MB more (the height's colour).
The film's dust step: 25.0 and 16.4 ms before, 22.5 and 19.6 ms after (face, ridge; eight frames).

**Tests.** `QuarryDustTests` (BlastCore, GPU): with every block awake and unmoved, no dust before any
swell begins and some before the first firing. `QuarryChipTests` (BombCAD, GPU): a 6,000-block ridge
cut fired for 4 s at the window's quality; under 5% of the chips in the air fall straight down from
rest (60% with main's chips).

**Where it stopped.**
- The window still plays the busiest seconds at a quarter to a half of real time while it follows
  the solver; the dust now starts with the rock, but the heave and the plumes are slow on screen.
  Starting the event later, once the solver is far enough ahead to play the firings at real time,
  would trade the 1 to 2 s wait to first motion that "Fire and watch at once" bought; not done
  without the user's word.
- The heave's puffs at the window's 1.5 m cells are separate soft blobs on the ridge.
- Chips are not stepped on frames the playback skips (a draw slower than a frame of the event, once
  the event is stored); they stand still for that frame. Seen only with the diagnostics slowing the
  draws.
- Files: `$BOMBCAD_DATA/hillside-blast/dust-lag/` (`diag2-*` the window's frames with and without
  dust at each time, `clean-*` the timing runs, `film-final-*` the film stills, `tools/` the
  measuring scripts).

## Stage 3e: rock that looks strong, 13 November 2026

emmettl/bombcad-work#139, on the user's word of 13 November ("keep working through the defects until
it looks strong"). Same standing: illustrative, stylised beds, joints and breakage, for the eye; not
a blast-design aid. Both scenes; the ridge cut's side of it, and the piece-size study, are in
[ridge-cut.md](ridge-cut.md#stage-3e-rock-that-looks-strong-13-november-2026).

**What was wrong.** Stage 3c laid every block's outer face on one surface, but a cell's outer face is
clipped by tangent planes cell by cell, so it meets that surface only at its corners: a thin shade
line still ran along many cells' edges in close views under the low sun. Past the strip's left end
the dressing's cells each stood proud by an amount of their own, so the rock there was still a
mosaic beside the now-continuous strip (at 1 s in the default view). And the weathered surface itself
was plain: banded and smooth, with little small relief.

**What changed.**
- *The held skin* (`QuarryFace.heldSkin`, BlastModel). One continuous render-only surface over the
  blocks' outer faces, 4.5 cm proud of them: a grid over the old surface (its columns along the
  strip, its rows by distance along the surface from the face's line, so a steep face is sampled as
  finely as a flat top), 0.25 m in the window and Record Clip and 0.15 m for the film, laid on the
  blocks' own outer surface. Each triangle is tagged with the block under it (or, in a hole of the
  cut's rock, the nearest; past the strip's ends, the nearest block of the held rock there, which
  never moves) and is clipped away whole once that block is released or has moved 3 cm
  (`skinVertex`), so the skin goes block by block as the rock breaks and the block's own faces show.
  It is in the world's frame, so the corners blocks share are the same numbers and the skin is
  watertight. Held blocks are drawn 2.5 m farther along the line of sight (more far off) while the
  skin is over them, and 1.2 m away from the sun in the shadow map, where the skin casts the rock's
  shadow: a block's face standing proud of the skin (a hard bed's block over the shale's recess, a
  thin piece kept from the surface) is never seen through it. The skin is drawn before the blocks,
  so the blocks under it fail the depth test before they are shaded.
- *Past a face's strip*, the dressing (render-only) is laid on the same surface as the held blocks
  (tessellate's `outer`, as the ridge's rock round the cut since #138), with the blocks' relief, its
  foot clipped just under the floor; where it lies under the skin (within 2.5 m of the old surface)
  it is tagged with weathering grade 30 (`underSkinGrade`) and drawn behind the skin as held blocks
  are. The steep ground behind it is set back along its normal smoothly from slope 0.95 to 2.4 m by
  0.6 (it was 1.8 m from 0.8 in a step, and the 1 m ground's triangles folded out in front of the
  shale's recess in dark slivers); a ridge cut's is as it was.
- *Weathered relief* (`QuarryFace.weatheredRelief`, `QuarryJoints`, BlastModel, Linux-tested): on the
  old surface, out along its normal, grooves along two near-vertical joint sets (3.7 and 5.6 m apart
  on average, wandering, dying out along their length, some beds' joints shifted from the next bed's,
  none of their own in the shale), knobs and hollows a metre or two across (±5 cm), and on the
  harder beds where the surface runs nearly along the bedding (a crest, a ledge's top) small steps
  where laminae have weathered off. The shader draws the same joints (`jointField`, a copy) as dark
  open cracks in their grooves, fading as they come under a pixel, and pits, pale lichen rosettes and
  dark crusts in patches close in. The skin's normals are held within about 50° of the surface's
  (folded over the shale's recess they turned away and shaded in dark blots). The weathered faces'
  bump is 0.12 in two octaves (0.2 in four; the finer octaves still spotted the crest dark blue), with
  a fine grain close in.
- `hillsideblast simulate` takes `--fracture S` (`QuarryFace.Options.fractureScale`, 1 as before):
  how much the bedding and joints cut the coarse cells, for the piece-size study. The scenes' defaults
  are unchanged.

**Measured.** Same rock as main (the generator's sizes, shapes and counts are unchanged: 116,967
blocks at the face, 96,386 on the ridge), so before and after share poses
(`$BOMBCAD_DATA/hillside-blast/rock-strong/face-poses`, `ridge-poses`, simulated on main at 240 Hz).
- *The skin.* At the face 1.28 M triangles over 17,827 blocks in the window (0.25 m) and 3.57 M for
  the film (0.15 m); on the ridge 0.11 M and 0.32 M. Building it takes 0.5 s (window) and 1.9 s (film)
  of the rock's generation; the window's rock and dressing took 4.12, 4.39 s against 3.42, 3.67 s on
  main (face) and 4.12, 3.84 against 3.62, 3.70 s (ridge).
- *The window's work a frame* (`play --self-test NAME --offscreen`, main's build and this one
  interleaved, two runs each, medians; load average 25 to 45 throughout): the face following the
  first firing 29.5, 31.9 ms before, 31.7, 33.0 after; scrubbing and orbiting 56.6, 58.3 before, 58.9,
  57.7 after; playing 19.1, 20.7 before, 20.8, 20.0 after. The ridge following 31.5, 29.2 before,
  30.3, 30.3 after; scrubbing 53.5, 61.7 before, 56.2, 61.6 after; playing 17.8, 18.3 before, 18.9,
  21.8 after. So about +1 to +2 ms a frame (5 to 8%), inside the runs' spread for scrubbing. Metal
  allocated after the first firing 792 to 807 MB (face), 656 to 658 MB (ridge); peak footprint 3.47,
  3.49 GB before and 3.45, 3.48 GB after (face), 3.16, 3.16 and 3.18, 3.17 GB (ridge). (A first
  version drew the skin after the blocks, which then were shaded and overdrawn: the face scrubbing at
  95 ms, following at 49. Drawn first, the blocks under it fail the depth test.)
- *Record Clip* of the default view, 600 frames at 1920 x 1080, interleaved three times: the face
  29.3, 26.9, 38.1 ms a frame before and 29.9, 35.4, 37.9 after; the ridge 27.3, 26.9, 31.9 before and
  24.8, 29.4, 33.5 after. The spread (load falling from 41 to 35 over the runs, yet frames slower) is
  larger than any difference.
- *Checked by eye*, from the same stored poses with the window's recorder (`hillsideblast clip`,
  frames from the movie files), before on main's build and after on this one: the face's default view
  at 0.3, 1, 3.5, 6.5 and 19.9 s, the face close (focus 75,0,3, yaw -0.58, 46 m, 30°), the strip's
  left end close (focus 0,0,8, yaw -0.7, 45 m, 30°) at 0.3 and 1 s, the ridge's default view at 1,
  2.6, 4.5, 12 and 19.9 s and the Pull back at 0.5 to 11.9 s. Files under
  `$BOMBCAD_DATA/hillside-blast/rock-strong/`: `before/`, `final/`, the measurement logs (`st-*`,
  `rc-*`, `measure.txt`) and the scripts (`scripts/`); the trials are `try*/`, and `debug-*/` the
  debug renders (skin coverage, normals, shadows, draw calls).

**The look, frankly.**
- *The unbroken face* is one rock: from the default view at 0.3 and 1 s, banded beds with weathered
  relief, joints and cracks; no seam lines along the blocks' edges, close or far, and past the strip's
  left end the same rock runs on (it was a mosaic of separate blocks on main). The blocks appear only
  where the first firings have started them moving, as the rock breaks.
- *Close in* the hard beds read as weathered limestone with joints, pits and stains. What is still
  weak: the joints are short, near-vertical and fairly evenly spaced, so in the thicker pale beds they
  can read a little like masonry joints; the shale bands show the faint fine laminations as a pattern
  of thin lines close in (as before); a few small dark blots remain on one shale band high on the face
  past the left end, where the ground behind shows through gaps between the skin's rows over a sharp
  fold; and the foot of the face past the strip still ends in a row of small teeth on the floor (the
  dressing's cells, as before).
- *The broken rock and the pile* (3.5 s on) are as before: the blocks' own look, unchanged.

## Stage 3h: rock surfaces that read as rock, 13 November 2026

emmettl/bombcad-work#142, on the user's word of 13 November ("keep working through the defects until
it looks strong"). Same standing: illustrative, for the eye; render-only and procedural, no
third-party assets, nothing reaches the solver. The rock, its blocks and their poses are unchanged
(116,967 blocks at the face, 96,386 on the ridge), so before and after are rendered from #139's stored
poses (`rock-strong/face-poses`, `ridge-poses`). The ridge cut's side of it is below
([Stage 3h on the ridge cut](#stage-3h-on-the-ridge-cut)).

**What was wrong** (#139's frames, `rock-strong/final/`), and what it was.
- *The joints read as coursed masonry.* Each bed had its own short cracks: a joint's openness was a
  noise of the bed and the joint, and 35% of beds had all their joints shifted by up to half the
  spacing, so cracks were a bed high, upright and evenly spaced.
- *Hatch lines on the shale and on the ridge's bands* were the beds' laminations: a ruled sine, nine
  lines a bed (about 14 cm apart), drawn whatever the pixel's size. Close in they read as hatching (6
  pixels apart in the face's close view); farther off they aliased into stripes. Proved by a render
  with them off: the lines went.
- *Dark blots along a shale band* were patches of the held skin whose normals turn away from the low
  sun (the shale's recess folds under the bed above), lit by the sky alone on the darkest rock: a
  render of the normal's light showed them at n·l of zero, not holes.
- *Light squares on the floor* were the floor's grit, a hash of 14 cm cells (`hash31(floor(p * 7))`),
  point-sampled: each cell one flat colour.
- *Teeth at the face's foot past the strip* were the dressing cells' lower ends against the floor.

**What changed.**
- *Joints* (`QuarryJoints`, BlastModel, and its copy `jointField` in the shader). Three sets: the two
  near-vertical ones, and a sparse inclined one (dipping about 60°). Each joint is a trace that wanders
  along its strike and down its dip, opens and closes over stretches some metres long both ways (a
  noise of position along the joint and height, not of the bed), so it runs through several beds; it
  jogs 0 to 0.4 m at 30% of bedding planes and stops at 15% of them; the spacing is warped so joints
  come in clusters and gaps, and 40 to 60% of the places hold one. The crack's width varies along it,
  and it thins and fades as it comes under a pixel instead of widening (it widened into a grid of dark
  lines far off). The weathered relief's grooves follow the same joints.
- *Laminations* (`laminae`): wavy, broken bands in three sizes (3, 8 and 19 to a bed), their contrast
  varying along the strike, each faded as it comes under a pixel; on the blocks, the skin, the face's
  steep ground and the ridge's.
- *Light on the weathered rock* wraps a little past the terminator (0.5 of the way on the shale, 0.1
  on the harder beds), so the small relief turned away from the low sun shades brown, not black.
- *The floor* (`quarryFloor`): close in, gravel and fines: stones of the beds' colours scattered in
  grit, more off the haul roads and in drifts, each domed and leaning its own way, faded with the
  pixel's footprint; far off their mean, a little paler.
- *A talus apron* (`QuarryFace.footApron`, BlastModel, Linux-tested; `apronFragment`): past both ends
  of the strip, grit and stones banked against the face's foot, its top 0.7 to 3 m up the face and
  wandering, low toward the strip's ends, concave down to a lobed toe on the floor that dips just
  under it, the toe's colour the floor's. About 33,000 triangles; drawn and in the shadow map. Nothing
  over the strip, where the broken rock goes.
- *Soil held on the rock* (`heldSoil`): on the weathered rock's gentler tops, in broad patches and
  hollows and in the joints' grooves, soil with grit and thin turf; the steps and steeper fronts stay
  bare. At the face only a little, mostly grit, on the ledges; on a ridge much more (below). A block
  thrown by the blast keeps some of its own.

**Measured.**
- *The window's work a frame* (`play --self-test NAME --offscreen`, main's build and this one
  interleaved, two runs each, medians; load average 23 to 43): the face following the
  first firing 29.9, 31.4 ms before and 33.0, 23.6 after; scrubbing and orbiting 63.7, 57.7 before and
  63.7, 53.2 after; playing 20.8, 18.9 before and 20.4, 18.5 after. The ridge following 30.6, 30.3
  before and 26.4, 31.4 after; scrubbing 59.1, 57.8 before and 59.2, 41.3 after; playing 17.8, 20.1
  before and 16.9, 16.9 after. No cost shows above the runs' spread (the shader's added work is
  mostly close detail, skipped as it fades). Metal allocated after the first firing 807 to 808 MB
  (face, the apron), 658 MB both (ridge).
- *GPU draw a frame* in Record Clip of the default view (the recorder's own GPU timing, from stage
  3f on; main's build and this one interleaved, twice): the face 14.69, 14.68 ms before and 15.29,
  15.38 after (+0.65 ms: the floor's gravel, the apron, the laminations and the joints' third set);
  the ridge 9.14, 9.25 before and 9.34, 9.41 after.
- *Record Clip* of the default view (600 frames at 1920 x 1080), interleaved three times:
  the face 30.6, 31.2, 31.8 ms a frame before and 29.1, 30.4, 30.4 after; the
  ridge 27.4, 28.1, 27.7 before and 28.0, 27.0, 27.9 after (load 30 to 80).
- *Checked by eye* from the stored poses with the window's recorder (`hillsideblast clip`, frames
  from the movie files), main's build and this one: the face's default view at 0.3 (before firing),
  1, 2, 3.5 and 4 s; the face close (focus 75,0,3, yaw -0.58, 46 m, 30°) at 0.3, 1, 2, 4 s; the strip's
  left end (focus 0,0,8, yaw -0.7, 45 m, 30°) at 0.3, 1, 2, 4 s; the ridge's default view at 0.3, 1,
  2.6 and 4 s and the Pull back at 0.5 to 6.5 s. Files under `$BOMBCAD_DATA/hillside-blast/rock-surface/`:
  `before/`, `after/`, `crops/` (enlarged details), the debug renders `dbg-*` and `exp-*` (laminations
  off, shadows off, occlusion off, n·l, soil cover), the trials `try*/`, the scripts (`scripts/`) and
  the measurements (`measure.txt`, `st-*`, `rc-*`).

**The look, frankly.**
- *Joints*: the face no longer reads as coursed masonry: long cracks run through several beds, some
  inclined, a few stopping or jogging at a bed, in clusters and gaps. They are still drawn lines of
  even darkness, without the spalled, rounded edges real joints have, and past the strip's left end
  they are few, so that stretch is plain.
- *No hatch lines* on the shale or the ridge's bands, close or far. The shale bands are plainer for it.
- *The dark blots* on the shale are softened to brown patches, still there where the skin folds.
- *The floor* close in reads as gravel and fines; a soft band remains where the stones fade out
  with distance.
- *The talus apron* covers the teeth and reads as talus. Its top meets the face in a slightly
  sawtoothed line where it is low, and its toe is a visible edge on the floor in places.

### Stage 3h on the ridge cut

The ridge cut's side of the same change (the ridge's doc is [ridge-cut.md](ridge-cut.md)).

**What was wrong.** From above (the default view) the crest read as a striped table: the beds crop out
across its gentle top as parallel bands of their own colours, the joints' two sets crossed the flat
tops in a regular grid of dark lines, the laminations aliased into fine stripes on the bands, and the
dense rock round the cut ended against the grass in a hard edge.

**What changed.**
- *Soil and turf held on the rock* (`heldSoil` in `QuarryRender.metal`): on the weathered rock's
  gentler tops (slope under about 30°), on the shale's slopes (under about 45°), in broad patches
  some ten metres across, in hollows and in the joints' grooves, soil with grit and thin turf, darker
  and greener than the flanks' dry grass; the harder beds' steps and steeper fronts stay bare rock.
  (Held to the laminae's treads, a first try striped the crest again, finer.)
- *The edge of the dense rock round the cut* blends into the flanks' cover: the rock reads the
  flanks' cover map (`QuarryFlank`, now bound to the blocks' shader too) a few metres round, and the
  nearer the ground outside the dense rock, the more soil and turf it holds, so the rock fades into
  the grass rather than ending at a line.
- Rock thrown by the blast keeps some of its soil and turf on its old top.
- The joints thin and fade with distance, so the flat tops show no grid far off.

**The look, frankly** (default view at 0.3 s, and the Pull back at 0.5 s; `rock-surface/before/`,
`after/`).
- From above the crest reads as a grassy, soil-covered hilltop with rock steps, rather than painted
  stripes; the cut's edge on the near side fades into the flank's grass.
- The steps still run in parallel lines across the crest: they are the beds' outcrops, now bare rock
  on steps between turf, but the parallel pattern remains.
- Close in (the Pull back at 0.5 s) the soil's stones read as round domes, a little too even.
- After the blast the thrown blocks carry patches of turf on their tops, which can read as green
  tiles from above.
- Judged first on #139's poses (96,386 blocks), then again on stage 3f's larger pieces (31,259 blocks,
  poses simulated on main after emmettl/bombcad-work#140, `rock-surface/ridge140-poses`;
  `before140/`, `after140/`): the crest before firing looks the same, and the broken crest's larger
  slabs carry their turf in patches. GPU draw a frame in Record Clip of the default view (main's build
  and this one interleaved, twice): 9.14, 9.25 ms before and 9.34, 9.41 after (+0.2 ms).

## Stage 3m: outcrops, crags and fallen blocks as rock masses, 14 November 2026

emmettl/bombcad-work#147, on the user's word of 13 November ("keep working through the defects list
until it looks strong"). Same standing: illustrative, for the eye; render-only and procedural, no
third-party assets; nothing reaches the solver. The rock, its blocks and their poses are unchanged
(116,967 blocks at the face, 31,259 on the ridge, its default since stage 3f), so before and after are
rendered from the same stored poses (`rock-strong/face-poses`, `rock-surface/ridge140-poses`).

**What was wrong** (#139's and #142's frames).
- *Outcrops on a ridge's flanks were too regular*: similar sizes and shapes, spread evenly over each
  cluster (one ledge every 3.2 m along a bed, kept wherever a cluster's noise allowed).
- *The far crags read as plates on edge*: each was swept along a straight line across the slope, its
  beds running out at its ends one at a time over a fifth of its width, so from along the flank it
  was a stack of thin slabs cut square.
- *Some fallen blocks were blades*: a stone's short axis went down to a third of its long one, the
  flat underside and the corners' pull thinned it further, and a large block's fracture cuts could
  take two opposite sides off one.
- *The ridge crest's rock steps ran as long parallel lines*: each bed's weathering back (`recess`)
  was one value per kind of rock, so where the beds crop out across the gentle crest every bed's
  edge was a step the length of the crest, parallel to the next.

**What changed.**
- *Outcrops* (`QuarryFlank.outcrop`, `findLedges`; `QuarryFace.outcrop`, `outcropMesh`): denser in
  the clusters' cores and thinning to the odd run at their edges, with bare slope between; the
  ledges' spacing along a bed is 0.7, 1 or 1.6 times the old in patches, so they are not evenly
  spaced; about a quarter of the outcrops stand on the bed below too (a mass two beds high, a soft bed
  weathered back under the hard one), some have tipped forward 2 to 10 degrees down the slope, some
  are broken into short blocks and some into long ones; their ends run on a little past the last
  ledge and sink over a short way, so they end in a broken block rather than a long thin wedge. A
  half-buried kind was tried and dropped: sunk into the slope a run read as a thin plate lying on it.
- *Crags* (`QuarryFace.crag`): swept along a line that bows out down the slope by a tenth to a fifth
  of its width and wanders a little, so its ends turn back into the hill and show their sides; its
  beds run out at its ends nearly together, so an end sinks into the slope as a whole; overhangs
  smaller and partings closed more often. A crag's outward side is now judged along the rows where its
  top shows (judged at one row, a bowed crag was drawn inside out: dark, unlit faces). A two-tier crag
  (upper beds set back over a bench) was tried and dropped: its lower tier's front came out as a long
  slab across the slope.
- *Fallen blocks and stones* (`flankStonePoint`, `roundStoneShape` in `QuarryRender.metal`): a stone's
  short axis at least about half its long one (0.48 to 0.72 for a stone, 0.56 to 0.82 for a block, its
  middle axis 0.66 or more), the corners' pull gentler, the flat underside cut at most a third of the
  way up, and a block's fracture cuts taking only a sliver across its short axis, so no two leave a
  slab.
- *The crest's steps broken along the strike* (`QuarryRock.strikeRecess`, BlastModel, Linux-tested):
  on a ridge cut the weathering as drawn eases each bed's recess toward the beds' mean along
  stretches some tens of metres long (so a step grows and dies out along it), varies the width of the
  ramp at each bed's edge (sharp in places, a slope in others), and jogs the bed boundaries up or down
  by up to 0.4 of a bed between joints of the first set, so the steps offset where a joint crosses.
  It moves only surfaces drawn over the solver's cells (the held skin and the blocks' outer faces,
  which the cells are still clipped under by `blendedRecess`, at most 0.62 m out or 0.45 m in) and
  the dense render-only rock round the cut. The blocks' shader takes the same jog (`strikeJog`, a
  copy) for the beds' colours and the soil, and on a ridge the shale's band is grassed over along
  stretches of its strike, its riser too.

**Measured** (main's build and this one interleaved; GPU draw from the recorder's own timing).
- *GPU draw a frame*, Record Clip of the default view (20 s, three rounds): the face 18.05, 17.87,
  18.36 ms before and 18.32, 17.31, 17.49 after; the ridge 13.23, 13.24, 13.70 before and 13.33, 13.32,
  13.30 after (within 0.1 ms; the target was at most +1 ms).
- *Record Clip* a frame: the face 30.1, 30.1, 30.5 ms before and 30.7, 29.8, 29.9 after; the ridge
  22.9, 23.1, 23.5 before and 23.1, 23.0, 23.0 after (load 6 to 10).
- *The window's work a frame* (`play --self-test NAME --offscreen`, two rounds, medians; load 6 to
  54): the face following 50.4, 30.4 ms before and 34.6, 29.0 after, scrubbing 62.2, 62.9 and 65.4,
  61.2, playing 19.9, 20.0 and 26.6, 22.0 (the face's frames are the same image before and after, so
  its spread is the machine's); the ridge following 16.6, 19.0 before and 16.9, 18.7 after, scrubbing
  37.5, 45.1 and 44.1, 46.1, playing 13.8, 14.5 and 14.2, 15.1. Metal allocated after the first
  firing 812 MB at the face both, 493 to 494 MB on the ridge. Outcrop triangles on the ridge 180,636
  before, 176,628 after (582 ledges before, 631 after; three crags).
- *The Quarry Face unchanged*: its frames from the same poses match main's to within a few levels in
  a handful of pixels (the recorder's own run-to-run spread).

**Checked by eye** from the stored poses with the window's recorder (`hillsideblast clip`, frames
from the movie files), before on main's build and after on this one: #142's poses (the face's default
view, close and left end; the ridge's default view and the Pull back) and #141's flank views (the
near flank, the wide view, the crag and its close-up, an outcrop close), plus the crest from above.
Files under `$BOMBCAD_DATA/hillside-blast/rock-forms/`: `before/` and `after/`, enlarged pairs in
`crops/` (`crag-*`, `wide-left-*`, `wide-right-*`, `crest-*`, `near-*`), the trials `try1/` to
`try7/` and `dbg-*`, the scripts in `scripts/` and the measurements in `measure.txt`, `rc-*`, `st-*`.

**The look, frankly.**
- *Far crags* now read as blocky rock masses with a lit top and a shaded front and sides, not stacked
  plates (`crops/wide-right-*`). Close in, a crag's ends still show a few square-cut slabs where a
  bed's front turns back into the hill, and the joints between its blocks are still evenly drawn.
- *Outcrops* are more varied in height and grouping (some two beds high, some short, some long, some
  tipped), and clustered with bare slope between, but they are still all swept along their bed's
  contour, so from above many still read as rows; a few short ones still end in a thin lip.
- *Fallen blocks* on the flanks no longer stand as blades; a few large angular blocks still read as
  wedges from some angles. The thrown rock of the cut itself (the solver's pieces) is unchanged and
  keeps its slabs and blades (39% blades by Zingg's measure): reshaping those would change the
  simulation.
- *The crest's steps* now vary in height along the crest, die out in places, jog where joints cross
  and are grassed over in stretches, but from the default view the two strongest (the shale under a
  limestone bed) still run most of the way across as near-parallel dark lines. They follow the
  bedding, which crosses the crest in straight lines; breaking them fully would need the bedding
  itself to fold or the crest's rock cells to differ, which is the solver's, so it is recorded here
  as a stop for this stage.

## Stage 3n: joints with broken edges, and the floor, talus, turf and outcrops' ends, 14 November 2026

emmettl/bombcad-work#148, on the user's word of 13 November ("keep working through the defects list
until it looks strong"). Same standing: illustrative, for the eye; render-side shading and
render-only geometry, procedural, no third-party assets; nothing reaches the solver. The rock, its
blocks and their poses are unchanged (116,967 blocks at the face, 31,259 on the ridge), so before
and after are rendered from the same stored poses (`rock-strong/face-poses`,
`rock-surface/ridge140-poses`).

**What was wrong** (#142's and #147's frames).
- *Joints were drawn lines of even darkness*: a crack of one width and tone with no broken edges,
  and past the strip's left end so few that the face was plain. A crag's joints were an even dark
  band.
- *A soft band across the quarry floor*: its grit and stones faded out together over 1.5 to 8 cm a
  pixel, so where they went the floor turned from gravel to smooth in one band.
- *The talus apron's top was sawtoothed where low* (0.7 m up the face, under the lowest dressing
  cells' lower ends, and the meeting line followed the ground's own steps), and *its toe showed as
  an edge on the floor*: its relief and normals were its own, not the floor's.
- *The soil's stones were even round domes* (every stone filling its cell, all domed alike), and
  the soil's edge against the rock was a hazy margin some decimetres wide close in.
- *Turf on rock that moved*: judged on the face as it now lay, and whole over each piece, so a
  thrown piece's top could read as a green tile.
- *A crag's end showed square-cut slabs*: where its upper beds run out (or the top layers are gone
  over a block) the bed below stopped in a square end at the same place, and a short block of the
  top layer could be left standing alone as a slab on the layer below.
- *Some outcrops ended in a thin lip*: as an outcrop sinks into the slope at its ends and gaps its
  lower layers were still weathered back under the top one, so the top layer stood out of the slope
  alone; and a layer gone from over a block could leave a thin lower layer bare as a plate.

**What changed.**
- *Joints* (`jointLook` in `QuarryRender.metal`; `QuarryJoints.field` keeps the crack's width in
  step): the crack gapes wider along stretches some metres long, and there its lips are spalled in
  chips (a few centimetres to two decimetres across, on one side or both, scalloped), drawn paler
  and fresher and bevelled down into the crack; the crack's darkness varies along it (filled paler
  in places). A fourth, render-only set of short cracks (spacing 1.9 m, open over a metre or two)
  lies between the joints close in, so no stretch is plain. The lips fade as they come under a
  couple of pixels. On the crags and outcrops (`ledgeFragment`) the joints vary in width and
  darkness along them and have chipped, paler lips.
- *The floor* (`quarryFloor`): grit, pebbles and cobbles each fade out at their own footprint (0.8
  to 3.5 cm, 2.5 to 10 cm, 7 to 24 cm a pixel), each leaving its mean tone, so there is no one place
  where the detail goes; the stones have their own outline (`stoneOutline`) and some are sunk.
- *The talus apron* (`QuarryFace.footApron`, Linux-tested): its top at least about a metre up the
  face, lower only over its last few metres to the strip; where it meets the face eased along the
  face over about two metres, with a row run on a little into the hill under the rock; toward its
  toe its normals are the floor's, and its toe is shaded with the floor's own relief, so it runs out
  into the floor with no edge.
- *Soil on the rock* (`heldSoil`, `screeGround`): each stone its own size (0.24 to 0.5 of its
  cell), elongation (to 1.9), turn and lumpy outline, some sunk to a low hump with the fines lapping
  over; the grit between is a smooth noise (a 2.5 cm hash read as a mosaic where it showed). The
  soil's edge wanders at a hand's breadth and is as sharp as the pixel allows; on steeper rock the
  soil thins to smaller patches rather than fading.
- *Turf on rock that moved* (`blockFragment`): judged on the face as it lay in the hill (its rest
  normal), so a piece thrown on its side keeps its turf on what was its top; on rock thrown more
  than about a metre the turf holds only in ragged patches and clumps back from the piece's edges,
  soil showing at the tear. Rock that has heaved, or been released but not yet moved far, keeps its
  turf whole (torn on every piece at release, a first try spotted the crest with a round patch on
  each). The sides of a ridge's render-only cells take the soil of the ground they stand in.
- *Crags and outcrops* (`QuarryFace.outcropMesh`, Linux-tested): where an outcrop sinks at its ends
  and gaps its layers stand flush (no overhang, no recess or batter), so it sinks as one block; a
  remnant a few centimetres proud of the slope is sunk whole. A layer goes from over a block only
  where what is left is at least half a metre thick; no block of the top layers is left standing
  alone at a run's end, nor a short one within. A crag's bed, as it runs out, curves back into the
  hill over 1.6 m, and the beds beside a block whose top layers are gone curve back over 1.2 m,
  rather than ending square. Outcrop triangles on the ridge 176,628 before, 215,358 after (631
  ledges and three crags both).

**Measured** (main's build and this one interleaved; GPU draw from the recorder's own timing;
`measure.txt`).
- *GPU draw a frame*, Record Clip of the default view (three rounds): the face 14.69, 14.73, 14.73
  ms before and 15.31, 15.31, 15.34 after (+0.6 ms: the lips and the fourth set's cracks close in,
  the floor's three sizes of stone); the ridge 11.45, 11.44, 11.47 before and 11.77, 11.78, 11.77
  after (+0.3 ms). The target was at most +1 ms.
- *Record Clip* a frame: the face 25.9, 25.9, 26.0 ms before and 26.4, 26.3, 26.5 after; the ridge
  19.8, 19.7, 19.8 before and 20.1, 20.1, 20.1 after (load 6 to 11).
- *The window's work a frame* (`play --self-test NAME --offscreen`, two rounds, medians; load 3 to
  8): the face following 21.6, 22.2 ms before and 23.7, 23.3 after, scrubbing 46.5, 46.2 and 46.9,
  46.8, playing 18.2, 18.2 and 18.6, 19.5; the ridge following 16.9, 16.9 before and 17.5, 17.1
  after, scrubbing 32.6, 32.5 and 32.9, 32.8, playing 14.3, 14.6 and 14.8, 14.6. Metal allocated
  after the first firing 812 MB at the face and 494 MB on the ridge, both builds.
- Rock unchanged: 116,967 blocks at the face and 31,259 on the ridge, both builds.

**Checked by eye** from the stored poses with the window's recorder (`hillsideblast clip`, frames
from the movie files), before on main's build and after on this one: #142's poses (the face's
default view, close and left end; the ridge's default view and the Pull back) and #147's (the near
flank, the wide view, the crag and its close-up, an outcrop close, the crest from above), plus a
joint close up on the face past the strip, the floor close, the apron, the crest close, and the
thrown rock from above at 10 to 11 s. Files under `$BOMBCAD_DATA/hillside-blast/rock-finish/`:
`before/` and `after/`, enlarged pairs in `crops/`, the trials `t1/` to `t16/`, the debug renders
`dbg*` (lip and crack masks, crag layers, which faces are skin, held, moved or dressing), the
scripts in `scripts/` (`clips.sh`, `try.sh`, `measure.sh`, `crop.swift`) and the measurements in
`measure.txt`, `rc-*`, `st-*`.

**The look, frankly.**
- *Joints* (`crops/joints-faceclose-*`, `joints-close-*`): they read as cracks in rock rather than
  drawn lines: wider and darker in places, with pale chipped lips that catch the light, filled
  paler in others. Close in, the lips are a fringe along the crack rather than real spalls: there
  is no depth to them, and under a raking light they can read as a pale line beside the dark one.
  The face past the strip's left end has more, shorter cracks and is no longer plain
  (`faceleft-plain-*`), though it is still the smoothest stretch of the face.
- *The floor* (`floorband-*`, `floor-*`): no band where the detail fades; scattered pale stones
  run on into the distance and thin out. The stones are still few and pale against the dark grit,
  so close in it reads as a scatter on a smooth bed rather than a gravel floor.
- *The apron* (`apron-*`, `apron-left-*`): its top meets the face in a smooth, wandering line, and
  its toe runs into the floor with no edge where it is shaded. It is still paler than the floor, so
  in the sun its foot reads as a change of colour along the face.
- *Soil on a ridge* (`soil-*`): stones of many sizes and shapes, some sunk, some proud; the soil's
  edge against the rock is crisp and irregular. Seen close the stones are rather many and too alike
  in colour, so a patch of soil reads somewhat pocked.
- *Turf on thrown rock* (`thrown-*`, `turf-margin-*`): a thrown piece keeps only ragged patches of
  its turf, so there are no green tiles among the thrown rock from above. The broken margin of the
  cut, rock that heaved but was not thrown, keeps its turf whole on each cell, and there its cells'
  outlines still show as green plates (the cells, not the shading: torn on every piece that moved,
  the crest was spotted with a round patch on each, so it was left).
- *Crags and outcrops* (`cragend-*`, `crag-*`, and `t10/outc1-00.30.png` against `t8/`): a crag's
  run-out curves back into the hill and the slab that stood alone on its end is gone; a few short
  outcrops no longer end in a thin lip, and none of the gaps leaves a plate on the slope. A crag's
  end is still a squarish block seen from along the flank, and its layers still meet the slope in
  straight sweeps.
- *No crawl* seen in a short orbiting clip close to a jointed face (`crawl-main/`, `crawl-after/`,
  consecutive frames at 1/30 s): the cracks and lips hold still as the camera moves.

## Stage 3o: crag ends, outcrops that don't read as rows, torn turf at the cut's margin, and a gravel floor, 14 November 2026

emmettl/bombcad-work#149, on the user's word of 13 November ("keep working through the defects list
until it looks strong"). Same standing: illustrative, for the eye; render-side shading and
render-only geometry, procedural, no third-party assets; nothing reaches the solver. The rock, its
blocks and their poses are unchanged (116,967 blocks at the face, 31,259 on the ridge), so before
and after are rendered from the same stored poses (`rock-strong/face-poses`,
`rock-surface/ridge140-poses`). The ridge's thrown and heaved blocks are the solver's bodies: their
displacement is read only to shade them.

**What was wrong** (#147's and #148's frames).
- *A crag's ends, seen along the flank, were square-cut blocks* and its layers met the slope in
  straight sweeps. The crag's sweep runs on past where it shows: as its line bows back into the hill
  the slope climbs over its beds, so its ends, where its beds ran out and curved back, were under
  the ground, and what showed was its full-height layers cut off by the slope.
- *Outcrops read as rows from above*: each run of ledges was one sweep along its bed's line.
- *At the cut's margin after the blast, green plates*: the render-only rock round the cut (the
  dressing) kept its turf whole on each cell's top, and as the ground's soil on its sides, so where
  the blast laid it bare it stepped down the cut's wall in green plates. (Not, as #148 thought, the
  solver's heaved pieces: a render of how far each piece had moved showed the plates on the
  dressing, which never moves.)
- *The quarry floor read as a scatter of pale stones on a smooth dark bed*, and the talus apron was
  paler than the floor, so its foot was a change of colour along the face.
- *Chipped crack lips were flat colour*: under a raking light, a pale line beside the dark crack.

**What changed.**
- *Crag ends* (`QuarryFace.outcropMesh`, Linux-tested): its ends are measured from where its top
  stands at least half a metre out of the slope, not from its sweep's ends; there its beds run out a
  step at a time (each 0.5 to 1.25 m in from the one below, a twentieth of its width at most until
  now), each bed's front curving back into the hill over 2.2 m and its top rounding down most of the
  way to its foot (0.35 m until now); and what stands above the slope settles toward it rather than
  sinking straight down, each block of its foot by its own amount. Talus lies at its ends
  (`QuarryFlank.stones`, and scree in the cover), blocks and stones half buried, over its last 12 m.
- *Outcrops* (`QuarryFace.outcrop`, Linux-tested): drawn in short pieces en échelon, one to four
  ledges each; each piece's beds are drawn shifted along the bedding's normal (up to 0.12 m at its
  middle) and twisted along it (0.04 to 0.1 m a metre, the same way along the run, its ends within
  0.45 m of the bed), so it runs a little obliquely across the slope and steps off the next; a lone
  ledge in a run makes a tor, a short block broken small, two beds high in places. The shift rides
  in the vertices' tags (`outcropTag`, 5 bits; `ledgeFragment` colours the beds as drawn). Outcrop
  triangles on the ridge 215,358 before, 183,752 after (631 ledges, three crags).
- *Margin turf* (`blockFragment`): on a ridge cut, once the blast has laid it bare (from 2.2 s; the
  first firing is at 1.8 s), the dressing's turf near the cut's rim (read from the flanks' cover map)
  is torn into ragged mats some decimetres across, wider tears the nearer the rim, soil in the
  tears; its sides facing the cut are bare rock, and under the cut it is bare rock with a little
  fallen soil. On the solver's pieces that heaved but were not thrown (moved 3 to 30 cm), the turf
  is split along the heave into mats, the splits wider the more the piece moved, and broken back
  from its edges. Before firing the hill looks as it did.
- *The floor* (`quarryFloor`): granules, pebbles and cobbles of the beds' rock, weathered toward the
  talus' grey-buff (the apron's palette), cover most of it, nearly touching, with darker fines
  between; fewer on the haul roads and in the damp hollows, more in drifts. Each size, faded under a
  pixel, leaves the mean of its stones and fines in their shares, so the floor's tone holds from
  near to far (within about 3% of main's by bands of the frame); at the pebbles' scale that mean is
  mottled a little. The floor's broad relief is gentler (0.1 to 0.17, from 0.16 to 0.26): under the
  low sun it shaded the gravel in dark blotches.
- *The apron* (`apronFragment`): its talus is darker (its mean the floor's gravel's) and over the
  lower half of its slope it turns into the floor itself in lobes (over its lowest third, from a
  paler talus, until now).
- *Crack lips* (`jointLook`, `blockFragment`): close in (a chip five or more pixels across) the
  chips are separate scoops with whole edge between, only a little paler than the patina, each a
  shallow scoop steepening toward the crack and turned a little its own way along it, so a lip
  catches the light on one side of the crack and is shaded on the other. A few pixels across, the
  lip runs along the crack as before (separate scoops there left the face's joints all but gone from
  the default view in a trial). The crack's width is unchanged, so `QuarryJoints` is too.

**Measured** (main's build and this one interleaved; GPU draw from the recorder's own timing;
`measure.txt`).
- *GPU draw a frame*, Record Clip of the default view (three rounds): the face 14.84, 14.85, 14.83
  ms before and 14.92, 14.92, 14.93 after (+0.08 ms); the ridge 11.58, 11.57, 11.56 before and 11.66,
  11.69, 11.66 after (+0.1 ms). The target was at most +1 ms.
- *Record Clip* a frame: the face 25.7, 25.6, 25.7 ms before and 25.8, 26.0, 25.8 after; the ridge
  20.3, 20.2, 20.1 before and 20.3, 20.5, 20.4 after (load 4 to 7).
- *The window's work a frame* (`play --self-test NAME --offscreen`, two rounds, medians; load 1 to
  6): the face following 21.9, 21.8 ms before and 22.0, 22.0 after, scrubbing 45.8, 45.7 and 45.9,
  45.8, playing 18.6, 18.5 and 18.7, 18.6; the ridge following 17.1, 17.1 before and 16.8, 17.3
  after, scrubbing 31.9, 31.9 and 31.9, 31.9, playing 14.3, 14.4 and 14.3, 13.6. Metal allocated
  after the first firing 812 MB at the face and 494 MB on the ridge, both builds.
- Rock unchanged: 116,967 blocks at the face and 31,259 on the ridge, both builds.

**Checked by eye** from the stored poses with the window's recorder (`hillsideblast clip`, frames
from the movie files), before on main's build and after on this one: #147's and #148's poses (the
face's default view, close, a joint close up, the floor close and farther, the apron, the ridge's
default view, the crest from above, the thrown rock, the crag, its close-up, an outcrop close, the
near flank, the wide view) plus a crag's end along the flank (focus 100,-133,19, yaw 0.25, 24 m),
the flanks from above (focus 105,-60,15, yaw 1.1, pitch 1.0, 130 m), the cut's margin after the
blast (focus 70,23,33, yaw 0.95, pitch 0.75, 28 m, at 11 s) and at 1.5 s, and the apron wider.
Files under `$BOMBCAD_DATA/hillside-blast/rock-masses/`: `before/` and `after/`, enlarged pairs in
`crops/`, the trials `t1/` to `t13/`, the debug renders `dbg1/` (no lips), `dbg2/`, `dbg3/` (how far
each piece moved, which is dressing) and `dbg4/` (the crag in red), orbiting clips `crawl-main/`
and `crawl-after/` (a joint and the floor, frames 50 ms apart in `g-*`), the scripts in `scripts/`
and the measurements in `measure.txt`, `rc-*`, `st-*`.

**The look, frankly.**
- *Crag ends* (`crops/cragend-*`, `after/crag-01.00.png`): seen along the flank the end now steps
  down: the upper bed stops short, the bed below runs on and rounds down into the slope, with blocks
  and stones at its foot. It is still made of large squarish blocks with flat tops; the right end of
  the long crag in the oblique view changed little (its beds there are cut by the slope rather than
  run out), and the layers still meet the slope in straightish lines where the slope crosses them.
- *Outcrops from above* (`crops/flanks-left-*`, `after/flanks-01.00.png`): the long runs are gone;
  the flanks show scattered blocks and short broken groups, some offset from their neighbours. Close
  in, a few pieces are thin slabs lying on the slope, and some groups still line up along their bed
  when seen in a row of three or four.
- *Margin turf* (`crops/margin-rim-*`, `crops/thrown-margin-*`): the green plates on the cut's wall
  and rim are gone: bare rock and soil with ragged turf at the rim. The flank's own turf beyond runs
  right up to the wall, so the edge between grass and bare rock is sharp in places. The heaved
  pieces' split turf is visible only close in.
- *The floor* (`crops/floor-near-*`, `after/floor-00.30.png`): it reads as gravel. The stones are
  rather smooth and rounded, like a beach more than crushed rock, and a little pale and even in size
  within each class; far off it is a plain mottled tone, as before.
- *The apron* (`crops/apron-*`): darker and closer to the floor, its foot no longer a pale band;
  where the sun rakes its slope it is still lighter than the shaded floor beyond, so its form shows.
- *Crack lips* (`crops/joint-*`, `crops/faceclose-*`): close in the continuous pale line is gone;
  chips are separate, some lit and some shaded. A scoop turned away from the sun can read as a dark
  hole beside the crack. In the face's default and close views the joints look as they did.
- *No shimmer* seen in the orbiting clips (`crawl-*`, frames 50 ms apart): the floor's stones and
  the joints move with the surface.
