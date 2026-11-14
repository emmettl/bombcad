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

**12 November 2026, dust and rubble** (emmettl/bombcad-work#137): the ridge's dust now starts as the
crest heaves (puffs off the heaving rock, twice the face's), and the rubble that fell as a curtain
into the notch now rides the rock it lands on. Details and numbers in
[hillside-blast.md](hillside-blast.md), "The dust from the first motion, and rubble that rides the
rock".

## Stage 3d: flanks that look like a hillside, 13 November 2026

emmettl/bombcad-work#138, on the user's word of 13 November ("keep working through the defects until
it looks strong"). Same standing as stage 3b: illustrative, for the eye; all of it is render-only and
procedural, chosen by eye, with no third-party assets; nothing reaches the solver. The cut, its
blocks, the firings, the launch and the dust are unchanged. Made and checked on stage 3c's stored
ridge poses (`rock-closeup/final-ridge-poses`, stage 3a's heave and 3c's rock).

**What was wrong** (stage 3b's own list, and the frames). The ledges were boxy: each a slab of one bed
with a flat top and a near-vertical front, so a run of them read as squared blocks or a ruined wall.
Some scree fans had straight, soft sides along the 1 m cover map. In the default view the near flank
below the rock round the cut was mostly grey scree. The stones were small and few against the gravel
texture, and the scrub was single dark lumps, so both read as texture. A thin pale line crossed the
far plain several hundred metres out. And (from stage 3c) the render-only rock round the cut, the
left part of the crest in the default view, still showed its cells and the ground between them,
where the cut's own held rock had become one surface.

**What a user gets.**
- *Outcrops.* Each run of ledges along a bed (`QuarryFlank.ledgeRuns`: ledges of one bed within
  7.5 m of each other along it, walked from one end) is one outcrop (`QuarryFace.outcrop`): a
  weathered layer of its bed swept along the run, its top the bed's top following the dip, worn
  unevenly and stepped where a lamina has come away, its nose rounded a little, its front in three
  tiers that stand out or are undercut along the run with a notch at each parting, broken across
  every 1.1 to 3.2 m by narrow joints, the blocks between them each standing out or set back by up
  to half a metre and some with their top lamina gone. It sinks under the ground at its ends and in
  gaps along it, and is buried at its back and its foot. 660 ledges make 170,184 triangles of
  outcrop. They are shaded by their own fragment function (`ledgeVertex`, `ledgeFragment`), not the
  blocks' shader: the bed's weathered colour paled toward grey, partings along the bed, streaks down
  the front, lichen, turf on the top in patches, soil and scree banked against the foot up to a
  wandering line (each vertex carries its height above the ground), and the joints dark.
- *Scree in fans.* Below the rock round the cut, scree comes only in fans, a lobe here and there
  along its edge (noise about 11 m across), and from the steepest ground only within them; below the
  outcrops only some of them shed scree. A fan widens the further it runs and its toe reaches on or
  stops short by noise, and the ground's shader reads the grass and scree a couple of metres off by
  noise, so the edges come in lobes and tongues. Grass holds on slopes up to about 0.7, thinning to
  none at 1.3 (it gave out from 0.35 to 0.85), so the near flank is grass with scree in its fans.
- *Stones and bushes.* Stones lie in groups (a larger one with one to four smaller ones round it),
  denser in clusters a few metres across, from 10 cm to boulders of 1.5 m at the fans' toes, a few
  half-buried in the grass, and blocks of 0.4 to 1.2 m fallen below about half the ledges. Each is an
  icosahedron of its own (`QuarryFlank.stoneShape`), turned its own way, its corners pulled in or
  left out, stretched to its own proportions and flat underneath, in the beds' weathered colours.
  Bushes are four to seven rounded, lumpy lobes about a low dome (`QuarryFlank.lobeShape`, 80
  triangles), each bush dark olive, grey-green, brownish or a little rusty, each lobe lighter or
  darker, lit as a ball of leaves with gaps; they are bigger and clumped.
- *Rock round the cut, whole.* The dense render-only rock's cells are clipped to one surface (the
  ground stood 0.35 m proud, back by each bed's weathering eased across beds, and sunk toward the
  rock's edge, bilinear) and their outer faces laid on it (`tessellate`'s `outer`, from stage 3c), so
  it reads as one weathered surface like the cut's held rock rather than a mosaic of cells; until now
  each cell stood back a random amount of its own.
- *No pale line on the far plain.* It was the sky through a gap: the skirt round the 3 m ground was a
  frame of four flat quads from a ring one row in, at the edge's mean height less a metre, and where
  the ground's edge stood lower than that the gap between them showed. The skirt is now joined to the
  3 m ground's own outermost vertices, out to 2.5 km.

**Measured** (release build, M4 Max Studio; main's build `12f84d89`, with stage 3c's rock and
emmettl/bombcad-work#137's dust and rubble, before, and this one on it after; the GPU was quiet for
the timings below).
- *Geometry* in the window's dressing, each drawn in the shadow pass and the scene: dense rock
  443,259 triangles before (stage 3b's count; the layout is the same), 419,197 after; ledges 11,755
  (in the dressing) before, outcrops 170,184 after; stones and scrub 16,107 instances of 12 triangles (193,284) before, 11,861 stones of 20
  (237,220) and 6,336 bushes' lobes of 80 (506,880) after. In all 0.65 M triangles a pass before,
  1.33 M after. The cover map, stones and bushes are built in 0.03 to 0.09 s.
- *The window's Record Clip* of the default view, 600 frames at 1920 x 1080 from the stored poses,
  before and after in turn three times: 21.5, 21.6, 21.5 ms a frame median before; 22.5, 22.4, 22.3
  after: 0.9 ms (4%) more, against a spread of 0.2 ms within each. (Earlier, on `40bf437a` with the
  GPU shared: 25.6, 24.4, 24.2 before and 26.2, 25.6, 25.5 after.) The other clips of the check
  moved alike: the Pull back 21.7 to 22.2 ms, the close view 21.1 to 22.1, the wide view 22.5 to
  23.6.

**Quarry Face unchanged.** A face has no flanks, outcrops, stones or bushes, and its dressing is built
as before (the continuous surface is a ridge cut's only); its skirt is the old one. Stills from face
poses simulated with main's build (`ridge-flanks-2/face-poses`; `render --blocks 110000 --stills
1.0,3.5,5.9`) and frames at 1.0 and 3.5 s from a clip by the window's recorder on the same poses are
byte-identical between main's build and this one, both on `40bf437a` and on `12f84d89`.

**Checked by eye**, with the window's recorder (`hillsideblast clip`) and frames from the movie files,
before and after at the same cameras and times: the default view held still for 20 s (frames at 0.5,
1, 2.6, 4.5, 7, 12 and 19.9 s), the Pull back over 12 s (0.5, 2.2, 4, 6.5, 8, 11.9 s), a close view
of the near flank (focus (112, -42, 18), 38 m, yaw 1.1, pitch 0.25) and a wide view (260 m, pitch
0.22), each before the first firing and at the end. Files under
`$BOMBCAD_DATA/hillside-blast/ridge-flanks-2/`: `before/` and `after/` (on `12f84d89`), `before-40bf/`
and `after-40bf/` (the same on `40bf437a`, before emmettl/bombcad-work#137 landed), the steps on the
way in `try1/` to `try6/`, the Quarry Face check in `face-*` and `faceclip-*`, and the scripts in `tools/`.
- *Default view.* The left of the crest beyond the cut is smooth banded rock continuous with the cut's
  where it was a mosaic of cells; the near flank below it is dry grass with one scree fan and stones
  scattered down it; outcrops stand out of the lower left as stepped, jointed layers with turf on
  them and soil at their feet; bushes sit on the skyline and the slope.
- *Close in*, the outcrops are jointed blocks of their bed in tiers, each block its own, with stones
  and fallen blocks below them; stones are chunky and lie in groups; bushes are lumpy masses of a few
  lobes.
- *Wide*, the ridge is grassland with crags in clusters, bushes clumped, scree in lobed fans, the
  rock round the cut whole; the far plain has no line.

**The look, frankly.**
- The outcrops are much better than boxes but not yet convincing bedrock from close in: the tiers
  run the length of a run like courses, so a run can still read as stacked, rounded bales; short
  runs that curve sharply bend into odd crescents; and they are pale and evenly lit, with the same
  dark mottling on their tops under the low sun as the cut's rock (the shadow and occlusion,
  shared). From the default distance they read as stepped, jointed rock with turf on it.
- The stones are faceted (20 triangles each) and can look like gems close in; the bushes are dark and
  read as bushes from close and middle distance, as dark dots far off.
- The outcrops are all of the harder beds and all about a bed thick; there are no larger crags or
  cliffs on the flanks.
- The cost doubles the dressing's triangles; clip frames are a few per cent slower. Half of the new
  triangles are the bushes' lobes, which could take a 20-triangle shape if that matters.
- Not looked at on a screen: all of it was made offscreen.

**Tests.** `QuarryFlankTests` (BlastModel, Linux): ledges fall into runs along their beds, each ledge
in one run; the runs become outcrops of their own, not dressing, buried at their backs and feet and
never more than a few metres proud of the ground; stones come before bushes' lobes, which stand on
grass; grass holds on all but the steepest ground.

## Stage 3g: outcrops, stones and crags that hold up close in, 13 November 2026

emmettl/bombcad-work#141, on the user's word of 13 November ("keep working through the defects until
it looks strong"). Same standing as stages 3b and 3d: illustrative, for the eye; all of it is
render-only and procedural, chosen by eye, with no third-party assets; nothing reaches the solver. The
cut, its blocks, the firings, the launch, the dust, the block shader and the shared shadow and
occlusion are unchanged. Made and checked on stage 3c's stored ridge poses
(`rock-closeup/final-ridge-poses`).

**What was wrong** (stage 3d's own list, and the orchestrator's look at its frames). Close in the
outcrops read as stacked, rounded bales or sandbags: their tiers ran the whole length of a run like
courses of masonry, a decimetre of smooth wear along the normal swelled them into pillows, and short
runs that turned sharply bent into crescents. The stones were faceted, 20 flat-shaded triangles each,
and looked like gems. The bushes showed only as dark dots in the wide view. Every outcrop was about
one bed thick; there were no larger crags. And the outcrops were pale and evenly lit, mottled on top
by the shared shadow and occlusion under the low sun.

**What a user gets.**
- *Outcrops that come and go* (`QuarryFace.outcropMesh`, which now builds both). A run's bed is one
  to three layers where its laminae have parted, swept along a line through its ledges that is eased,
  and laid straight for a run under 9 m, so it no longer bends into a crescent. Each layer is broken by
  joints (most through every layer) into blocks of its own: a block's front stands out or back, square
  or skew to the run with a kink along it, its corners broken back, its top dropped where a lamina has
  gone, its face bulging or hollowed half way down; now and then one has fallen away and left a bay.
  Over about a third of the top layer's blocks that layer, and sometimes the next, is gone, so the
  top steps down a layer; a parting between layers is closed over some blocks (one face) and open over others; a
  layer weathers back along stretches of its own, so the tiers come and go, the layers above overhang
  it, and its front leans back or is undercut. The partings wander up and down along the run, every
  point is moved a little by noise in all three directions, so the edges wander and the faces are
  uneven planes, and the wear along the normal is a few centimetres, not a decimetre. Nothing stands
  above the ground uphill of where the top meets it.
- *Crags* (`QuarryFlank.crags`, `QuarryFace.crag`). Up to six, 60 m apart, where the slope over 9 m
  is steeper than 0.6 and steady, at least 30 m from the cut and from the opening view's lines from
  the eye to what it looks at and to the crest either side of the cut (in plan), and wholly on the map
  clear of the dense rock. Each is its top hard bed and as many beds below as make it 5 to 9 m high,
  22 to 40 m along the slope, its foot 3 to 14 m downhill of its top; shale is weathered back under
  the harder beds, a thick hard bed parts in two, and the upper beds run out before the lower ones so
  its ends step down. Its top carries turf, scree falls in fans from most of its foot, and blocks of
  0.45 to 2.4 m lie below it. The ground under it and round it has no ledges, stones or bushes. The
  built-in ridge's default cut gets three: on the near flank 40 m wide (5 beds), and two on the far
  flank, 27 and 23 m (5 and 7 beds).
- *Their own shading and light* (`ledgeFragment`, its own; not `shade`, `shadowAt` or the blocks'
  shader). Close in, the facets' own planes, so edges read broken; the bed's weathered colour, greyed,
  each outcrop and layer its own tone; a few wandering, broken partings rather than ruled lines; dark
  water stains down the fronts; on the tops lichen in patches and rosettes (grey-green, a few yellow)
  and dark crusts; turf in patches, more on a crag's top; soil and scree banked at the foot. Its own
  light: the sun through its own shadow lookup (pushed out along the normal and toward the sun, 16
  taps over a wider footprint), sky light that falls off under overhangs, in partings and joints and
  toward the foot, and warm light thrown up from the ground; a gentler bump. The screen-space
  occlusion pass still runs over it, as over everything.
- *Stones.* Corners pulled in less, and shaded by their stretched shape's smooth normal with a fifth of
  the facets (a block's nearly half), with grain, lichen, dark spots and a soil stain at the foot. The
  stones of 0.45 m and more (about a fifth) are drawn with the 80-triangle sphere (`roundStoneVertex`),
  shaped as a function of direction alone, so the normal is the shape's own: rounded and a little
  lumpy, cut by five flat fracture faces of its own, flat underneath, and a fallen block squared off.
  Blocks fallen from outcrops and crags are mostly angular (`Stone.look.w`).
- *Bushes in the wide view.* Far off, where a leaf is under a pixel, the leaves, gaps and normal
  jitter give way to their mean and a lobe is lit as a ball with its sunlit crown a little paler, so a
  bush reads as a lit, rounded shrub; the colours are a little lighter; one in seven is 1.6 times as
  wide.

**Measured** (release build, M4 Max Studio; main's build `bd99abab` before, this one after).
- *Geometry*, each drawn in the shadow pass and the scene: dense rock 419,197 triangles before and
  after; outcrops 170,184 (660 ledges) before, 180,636 after (582 ledges and 3 crags); stones 11,861 of
  20 triangles (237,220) before, 8,515 of 20 and 2,335 of 80 (357,100) after; bushes' lobes 6,336
  (506,880) before, 6,311 (504,880) after. In all 1.33 M triangles a pass before, 1.46 M after. Built
  in 0.03 s as before.
- *The window's Record Clip* of the default view, 600 frames at 1920 x 1080 from the stored poses,
  before and after in turn three times: 22.5, 22.4, 22.4 ms a frame median before; 22.6, 22.6, 22.6
  after: 0.2 ms (1%) more, against a spread of 0.1 ms within each.

**Quarry Face unchanged.** A face has no flanks, outcrops, crags, stones or bushes; its draws are as
before (the new pipelines are made but nothing is drawn with them). Stills from face poses
(`ridge-flanks-2/face-poses`; `render --blocks 110000 --stills 1.0,3.5,5.9`) and frames at 1.0 and
3.5 s from a clip by the window's recorder on the same poses are byte-identical between main's build
and this one.

**Checked by eye**, with the window's recorder (`hillsideblast clip`) and frames from the movie files,
before and after at the same cameras and times: the default view held still for 20 s (0.5, 1, 2.6,
4.5, 7, 12, 19.9 s), the Pull back (0.5, 2.2, 4, 6.5, 8, 11.9 s), the near flank close (focus (112,
-42, 18), 38 m, yaw 1.1, pitch 0.25) and the wide view (260 m, pitch 0.22) at 1 s and the end, and
three new ones at 1 s: the near-flank crag (focus (104, -119, 19), 55 m, yaw 1.3, pitch 0.1), the
same close (focus (104, -122, 19), 26 m, yaw 1.75, pitch 0.06) and an outcrop close (focus (100, -36,
22), 14 m, yaw 0.9, pitch 0.12). Files under `$BOMBCAD_DATA/hillside-blast/ridge-crags/`: `before/`
and `after/`, the steps on the way in `try1/` to `try8/`, the Quarry Face check in `face-*` and
`faceclip-*`, the timings in `perf-*`, and the scripts in `tools/`.
- *Crag.* From in front it reads as a small jointed limestone cliff: turf on its top, faces in a few
  beds with the partings closed in places and open in others, blocks standing out or set back, an
  overhang, its ends stepping down, scree and fallen blocks below.
- *Near flank close.* The outcrops are jointed blocks of their beds, uneven in height, some stepped
  down, some fallen away, with broken edges, rather than rows of bales; the stones are weathered
  stones, round or blocky, not gems.
- *Wide.* The crag on the near flank shows as a turf-topped band of rock; the bushes read as small lit
  shrubs, a few larger.

**The look, frankly.**
- Close in, some outcrops are still regular: blocks with near-square corners in tidy rows can read as
  masonry or crates from above, and a few short runs leave thin flat slivers where they sink into the
  ground at their ends. The faces are still fairly smooth between their facets; real rock has more
  relief at a hand's breadth.
- The far flank's crags, seen from the side in the wide view, read as a stack of plates: their ends
  step down a bed at a time, cut square.
- The crags are only three on the built-in ridge (the rest of its steep, steady ground is within 30 m
  of the cut or the view's lines); a gentler ridge may have none.
- A few fallen blocks are long and thin enough to look like blades on end.
- The screen-space occlusion still darkens the outcrops' tops a little in patches; only the shadow
  lookup is their own.
- Not looked at on a screen: all of it was made offscreen.

**Tests.** `QuarryFlankTests` (BlastModel, Linux): crags lie clear of the cut, the opening view's line
and each other, of at least two beds, with no ledges on their ground; they are made into outcrops
after the ledges' (a tag bit marks them), standing 3 to 14 m proud of the ground, with fallen blocks
below; small stones come before large ones.

## Stage 3e: rock that looks strong, 13 November 2026

emmettl/bombcad-work#139, on the user's word of 13 November. Same standing: illustrative, for the eye.
The changes (shared with the Quarry Face) and the cost are in
[hillside-blast.md](hillside-blast.md#stage-3e-rock-that-looks-strong-13-november-2026); this is what
they do to the ridge cut, and the piece-size study.

- *The crest before it breaks.* The held skin covers the cut's rock (0.11 M triangles in the window,
  0.32 M for the film) and goes block by block as the swell lifts the blocks. The weathered surface
  now has joints that wander and die out with dark open cracks, knobs and hollows, laminae stepped
  off the harder beds' tops, pits, lichen and crusts: in the Pull back's close shot at 0.5 and 1 s the
  crest reads as jointed limestone pavement rather than banded smooth slabs.
- *The rock round the cut* (#138's render-only rock, laid on one surface since then) takes the same
  relief and shading, so it and the cut's crest match: in the default view at 1 s both are jointed
  weathered rock.
- *What still looks wrong.* From the default view the two joint sets on the crest's flat tops read
  as a fairly regular grid, like a limestone pavement's, which is natural but a little tidy; the
  shale bands' fine laminations show as thin lines close in.
- Files: `$BOMBCAD_DATA/hillside-blast/rock-strong/` (`before/ridge-*` and `final/ridge-*` from the
  same poses, `ridge-poses`; the piece-size runs `ridge*k-poses` and their clips `size*/`).
- *Piece size* (below): the scene's default block size and count are unchanged; a proposal for the
  user.

**Piece size: a proposal, not changed.** The ridge's pieces are small (median 0.57 m), so the broken
crest reads as a field of small blocks. Tried with `hillsideblast simulate --ridge --blocks N
[--fracture S]` (main's solver, 20 s at 240 Hz; `--fracture` scales how much the bedding and joints cut
the coarse cells, `QuarryFace.Options.fractureScale`, 1 as the scene is):

| asked | blocks | median / 90% / largest (m) | spheres | physics a frame while awake, median / p90 (ms) | last second: worst move, over 10 cm |
|---|---|---|---|---|---|
| 100,000 (default) | 96,386 | 0.57 / 1.01 / 2.46 | 524,956 | 37.8 / 70.6 | 1.47 m, 2 |
| 70,000 | 75,369 | 0.61 / 1.10 / 2.54 | 411,848 | 26.5 / 43.3 | 0.00 m, 0 |
| 50,000 | 59,820 | 0.65 / 1.20 / 2.73 | 327,040 | 19.7 / 32.1 | 0.01 m, 0 |
| 30,000 | 42,338 | 0.71 / 1.35 / 2.83 | 230,157 | 12.9 / 20.5 | 0.29 m, 2 |
| 30,000, fracture 0.5 | 31,259 | 0.82 / 1.49 / 2.86 | 175,368 | 10.4 / 16.4 | 0.03 m, 0 |

No NaNs in any. Asking for fewer blocks alone changes the size slowly (the cut's coarse cells are
capped by its volume, and the bedding and joints cut each cell much the same), so the pieces stay
small; halving the fracture as well gives pieces 44% larger at the median and a third of the blocks
and spheres. In the Pull back at 2.6 and 3.2 s the crest then breaks into broad slabs and blocks a
metre or two across rather than a carpet of small ones, and the pile at 19.9 s is coarser
(`size30kf05/`, against `before/`; `size50k/`, `size30k/` the others). Physics while the rock moves
falls by about 3.6 times (the Studio was loaded; GPU medians while more than 5% are awake), and the
event settles as well. **What it would take:** for a ridge cut only, the window's and the clip's
block count 100,000 to 30,000 and `fractureScale` 0.5 (two lines where the session's options are
made, with the face unchanged), and a check that the heave (#134's swell, carried and released by
block) still reads with fewer, larger blocks; it did in these clips. Left for the user's word.

## Stage 3f: dust and heave that look strong, 13 November 2026

emmettl/bombcad-work#140, on the user's word of 13 November ("keep working through the defects
until it looks strong"). Same standing: illustrative, a stylised heave and its dust for the eye;
nothing here is how real rock heaves, a load, a blast design or a claim about fragments or their
reach. It follows stage 3a's heave (emmettl/bombcad-work#134) and the dust from the first motion
(emmettl/bombcad-work#137), and takes up what they left. It was made and checked before stages
3d and 3g (the flanks and crags, emmettl/bombcad-work#138 and emmettl/bombcad-work#141) landed,
so the flanks in its frames are stage 3b's; it changes none of theirs.

**What was wrong.**
- *The firings' dust started inside the rock.* Each column was born within 9 m above or below the
  old ground over its firing; by the firings the heave had lifted the crest 3 to 7 m, so most of a
  column started inside the risen rock and came out of the middle of the breaking mound.
- *The heave's puffs were fog.* Every exposed block puffed dust over the first third of its swell,
  so at the window's 1.5 m cells the crest wore soft separate blobs that lay on it like patchy fog
  and hid the dome (13 to 22% of the window's frame from 1.6 to 3.2 s, most of it on the rock).
- *A small dome that ran along the cut.* Each block's swell ended at its own release, so the heave
  followed the firings from the far flank to the near one: at the first firing (1.8 s) the top of
  the rock had risen 0.5 m in the median, at 2.4 s it stood 7.4 m at the far end of the cut and
  0.5 m at the near one (`tools/dome.py`, below), and the crest's skyline rose only 2 to 3 m
  before it broke.

**What changed.**
- *One dome* (`QuarryLaunch.applyRidge`, BlastModel; `integrate`, `QuarrySolver.metal`). Every
  ridge block's swell now starts together, `ridgeRise` (1.5 s) before the first firing, and ramps
  up over the same 1.5 s; after it, a block not yet let go keeps rising at a speed that eases off
  with a time constant of 0.3 of the ramp (`ridgeHold`), still carried, so it waits near the dome's
  top until its firing breaks it. Its swell is in proportion to the depth of rock over the floor
  where it stands (`ridgeDome`), so the dome peaks over the crest and dies out toward the cut's
  ends, and eases to nothing toward the walls as before. `ridgeSwell`, now the swell's whole reach
  over the deepest rock, is 10 m (it was 4.5 m over each block's own swell). The release is as
  stage 3a's (the swell's velocity at that moment, with half the law's launch on top), so a block
  let go late, its swell eased off, breaks away more gently: the dome slumps and spills rather than
  being thrown up. The solver tells the dome's profile by `spinRise.w`, which carries minus the
  ramp for a ridge's blocks (a face's carries a positive value the solver never read), and the
  ease's time constant is a new uniform, `heaveHold`, 0 at a face; the face's swell takes the old
  branch unchanged. `ridgeTogether` false gives back stage 3a's heave, and `hillsideblast simulate`
  takes `--hold`, `--dome` and `--travelling` beside stage 3a's options.
- *Dust from the rock's cracks* (`QuarryDustField`, a ridge cut only; the face's sources are as
  they were). The heaving rock no longer puffs over its whole top. A few blocks of its top (2% at
  first, up to 8% as the dome rises, by a fixed draw a block) are cracks: each gives a thin hot jet
  from just above its top, rising 9 m/s faster than the rock under it, in proportion to how fast
  the rock rises, and the first quarter of them spurt as the rock starts to move, so the dust still
  starts with the first motion. A block's puff as it lets go now bursts up from its top (6 m/s up)
  rather than from its middle.
- *Dust that comes out of the breaking mass.* Half of the exposed blocks, at twice the rate, shed
  dust for 1.5 s after they let go, carried at 0.7 of their velocity, so the cloud pours out of the
  breaking rock and follows it down the flank instead of being left where the dome was. (Shedding
  from every block gave the same cloud for 0.4 ms more of the step.)
- *Columns from the rock's top.* Each firing's column is born on the rock as it now stands over
  the firing (the highest moving block's top within 2 m columns round it, mapped only while a
  column is fed) or the old ground if higher, and only above it; most of its dust is slow, so it
  stands on the rock rather than leaving it as a puff, and a little less hot.
- *The march* (`dustFragmentRidge`, `QuarryRender.metal`; `QuarryDustPass`). A ridge cut's dust is
  drawn by its own copy of the face's march, which warps the lookup by 3.3 m rather than 5.5 m:
  warped further, the jets showed as loose patches over the rock. A copy, not a shared function:
  with the face's march sharing the code (inlined with a constant, or with a branch) the face's
  frames came out one level different in a few pixels.
- `hillsideblast clip` takes `--no-dust` (the window's recorder with the dust run but not drawn)
  and prints the clip's median draw and dust times; `render` prints the dust step's wall time over
  the firings.

**Measured** (release build, M4 Max Studio, the built-in ridge at 100,000 blocks asked, 96,386 made,
20 s runs; `tools/` below).
- *The dome* (the top layer of the rock over the cut, median rise; `heave.py`): 4.9 m at the first
  firing (1.8 s; 0.5 m before), with 87% of the top layer risen more than a metre; 6.7 m at 2.2 s;
  at most 8.1 m at 3.0 s (before 7.5 m at 3.7 s, most of it from rock already thrown). Within each
  4 m square the spread of the rise (interquartile) is 0.28 m at 1.8 s and 0.43 m at 2.2 s, so it
  rises as a mass. Along the cut's line (`dome.py`, 10 m bins from x 30 to 120, |y| < 8 m), at
  1.8 s: 0.5, 1.4, 3.8, 5.3, 6.0, 6.0, 5.0, 2.6, 0.5, 0.2 m; at 2.6 s: 0.3, 3.8, 6.7, 8.3, 9.0, 8.9,
  7.5, 3.9, 0.8, 0.3 m: one dome over the crest, rising together. The crest (x 70 to 90) stands
  about 9 m up when its own firings break it at about 2.7 s (about 4 m before).
- *Stable.* No NaNs. Fastest block 25.0 m/s (26.8 before). The last second (each block's move from
  19 to 20 s): worst 0.30 m, one block over 10 cm, on the near end's wall at 16 m up; the same
  block and move in a second run. Main's build on the same machine: 0.002 m and none; stage 3a's
  figures were 1.5 to 1.8 m and one or two. Tried and not kept (each a 20 s run): 4.5 m (the old
  amplitude) on the one dome rose only 4 m by 2.8 s; 7 m and 9 m with the hold at 0.5 rose 6 and
  8 m, read well but flat-topped, as a raised table (dome share 0.6, full depth from 60% of the
  deepest); 10 m with the hold at 0.3 and the dome by depth is the default. All settled with no
  block over 10 cm but this one.
- *Dust from the first motion* (the window's own session, `play --ridge --self-test --offscreen
  --shots-at`, frames every 0.2 s with and without dust, as #137 measured it): the rock is now on
  view (1% of pixels by more than 12 levels) at 0.4 s, since the whole dome starts to rise then
  (before at 1.4 s, the far flank's first blocks); dust shows at 0.6 s first firing, 0.8 s on Fire
  again and on a moved cut: 0.2 to 0.4 s of event, about 0.5 s on screen, where it was 0. That
  first motion is a few centimetres; the crest is plainly rising from about 1 s. The dust covers 8
  to 11% of the window's frame from 1.6 to 2.6 s (13 to 22% before), so the dome shows, and 35 to
  39% from 3.4 to 4.4 s as it breaks (16 to 22% before).
- *Cost.* The dust step's wall time over the firings (`render --ridge --dust-h 1.5 --ss 1`, 1.5 to
  5.5 s, interleaved, two each): main 6.5 and 6.9 ms; shedding from every block 7.5 and 7.7; as
  landed 7.3 and 7.3: about 0.5 ms more. The window's recorder's draw (GPU, 1920 x 1080, the
  firings' four seconds): 11.5 to 11.8 ms for this build and its variants on a quiet GPU, and 11.5
  to 11.6 (main) against 12.5 to 13.3 (this) with another session's self-test running beside them.
  The window's own session (`play --self-test`, two pairs interleaved; dust-and-chips step, then
  draw, medians from 1 to 5 s of the event while following the first firing): 15.2 / 23.1 and 16.3
  / 23.9 ms main, 15.8 / 24.6 and 19.7 / 25.2 this (an earlier build, shedding from every block); a
  second set ran beside another session's GPU work and swung by half again between runs of one
  build. Physics: the whole cut is awake from 0.3 s (from 0.7 s), so the solver works longer: 15.6
  s of GPU over the 20 s event against 12.8 s (single runs). Memory as before but for a 2 m map of
  the rock's top over the dust box (tens of kilobytes).
- *Options for the dust's cost, with their look.* Halving all of this stage's dust (the jets, the
  spurt and the shedding) changed neither the dust step's GPU time (3.92 to 3.93 ms against 3.93
  to 3.94) nor the draw (11.5 to 11.8 ms either way), and its frames are barely thinner: the cost
  is in the number of sources a frame and the screen the cloud covers, not in how dense it is.
  Shedding from half the blocks at twice the rate saved 0.4 ms of the step with the same cloud
  and is what landed. Recommendation: keep this as it is; no default to change.

**Quarry Face unchanged.** Its launch, swell branch and dust sources are not touched (its march is
the same function, not recompiled through a shared one). Stills from the same face poses
(`face-poses`, made with main's build, 110,000 blocks, `render --stills 1.0,2.0,3.5,5.9`) with
main's build and this one are byte-identical PNGs.

**Checked by eye**, before (main's build, its own 20 s run) and after, at the same cameras and
times, with the window's recorder (`hillsideblast clip`, frames from the movie files): the
opening view held still (1.0 to 19.9 s), with and without dust; Pull back (0.5 to 11.9 s); and a
close shot of the crest (`--focus 81,0,38 --distance 42 --yaw 0.95 --pitch 0.12`, 1.0 to 7.0 s);
and the window's own frames while following (`play-before`, `play-after3`, every 0.2 s to 4.4 s).
- *Opening view.* Before, the crest is flat under patches of fog at 1.6 to 2.6 s, its skyline
  barely raised; the mound only stands up as it breaks into loose rock at 3.0 to 3.6 s. Now the
  whole crest over the cut rises from about 1 s, its old surface and beds still on it, and by 1.6
  to 2.6 s it stands as a raised mass against the sky with small jets of dust off its top; the
  firings' columns burst from its top in their order from 2.2 s, and from 3.0 s the dome breaks
  and a heavy cloud, shadowed dark in its core, pours out of the breaking rock and runs down the
  near flank with it. At 4.5 s the dust follows the rock down; at 7 s the notch is clear; the end
  is as before.
- *Close on the crest.* The crest rises as a wall of cracking rock, the cracks between its cells
  opening dark, wisps of dust off its top, then breaks into blocks inside its own dust at 3.0 s.
- *The film* (`hillsideblast render --ridge`, 1 m cells, supersampled; stills at 1.6, 2.6, 3.6 and
  4.5 s): the same story as the window's, the early jets a little finer.
- *Pull back.* The close opening shot now fills with the rising rock by 2.2 s (the sky above the
  crest is gone from the frame until the camera pulls back), then the break and the cloud; from
  6 s the pull-back shows the notch as before.
- Files: `$BOMBCAD_DATA/hillside-blast/ridge-dust-heave/`: `before/` and `after/` (`poses`, a link
  to `v5/poses`, the after run; `clips/` with `still.mp4`, `still-nodust.mp4` (before),
  `pullback.mp4`, `crest.mp4` and their frames; `sheet-*.png` side by side), `play-before/` and
  `play-after3/` (the window's frames, with `-nodust` twins), `lag/` frames from the clips, the
  film's stills in `film-before/` and `film-after/`, the trials `v1` to `v6` (`report.txt`: dome
  and settle), the cost runs `cost-*`, `clipcost/`, `steptime/`, the face check `face-poses`, `face-main`, `face-new5`; `tools/` (`trial.sh`,
  `look.sh`, `quick.sh`, `play.sh`, `lagclip.sh`, `dome.py`, `heave.py`, `settle.py`, `lag.py`,
  `cost.py`, `sheet.py`).

**Tests.** `QuarryRidgeTests/oneDome` (BlastModel, Linux): every released block's swell starts at
the same moment, the ramp before the first firing; the swell over the crest is more than 1.5 times
that toward the cut's ends; with `ridgeTogether` off the starts follow the firings again.
`QuarrySimulationTests/ridgeHeaves` (BlastCore, GPU) now watches, when the first block of the
top lets go, the top over the deeper half of the cut not yet let go (every block there has swelled
since the same moment): its median rise more than 2 m and its 10th percentile more than 0.5 m (it
asked 0.8 and 0.3 m of blocks 0.7 through their own swells; the old filter now catches the cut's
far end, where the dome is low).

**With the ridge's larger pieces, 13 November.** The user chose the piece-size proposal of stage
3e for the ridge cut (its own commit, emmettl/bombcad-work#140): `QuarryFace.Options(scene:)`
asks a ridge cut for 30,000 blocks with `fractureScale` 0.5, in the window (each scene's default in
the Blocks choice), its Record Clip and `hillsideblast` alike; a face is as it was. The heave and
dust above were judged again on it, before (main with the larger pieces, stage 3a's heave and
#137's dust: `b30-bin`) and after (`a30-bin`), from 20 s runs of 31,259 blocks (median piece 0.82 m)
and the window's recorder at the same three cameras.
- *The dome* is the same as at 96,386 blocks: the top layer's median rise 4.9 m at the first
  firing (0.6 m before), 6.6 m at 2.2 s, at most 8.1 m at 3.0 s (before 7.6 m at 3.7 s); along the
  cut at 1.8 s 0.5, 1.4, 3.9, 5.3, 6.0, 5.9, 5.1, 2.7, 0.5, 0.2 m, where before it ran 4.2 m at
  the far end down to 0 at the near one.
- *Stable.* No NaNs; the last second's worst move 0.14 m, one block over 10 cm (before 0.21 m and
  one); fastest 24.9 m/s (27.7).
- *Physics* (the two runs side by side on the GPU): a frame while more than 5% of the blocks are
  awake, 11.0 ms median against 10.3, and the 20 s event 5.2 s of GPU against 3.7 s, for the whole
  cut swelling from 0.3 s. At 96,386 blocks it was about 40 ms.
- *The window* (`play --self-test`, two runs each, interleaved): following the first firing the
  solver took 4.0 to 4.6 ms a frame either way and the event was simulated in 5.1 to 5.3 s, so it
  played at 0.97 to 0.99 of real time both before and after (0.4 to 0.5 at 96,386 blocks); playback
  starts at once and is never held. The dust-and-chips step while it fires, 8.3 and 9.0 ms against
  8.6 and 8.7; the draw 10.3 and 9.8 against 8.7 and 9.3 ms (about 1 ms more, the bigger cloud).
- *Dust from the first motion*: with a third as many blocks a third as many crack, so the first
  dust was thinner; the first cracks' spurt is now 200 (from 160), and dust shows at 0.6 s on the
  first firing and a moved cut (rock on view at 0.4 s) and at 1.0 s on Fire again, whose camera
  (turned by the self-test) sees the crest's top less. Raising the cracks' share to 0.12 brought
  back patches on the dome's near slope, so it stays at 0.08.
- *By eye.* The dome, its jets and the columns read as at the finer size: from the opening view the
  crest rises as one mass, now visibly of larger slabs, with small jets off its top from 0.8 s and
  the columns bursting from its top from 2.2 s, then the cloud pours out with the rock; close on
  the crest the cracks between larger cells open and the top breaks into slabs; Pull back as
  above. Before, the crest stayed flat under fog to 2.6 s and broke into a travelling heap.
- Files: `b30/` and `a30/` (poses, `clips/` with `still.mp4`, `pullback.mp4`, `crest.mp4`,
  `still-nodust.mp4` (after) and frames; `sheet-still-ba.png`, `sheet-crest-ba.png`,
  `sheet-pullback-ba.png` side by side), `play-b30*`, `play-a30*` and `play-a30s-shots/`, `a30t/`
  (the 0.12 cracks).

**What still looks wrong.**
- *A raised table more than a dome across the cut.* Along the cut it is a dome; across it the rock
  between the walls rises nearly level and its edges stand as a step where the shoulder eases off,
  so from the opening view the risen crest has a flat top and squared ends.
- *The cloud at the break is heavy.* From 3.2 to 4.5 s the firings' columns and the shed dust
  together cover the right half of the frame with a dark-cored cloud; strong, but it hides most of
  the rock running down the near flank for a second.
- *The first dust is puffs, not jets.* At the window's 1.5 m cells a crack's jet is three metres
  across at the least; the early ones read as small puffs rising off the rock's top rather than
  thin sprays.
- *Pull back's opening shot* was framed for a small heave: the rising crest fills it.
- *The dust starts 0.2 to 0.4 s of event after the first, few-centimetre motion*, about 0.5 s on
  screen; it was simultaneous with stage 3a's heave, which began later.
- *The solver works longer* (the whole cut swells from 0.3 s), so following the first firing in the
  window is slower by about a fifth of the physics.
- Not looked at on a screen: all of it was made offscreen.

## Stage 3i: a cloud that reads as sunlit dust, and an opening shot for the dome, 13 November 2026

emmettl/bombcad-work#143, on the user's word of 13 November ("keep working through the defects
list until it looks strong"). Same standing: illustrative, render-only; the rock's physics, block
counts and motion are unchanged (every frame below is drawn from stage 3f's own 20 s run of 31,259
blocks, `ridge-dust-heave/a30/poses`). Nothing here is a load, a blast design or a claim about
fragments, dust or their reach.

**What was wrong** (stage 3f's frames, and the list it left).
- *Dark cores.* From 3.0 to 4.5 s the cloud had near-black cores and blotches (worst at 3.6 s in
  the opening view) and hid the rock running down the near flank.
- *Pull back* opened filled by the rising rock: it was framed for the old, lower heave.
- *Jets* from the cracks read as round puffs at the window's 1.5 m dust cells.
- *Dust about 0.2 s after the first motion.*

**Why the cores went dark.** Three causes, found by drawing the march's own quantities.
- *The sun's light was lost exponentially in the cloud.* The march lit each sample by an octave sum
  of exponentials of the sun's optical depth (`exp(-tau) + 0.32 exp(-tau/4) + 0.14 exp(-0.06 tau)`).
  Drawn as a picture, the depth in the cloud's core from 3 s on is 3 to 10, where that sum is a
  fifth to a tenth of a sunlit sample's; with only the sky's light beside it the shaded parts came
  out near black. Dust scatters nearly all it takes, so light in a thick cloud diffuses through it
  and falls off slowly. Drawn with the self-shadow off, the cores went pale (and flat): this is
  the main cause.
- *The shadow was looked up where the dust was not.* The density was looked up through a warp of
  a few metres; the sun's depth at the unwarped point. A puff's sunward side could be lit by the
  field's shape 3 m off, inside it: dark patches on lit dust.
- *Grain.* Thin dust over the heap was a speckle of dust and dark rock. Drawn as each pixel's mean
  colour and its coverage, the dust's colour was even and its coverage speckled: the fine warp
  (3.3 m of noise whose features are 0.3 to 0.6 m) turned faster than the march's 0.9 m steps
  sample it, so each pixel drew a random handful of the field within 3 m. Finer steps (0.3 m) took
  it away, at 2.6 ms more of the window's draw; neither a finer coarse search, a softer cut of the
  noise nor a thin haze under it did. The coarse search's last probe also skipped dust lying on
  the rock within 2 m of it, for pixels whose jittered probes fell past it.
- Not a cause: density clamping (sources stop at 40, the march saturates long before), and the
  ambient occlusion (drawn before the dust).

**What changed** (`dustFragmentRidge`, `ridgeDustLit`, `jetVertex`, `jetFragment` in
`QuarryRender.metal`; `QuarryDustPass`; `QuarryDustField`; `QuarryPullBack`, `QuarryClipCamera`).
- *Diffused sunlight.* A ridge's dust is lit by the sun's light scattered once, with its phase
  (bright rims toward the sun), plus the light diffused through the cloud, spread evenly and
  falling as 1 / (1 + 0.15 tau) (as a slab's diffuse transmission does, rather than exp(-tau); the
  0.15 chosen by eye), and the sky's light a quarter stronger in the shade. Shaded dust is now a
  darker tan where it is thick and turned from the sun, never near black.
- *The shadow at the warped point*, the same lookup as the density's.
- *The warp in two scales*: 3.3 m of a slow one (features of 2 m and more), which billows the
  cloud, and 1.2 m of the fine one (it was 3.3 m). The grain is gone; thin dust over the heap is a
  soft veil the rock shows through. Three more noise samples a fine step.
- *The coarse search's last probe* lands 5 cm short of the surface the ray ends on, and the last
  step is cut at it.
- *Jets as thin spurts* (the ridge's cracks only). Each crack that jets is also drawn as a narrow
  streak facing the eye from its top (`QuarryDustField.Jet`, three buffers in turn, up to 1,024),
  0.25 m wide at the crack and fanning out, growing at the jet's speed (9 m/s and the rock's rise)
  to 4.5 m, with packets of grit running up it, streaks, ragged sides and wisps at its tip, lit as
  the dust is, drawn over the scene before the march so the cloud veils it; for 0.35 s after it
  stops its tail flies on up and fades. Only 0.35 of a crack's dust now goes into the field
  (`crackField`): the rest is the streak, and at the field's cells it was the round puff.
- *Pull back for the dome.* A ridge cut's pull-back has its own shot (`QuarryPullBack.ridge`): 0.8
  of the view's distance (0.7), 0.75 of its field (0.55), aimed 0.09 of its distance higher (0.1),
  moving out from the first firing (0.7 s after it) over 4 s (5 s). A face's is as it was
  (`QuarryPullBack.face`).
- The face's march, sources and frames are untouched. Its film stills from the same poses (110,000
  blocks, 1.0 to 5.9 s): two runs of this build are byte-identical to main's first run or differ
  from its second in 2 pixels by one level, as main's two runs differ from each other; one run of
  this build, made while another job used the GPU, differed in 214 pixels by up to 8 levels at
  1.0 s. Its Pull back frames are byte-identical.

**Measured** (release build, M4 Max Studio, loaded by other sessions; `tools/` below).
- *Record Clip's draw* (GPU, 1920 x 1080, 1.5 to 5.5 s of the event, interleaved): main 8.34 and
  8.19 ms, this 8.32 and 8.62 ms (about +0.2 ms); the dust step 4.04 to 4.09 ms either way.
- *The window* (`play --ridge --self-test`, two runs each interleaved; medians from 1 to 5 s while
  following the first firing): draw 10.4 and 9.7 ms main, 10.5 and 10.3 ms this (about +0.35 ms);
  following Fire again 10.8 and 11.3 against 11.3 and 10.7 ms; the dust-and-chips step 9.1 and 8.2
  against 7.8 and 8.9 ms.
- *Dust on view* (the window's own frames every 0.2 s with dustless twins, `lag.py`): the first
  dust still shows at 0.6 s on the first firing, 0.2 s after the rock (0.4 s), unchanged; on Fire
  again at 1.0 s (1.23 s before); on a moved cut at 0.83 s (0.6 s before), since less of the first
  cracks' dust is in the field and the thin spurts cover fewer pixels than the measure's 1%. The
  dust's share of the frame is 3 to 4% from 1.0 to 2.4 s (3 to 7% before) and 28 to 29% from 3.4
  to 4.4 s (31 to 34% before). The delay is left: the jets start with the cracks, but the first
  motion is a few centimetres and the first spurts are short.

**Checked by eye**, before (main's build) and after, from the same poses and cameras: Record Clip's
opening view held still (0.4 to 12 s), Pull back (0.4 to 11.9 s) and the crest close in (0.6 to
7 s), and the window's own frames while following (every 0.2 s to 4.4 s, then 5 and 6 s).
- *The cloud.* From 3.0 s the columns stand as pale tan billows with soft shading on their turned
  sides and bright rims; no black cores. At 3.6 s the rock running down the near flank shows
  through the thin dust over it; the speckle over the heap is gone.
- *Jets.* From 0.6 s spurts of grit rise off the dome's top as thin fanned streaks, many along
  the skyline by 1.6 to 2.2 s, rather than round puffs; close in they flicker in gusts. The early
  cracks still leave small soft puffs in the field over them.
- *Pull back* opens on the whole crest with sky over it; it swells, its spurts rise off the top,
  the columns burst from 2.2 s, and the camera eases out from the first firing as the rock breaks
  and comes down the flank.

**What still looks wrong.**
- *The columns' puffs are smooth balls.* With the grain gone, the big puffs at 3.6 to 4.5 s read
  as rounded cotton wool, the field's own shape, where stage 3f's were wispy (and grainy). A finer
  detail at no aliasing (a march at finer steps where the cloud is thin, or a detail noise in the
  light rather than the shape) is the next thing to try.
- *Less cloud follows the rock down the flank.* The fine warp spread the shed dust's thin field
  into a visible veil; at 1.2 m it shows less, so the near flank is clearer at 3.6 to 4.5 s (as
  asked) and the cloud pours less visibly with the rock.
- *Jets on the near slopes* of the dome read as faint vertical streaks over the rock in the close
  shot, and a crack near the eye in the window's following view (0.8 to 1.0 s) is a soft pale
  smudge rather than a spurt.
- *Pull back's opening* still cuts the crest's far end at the right of the frame; wider would make
  it the opening view.
- *The dust's delay* (0.2 s of event on the first firing) is unchanged, and on a moved cut longer
  by the coverage measure (see above).
- Not looked at on a screen: all of it was made offscreen.

Files: `$BOMBCAD_DATA/hillside-blast/ridge-cloud/`: `before/` and `after/` (`clips/` with
`still.mp4`, `pullback.mp4`, `crest.mp4` and their frames), `sheet-still-ba.png`,
`sheet-pullback-ba.png`, `sheet-crest-ba.png` (Record Clip, before left), `sheet-window-early.png`
and `sheet-window-late.png` (the window's frames), `play-before/` and `play-after/` (with
`-nodust` twins), the cost runs `cost-*`, `clipcost/`, `costs.txt`, the face check `face-*`, the
diagnostic frames (`taudbg/` the sun's depth, `noshadow/`, `coldbg/` the dust's colour, `stepdbg/`
its coverage, `finedbg/`, `warplo/`, `warp2-*`), and `tools/` (`iter.sh`, `try.sh`, `look.sh`,
`play.sh`, `costruns.sh`, `clipcost.sh`, `face.sh`, `pairs.py`, `crop.py`).

**Tests.** `QuarryRidgeViewTests/pullBack` (BlastModel, Linux) runs for both shots: each holds,
starts at its own distance and field, ends on the view and only moves out; `ridgePullBackOpensWider`:
a ridge's opens wider and moves sooner than a face's.

## Stage 3j: dust that billows, and a veil that runs with the rock, 13 November 2026

emmettl/bombcad-work#144, on the user's word of 13 November ("keep working through the defects
list until it looks strong"). Same standing: illustrative; the rock's physics, block counts and
motion are unchanged (every frame below is drawn from stage 3f's own 20 s run of 31,259 blocks,
`ridge-dust-heave/a30/poses`). Nothing here is a load, a blast design or a claim about fragments,
dust or their reach.

**What was wrong** (stage 3i's list).
- *Cotton wool.* At 3.6 to 4.5 s the columns' big puffs were smooth balls with round outlines and
  even shading: the field's own shape at its 1.5 m cells. Stage 3i had taken out the fine warp,
  which made grain (0.3 to 0.6 m features against the march's 0.9 m steps), and finer steps cost
  2.6 ms.
- *Less cloud followed the rock down.*
- *Pull back's opening* cut the crest's far end at the right of the frame.
- *Early cracks* left small soft puffs, and near cracks seen from above in the window's following
  view were pale smudges on the rock.

**What changed.**
- *Billows, once a pixel* (`dustFragmentRidge`, `ridgeBillow`, `QuarryRender.metal`). Detail drawn
  in the march aliases against its steps, so it is drawn after it: the march keeps where the dust
  it draws lies (its points weighted by what each gives the pixel), and at that point a lobe field
  is looked up once. The lobes are the dust's own baked noise (inverted Worley in three octaves),
  at two sizes, 3.2 m to 0.8 m and three times that, rounded, bright in the middle and creased
  between. The noise volume is now mipmapped (`QuarryDustField`, eight levels) and the lobes are
  looked up at the level a pixel holds (the pixel's angle times the distance), so nothing finer
  than the screen shows. The lookup is carried with the dust's own flow (its velocity, held to
  5 m/s) in two phases half a second apart, crossfaded with the contrast kept, so the lobes rise
  and roll with the cloud rather than standing while it moves through them. With them:
  - the dust's optical depth is cut where it is moderately thick (0.5 to 2), by up to 2.4 in the
    lobes' creases, keeping 0.3 of what is cut as haze: a puff's edge tears into lobes and thins
    into haze, its core is left whole;
  - thin dust (a veil, the haze round a puff) is mottled by the same lobes (0.45 to 1.35 of its
    depth), so it rolls rather than lying as an even sheet;
  - thick dust is shaded by them: creases to 0.68, lobes to 1.1, and each lobe a little brighter
    on the side toward the sun as the screen shows it (from a second lookup across the line of
    sight, 0.45 m or two pixels toward the sun, not along it, since the seen point is only good to
    a step along the ray).
- *A low veil* (`QuarryDustField`). A block running over the ground at more than 2 m/s (the cut's
  floor, the flanks; anywhere, not only below the floor as the skirt is) sheds dust 0.9 m over the
  ground under it, 32 per square metre of block and m/s (to 10 m/s), dragged at 0.85 of its speed
  across the slope, rising 0.4 m/s, a little warm (0.15) so it neither climbs away as the skirt
  does nor drops out at once. Only 10 to 28 moving blocks are below the floor in the first 5 s, so
  a veil from the flanks alone did not show.
- *Early cracks.* The first cracks' spurt puts 0.12 of its dust into the field (it was 0.35, as
  the rest of a crack's), so it no longer leaves round puffs at the field's cells; its streak is
  drawn as before. A jet's streak is faded as it turns toward the eye (by the sine of the angle
  between it and the line of sight, from 0.45 to 0.8): seen from above, close in, it was
  foreshortened to a pale fan lying on the rock.
- *Pull back* (`QuarryPullBack.ridge`, BlastModel): it opens with 0.82 of the view's field (0.75),
  aimed 0.06 of the distance higher (0.09) and 0.055 of it to the frame's right (`startAcross`,
  new, 0 for a face), so both ends of the crest are in the frame; a face's is as it was.
- The face's march, sources and frames are untouched: its stills and Pull back frames from the
  same face poses (110,000 blocks) with main's build and this one are byte-identical PNGs (its
  march samples the noise volume's base level, as before).

**Measured** (release build, M4 Max Studio, loaded by other sessions; `tools/` below).
- *Record Clip's draw* (GPU, 1920 x 1080, 1.5 to 5.5 s of the event, interleaved): main 9.51 and
  9.91 ms, this 10.82 and 10.62 ms (about +1.0 ms); the dust step 4.45 and 4.54 against 4.68 and
  4.60 ms (the veil's dust).
- *The window* (`play --ridge --self-test`, two runs each interleaved; medians from 1 to 5 s):
  draw while following the first firing 11.7 and 11.9 ms main, 12.2 and 12.7 ms this (+0.5 to
  0.8 ms); following Fire again 12.7 and 12.6 against 13.2 and 12.4 ms; the dust-and-chips step
  12.3 and 13.5 against 12.3 and 12.9 ms.
- *No crawl* (`flicker.py`, the opening view's cloud at 3.60, 3.63 and 3.67 s, frames in a row):
  the change between frames in the detail finer than a few pixels is 5.74 and 5.84 (main) and 6.09
  and 6.16 (this), up by the same 6% as that detail itself (6.21 to 6.61): the lobes move as the
  cloud moves and do not boil or crawl.

**Checked by eye**, before (main's build) and after, from the same poses and cameras: Record
Clip's opening view held still, Pull back and the crest close in (0.6 to 7 s, with 3.60, 3.63 and
3.67 s in a row), and the window's own frames while following (0.2 to 7 s).
- *The cloud.* From 3.0 s the columns stand as lobed billows, the upper puffs of the crest's row
  lobed with darker creases between, their edges torn into lobes and wisps against the
  sky; at 4.5 to 5.5 s the risen puffs are clusters of lobes rather than balls. Frames in a row
  show the same lobes moving a little with the cloud.
- *The veil.* From 4 s a thin, mottled sheet of dust lies over the rock running down, and by 5.5 s
  a low rolling veil runs down the near edge of the heap toward the eye.
- *Early.* At 0.6 to 1.0 s the crest's first cracks show thin spurts with no round puffs over
  them; the pale smudges on the near rock in the window's following view (0.6 to 1.6 s) are gone.
- *Close on the crest* the soft puffs over the first cracks at 0.6 and 1.0 s are gone, leaving
  their thin spurts, and the cloud in the break at 3.0 to 4.5 s is torn and lobed where it was a
  smooth wash.
- *Pull back* opens on the whole crest, both ends, with less empty sky, and still moves out to the
  view; it is closer and narrower than the view.

**What still looks wrong.**
- *The two big low puffs at 3.6 to 4.5 s* (right of the opening view) are lobed inside but their
  outlines are still roundish: they are the densest dust, whose edges go from clear to opaque in a
  few pixels, and cutting deeper made holes in their cores. Shaping the dust's own sources (fewer,
  hotter, more broken) would do more than the render can.
- *The veil lingers near the eye.* The last blocks running toward the camera at 6 to 7 s keep
  shedding it, so a lumpy patch of dust stands by the notch's near end at 7 s, where it was clear.
- *The first dust is fainter.* With the spurts' puffs gone the first dust at 0.6 s is a faint
  wisp; the spurts' streaks are as thin as before.
- *The puffs' lit side.* With the low sun behind the eye, the lobes' sunward brightening is small;
  most of the billowing reads from the creases.
- Not looked at on a screen: all of it was made offscreen.

Files: `$BOMBCAD_DATA/hillside-blast/ridge-billow/`: `before/` and `after/` (`clips/` with
`still.mp4`, `pullback.mp4`, `crest.mp4` and their frames), `sheet-still-ba.png`,
`sheet-pullback-ba.png`, `sheet-crest-ba.png` (Record Clip, before left),
`sheet-still-consecutive-ba.png`, `sheet-consecutive-crop-before.png` and `-after.png` (frames in
a row), `sheet-window-early-ba.png` and `sheet-window-late-ba.png` (the window's frames),
`play-before/` and `play-after/` (with `-nodust` twins), the trials `v1` to `v14`, the cost runs
`cost-*`, `clipcost/`, `costs.txt`, `clipcost.txt`, the face check `face-*` and `face-check.txt`,
and `tools/` (`iter.sh`, `try.sh`, `look.sh`, `play.sh`, `final.sh`, `face.sh`, `clipcost.sh`,
`costruns.sh`, `flicker.py`, `winsheet.py`, `sheet.py`).

**Tests.** `QuarryRidgeViewTests/ridgePullBackAimsRight` (BlastModel, Linux): a ridge's pull-back
opens aimed to the frame's right by its share and only across, a face's straight on; `pullBack`
runs for both shots as before.

## Stage 3k: one plume that drifts and lingers, 13 November 2026

emmettl/bombcad-work#145, on the user's word of 13 November ("keep working through the defects
list until it looks strong"). Same standing: illustrative; the rock's physics, block counts and
motion are unchanged (every frame below is drawn from stage 3f's own 20 s run of 31,259 blocks,
`ridge-dust-heave/a30/poses`). Nothing here is a load, a blast design, or a claim about
fragments, dust, a dust hazard or anything's reach.

**What was wrong** (stage 3j's frames at 4.5 and 7 s).
- *A row of puffs.* At 4.5 s the firings' columns stood as an evenly spaced row of separate blobs
  over the crest, and the low ones on the near flank were dense, roundish balls. Each column was a
  ball 4 m across, fed for 0.35 s, the same at every firing.
- *The dust vanished.* By 7 s the cloud had nearly gone and the heap stood clean. A ridge's field
  thinned all its dust at 0.9 a second high up and 0.6 near the ground (e-folding in about a
  second), and the march's noise cut leaves out thin dust, so a cloud that spread went from
  visible to nothing.
- *A smudge by the camera.* At 7 s a lumpy brown patch stood by the notch's near end: the low
  veil, fed by the last blocks rolling toward the eye.
- *The wind* (1.4 m/s along the cut, added to the flow when the dust was carried) blew mostly
  toward the opening view's eye, and it went through the ground as well as over it; with the dust
  gone in a second it never showed.

**What changed** (`QuarryDustField`, `QuarryDust.metal`, BlastCore; `dustFragmentRidge`,
`QuarryRender.metal`). A ridge cut's field has its own copies of the kernels it changes
(`dustAdvectVelocityRidge`, `dustForcesRidge`, `dustAdvectDensityRidge`, `dustBackwardRidge`,
`dustCorrectRidge`, and `dustWindStart`); the face's kernels and sources are untouched.
- *Columns that merge* (`QuarryDustField.columns`). Each firing's column is drawn once from its
  place in the pattern: a delay of 0 to 0.3 s, fed over 0.5 to 1 s, strength 0.4 to 1.5, rise 0.7
  to 1.3, its middle moved by up to half the spacing along the cut and a quarter of the half-width
  across, and a footprint 0.9 to 1.9 times the spacing along the cut and 0.35 to 0.7 of the
  half-width across (both rows), denser in the middle, born on the rock's top over each point of
  it. Toward the cut's ends, over shallower rock, a column is up to half as strong, fed up to 1.6
  times as long, over up to 1.5 times the footprint: the low columns on the near flank were the
  densest puffs. In all, 0.7 of stage 3f's dust.
- *A light, steady wind in the flow.* 3 m/s at 12 m and more over the ground, a third of that at
  the ground, across the opening view from its right to its left and a little away from the eye
  (so the plume leans and drifts over the far flank, not toward the camera). The flow starts as
  the wind and relaxes back to it as the face's relaxes to rest; across, clear of the ground, it
  relaxes faster (0.5 a second more), as a plume takes in the air round it, so it leans within a
  few seconds of rising. The pressure solve turns it over the ground rather than through it.
- *Gusts.* The baked noise (features of about 16 m and 8 m), carried with the wind and turning
  slowly, pushes the flow about by up to 0.27 m/s²; the pressure solve keeps only its swirl.
- *Dust that thins, spreads and settles.* Thick dust's coarse part falls out (0.45 a second above
  a density of 3.5, eased in from 0.8; up to 0.9 near the ground where it is cold), its fines
  slowly (0.05 a second from 10 m over the ground up, 0.15 within 3 m of it). A puff drops within
  a few seconds to a haze that drifts and clears over the next ten to fifteen.
- *The box's sides.* Dust fades over the last 8 m before the box's sides, so a drifting plume
  never ends on a face of the box. The box itself is as it was (45 m past the cut's ends, 100 m
  either side of its line, at least 129 m high); the plume stays well inside it over 20 s.
- *Haze* (`dustFragmentRidge`). Thin dust, which the march's noise cut leaves out, still dims and
  lights the ray (0.03 a metre and unit of density, to 1.5), so a cloud that has spread stays on
  view as haze; the billows mottle it as before. The billows' flow no longer adds the old wind,
  which is now in the field's own flow.
- *The veil* is no longer fed by a block slower than 2.5 m/s (it eases in to 6 m/s), within 45 m
  (in plan) of the opening view's eye (easing in to 67 m), or from 2.5 s after the last firing
  (fading out over 3 s). The eye is the opening view's, a fixed place, not the window's moving
  camera, so the field does not depend on where the user looks.
- *Shed dust* is 36 (it was 56): with the dust lingering, the cloud at 4.5 s hid the rock running
  down the near flank.

**Measured** (release build, M4 Max Studio, loaded by other sessions; `tools/` below).
- *Record Clip* (GPU, 1920 x 1080, the opening view, interleaved, two each): while the ridge fires
  (1.5 to 5.5 s) the draw is 8.72 and 8.90 ms main, 9.04 and 8.96 ms this (+0.2 ms); over the whole
  20 s event 8.29 and 8.53 against 11.23 and 11.19 ms (+2.8 ms, the haze that now stays). The dust
  step over the whole event 4.08 and 4.00 against 4.00 and 4.00 ms, and while firing 3.94 and 4.06
  against 3.97 and 4.03 ms: unchanged (it is the grid's work, whatever the dust). The crest close
  in, its camera inside the lingering dust, draws 17.9 ms in the median over 18 s (10.1 before).
- *The window* (`play --ridge --self-test`, two runs each, interleaved; medians from 1 to 5 s
  while following the first firing): draw 10.9 and 10.4 ms main, 10.5 and 11.1 this; the
  dust-and-chips step 8.8 and 8.1 against 8.5 and 9.8 ms. Over the whole event the draw is 8.9 and
  8.8 against 10.0 and 10.2 ms (+1.3 ms), the step 6.8 and 7.6 against 6.1 and 7.3 ms.
- *No crawl* (`flicker.py`, the opening view's cloud at 4.50, 4.53, 4.57 s and 12.00, 12.03,
  12.07 s): the change in fine detail between frames is 5.9 and 5.8 at 4.5 s (9.2 and 9.0 before,
  the old puffs' sharper edges) with the fine detail itself 5.3 (7.7), and 0.48 and 0.40 at 12 s
  (0.39 and 0.35 before, where there was no dust): the haze drifts slowly and nothing pops.
- *The field* (`QuarryDustTests/ridgeDustLingers`): with only the columns feeding it, 8 s after the
  first look at the dust (2 s after the last firing) more than a tenth of it is left (stage 3j's
  thinning would leave under 1%), and its middle has moved more than 5 m downwind.

**Quarry Face unchanged.** Its kernels, sources and march are untouched. From the same face poses
(`ridge-dust-heave/face-poses`, 110,000 blocks), two runs each of main's build and this one: every
Record Clip frame (Pull back at 0.5, 2.0, 3.5, 6.0 and 7.9 s, the opening view at 2.0, 4.0 and
7.9 s) of this build is byte-identical to one of main's two runs; main's own two runs differ in
some of them (up to 1.85 M pixels by up to 159 levels: the clip's runs are not repeatable on this
loaded machine, in main as here). The film stills at 2.0, 3.5 and 5.9 s are byte-identical; at
1.0 s main's two runs differ in 214 pixels by up to 8 levels, and this build's from main's in 3 to
217 pixels by up to 8 (`face-check.txt`).

**Checked by eye**, before (main's build) and after, from the same poses and cameras: Record
Clip's opening view held still, Pull back and the crest close in at 2, 3, 3.6, 4.5, 6, 8, 12 and
18 s (with 4.5 and 12 s three frames in a row), and the window's own frames while following.
- *Merging.* At 3 s the columns already run together into one billowing bank along the crest. At
  3.6 to 4.5 s it is one tall cloud over the breaking rock, uneven along the cut (a higher mass
  over the crest and the far side, a lower, softer one on the near flank), torn and lobed at its
  edges; no row of puffs, and no dense round balls on the near flank.
- *Lingering.* At 6 s the cloud's upper part is an arch of billows drifting left over the notch,
  its lower part thinned to a haze over the heap. At 8 s the top of the plume is leaving the frame
  above the crest and a broad haze hangs over the notch, leaning left; at 12 s a pale haze lies
  across the sky left of the heap and a light haze over the heap; at 18 s a faint haze remains high
  on the left and the heap is clear. Before, the sky was clear from 6 s.
- *The veil* no longer leaves a lump of dust by the camera at 7 s; the near flank there has only
  the thin haze.
- *Pull back* ends on the same view, so from 6 s it is as the opening view; at 3 to 4.5 s it shows
  the one cloud rising over the whole crest.

**What still looks wrong.**
- *The cloud at 3.6 to 4.5 s is heavy.* It is one plume now, but tall and opaque: it fills the
  upper right half of the opening view and hides much of the rock running down the near flank for
  a second or two (stage 3f's heavy cloud, merged).
- *The lean is slight.* The plume rises above the top of the opening frame (about 30 m over the
  crest) before the wind has moved it far, so in the frame it reads as a cloud that rises and then
  thins and drifts left as haze, more than as a leaning column. A stronger wind (tried at 10 m/s)
  leans it more but would no longer be light.
- *Close in, a dust fog.* The crest close shot, whose camera stands in the cut's lingering dust,
  is fogged from 6 to 12 s (clearing by 18 s), and its draw doubles meanwhile.
- *The thin haze's texture.* At 6 to 8 s the cloud's mid-thick parts show swirled, marbled lobes
  (the billows carried by the gusty flow), and the haze at 12 s has a faintly patchy look.
- *The haze costs* about 3 ms of Record Clip's draw after the firings in the opening view (more
  close in): the march steps finely through more of the frame for longer. Not tried: coarser
  steps in thin haze.
- Not looked at on a screen: all of it was made offscreen.

Files: `$BOMBCAD_DATA/hillside-blast/ridge-plume/`: `before/` and `after/` (`still.mp4`,
`pullback.mp4`, `crest.mp4` and their frames), `sheet-still-ba.png`, `sheet-pullback-ba.png`,
`sheet-crest-ba.png`, `sheet-consecutive-ba.png` (before left), `sheet-window-ba.png` (the window's
frames), `play-before/` and `play-after/` (with `-nodust` twins), the trials `v1` to `v9` and
`d-wind10`, `d-nocol`, `v4noshed`, the cost runs `cost-*`, `clipcost/`, `costs.txt`,
`clipcost.txt`, `flicker.txt`, the face check `face-*` and `face-check.txt`, and `tools/`
(`look.sh`, `try.sh`, `play.sh`, `final.sh`, `face.sh`, `clipcost.sh`, `costruns.sh`,
`flicker.py`, `sheet.py`, `winsheet.py`).

**Tests.** `QuarryDustTests/ridgeDustLingers` (BlastCore, GPU): a ridge cut's columns are of
unequal strength and each reaches its neighbours along the cut; with only the columns feeding the
field, more than a tenth of the dust 2 s after the last firing is left 8 s later, and its middle
has drifted more than 5 m downwind.

## Stage 3l: a plume that lets the rock show, a cheaper haze, and one dust for both scenes, 13 November 2026

emmettl/bombcad-work#146, on the user's word of 13 November ("keep working through the defects
list until it looks strong"). Same standing: illustrative; the rock's physics, block counts and
motion are unchanged (every ridge frame below is drawn from stage 3f's own 20 s run of 31,259
blocks, `ridge-dust-heave/a30/poses`). Nothing here is a load, a blast design, or a claim about
fragments, dust, a dust hazard or anything's reach. The Quarry Face's side of it is in
[hillside-blast.md](hillside-blast.md), "Stage 3l".

**What was wrong** (stage 3k's list).
- *The plume hid the rock.* At 3.6 to 4.5 s the merged plume stood as a tall, opaque wall over
  the near flank, hiding the rock running down it for a second or two. Drawn without the columns
  (stage 3k's `d-nocol`) the wall went and without the shed dust it stayed: it was the low columns
  over the shallow rock toward the cut's ends, which stage 3k had fed 1.6 times as long over 1.5
  times the footprint, so they lay low and thick on the flank.
- *The haze cost.* The crest close shot sits in the lingering dust from 6 to 12 s, its draw near
  twice the clear shot's, and the haze added about 2.8 ms to Record Clip's draw over the event.
- *Two copies.* The ridge's dust had its own copies of the face's kernels and march
  (`dustFragmentRidge`, `ridgeBillow`, the `...Ridge` kernels), kept apart so the face stayed
  byte-identical, so none of stages 3f to 3k reached the face.

**What changed.**
- *One dust for both scenes* (`QuarryDust.metal`, `QuarryDustField`, `QuarryRender.metal`,
  `QuarryDustPass`). The ridge's kernels and march are now the only ones (`dustAdvectVelocity`,
  `dustForces`, `dustAdvectDensity`, `dustBackward`, `dustCorrect`, `dustWindStart`;
  `dustFragment`, `dustLit`, `dustBillow`); the face's older ones are gone. What differs by scene
  is in the uniforms and the sources: the wind's way (`u.wind`), the fines' thinning (`u.low.w`,
  `u.wind.w`: 0.05 and 0.15 a second here, as stage 3k), the share of thin dust drawn as haze
  (`u.sun.w`, new: all of it here), a face's bench height (`u.dims.w`, new, 0 here: a face's slower
  coarse fall-out, its trench's settling, its haze share by height and its paler light key off
  it), and each scene's own firing sources. The face's own branches were added after this
  section's ridge frames were made; drawn again with them, every ridge frame whose own runs repeat
  (the opening view at 4.5 to 18 s, Pull back at 4.5 to 8 s) was byte-identical to before. Checked on its own with
  the face's old sources (the ridge's code is the same, renamed): every Record Clip frame of the
  three views at stage 3l's times was byte-identical to main's but the opening view's 4.50, 4.53
  and 4.57 s, where 44,000 to 50,000 pixels in the frame's lower right corner (thin dust on the
  heap) differed by up to 48 levels through one group of the movie's frames. A later build with
  the same path and the march's skip below drew the opening view and the crest close at 4.50 s
  byte-identical to main's, so that was one run's variation (stage 3k found Record Clip's runs not
  repeatable on this loaded machine), not the fold.
- *A plume that lets the rock show* (`QuarryDustField.columns`). Over the shallow rock toward the
  cut's ends a column is now up to a quarter as strong (it was a half), fed as long as the others
  (it was up to 1.6 times), and its dust comes from three clumps of its footprint, each 0.7 of it
  (`clumps`, `clumpSize`, from a shallowness of 0.3), so low down the dust over the rock running
  down the near flank is broken, with the rock between, and it merges above into the same plume.
  The crest's columns are as they were. In all, a little less dust (the near flank's columns).
- *A cheaper march in haze* (`hazeBound`, `dustSpreadMax`; `dustFragment`). The dust step now
  keeps the most dust within 5 cells (7.5 m at the window's 1.5 m cells) of each cell, a box filter
  of maxima in three passes. At each fine step the march looks up the two noises of its cuts first
  and works out the least dust the cuts would keep anything of there; where the bound is under it,
  no lookup the warp can make there (5.1 m at most, and a cell's interpolation) would be kept, so
  the warp's five lookups are skipped and the dust drawn as haze, lit at the unwarped point. This
  is exact for the cut (shaped dust is never lost); the haze is lit a few metres off where it was.
  Frames where the cloud is thick come out the same (the opening view at 4.5 s and the crest close
  at 4.5 s were byte-identical to main's with this alone); in the lingering haze the difference is
  up to 37 levels in the haze's lighting, invisible side by side.
- Tried and not kept, each measured interleaved against main on the crest close (6 to 12 s):
  bricks of 4 cells, their maxima spread over the bricks within reach, with the march stepping two
  cells at a time and unwarped through bricks under a fixed threshold, was 1.2 ms slower (the
  bricks' bound, 12 m round, was almost never under it in this haze: a debug march found no fine
  step in such a brick at 6 to 8 s, though at 8 to 12 s the noise's cuts kept nothing at 99 to 100%
  of steps); the same with a full-resolution bound, 1.35 ms slower; a coarser fine step in such
  bricks, a skip by the first cut alone, and the same branches made uniform across each SIMD group
  (`simd_all`, `simd_any`), all 0.4 to 1.7 ms slower. Each added branch cost more than it saved
  until the skip was tested per step against the cuts' own noise.

**Measured** (release build, M4 Max Studio, loaded by other sessions; Record Clip at 1920 x 1080,
interleaved with main's build, two runs each; `tools/` below).
- *Record Clip while the ridge fires* (the opening view, 1.5 to 5.5 s): draw 9.84 and 9.82 ms main,
  9.81 and 9.83 ms this: unchanged. The dust step 4.20 and 4.21 against 4.50 and 4.52 ms (+0.3 ms,
  the haze bound's three passes).
- *Over the whole 20 s* (the opening view): draw 11.81 and 11.82 ms main, 10.72 and 10.72 ms this
  (-1.1 ms of stage 3k's +2.8 ms).
- *The crest close shot* in its fog (6 to 12 s): 15.56 and 15.55 ms main, 13.20 and 13.15 ms this
  (-2.4 ms); over its whole 20 s 14.55 and 18.47 (a run beside another job) against 12.30 and
  12.55 ms.
- *A debug march* (each pixel's mean dust along its fine steps, the share of steps whose cuts kept
  anything, and the count of steps, read back through a ramp drawn in the frame): in the crest
  close shot the fine steps' mean density is 0.76 at 6 s, 0.58 at 8 s and 0.28 at 12 s, the cuts
  kept anything at 8% of them at 6 s, 0.8% at 8 s and none at 12 s, over 90 to 115 steps a pixel:
  the fog is dust the cuts keep nothing of, looked up through the warp at every step.
- *The window* (`play --ridge --self-test`, two runs each interleaved, the first of each with shots;
  medians from 1 to 5 s while following the first firing): draw 13.6 and 15.1 ms main, 18.4 and
  14.8 ms this (the 18.4 beside other load: its dust-and-chips step was 12.1 against 9.3 to 11.0 in
  the others); over the whole event 12.2 and 13.4 against 15.1 and 11.6 ms. Inside the runs'
  spread either way.

**Checked by eye**, before (main's build) and after, from the same poses and cameras, with Record
Clip's opening view held still, Pull back and the crest close in at 1, 2, 3, 3.6, 4, 4.5, 6, 8,
12 and 18 s (with 4.5 and 12 s three frames in a row), and the window's own frames.
- *The plume at 3.6 to 4.5 s.* The near flank's low wall is gone: the rock running down it shows
  through thin, broken dust, two or three narrow stems rising from it into the plume. Above the
  crest it is one tall plume, as before, its top and the far side unchanged.
- *From 6 s* the frames are as stage 3k's: the plume drifts left and thins to a haze; the crest
  close shot is in the same fog from 6 to 12 s.
- *No crawl* (`flicker.py`, the opening view at 4.50, 4.53, 4.57 s and 12.00, 12.03, 12.07 s): the
  change in fine detail between frames at 4.5 s is 5.27 and 5.21 (main 4.84 and 4.79), with the
  fine detail itself 5.93 (5.63), the broken low dust; at 12 s 0.57 and 1.03 (0.47 and 0.39), the
  second spread evenly over the whole frame, ground and sky alike (14 pixels over 20 levels): the
  movie's key frame, not the dust.

**What still looks wrong.**
- *Stems.* The near flank's broken low dust reads as a few separate stems at 3.6 to 4 s, rising
  into the plume; the plume's middle over the crest is still a tall dense mass in front of the
  crest's own break.
- *The crest close shot is still in fog* from 6 to 12 s: it is cheaper to draw, not clearer.
- *The lean is slight* and *the haze's texture* swirls at 6 to 8 s, as stage 3k left them.
- Not looked at on a screen: all of it was made offscreen.

Files: `$BOMBCAD_DATA/hillside-blast/quarry-dust/`: `before/` and `after/` (`ridge/` and `face/`,
each with `still.mp4`, `pull.mp4`, `close.mp4` and their frames), the sheets `sheet-ridge-still-ba.png`,
`sheet-ridge-pull-ba.png`, `sheet-ridge-close-ba.png`, `sheet-ridge-plume-ba.png` (3.6 to 4.5 s),
`sheet-ridge-consecutive-ba.png` (before left), the window's `play-*` and `sheet-window-*`, the
trials `r1` to `r5` (the plume), `f1` to `f7` and `k1` to `k9` (the face), `fold/` (the shared path
with the face's old sources), the cost variants `iter*-bin`, `cost-*` and `clipcost.txt`, the
debug marches `dbg*/`, and `tools/` (`look.sh`, `clipcost.sh`, `play.sh`, `sheet.py`, `flicker.py`,
`pixdiff.py`, `dbgshare.py`, `noisemax.py`).

**Tests.** `QuarryDustTests/faceDustMergesAndHazeBound` (BlastCore, GPU): a face's firings' dust
is of unequal strength and each reaches its neighbours along the strip, its wind blows along the
strip and off the face, and after the firings every cell's dust is under the haze bound of every
cell within its reach (which covers the warp and a cell). `ridgeDustLingers` as before.
