# Freestanding objects

Experimental. Rigid boxes and simplified cars that slide, lift, tip and strike each other and
the scene's blocks, with the object nearest a charge coupled to the air. Nothing here is
validated against a blast experiment: the car is an illustrative 1500 kg saloon on locked
tyres with rigid suspension, and the checks below are numerical and mechanical. The staged plan
is in the [roadmap](roadmap.md#freestanding-objects-and-supports); milestones 1–3 (one box, one
box in the air, one car) are described there.

## A car beside a charge: resolving the gap under it

The case is the saloon parked side-on, its near side 1.5 m from 1, 5 or 10 kg of TNT 0.3 m
above the ground, in an open 8.4 × 9.6 × 4.8 m domain (`ExperimentalRigidCarStudy`,
`swift run -c release rigidboxdemo --car-convergence`). The shell is a box 0.15 m above the
ground; the blast reaching under it is what lifts the car.

The earlier comparison (0.2 against 0.1 m uniform cells: upward impulse 8.2 against
3.7 kN s, overturning against rocking back) turned out to mix three effects:

- **The represented gap.** Air cells are solid where their centres lie in the shell. On
  0.1 m cells the shell's underside, at 0.15 m, lies on a row of cell centres and the gap is
  0.1 m; on 0.2 m cells it is 0.2 m. The scene now puts every shell face on the faces of
  0.05 m cells, and the comparison uses near-car cells of 0.075, 0.05, 0.0375 and 0.025 m,
  which resolve the gap exactly with 2, 3, 4 and 6 cells, from patches twice or four times
  finer than 0.15, 0.1 or 0.2 m air over the car.
- **Gas packed into the patches at the start.** Where a shell face cuts through a coarse
  cell, placing the patches shared the coarse cell's gas over the shell among the fluid fine
  cells, so the car started between layers at 4/3 to 2 times ambient pressure. In still air
  it was pushed up by 231 N s in 0.1 s. The drivers now give that share back once, after the
  first patches are placed (`removeExperimentalBoxPackedGas`); still air then exerts no load
  (a test at factors 2 and 4).
- **Late flow.** After about 0.4 s, with the car well tilted, the air's load on it differs
  between grids in sign and size (sideways −4.0 to +1.3 kN s between 0.4 and 0.7 s), while
  from 0.1 to 0.4 s it agrees (−0.1 to −0.5 kN s). It is the blast's load that converges.

### 10 kg

Impulses are the air's on the shell up to 50 ms, when the blast has passed. "Blast only"
lets the air act for the first 0.15 s and then the car carry on alone; "full" couples it
throughout (runs stop once the car is on its side, past 80°, or back on its tyres and still).

| Near-car cells (outer) | Up (kN s) | Sideways (kN s) | Blast only: tilt at 0.5 s | Past the 35.3° balance angle | Blast only | Full | Wall time, blast only / full |
| --- | ---: | ---: | ---: | ---: | --- | --- | ---: |
| 0.2 m uniform (gap 0.2 m) | 3.20 | 4.51 | 37.3° | 0.48 s | overturns | overturns | 1 / 6 s |
| 0.1 m uniform (gap 0.1 m) | 1.84 | 4.59 | 10.4° | — | upright (12.6° peak) | upright (12.0°) | 14 / 53 s |
| 0.075 m (0.15 m × 2) | 4.51 | 4.83 | 27.1° | 0.61 s | overturns | overturns | 10 / 119 s |
| 0.05 m (0.1 m × 2) | 4.16 | 4.86 | 35.7° | 0.50 s | overturns | rocks back from 36.1° | 34 / 512 s |
| 0.05 m (0.2 m × 4) | 4.17 | 4.99 | 40.8° | 0.46 s | overturns | overturns | 26 / 161 s |
| 0.0375 m (0.15 m × 4) | 3.99 | 4.94 | 47.0° | 0.41 s | overturns | overturns | 71 / 357 s |
| 0.025 m (0.1 m × 4) | 3.75 | 4.89 | 46.5° | 0.41 s | overturns | overturns | 258 / 1822 s |

With the gap resolved the car overturns: the blast throws it up (its centre of mass reaches
about 1.0 m at 0.3 s, 0.3 m higher than its tyres would put it) and rolls it past its
balance angle, the two finest grids agreeing on when (0.41 s) and on the tilt at 0.5 s
(46.5–47.0°). The sideways impulse has converged within 2%; the upward one still falls by
about 5% with each refinement, which the tilt does not follow, since the moment about the far
tyres matters more than the total. The one full run that rocks back (0.05 m on 0.1 m air) is
turned by the late flow, which pushes it back towards the charge by 4 kN s between 0.4 and
0.7 s; it then yaws and leaves the cropped domain at 1.31 s. Letting the air act for 0.3 s
instead of 0.15 s changes no outcome.

How far the answer is from its threshold: on 0.05 m cells the car still overturns with 90% of
the air's load and rocks back with 80% (peak 38.8°); the finer grids tip it faster.

### 5 and 1 kg

| Near-car cells | 5 kg: up / sideways (kN s) | 5 kg peak tilt | 1 kg: sideways (N s) | 1 kg peak tilt |
| --- | --- | ---: | ---: | ---: |
| 0.2 m uniform | 1.20 / 2.17 | 5.7° | 326 | 0.1° |
| 0.1 m uniform | 0.73 / 2.34 | 3.1° | 400 | 0.4° |
| 0.075 m | 1.91 / 2.34 | 7.5° | 336 | 0.1° |
| 0.05 m | 1.98 / 2.52 | 9.9° | 352 | 0.1° |
| 0.0375 m | 1.95 / 2.47 | 10.0° | 370 | 0.1° |

