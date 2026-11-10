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
