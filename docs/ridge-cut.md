# Ridge cut: a notch fired through a ridge (experiment)

**Standing: illustrative.** As with the [Quarry Face scene](hillside-blast.md), this is for the eye.
The cut's shape (a level floor between steep walls) and its firings (rows of points over the cut,
fired in a stylised order at even spacing and time) are chosen by eye. There are no charge masses,
hole layouts, burdens, spacings or loadings of any kind. Each firing only gives nearby blocks a
velocity by the face's stated law, sent up and out down the flank. Nothing here is a blast-design
aid, a road-cut design or excavation guidance. It says nothing about real fragmentation, flyrock
reach or safe distances. The ridge and its rock are procedural; no third-party assets are used, and
how such an event looks is drawn from general knowledge.

emmettl/bombcad-work#131. The strand is "Landscapes and a wider audience" in
[long-term-vision.md](long-term-vision.md): terrain explosions make the app approachable for people
who are not engineers.

## Stage 1, 12 November 2026

**What a user gets.** **File ▸ New Ridge Cut (Experimental)…** opens the Quarry Face window with
its other scene, *Ridge cut*, chosen (Scene, at the top of the sidebar, switches between the two).
The window lays out the built-in ridge, cuts a notch across its crest, breaks the rock above the
cut's floor and fires it. The crest heaves, breaks open and is thrown up. The rock comes down into
the notch and slides down both flanks while dust rises from the firings and from where blocks
strike. What is left is a notch in the skyline with broken rock in it and spilled down the flanks.
- *Place cut* (top right of the 3-D view), or a drag on the map, lays the cut's line across the
  ridge: from one flank, over the crest, to the other. The line is drawn over the view with the
  outline of the cut's floor; either end can be dragged. On release the rock is broken and fired.
  There is no snapping: a cut's line can go anywhere on the ground.
- *Cut (stylised)*: the floor's width (12 to 40 m) and its depth below the highest ground on the
  line (8 to 30 m). Each applies when its slider is let go.
- The rest is the Quarry Face's: the ground (built-in, an area of a terrain file, or the open
  project's terrain), the firing order, ripple and count with Fire again, playing as it is
  simulated, scrubbing, the orbit, and Record Clip.
- A file's or a project's terrain starts with a cut across its highest ridge (at right angles to
  the ridge's line there, long enough to reach ground the cut's depth below the crest on both
  sides). Where nothing drops away on both sides within 200 m, it asks for a line to be dragged.
  A line that does not cross a ridge (the ground on it does not fall by half the cut's depth on
  both sides of its highest point) is refused with a message: the cut would be a pit.

