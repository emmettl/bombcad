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

## Stage 2b: an opening view that shows the heave, 12 November 2026

emmettl/bombcad-work#133, approved by the user on 12 November. Same standing: illustrative, for the
eye. Only the camera, its default and the backdrop changed; the cut, the firings, the launch, the
solver and the dust are as they were (the dust is stage 2a's, emmettl/bombcad-work#132, which
landed while this was checked: the frames below were made first with stage 1's dust, then again with
2a's).

**What a user gets.** A ridge cut now opens close on its crest: about 94 m off (stage 1's was 189 m),
off the cut's steeper flank and a little to its side, with the eye 2 m under the crest's height. So
the crest and, later, the notch stand against the sky in the upper third of the frame; the near
flank the rock comes down is below them; and the cut's wall that faces the eye is in the sun. It is
still an ordinary view, orbited and zoomed as before. Record Clip's *Camera* has a third choice,
*Pull back*: it starts close in on what the view looks at and holds there until just after the
first firing, then eases back to the view as it stands over five seconds of the event while the
rock spills. The far plain seen through the notch now fades into the backdrop's distant hills.

**How the view is chosen** (`QuarryRidgeView.opening`, BlastModel). Everything is in the cut's own
frame (x along its line, y across it), worked out from the cut and the ground:
- *Which flank.* The steeper one (the old ground's drop over 30 m from the crest along the line):
  the rock runs furthest down it, toward the eye. On the built-in ridge that is past the line's end.
- *Which side.* The line's right when the eye is off its end, its left when off its start, so a
  line drawn either way is seen from the same place on the ground, in the same light.
- *Where it looks.* On the line, 15% of the way from the crest to where the cut runs out on the far
  flank (the notch shows in the skyline between the two), at 65% of the cut's depth above its floor.
- *How far.* 1.5 times the notch's width at its top (the floor's plus its two walls') plus the
  cut's depth, at least 80 m: 94.3 m for the default cut, 122.7 m for the sliders' largest (40 m
  wide, 30 m deep), 80 m for a small one. At 32° that frame is about 96 m across where it looks.
- *Yaw and height.* 0.95 rad off the line (stage 1's was 1.0), the eye 2 m under the crest.
- *Nothing in the way.* The eye must be 4 m clear of the ground and see, over the ground after the
  cut, where it looks and the crest's top either side of the cut. If not, the view is turned 0.2
  and 0.4 rad either way, then raised by 6, 12, 20 and 32 m, then tried from the other side and the
  other flank; failing all of them, from high above the near flank.
- *The sun* is stage 1's for this view (low, 18°, along the ridge from the eye's side and a little
  behind it), mirrored with the flank and side, so it stays where it was relative to the cut and
  the eye. The renderer takes it from the same function, so the dust is lit to match.
A new cut makes a new session, which starts at this view, so moving the cut (on the map or in the 3-D
view), changing its width or depth, or using a file's or the project's ground frames the new cut. The
window's default view stays a still one.

**The pull-back** (`QuarryPullBack`, BlastModel; `QuarryClipCamera.Motion.pullBack`, BlastRender).
At its start the eye is at 0.7 of the view's distance on the same line, the field is 0.55 of the
view's (32° to 17.6°) and it aims higher by a tenth of the distance (9.4 m by default), so the crest
fills the frame with sky above it. It holds that until 0.7 s after the first firing (2.5 s at the
default 1.8 s), then eases (smoothstep) to the view over 5 s of the event, so the move is the same
moment at real time, half or quarter speed, and a clip started later than 7.5 s is simply the view.
It is a dolly and a zoom together: a dolly alone from that close put the eye down on the steep flank
grazing the rock (tried first, at 0.42 of the distance), and a zoom alone has no parallax. The
first firing's time is passed from the event's firings.

**The far plain in the notch.** Stage 1's pale strip was partly the backdrop: past about 1 km the
ground was fogged toward the bare sky's horizon colour (a warm pale peach), but the sky draws its
distant hills, darker and greyer, just above the horizon, so the far plain read as a bright band
under darker hills. A ridge cut's far ground now fades toward the backdrop as drawn at that azimuth,
hills included (the sky's hills moved into a `backdrop` function that the sky and the fog share;
`QuarryCamera.fogColor.w` is 2 for a ridge cut, 1 for a face, which keeps its fog as it was). The
rest is terrain: the built-in ridge's plain is flat bare ground with only a metre or two of relief,
evenly lit by the low sun, so through the notch it reads as an empty pale plain. From the new view,
nearer and lower, it is seen as ground running out to the hills, its far edge now the hills'
grey rather than a pale band (with 2a's dust the notch is clear from 7 s, so this shows for most of
the event); from stage 1's view (kept for comparison below) a lighter
band still shows at the bottom of the notch, now greyer at its far edge. Not changed: the plain
itself (texture, scrub, a farther ridge behind) would be the terrain's next step.

**Checked by eye**, from the same stored poses as stage 1 (`ridge/final/poses`, 96,987 blocks, 20 s):
- With a new `hillsideblast clip` command, which runs the window's own Record Clip
  (`QuarryClipRecorder`: its renderer, dust, camera and writer, at the window's mesh) from stored
  poses offscreen and takes frames from the movie file itself. New default, held still, and stage
  1's view (yaw 1.0, pitch 0.07, 189.2 m, focus (81, 4, 20.6)), 20 s each, frames at 1, 2.3, 2.6, 3,
  4.5, 7, 12 and 19.9 s; the pull-back over 12 s at real time (frames at 0.5 to 11.9 s) and over 1.5
  to 5.5 s at quarter speed (16 s of movie). Each 1920 x 1080 clip took 21.6 to 24.1 ms a movie frame.
- Film stills (`hillsideblast render --ridge`, supersampled) at the same times, at the new default
  and at stage 1's camera path.
- What they show. From stage 1's view the crest is a thin band at a third of the frame's height, the
  plain fills the lower half and the heave is a few pixels of churn. From the new view, half as far, the crest is
  twice the size in the frame and stands against the sky: at 2.3 to 2.6 s its surface visibly breaks up and blocks
  lift off its top against the sky, the first dust puffs rise from it, by 4.5 s the notch is open in
  the skyline with rock tumbling down the near flank toward the eye, and at 19.9 s the notch with
  its rock and the pile on its far shoulder fill the middle of the frame. The pull-back opens on the
  crest's broken top with sky above, shows blocks thrown up from it at 2.2 s, and pulls back through
  the dust to the notch by 7.5 s.
- With stage 2a's dust (the new default held still, and the pull-back, again from the file): the
  firings' columns rise from the crest in order at 2.3 to 3.3 s against the sky, the notch is open
  and clear by 7 s, and from then to the end the whole notch, its rock and the tongue down the near
  flank are in view, the far plain through the notch running out to the hills. In the pull-back the
  close shot fills with the columns at 2.6 to 4 s, so its view of the crest breaking is 2.2 to 2.6 s.
- Files: `$BOMBCAD_DATA/hillside-blast/ridge-view/final/` (stage 1's dust: `new-still.mp4`,
  `new-pullback.mp4`, `new-pullback-quarter.mp4`, `old-still.mp4`, their frames, `film-new/` and
  `film-old/`) and `final-2a/` (2a's dust: `new-still.mp4`, `new-pullback.mp4` and their frames).

**Quarry Face unchanged.** The face's view, sun, fog and clip cameras take the same arithmetic as
before (its default orbit now comes from the same `QuarrySession.defaultOrbit`, with the same numbers).
Stills from the face poses of stage 1's check (`ridge/facecheck/poses`, `render --blocks 110000
--stills 1.0,3.5,5.9`) with this build are byte-identical to main's.

**Tests.** `QuarryRidgeViewTests` (BlastModel, Linux): the built-in cut is seen from off its steeper
flank, 85 to 105 m off, 2 m under the crest, with nothing in the way and stage 1's sun; a cut moved
150 m along the ridge is framed on its own crest, and one drawn the other way is seen from the same
place on the ground (within 2 m) in the same sun; a turned copy of the ridge gives the same view in
the cut's frame, as does the cut a terrain starts with; the largest cut is seen from further off and
a small one from the nearest; a knoll put in front of the default eye turns or raises the view
until it is clear; the pull-back holds until 0.7 s after the first firing and only moves out, along
the view's own line, ending at the view.

**The look, frankly.**
- *The heave itself is weak in the event,* not just far away: even from 94 m, and in the
  pull-back's close shot, the crest's top breaks up and churns rather than visibly rising as a
  whole before its blocks are thrown, and from about 2.6 s the firings' dust covers the crest
  until the notch clears. The pull-back shows the break-up best. A heave that reads as a whole would need
  a stronger, slower swell in the launch, which is the event's look, not the camera's; not tried.
- *The near flank fills the lower half of the frame* in the new view: its render-only slabs and
  the plain tan ground below the rocky crest (listed in stage 1) are now close and large, and
  the tongue of rock down the flank is cut by the frame's bottom in a 16:9 clip (the window, taller,
  shows more of it). Raising the eye shows more tongue but puts the far plain behind the crest.
- *The pull-back's opening* is the near crest's surface, all render-only dressing and blocks of one
  texture, close enough for the blocks' small size (0.57 m median) to read as gravel.
- *The far plain* through the notch is flat and bare (above).
- Not looked at on a screen: all of it was made offscreen.

## Stage 3a: a heave that reads, 12 November 2026

emmettl/bombcad-work#134, approved by the user on 12 November. Same standing: illustrative, a
stylised firing for the eye; nothing here is a load, a blast design or a claim about how real rock
heaves. Only the ridge cut's launch and two of the solver's ridge-only terms changed; the firings,
their times and order, the dust, the view and the renderer are as they were.

**What was wrong.** Stage 2b said the crest "churns rather than visibly rising"; measured from the
poses (`tools/heave.py` below: the 13,770 moving blocks within 3 m of the old surface over the
cut), it never rose at all. On main the top layer only sank: its median height change was −0.07 m
at 1.8 s, −1.2 m at 2.5 s, −2.8 m at 3.0 s, and no block of it rose a metre before it broke. Two
reasons:
- *Gravity took back the swell.* The swell is dynamic (hillside-blast.md, stage 3): a swelling
  block is awake and pushed along its swell's velocity, under gravity like any other. At a face the
  swell is mostly outward along the floor, which holds the rock up. A ridge's is mostly up: at the
  crest's top, about 12 m from the nearest firing, 2.6 m over about a second, against the 4.9 m a
  free fall takes in that second. So it never lifted off what lay under it.
- *The launch slowed it.* A block lets go with the law's launch less the swell's velocity. At the
  crest's top the law gives about 3.75 m/s (jittered by 0.7 to 1.2), less than the swell's 5 m/s
  there, so what little
  lift there was stopped when the rock let go, and the top was thrown about by the launches of the
  rock under it: the churn.

**What changed** (`QuarryLaunch.applyRidge`, BlastModel; `QuarrySolver.metal`, BlastCore; a ridge
cut only).
- *The swell is carried.* While a ridge cut's block swells, the solver holds up its weight (the gas
  under the burden, stylised): `launchSwell.w` of a body, 1 for a ridge's blocks and 0 at a face,
  is the share of gravity cancelled until it lets go, and the creep damper leaves a swelling,
  carried block alone (it is starting to move, not coming to rest). Still dynamic: contact keeps
  swelling blocks apart, the cure for stage 3's burst blocks is untouched.
- *Slower, larger, and the same through a column.* Up to 4.5 m (it was 3.4 m, falling off with
  distance in 3-D to 20 m) over 1.5 s (0.8 s), a little longer away from the firings (+0.3 s at
  25 m); by the distance in plan to the nearest firing over 30 m, so a column swells together
  rather than its top least; easing to nothing over 8 m from the cut's walls, so the crest rises
  as a dome between them; mostly up, 0.3 of it out down the flank, no part of it down.
- *It lets go still rising.* At release a block keeps its swell's velocity and takes half the
  law's launch on top (`ridgeBreak` 0.5), capped at the law's fastest (18 m/s). So the dome goes on
  rising after it lets go, as it breaks apart, and falls back and spills.
- *Rolling resistance on a ridge.* With the rock thrown higher, more blocks rolled on down the
  flanks at 1 to 2 m/s for the rest of the event (4 to 19 over 10 cm in the last second in the
  trials). A clump of spheres has no rolling resistance, so a ridge cut's solver now gives it
  some: the spin of a block held up by contact decays at 2.5 a second (`rollDrag`, a new uniform,
  0 at a face). The face's creep threshold and everything else in the solver are as they were.
- The settings live on `QuarryLaunch` (`ridgeSwell`, `ridgeRise`, `ridgeSwellReach`,
  `ridgeShoulder`, `ridgeCarried`, `ridgeBreak`, `ridgeRollDrag`); `hillsideblast simulate` takes
  `--swell`, `--rise`, `--carried`, `--break` and `--roll` for trying others.
- *Tried and not kept* (each a 20 s run at 100,000 blocks, judged from the poses and from clips):
  5 m over 1.25 s with 0.7 of the law at release threw the crest 11 m up and 14 m at the
  90th percentile, a volcano of loose blocks filling the frame by 4.5 s, and left 9 blocks moving
  in the last second (worst 4.7 m); 4 m and 0.4, and 3.5 m over 1.5 s and 0.5, rose 6 to 7 m but
  without rolling resistance left 7 to 19 moving (worst 2.3 to 5 m); 3.5 m with rolling resistance
  1.5 settled well (one block, 0.38 m) but its dome was hard to see from the opening view, about
  3 m when the dust came; 4.5 m with 1.5 left four moving (2.3 m); 4.5 m with 0.35 of the law rose
  a little less and left two.

**Measured** (release build, M4 Max Studio, 96,987 blocks, the window's and the film's 240 Hz).
- *The heave* (top layer, median height change; in brackets the share risen more than a metre):
  0.16 m at 1.5 s (10%), 1.4 m at 2.1 s (65%), 3.1 m at 2.5 s (89%), 5.3 m at 2.9 s, 6.9 m at
  3.3 s and at most 7.5 m at 3.7 s (the 90th percentile of blocks 8.9 m), back at the old height
  by 4.9 s as the rock falls. As a mass: within each 4 m square of the top layer the spread of the
  rise (interquartile) is 0.11 m at 2.1 s, 0.33 m at 2.5 s and 0.6 m at 2.9 s, against a rise of 3
  to 5 m; the old churn had 0.33 m of spread at 2.5 s with the rock sinking. The crest begins to
  move at about 0.7 s and is seen to rise from about 1.6 s, so the calm ridge is on view for a
  second and a half (it was nearly 2).
- *Stable.* No NaNs in any run. Fastest block 26.3 m/s (28.6 before; the cap at release is the
  law's 18 m/s, the rest is falling). The last second's moves (each block's distance from 19 to 20 s),
  after: worst 1.84 m with one block over 10 cm, and in a second run 1.52 m with two (median and
  99th percentile 0 in both); the same block both times, from the top of the crest by the start's
  wall, rolling at about 1.5 m/s on the start's flank. Before, with main's build on the same
  machine: 1.60 m and two, 0.01 m and none, 2.09 m and two (stage 1's figure: 1.16 m and one). The
  same as before, within run-to-run spread (the solver's sums are not in a fixed order).
- *Physics cost* (`simulate --ridge --blocks 100000 --seconds 20`, GPU time, before and after
  interleaved, other sessions' jobs running beside them in some): a frame of 1/30 s in the event's
  busy stretch (1 to 10 s), median, 41.1 and 41.4 ms before, 49.4 and 50.4 ms after (65.7 and
  69.3 ms in a loaded pair): about a fifth more. The whole 20 s event, 15.9 and 17.4 s of GPU
  before, 17.3 and 18.5 s after (25.6 and 27.5 loaded): 6 to 9% more. More of the rock is moving
  for longer: more than 5% of the blocks awake from 0.67 to 10.5 s, where it was from 1.3 to 7.6 s.
- *The window* (`hillsideblast play --ridge --self-test NAME --offscreen`, before, after, after,
  before) ran while other sessions' GPU jobs ran, and their load swamps the difference: following
  the first firing as it is simulated, playback at 0.51 and 0.31 times real time in the median
  before, 0.49 and 0.46 after; the whole event simulated in 23.9 and 28.1 s before, 20.9 and 20.7 s
  after; work a frame 66.9 and 82.7 ms before, 34.2 and 34.8 ms after (stage 1, on a quiet
  machine: 18 ms and 0.77 times real time). Expect following to be a little slower than before on
  a quiet machine, by the fifth more physics above; not measured quietly.

**Quarry Face unchanged.** A face's blocks carry 0 in `launchSwell.w` and its solver 0 in
`rollDrag`, so neither new term runs for it, and the face's launch is not touched. Stills from the
same face poses (`ridge-heave/face-before/poses`, 110,000 blocks, `render --stills 1.0,3.5,5.9`)
with main's `hillsideblast` and with this one are byte-identical PNGs. The face's simulation itself
cannot be compared byte for byte: two runs of main's own build part at 0.9 s (frame 27), and main's
against this one part at the same frame, by the same amounts after (at 6 s a median block 0.17 m
apart in both pairs, 99th percentile 2.25 m).

**Checked by eye**, before (main's build, its own 20 s run) and after, same camera and times, with
`hillsideblast clip` (the window's own Record Clip from stored poses, frames taken from the movie
files): the opening view held still over 20 s, frames at 1.0, 1.6, 2.0, 2.2, 2.4, 2.6, 2.8, 3.0,
3.3, 3.6, 4.5, 7.0, 12.0 and 19.9 s; *Pull back* over 12 s (frames 0.5 to 11.9 s); and *Pull back*
at quarter speed from 1.2 s (3 s of the event in 12 s of movie). What they show:
- *From the opening view* (94 m), on main the crest's skyline stays where it is and goes ragged
  from 2.0 s, and by 3.3 s the crest is behind the firings' columns. Now the skyline over the cut
  rises from about 2.0 s, by about 2.5 m at 2.4 s and 5 m at 2.8 s, a smooth swelling dome with
  the old surface still on it; at 2.8 s it opens, the dust coming out of it, and at 3.3 s a mound
  of breaking rock stands over the old crest against the sky with the columns beside it rather than
  over it; by 4.5 s it spills down into the notch and the near flank. The end is much as before:
  the notch in the skyline with rock in it and down the near flank (at 7 and 19.9 s, a little more
  rock on the near flank and on top of the far shoulder's pile).
- *In Pull back's close shot* the change is plainest: the crest's top rises into the sky as one
  surface from 1.6 to 2.4 s, then breaks into blocks with the dust venting through, where main's
  was a flat field of loose pieces under the columns. At quarter speed the dome's rise and its
  breaking take about 6 s of movie.
- Files: `$BOMBCAD_DATA/hillside-blast/ridge-heave/`: `before/clips/` (main: `still2.mp4`,
  `pullback2.mp4`, `pullback-quarter.mp4` and their frames) and `after/clips/` (`still.mp4`,
  `pullback.mp4`, `pullback-quarter.mp4` and frames), crops of the crest at the same times in
  `crops/`, the poses in `before/poses` and `after/poses`, the trials in `v1` to `v7`, the cost
  runs in `cost/`, the face check in `face-before/`, `face-stills-main/` and `face-stills-new/`;
  `tools/heave.py` (the heave from a poses file) and `tools/settle.py` (the last second, fastest,
  NaNs and cost from a run).

**Tests.** `QuarryRidgeTests/launch` (BlastModel, Linux) also asks that every released block swell
up over at least the ridge's rise and that most let go still rising at least as fast as they
swelled. `QuarrySimulationTests/ridgeHeaves` (BlastCore, GPU): on the built-in ridge at 20,000
blocks, the top of the rock, watched when its first block lets go, has risen by its median more
than 0.8 m and by its 10th percentile more than 0.3 m among the blocks 0.7 of the way through their
swell; with the carry turned off (`ridgeCarried` 0) it fails, the median at −2.85 m.

**What still looks wrong.**
- *From the opening view the dome is modest until it breaks*: 2 to 3 m of rise on a crest 25 m
  above the cut's floor, 94 m off, is a slow swelling of the skyline that a still barely shows; it
  reads in motion, and best in Pull back. The big rise (5 to 7.5 m) comes as it breaks apart, so
  the most striking moment is a mound of loose rock rather than an intact dome. A larger swell made
  a volcano and threw rock far down the flanks (above).
- *The heave runs along the cut with the firings* (1.8 to 3.3 s, from the far flank over the crest
  to the near one), so it is a travelling bulge, not one dome: the part nearest the camera rises
  last, toward the eye, while the far part is already falling.
- *The firings' dust is still born where the old ground was*, now inside the risen rock: it shows
  as dust venting from the mound, which reads well in the close shot, but a column can also appear
  out of the middle of the breaking rock rather than from its top.
- *The calm ridge before the event is shorter* (about 1.6 s on view, from nearly 2).
- *More rock moving for longer* costs about a fifth more physics a frame while it moves and keeps
  the solver busy to about 10.5 s; the window's following of a firing is correspondingly slower.
- One block still rolls at the end, as before.
- Not looked at on a screen: all of it was made offscreen.

## Stage 3b: flanks that read as ground, 12 November 2026

emmettl/bombcad-work#135, approved by the user on 12 November. Same standing: illustrative, for the
eye. Everything here is render-only and procedural, chosen by eye: no third-party assets, nothing
reaches the solver, and the ground cover is no survey of any real hillside. This stage changes none
of the cut, its blocks, the firings, the launch (stage 3a's, which landed beside it) or the dust; it
was made and checked on the stored stage 1 poses, from before stage 3a's heave.

**What was wrong.** Stage 1 paved the ridge with the face's render-only bedded cells from its crest
down to about the cut's floor, and on the steepest ground below. Each cell was clipped to the
slope's tangent planes a few decimetres above the ground, so the paving was flagstones lying on the
slope, with the ground showing through wherever a cell of a recessed bed dipped below it. From
stage 2b's view, 94 m off, that paving filled the lower left of the frame and read as cut-outs;
below it the flanks were plain tan ground with scattered slabs.

**What a user gets.** The ridge outside the cut is now grassy ground with crags. Dry grass and low
scrub cover the gentler slopes and the crest; bedded ledges of the harder beds stand out of the
steeper slopes in broken clusters; scree lies in fans below the ledges and below the rock round the
cut; and the ground's gravel, tussocks and soil keep their detail down to a few centimetres a
pixel. Dense rock is only the cut's and a ragged margin round it, so before the blast the cut still
sits in rock. The far plain, through the notch and round the ridge, is patchy grassland with
paler bare ground and darker scrub rather than one flat pale colour.

**How** (`QuarryFlank`, BlastModel; `ridgeTerrainFragment` and `flankStone*`, BlastRender).
- *A cover map.* On a 1 m grid over the dressing's area (440 by 341 m round the cut), from the ground
  after the cut: the cut (where the old ground stands 0.3 m above it), the distance from it, and the
  slope. Built in about 0.03 s, by the dressing's thread and again by each renderer.
- *Dense rock* (`paving`): the cut and a margin 2.5 to 7.5 m wide round it (its edge wandering by
  noise), down to 3 m below the floor. The face's dressing code places its cells only there now,
  and they dip under the ground over the margin's last 3 m (their tangent clip lowered by up to
  0.9 m), so the rock ends by going under the ground rather than in slabs standing proud of it. The
  steep ground behind the rock is set back as before, but only inside the dense rock, tapering over
  its last 3 m (it was set back 1.8 m wherever the ground was steeper than about 37°).
- *Ledges.* Where the ground going uphill crosses the top of a bed that crops out (every limestone
  bed, half the sandstone and ironstone beds by a hash of the bed's index, never shale), on slopes
  steeper than 0.3 and inside clusters of noise about 34 m across, broken into runs by finer noise,
  one ledge every 3.2 m or so along its bed. Each is a slab of its bed standing out of the slope on
  its downhill side: its top the bed's top (tilted and lowered a little each), its front 1.2 to 3.2 m
  downhill from where the bed meets the ground (no further than keeps its front about as tall as the
  bed is thick), leaning back or overhanging a little, reaching down 1.2 m below the bed so it never
  stands on its underside, cut from its neighbours along the bed by tight joints (a quarter of them
  open a few decimetres), its top front edge worn round, tessellated and displaced like the
  dressing. 660 ledges on the built-in ridge's default cut, 11,800 triangles in the window.
- *Scree.* Sources at each ledge's front, below the dense rock and, weakly, on ground steeper than
  0.7; spread a little across the slope, then carried down it, each texel taking the largest source
  up to 14 m uphill along the slope's gradient, fading over 2 m on gentle ground and 8 m on steep,
  streaked by noise.
- *Grass* on ground gentler than about 0.35 to 0.85, away from scree and rock, in patches.
- *Stones and scrub.* About 3.5 stones a square metre where the scree is full, sized from 9 cm on
  a power law to 1.1 m, larger at a fan's thin toe (where the large ones roll to), each turned to
  the ground and sunk into it; scrub in clumps on the grass, each two or three rounded masses 0.5 to
  1.4 m across. Drawn as instances of the chips' 32 stone shapes (read only, from
  `QuarryChipShapes`) in the shadow pass and the scene: about 16,000 on the default cut. Stones are
  the beds' weathered colours with lichen; scrub is dark olive and brown, lit as a rounded mass of
  leaves.
- *The ground's shading* (`ridgeTerrainFragment`, a separate fragment function for a ridge cut, so
  the face's `terrainFragment` is not touched). Soil, grass, scree and rock mixed by the cover map,
  its 1 m texels broken up by noise. Scree is gravel and grit streaked down the slope with packed
  stones at two sizes (domed, darker in the crevices); grass is tussocks with soil between and
  blades as speckle; soil carries grit, mottling and fine gravel. The fine detail fades with the
  pixel's footprint (from 3 to 11 cm), so it does not shimmer. Past the map the far ground's own
  cover: grass in broad patches, paler bare ground, darker scrub, a little scree on steeper slopes.

**Measured** (release build, M4 Max Studio; the GPU was shared with two other sessions' checks and
self-tests throughout, so every timing here is loaded and noisy, and stage 2b's quiet 21.6 to 24.1
ms a clip frame is not comparable).
- *Geometry.* The window's dressing for the default cut: 3,510,747 triangles before, 443,259 of dense
  rock and 11,755 of ledges after (82,320 cells to 11,517, and 660 ledges); 16,107 stones and scrub
  of up to 12 triangles each, drawn in the shadow pass and the scene (at most 0.19 M triangles a
  pass). The cover map and the stones are built in 0.03 to 0.04 s.
- *The window's Record Clip* of the default view from the stored poses (`hillsideblast clip`, 600
  frames at 1920 x 1080, before and after in turn, three times each): 36.3, 39.4, 35.8 ms a frame
  median before; 36.8, 33.2, 33.2 ms after.
- *The window's own session* (`play --ridge --self-test NAME --offscreen`, two runs each,
  interleaved): playing a stored event 27.0 and 30.5 ms of work a frame before, 44.4 and 24.3 after;
  following the first firing 52.1 and 69.9 before, 48.6 and 33.9 after. These swung by a factor of
  two between runs of the same build with the other jobs, so they say only that nothing grew by
  much; the clip pairs above are the steadier measure.
- *Memory*, the same self-tests: Metal allocated 932 MB before, 724 MB after, at the first firing
  (the dressing's buffers); footprint after the first firing 3.62 and 3.77 GB before, 3.07 and 3.06
  GB after.

**Quarry Face unchanged.** A face has no `QuarryFlank`, so its dressing, its ground's mesh, its
pipelines' functions and its draws are as they were (the ridge's ground is a separate fragment
function; the stones are drawn only when there are some). Stills from the face poses of stage 1's
check (`ridge/facecheck/poses`, `render --blocks 110000 --stills 1.0,3.5,5.9`), and frames at 1.0
and 3.5 s taken from a clip made by the window's recorder on the same poses (`clip --blocks
110000`), are byte-identical between main's build and this one.

**Checked by eye**, on the stored stage 1 poses (`ridge/final/poses`), with the window's recorder
(`hillsideblast clip`) and frames taken from the movie files: the default view held still, 20 s,
frames at 1, 2.6, 4.5, 7, 12 and 19.9 s; the pull-back over 12 s, frames at 0.5, 2.2, 4, 6.5, 8 and
11.9 s; and three other cameras at 1 s and the end of the event: close on the near flank (focus
(112, -42, 18), 38 m, yaw 1.1, pitch 0.25), a wide view from 260 m and pitch 0.22, and the default
view. Before and after at the same cameras and times. Files under
`$BOMBCAD_DATA/hillside-blast/ridge-flanks/`: `before/` and `after/` (`still.mp4`, `pullback.mp4`
and their frames), `quick-before/` and `after-quick/` (the other cameras), `face-before/`,
`face-after/`, `faceclip-before/`, `faceclip-after/`; the steps on the way in `try1/` to `try4/`.
The tools are in `$BOMBCAD_DATA/ridge-flanks-tools/`.
- *What they show.* From the default view the lower left, which was flagstones with olive ground in
  their gaps, is now a slope of grey scree with ledges standing out of it, under a grassy crest
  with scrub on its skyline; the rock round the cut now ends by going under the scree rather than
  in slabs. In the wide view the ridge reads as a grassy ridge with crags and grey talus fans below
  them on its steep flank, the cut's rocky margin, and the tongue of broken rock running out onto
  the grass. Through the notch, and from the wide view, the plain is patchy dry grassland. Close
  in, the grass is tussocks with soil between and the scree gravel and stones, without shimmer.

**The look, frankly.**
- *The ledges are boxy.* Each is a slab of one bed with a flat top and a near-vertical front, so a
  run of them reads as a row of squared blocks, a little like a ruined wall, more than as bedrock
  breaking through the ground; they carry the dressing's weathered face, whose large dark blotches
  (the shared block shading, emmettl/bombcad-work#136's) are as strong on them as on the crest.
  Real outcrops would want rounder, more uneven tops, partly under soil and grass, and fallen
  blocks below them.
- *Scree aprons have straight edges* in places: they follow the 1 m map, the march down the slope
  and the ledges' rows, so some fans are strips with soft but straight sides.
- *The near flank is more scree than grass* in the default view: it is the steep flank below the
  rock round the cut, which feeds scree all the way down. That is plausible below a crag, but it
  leaves the frame's lower left grey.
- *The stones are small and few* against the shaded gravel (16,000 over the whole area), and the
  scrub is single dark lumps from the chips' hull shapes; at the default distance both read as
  texture, not as things.
- *The dense rock round the cut* is still the stage 1 paving close up, and the cut's own surface
  before the blast is the blocks' (unchanged); the pull-back's opening shot is all blocks.
- *A thin pale line* still crosses the far plain in the wide view, several hundred metres out; it
  was there before this stage. Fading the shadow map's edge was tried and did not move it, so it is
  more likely where the 3 m ground meets the skirt beyond it; not traced.
- Not looked at on a screen: all of it was made offscreen.

**Tests.** `QuarryFlankTests` (BlastModel, Linux): a face has no flanks, and a ridge cut's dense rock
is the cut and its margin, with no grass in it; ledges crop out clear of it, on slopes, in beds that
are not shale, on the ground, and each becomes rock; scree lies below the ledges more than on open
gentle ground, and grass on the gentle ground; stones and scrub lie on the ground outside the rock,
the same each time, fewer at a smaller scale.

## Stage 3c: close-up rock, 12 November 2026

emmettl/bombcad-work#136, on the user's word of 12 November. Same standing: illustrative, for the eye.
The cause, the changes (shared with the Quarry Face) and the measurements are in
[hillside-blast.md](hillside-blast.md#stage-3c-close-up-rock-and-rock-that-is-whole-until-it-breaks-12-november-2026);
this is what they did to the ridge cut.

- *The Pull back's opening.* The scattered paper-thin shards over the crest at 2.2 to 2.6 s were the
  decorative chips: every block's chips, buried ones too, were set on the surface as soon as their
  blocks let go, and many were as large as the ridge's small blocks and a fifth as thick as long. Now
  a few small chunky stones fly off the top of the breaking crest, and the blocks lifting and turning
  read as blocks. The crest before the first firing (0.5 and 1 s) is one weathered surface, banded by
  its beds, where it was a mosaic of cells, each in its own tint, spotted dark blue by the bump.
- *From the default view* at 1 s the crest of the cut is smooth banded rock with ledges; at 4.5 s the
  tongue and the notch are much as before; at 12 and 19.9 s the pile is as before.
- *The rock itself:* 96,386 blocks against 96,987, the same sizes and shapes; the cut's cells are no
  longer stood back by a random amount of their own, so the crest's surface is one surface.
- *What still looks wrong.* In the default view the crest's left part beyond the cut is the
  render-only dressing, which still shows its cells and grass between them (emmettl/bombcad-work#135
  is replacing it). In the Pull back's close shot the crest's surface is a little plain before it
  breaks: banded and smooth, with less small relief than real weathered rock. The ridge's pieces are
  still small (0.57 m median), so the broken crest is a field of small blocks.
- *With stage 3a's heave* (landed beside this, emmettl/bombcad-work#134), in `final/`: the crest
  lifts as one weathered mass at 2.2 to 2.6 s, then splits into blocks along the cells as it rises,
  and at 3.2 s the close shot is full of solid blocks tumbling; no sheet-like shards.
- Files: `$BOMBCAD_DATA/hillside-blast/rock-closeup/` (`before/ridge-*`, `after/ridge-*` on stage 2b's
  launch, `final/ridge-*` on stage 3a's, and the debug renders `debug1/` and `debug2/` from the Pull
  back).