At 5 kg the car rocks to 10° and back, the two finest grids agreeing within 0.1°; at 1 kg it
barely moves, and the net upward impulse is a small difference of push and suction.

### Checks

- *Still air:* no load on a resting car with patches over it.
- *Flight in still air* (`--car-flight`): the shell flying at 2 m/s while rolling at
  1.5 rad/s, with no gravity, picks up about 45 N s in 0.2 s (sideways), near the impulse to
  set the surrounding air moving, falling from 98 N s on 0.2 m cells to 44 N s at 0.05 m and
  alike with connected transport. Moving the shell across whole cells is not the source of the
  late loads.
- *Repeatability:* reruns are bit-identical.
- *Domain:* growing the domain by half each way changes the 50 ms impulses by under 3% and
  delays the overturn from 0.91 to 1.14 s (0.05 m at the car).
- *Cost* is the coupling as much as the air: moving the shell through the fine patches is
  done on the CPU each step. A dense index over the shell's region replaced dictionaries
  there, and box impulses are summed over the patches in use only, which cut the coupling's
  time about fourfold with bit-identical loads. Wall times above were measured with the Mac
  heavily loaded by other work and vary by a factor of two.

### What would converge the late flow

The late loads come from the air's flow after the blast while the car is steeply tilted:
whole-cell masks there still make the closing wedge between the shell's far side and the
ground, and the hot gas that engulfs the car, depend on the grid. A fractional (cut-cell)
shell would remove the first; gravity in the air (the fireball's buoyant rise) and a domain
that holds the whole fireball would address the second. Until then, results after the blast
should be read as indicative.

## Several objects

`RigidBodyWorld` steps several boxes and cars together with the ground, static blocks and each
other. Contact is found from corners: each box's corners against the other boxes and blocks,
and each block's corners against the boxes, with a point on a face, edge or corner taking the
face nearest the other body's centre. Impulses are speculative and inelastic, with Coulomb
friction (static tried before sliding, the pair taking the smaller coefficients), as in the
single-body references. Between bodies they are equal and opposite, so contact conserves
linear and angular momentum and cannot add kinetic energy; positional corrections move
positions only. A sweep along x over bounds grown by each body's travel in the step picks
the candidate pairs. A car's tyres touch only the ground; its shell touches everything.

Tests: a box sliding into a wall stops against it, at the speed friction predicts on arrival,
without rebound or entering it; two cars colliding conserve linear and angular momentum in
free flight to 1 part in 10⁹ and horizontal momentum on frictionless ground, losing energy and
sharing their speed when side by side; stacks with equal footprints, on the ground and on a
block, rest without creeping and carry their weight; the sweep finds exactly the overlapping
pairs; one car moves as the single-car reference does.

Contact cost, mechanics only (`--contact-benchmark`, boxes falling into a pen in four layers,
1 ms steps, the Mac heavily loaded):

| Boxes | Contacts | Pairs tested | Pairs unfiltered | Time per step |
| ---: | ---: | ---: | ---: | ---: |
| 16 | 30 | 21 | 184 | 2.0 ms |
| 64 | 115 | 88 | 2,272 | 8.8 ms |
| 256 | 463 | 421 | 33,664 | 38.7 ms |

`ExperimentalRigidWorldSimulation` couples one object, by default the one nearest the charge,
to the air as the car study does, and moves the rest through contact only. The others take no
air load and do not obstruct the blast, so they neither shield nor reflect onto the coupled
one. This is a mechanics reference for populated scenes, not a prediction of the air's loads
on more than one object.

### A row of cars

Four saloons in 2.4 m bays (0.85 m apart), 10 kg 1.5 m from the first
(`--car-row --cases=0.2x4`): the first slides 0.93 m (peak 6.4 m/s) into the second, which
props it at 19.5° and is itself shoved 0.19 m; the third and fourth are not reached. The
neighbour stops the overturn the lone car undergoes. On identical geometry, holding every car
took 51 s (air 39 s, coupling 12 s) and the free run 225 s (air 100 s, coupling 123 s,
motion and contact 0.8 s), over 9,700–10,400 steps; the air's time doubled between the two
with the Mac's load, so only the coupling and contact figures separate cleanly.

## In the app

The layout editor's "Freestanding objects (experimental)" section adds boxes, cars and a row
of four cars, duplicates and removes them, and edits position, heading, mass, a box's size and
friction through the definitions' validation. They are saved in the project as before
([save files](save-files.md)); older projects have none. They do not take part in the ordinary
run. Compute Motion runs `FreestandingMotion` in the background: the scene cropped to the
objects and the charge with 2.4 m around them (at most 3 million cells of 0.2 m), the
nearest object on 0.05 m cells, the rest moving through contact. The section lists each
object's displacement, peak speed, peak tilt and outcome, with the cost, and a slider shows
the poses in the 3D view, which draws freestanding objects as oriented boxes. A result is
marked out of date when the layout changes. A deformable structure in the scene is refused.

## Limitations and future work

- One object at a time takes the air's load. Several in the air need the solver's moving
  boundary for more than one box, and per-object load recording on the GPU.
- Late flow is not converged (above).
- Edge-on-edge contact between boxes crossed at an angle is not found; contact is inelastic
  and first order in time; the stack test settles but does not prove stability of tall piles.
- Locked wheels, rigid suspension, no crushing; the saloon is illustrative.
- Next: a fractional shell boundary, the air's gravity, objects in the air together, a
  populated car park and a furnished room.