**Why a scene inside the same window, not a window of its own.** The code decided it. Almost
everything the Quarry Face window does is the same for a ridge: the rock generator (beds, joints,
weathering, the blocks and their spheres), the solver, the run that streams the event while it is
simulated, the pose cache, the dust and its fields kept on disk, the renderer with its chips and
fines, the clip recorder, the ground choices and the firing controls. What differs is what is laid
out on the ground, and that is one piece of data: `QuarrySite.scene`. A separate window would have
duplicated about 1,300 lines of view code for a different picker and two sliders. So `QuarryFace`
carries an optional `QuarryRidge` (the cut's floor, crest, walls), and the few places that read a
face's geometry ask it: the layout, the box the rock is sampled in, the firing pattern, the launch's
direction, the dust's box and puffs, the render-only rock, the ground drawn round the scene, the
default view and sun.

**The cut** (`QuarryRidge`, BlastModel). In the frame of the cut's line (x along it from its start,
y across it, z up), the crest is the highest old ground on the line, and the floor is level, `depth`
below it. The ground after the cut is the old ground or, where that is higher, the floor plus a
wall rising at 2.75 m a metre (about 70°) from `width / 2` across the line, the half-width wandering
by up to 1.4 m so the walls are not ruled lines. Past the line's ends the same walls rise, so a line
that stops short of the flanks ends in walls rather than an open slope. On a ridge the floor runs
out into daylight on both flanks, which is the notch. The rock between the two surfaces is broken
exactly as a face's is (bedded coarse cells cut by bedding and joints, weathered near the old
surface, held to the two surfaces by tangent planes). A ridge cut has no held skin past its ends
(a face's runs 165 m along the face either side); to ask for about as many blocks in either scene
from the same Blocks setting, a ridge cut takes 2.1 times the coarse cells.

**The built-in ridge** (`QuarrySite.builtInRidge`): a long ridge over a plain, 1.1 by 1.3 km at
1 m, its crest about 37 m up and wandering a little, one flank gentler (about 29° at its steepest)
than the other (about 35°), dying into the plain 330 to 480 m along it either way so the view never
finds it cut off. Its crest down to about the cut's floor (with an irregular edge) and its steepest
ground below are dressed with the same render-only bedded rock as the face past its strip, so the
broken rock of the cut is of a piece with the ridge it is cut from. The default cut: a line 160 m
across the crest, a floor 28 m wide and 25 m below the crest.

**Firings** (`QuarryFiringPattern.ridge`). One row along the line through the middle of the cut
(fewer than 10 firings), or two rows 0.45 of the half-width either side of it, the second between
the first's points; evenly over the cut where it is deeper than a metre, less 6 m at each end;
each halfway down from the old ground to the floor. The order runs along the line: left to right
is from its start to its end (from one flank over the crest to the other), centre out from the
crest down both flanks, edges in the reverse, scattered at random. Ripple and count as the face's.

**The launch** (`QuarryLaunch.applyRidge`): the face's law (speed 15 (3 / max(r, 3)) m/s from the
nearest firing, jittered, released at that firing's time plus r / 200 m/s, after a coherent swell),
but sent out along the line down the flank the block is on (none on the crest, where the ground is
level along the line) rather than out of a face, with 0.8 of it upward rather than 0.55, and a swell
that is mostly up: the crest heaves. Blocks within about 2.6 m of a wall (wandering from none to
about 10 m, as a face's last skin does) stay put, so the walls are left rough. The dust's puffs are
born on the ground above each firing and go up and out down the flank; blocks trail dust and throw
it up where they strike anywhere up to 10 m above the ridge's top (a face's up to 30 m, its pile).

**One change to the solver, for the flanks.** On a face the rock comes to rest on a level floor. On
a ridge it rolls down slopes, and a clump of spheres has no rolling resistance: in the first run a
few rounded blocks were still rolling on the lower flanks at about a metre a second after 17 s. The
solver damps a supported body slower than 0.6 m/s toward rest (explicit contact has no static
friction); that threshold is now a uniform, 0.6 m/s for a face (as it was, the same value) and 1.0
m/s for a ridge cut.

**The budget, and how the cut was sized.** The Blocks setting asks for a count, not a size, so a
cut's volume sets how big its blocks are. The default cut was chosen with the built-in ridge so
that the count and its cost sit in the Quarry Face's range: 43,800 m³ of rock (the face's strip is
120,000 m³), broken into 96,987 blocks at the window's 100,000 (the face makes about 108,000 to
116,000, a third of them its held skin), 528,206 contact spheres (the face 494,873 to 528,460). So
a ridge cut's pieces are smaller than a face's: by cube root of volume 0.30 m at the 10th
percentile, 0.57 m median, 1.01 m at the 90th and 2.50 m the largest, against the face's 0.47,
0.74, 1.40 and 3.37 m. A wider or deeper cut has more rock and so larger blocks: at the
sliders' far end (40 m wide, 30 m deep) 84,900 m³ in 117,651 blocks (647,285 spheres, a fifth over
the face's), median 0.65 m. A small cut is broken into fewer blocks rather than smaller ones: its
coarse cells are capped so the mean block stays at least 0.62 m across (`QuarryRidge.smallestEdge`).
Before that cap, a cut 16 m wide and 14 m deep made 69,576 blocks of 0.34 m median and a solver grid
of 28 M cells (the face's is 6.7 M; the grid is cleared every substep); with it, 36,803 blocks of
0.44 m and 14 M cells, and at the sliders' near end (12 m, 8 m) 8,938 blocks. Nothing else was
cleared or shortened to fit; no cleared notch was made (the rock stays where it lands).

**Measured** (release build, M4 Max Studio).
- *Physics* (the film's 240 Hz, `hillsideblast simulate --ridge --blocks 100000 --seconds 20`):
  48.4 ms median and 68.3 ms p90 a frame of 1/30 s while more than 5% of the blocks are awake
  (189 frames), against the face's 44.0 and 59.7. Nearly every block of a ridge cut moves; 10,377
  stay against the walls. Solver buffers 77 MB; its grid 382 x 191 x 110 cells of 0.84 m.
- *The window's own session* (`hillsideblast play --ridge --self-test NAME --offscreen`, 1600 x 900,
  the window's 100,000 blocks: 96,987 made, 3.63 M block triangles and 3.51 M of render-only rock),
  medians of the work a frame: playing a stored event 16.9 ms (p90 19.0); following a firing as
  it is simulated 18.0 and 18.4 ms (p90 47.9 and 45.7; playback at 0.77 times real time in the
  median, 0.39 at the slowest, through the busiest seconds); scrubbing and orbiting every frame
  36.4 ms. The face's, from its stage 3b: 17.8, 20.3 to 20.5 and 44.4 ms. Window opened to first
  frame 2.5 s (rock broken in 2.1 s); Fire again to first frame 0.17 s; a moved cut 2.7 s; a whole
  20 s event simulated in 14.4 to 14.6 s.
- *Memory*, the same run: poses 282 MB, dust fields 152 MB (1.5 m), dust kept on disk up to 380 MB,
  Metal allocated 858 to 932 MB; footprint 3.36 GB after the first fire, 3.00 GB after a refire,
  3.12 GB after a moved cut, peak 3.84 GB. Inside the face's 3 to 4 GB.
- *The film* (`hillsideblast render --ridge … --clip`, 1920 x 1080 from 3840 x 2160): 39.9 ms
  median to draw (10.1 M block triangles), 13.9 ms for the dust step at 1 m.

**Stable.** The 20 s event at 240 Hz: no NaNs; over the last second the median and 99th percentile
block moved 0, the worst 1.16 m, and one block of 96,987 more than 10 cm: a single block still
rolling at about a metre a second on the gentle foot of the long flank. The fastest block reached
28.5 m/s (the launch law allows 18 m/s at release; as at the face, the fastest are driven down under
the rock coming down on them). Before the creep threshold was raised for the ridge, the same
measure was a worst of 86 cm and six blocks over 10 cm, all rolling on the lower flanks.

**Quarry Face unchanged.** The shared code takes the face's path wherever it asks the scene (the
layout, the dressing, the dust, the launch and firing pattern, the ground drawn round it, the sun
and view), and the solver's creep threshold is the same 0.6 m/s, now passed as a uniform. Checked
by rendering the same face poses (`simulate --blocks 110000 --seconds 6`) with main's
`hillsideblast` and with this one: the stills at 1.0, 3.5 and 5.9 s are byte-identical PNGs. The
face's tests (`QuarryFaceTests`, `QuarryStripGuideTests`, `QuarryFaceSceneTests`) pass unchanged.

**Checked by eye.** Stills at 1.0, 2.3, 3.0, 4.5, 7.0, 12.0 and 19.9 s, and frames taken from the
clip file itself at 1.0, 2.5, 3.5, 5.0, 8.0, 12.0 and 19.5 s (it plays in order: the calm ridge,
the first puff over the crest, the notch opening with rock spilling, the tongue of rock down the
near flank, the settled notch), and the far flank from the other side at 5.0 and 19.9 s. Run:
`hillsideblast simulate --ridge --blocks 100000 --seconds 20 --out ridge/final/poses`, then `render
--ridge --blocks 100000 --poses ridge/final/poses --out ridge/final --clip --bitrate 9000000
--stills 1.0,2.3,3.0,4.5,7.0,12.0,19.9`; the far side with `--eye -120,-120,30 --eye-end
-120,-120,30 --target 81,4,17 --target-end 81,4,17 --fov 28`.

**The window, offscreen** (`BOMBCAD_INTERFACE_REVIEW=dir swift test -c release -Xswiftc
-enable-testing --filter QuarryFaceReviewTests/ridgeCut`, the window's 100,000 blocks, 96,987 made):
captured while following the solver, settled, in Place cut (the calm ridge with the cut's line over
the crest and its floor's outline), dragging a new line from high above, and 5 s into the new cut's
event. The sidebar shows Scene, the ridge's text, Built-in ridge, the map with the line across the
ridge and Cut (stylised) with its two sliders. Window opened to 3.4 s of the event on view in 11 s;
a dragged cut on view 2.8 s after release, where it was dragged (within 0.4 m, picked through the
view). A 20 s clip from the window's Record Clip, on a slow orbit: 600 frames in 14.7 s, 23.5 ms a
frame median, Metal at most 2.1 GB while recording; frames from its file at 1, 2.5, 4, 6, 10 and
19.9 s play in order.

**The look, frankly.** Better than expected for a first stage. With its crest dressed in bedded
rock the ridge reads as a rocky ridge, and before the blast the cut does not show as a patch. The
notch in the skyline reads at once, the tongue of broken rock down the near flank with blocks
scattered at its foot is convincing, and some rock spills down the far flank too. What looks wrong:
- *The dust* is one big, smooth cloud over the crest that rises into an arch and hangs there for the
  rest of the event; it reads as a cloud, not as dust thrown out of a cut, and it hides the notch
  for several seconds. There is little dust where the rock comes down the flank.
- *The heave* is hard to see from the default view, about 200 m off: at 2 to 3 s the crest churns
  rather than visibly lifting as a whole.
- *The lower flanks* carry scattered render-only slabs where the ground is steepest, which read as
  flat cut-outs from close; and below the rocky crest the flanks are plain tan ground.
- *Through the notch* a flat pale strip of the far plain shows, which looks like a seam.
- *The pieces* are smaller than the face's (0.57 m median), so from 200 m the pile reads as gravel
  near the crest; the big blocks are the ones that run down the flank.
- *The beds* are level, as the face's are; a ridge would more often be of tilted beds (a hogback).
- One block is still rolling at the end.

**Tests.**
- `QuarryRidgeTests` (BlastModel, Linux): the floor is its depth below the crest and the rock fills
  the cut; a turned and moved copy of the ridge gives the same cut and volume; flat ground, a
  slope and a line along the crest are refused; every firing order fires each point once at the
  stagger in rows inside the cut, centre out from the crest; a face's pattern is its row as before;
  the launch holds the blocks by the walls and sends the rest up and out down their own flank; a
  first cut is laid across the built-in ridge at right angles, none on a slope; the cut's lines.
- `RidgeCutSceneTests` (BombCAD, GPU, offscreen): the window opens a ridge cut, breaks, fires and
  settles it (rock down both flanks, the last second still); switching scene and the cut's width
  and depth; a cut's line dragged across the ridge in the 3-D view lands where dragged; a
  project's terrain is cut across its ridge, and flat ground asks for a line.
- `QuarryFaceReviewTests/ridgeCut` (with `BOMBCAD_INTERFACE_REVIEW`): the window captured
  offscreen following, settled, placing the cut and dragging a new one, and a clip recorded from
  the window, with frames taken from its file.

**Where it stopped, and stage 2.**
- Not looked at on a screen: the window was captured offscreen, and the drags were synthesised.
- The dust is the face's, fed from new places; a ridge would want a sharper, faster plume from
  each firing that thins quickly, and dust where the rock strikes the flank.
- Stage 2, in order of what would move the look most: the dust (above); a view that shows the heave
  (closer, or an opening move in a clip); the flanks below the crest (scree and grass rather than
  scattered slabs); tilted beds for the ridge; larger pieces for the same count where the camera is
  far (fewer, larger coarse cells away from the cut's middle); and a cleared notch (taking the
  rock left in the floor away after the blast), which was not tried.

## Stage 2a, 12 November 2026: the dust

On the user's word of 12 November (emmettl/bombcad-work#132). Same standing: illustrative, for the
eye. The dust still comes only from the firings and the rock; nothing was added that does not
follow the rock.

**What a user gets.** Each firing throws up its own column of dust from the ground above it, so
the firings read in their order along the cut (the default order runs from the far flank over the
crest to the near one, 16 firings from 1.8 to 3.3 s). The columns thin as they rise. The notch
shows again at about 5.5 s, two seconds after the last firing, and is clear by 6.5 s; before, the
arch of dust hid it through 12 s and later. Rock running down the flanks trails a skirt of dust
down the slope, which fades once the rock stops (gone by about 12 s).

**What changed** (`QuarryDustField`, `QuarryDust.metal`; all of it only for a ridge cut).
- *The firings' puffs.* A column rather than a ball: born within 3 m across and 9 m above or below
  the old ground over the firing (it was 7 m across and 5 m up or down), sent mostly up with little
  spread at 1.4 to 14 m/s each (it was 20 m/s for all, so the dust left the ground as a ball and the
  stem was empty), for 0.35 s, 120 a particle against 70. The heat that lifts it is as before.
- *Thinning.* A ridge's dust thins by 0.9 of itself a second from 10 m above the ground up and 0.6
  within 3 m of it, blended between, on top of what the face's dust keeps. That is what clears the
  notch; the face's dust only loses 2% a second high up, so its plumes hang. The two rates ride in
  the spare `w` of two of the dust uniforms (`low.w`, `wind.w`, zero for a face), so the shader
  struct and its copies are unchanged.
- *The skirt.* A block moving faster than 1 m/s within 0.6 of its size plus 0.5 m of the ground,
  where that ground is a metre or more below the cut's floor (the flanks, out of the notch), kicks
  up dust in proportion to its speed (to 12 m/s) and the square of its size. The dust goes on with
  0.7 of the block's velocity and 2 m/s up, warm enough to rise a little. It is born 2.5 m clear of
  the ground and scattered by up to 2 m: born at the block, it lay behind the bedded ledges of the
  flank and showed only as flat horizontal strips between them.
- *Blows.* Count from a change of 3 m/s in a frame (4 at the face) and throw up about 17 times the
  face's dust for the same blow; at the face's rate they hardly showed from 200 m.
- *Tried and not kept.* The skirt fed from every block sliding near the ground, the notch's floor
  included: the dust over the floor lay under the pile and showed only past the floor's lip, as a
  flat pale lens at the notch's mouth from 4 to 10 s. A dust box reaching lower (it already reaches
  3 m below the lowest ground in it). Hotter skirt dust: it rose into one smooth pillow over the
  middle of the tongue.

**Measured** (release build, M4 Max Studio; another session's checks were running for the second
pair of window runs).
- *The film's dust step* (`render --ridge … --clip`, 1 m field, GPU time): 13.9 ms median before
  (stage 1's run), 13.5 ms rendering the stills before and after, 13.7 ms in the clip after. The
  whole step with its sources on the CPU, timed by the wall clock over the same stills run: 16.3
  and 17.3 ms before, 15.6 and 16.6 ms after. The extra sources (a height lookup for each block
  moving faster than 1 m/s, a few hundred to a thousand a frame) do not show.
- *The window's work a frame* (`hillsideblast play --ridge --self-test NAME --offscreen`, two runs
  each, before then after, then after then before): following a firing 18.2 / 17.7 and 21.3 / 20.9 ms
  before, 19.7 / 22.4 and 21.5 / 20.0 ms after; playing a stored event 16.8 and 17.3 ms before, 17.1
  and 17.3 ms after. Within the runs' spread; the stage 1 figures were 18.0 / 18.4 and 16.9.
- *Memory:* unchanged (the same fields; no new buffers).

**Quarry Face unchanged.** Stills from the same face poses (`ridge/facecheck/poses`, 110,000
blocks) at 1.0, 3.5 and 5.9 s from main's `hillsideblast` and from this one are byte-identical
PNGs. On the way they were not: the ridge's thinning first went in as a factor on the face's own
expression, and the shader compiler then evaluated the face's product differently (an image of the
same look, not the same bytes). The thinning is now a separate multiply after the face's value.

**Checked by eye**, from the stored stage 1 poses (`ridge/final/poses`) at the same camera and
times, before with main's build: stills at 2.0, 2.5, 3.0, 3.5, 4.5, 6.0, 8.0 and 12.0 s, and frames
taken from each clip file itself at 2.0, 3.0, 3.5, 4.5, 5.5, 6.5, 8.0 and 12.0 s; the far side
(`--eye -120,-120,30 --target 81,4,17 --fov 28`) at 3.5, 4.5, 5.5 and 8.0 s; and the window's own
captures while following. Files under `$BOMBCAD_DATA/hillside-blast/ridge-dust/`: `before/` and
`after/` (stills, `clip.mp4` in `after/`, frames in `fromclip/`; the before clip is stage 1's
`ridge/final/clip.mp4`), `before-far/` and `t15-far/`, `face-before/` and `face-after/`,
`play-before*/` and `play-after*/`.

**What still looks wrong.**
- *The columns are clean, rounded billows,* brighter and smoother than dust off a real cut; there
  is no darker fume in them, and from the default view the row of columns along the line, which
  runs toward the camera over the crest, still draws an arch for a second or two (now of separate
  columns, and gone in a few seconds rather than staying).
- *The skirt reads in horizontal bands* from the default view: the flank's bedded ledges still hide
  the dust nearest the ground behind them. It is strongest near the notch's mouth on the near flank
  and fainter down the slope, where the rock has slowed.
- *The far flank has little dust.* Less rock goes down it: 20 to 100 blocks a frame slide on it
  against up to 900 on the near flank, so its skirt is faint, honest to the rock but weak to look at.
- *Dust on the notch's floor* where the rock lands is under the pile and mostly unseen.
- *The window's field is 1.5 m*, so its columns are coarser than the film's.
