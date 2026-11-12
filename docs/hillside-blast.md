# Hillside blast: a quarry face as a spectacle (experiment)

**Standing: illustrative.** Like the crater's growth ([docs/cratering.md](cratering.md), "How it
grows"), this is for the eye. The fracture pattern is a Voronoi tessellation chosen by eye; the
firings are a stylised row at even spacing and time, with no charge masses, hole layouts or
loadings of any kind; each firing only gives nearby blocks a velocity by the law below. Nothing
here says anything about real fragmentation, flyrock reach or safe distances, and no code path
offers it as a blast-design aid. It is an experiment, reachable only from the `hillsideblast`
command, and it changes nothing in the solver or any existing result.

emmettl/bombcad-work#122.

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
- The 3-D view stretches the renderer's 16:9 frame over the view, whatever its shape (since stage 1),
  so in the default window the rock is squeezed sideways by about a quarter; the clip, at 16:9, is
  not. Picking allows for it. Rendering at the view's own shape was not done here.
- Placing has not been tried by hand on a screen: the drags were synthesised offscreen.
- The strip is laid on the ground as it was before any blast; strips do not build on each other.
- A clip is of the window's quality (its mesh, 1.5 m dust, no supersampling), not the film's.
