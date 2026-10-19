# Freestanding objects

Experimental. Rigid boxes and simplified cars that slide, lift, tip and strike each other, the
scene's blocks and deformable structures, every one of them coupled to the air. Nothing here is
validated against a blast experiment: the car is an illustrative 1500 kg saloon on locked
tyres with rigid suspension, and the checks below are numerical and mechanical. The staged plan
is [below](#the-staged-plan); milestones 1–3 (one box, one
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
  from 0.1 to 0.4 s it agrees (−0.1 to −0.5 kN s). It is the blast's load that converges. Most
  of the late disagreement was the domain's copying faces (see [Far-field
  faces](#far-field-faces-16-october-2026)).

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

### Far-field faces (16 October 2026)

The runs above copied the cells inside at the domain's open faces, which drains the cropped
domain: it lost 20–38% of its gas by the end. The study now puts ambient air beyond them
(`--copy-faces` for the old runs). Full runs, 10 kg, the air's impulses to 50 ms:

| Near-car cells (outer) | Up (kN s) | Sideways (kN s) | Tilt at 0.5 s | Past 35.3° | Outcome |
| --- | ---: | ---: | ---: | ---: | --- |
| 0.2 m uniform | 4.04 | 5.56 | 44.3° | 0.40 s | overturns |
| 0.1 m uniform | 2.85 | 5.41 | 29.1° | 0.63 s | rocks back from 44.5° |
| 0.075 m (0.15 m × 2) | 4.99 | 5.83 | 40.8° | 0.43 s | overturns |
| 0.05 m (0.1 m × 2) | 4.72 | 5.86 | 49.9° | 0.36 s | overturns |
| 0.05 m (0.2 m × 4) | 4.68 | 5.87 | 50.1° | 0.36 s | overturns |
| 0.0375 m (0.15 m × 4) | 4.53 | 5.88 | 53.5° | 0.35 s | overturns |

- **The late flow's disagreement was the copying faces'.** The one refined grid that rocked back
  (0.05 m on 0.1 m air, 52° with today's code) overturns, and every refined grid now passes the
  balance angle within 0.35–0.43 s. The domain lost 12.5% of its gas, the same on every grid.
- **The blast pushes harder**: the sideways impulse rises by a fifth, to 5.8–5.9 kN s, the same
  within 1% on the four refined grids, and the upward one by 13%, still falling about 5% with
  each refinement.
- **The row** (`--car-row --cases=0.2x4 --nearest-only`) is the same in kind: the first car slides
  0.94 m into the second, which props it at 30.8° (19.6° with copying faces) and is shoved 0.32 m
  (0.20 m).

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

### Every object in the air

`ExperimentalRigidWorldSimulation` puts every object in the air, as the car study puts one:
each is a moving boundary with its own patches, so objects shield and reflect onto each other,
and each takes the load of the faces it owns. The solver keeps a list of boxes; the shaders take
each one's definition and bounds from a buffer, and record one impulse per cell face instead of
a summed force and moment, which the host gives to the box beyond the face, about that box's
centre of mass. Where two boxes would share a cell, the first in the list has it. Boxes whose
regions overlap, patches meeting or overlapping, are remapped together, the rest apart (side by
side on the CPU), and every box moves or none does. An object about to leave the cropped air
domain leaves the air for good and carries on under gravity and contact. A cell freed or
squeezed between objects that touch, with no air beside it, trades gas with the nearest air a
few cells away. Objects can still be left out of the air (`coupled:`), to compare with the
nearest alone.

Tests (`ExperimentalRigidWorldTests`):

- Two held boxes side by side, the charge facing their seam, take between them the load of one
  box of the same total size to 1 part in 10⁹, and their moments about its centre add up to
  its moment; each takes half the push to 1%, and the pressure on their outer sides pushes
  them together. On uniform 0.1 m air and on 0.2 m air with patches twice finer.
- A box 0.6 m behind another of the same size is sheltered: its peak force is 19% of what it
  takes alone (30.6 against 164.5 kN), while the front box's peak is unchanged.
- Three free boxes moving through closed, uneven air with patches twice finer, two of them
  0.1 m apart so that their patches meet and they strike each other, keep the gas's mass and
  energy to 1 part in 10⁷ as they are placed and its mass to 1 in 10⁶ over 100 steps, by both
  remaps; two moving boxes and the air exchange equal and opposite momentum.
- An object thrown out of the domain leaves the air without losing gas and carries on; trapped
  cells borrow from and give to the nearest air conservatively.
- One car still moves as the single-car driver does.

### A row of cars

Four saloons in 2.4 m bays (0.85 m apart), 10 kg 1.5 m from the first
(`--car-row --cases=0.2x4 --nearest-only`), only the first in the air: the first slides 0.93 m (peak 6.4 m/s) into the second, which
props it at 19.5° and is itself shoved 0.19 m; the third and fourth are not reached. The
neighbour stops the overturn the lone car undergoes. On identical geometry, holding every car
took 51 s (air 39 s, coupling 12 s) and the free run 225 s (air 100 s, coupling 123 s,
motion and contact 0.8 s), over 9,700–10,400 steps; the air's time doubled between the two
with the Mac's load, so only the coupling and contact figures separate cleanly.

## Striking a deformable structure

`ExperimentalRigidStructureSimulation` steps the objects with the scene's structures, of solid
elements, shells or both, without air, all at the shortest of their time steps (a box thrown
between two walls strikes the one it is thrown at, which alone takes the reaction). After each structure step the nodes
near an object are handed to `RigidBodyWorld` as point masses (a shell's as spheres of half its
thickness); the object's faces strike them with the same inelastic, frictional impulses as
everything else, equal and opposite, and the nodes' new velocities go back to the structure.
Contact so conserves the momentum of objects and structure together and cannot add kinetic
energy; positional corrections move only the objects. Held nodes are immovable, and a solid's
interior nodes are left out, as in the structure's own contact. The reaction on the structure,
and the kinetic energy contact takes from the objects and gives the structure, are recorded.

Tests (`ExperimentalRigidStructureTests`, an elastic block of 3 GPa, 0.1 m elements, a 0.4 m
box of 50 kg at 5 m/s): thrown into a free block, solid or shell, the box stops and the
block's momentum equals the reaction, the total conserved to 1 in 10⁴ (the nodes' velocities
are single precision); contact takes 625 J from the box and gives the block about 150 J, never
more than it takes. Thrown into a wall clamped at its base, the box's momentum change is the
reaction to 1 in 10⁹, and it goes 0.2 mm (solid) or 1 mm (shell) past the wall's face.

A 100 kg box (0.5 m) at 10 m/s into a reinforced concrete wall 0.2 m thick, 3 m wide and 2.5 m
high, clamped at its base, 0.1 m elements (`rigidboxdemo --box-wall`):

| Wall | Reaction (N s) | Peak force over 0.5 ms | Box leaves at | Into the face | Wall moves | Contact: from the box / to the wall | Time |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Solid elements | 1,061 | 1.49 MN | 0.61 m/s | 1.5 mm | 8.4 mm | 4,975 / 2,054 J | 1 s |
| Shells | 1,052 | 1.45 MN | 0.52 m/s | 3.1 mm | 8.7 mm | 4,983 / 1,530 J | 2 s |

The two walls agree within 3% on the force and on how far they move. Contact is perfectly
inelastic at each node, so the box loses almost all its 5 kJ at the first touch and only the
wall's own spring gives it back a little speed; a real box's rebound would depend on its own
stiffness, which a rigid box does not have.

## Populated scenes

`PopulatedScene` builds three scenes, every object in the air, the structures rigid blocks held
still, the objects resting on the ground under gravity, held by friction alone and fixed to
nothing:

- **Car park with parked cars**: the car park layout (two decks and a roof of 250 mm slab on
  400 mm columns on a 7.5 m grid), here rigid, with 17 saloons side by side in 2.4 m bays, a
  row in each span between column lines and one in the open beside the building, and 100 kg
  0.8 m up in a car on the ground floor (that car not modelled). Tyres 0.8 static, 0.7 sliding.
  Air of 0.15 m, 0.075 m at the cars, resolving their 0.15 m gap exactly.
- **Furnished room**: a 6 × 5 m room 2.8 m high, walls 0.3 m thick with a door and a window,
  furnished with a dining table and four chairs, a desk and its chair, a sofa, a cabinet, a
  bookcase and a side table at typical masses (6 to 60 kg), 1 kg 0.3 m up by one end wall.
  Each piece is a solid box: the space under a table or chair is filled, overstating the area
  that faces the blast low down and leaving out the flow through it. Friction 0.5 static and
  0.4 sliding (wood or fabric on a hard floor). Air of 0.1 m, 0.05 m at the furniture.
- **Crowded pen**: 48 boxes of 0.5–0.6 m and 20–40 kg, side by side almost touching, three
  layers in a pen of rigid walls open towards 2 kg 1.5 m away. Air of 0.2 m, 0.1 m at the boxes.

The first two are layouts in the app. Each ran for the time shown, free and with every object
held on the same geometry, so the air's own cost is measured apart from the motion, the
coupling and the contact (`rigidboxdemo --populated`). The Mac was heavily loaded by other work
(load averages of 30 to 45 on 14 cores), so times vary by a factor of two or more between runs;
the held and free air times differ for that reason as much as any other.

| Scene | Objects | Air cells (at the objects) | Simulated | Held: steps, air / coupling | Free: steps, air / coupling / motion and contact | Free over held |
| --- | ---: | --- | ---: | --- | --- | ---: |
| Car park with parked cars | 17 cars | 606,144 of 0.15 m (0.075 m) | 0.5 s | 5,721: 95 / 56 s | 7,821: 126 / 488 / 0.8 s | 4.1× |
| Furnished room | 11 pieces | 558,144 of 0.1 m (0.05 m) | 0.3 s | 4,071: 10 / 6 s | 5,290: 30 / 74 / 0.5 s | 6.9× |
| Crowded pen | 48 boxes | 44,982 of 0.2 m (0.1 m) | 0.3 s | 2,343: 6 / 3 s | 2,345: 7 / 12 / 0.4 s | 2.2× |

Per step, the coupling of moving objects took 62 ms in the car park, 14 ms in the room and 5 ms
in the pen, against 10, 1.5 and 1.3 ms with them held (reading their loads alone); the air took
16, 2.5 to 6 and 3 ms. Moving objects also shorten the step (a box may cross a fifth of a fine
cell per step), which is why the free runs take more steps.

What they show: in the car park the cars either side of the charge's are thrown at 31–32 m/s,
one leaving the cropped air at 63 ms and rolling over, the other sliding 3.5 m and tipping to
31°; the cars of the second row, behind the first, move 0.1 to 3.9 m, one overturning, and the
row in the open beside the building up to 4 m, one ending on its side; four cars had left the
air by 0.32 s and carried on without its load. In the room the chairs nearest the charge are
thrown at 20–35 m/s and travel 2.6–3.0 m in 0.3 s, the table slides 0.4 m and tips to 38°, and
the desk, its chair, the side table and the cabinet pass their balance angles; the bookcase in the far corner barely moves. In
the pen the front boxes reach 7 m/s, the whole stack shifts by 0.1 m on average, and one box of
48 tips over.

The coupling cost as much as the air or more in every scene: it was the CPU remapping each
object's region of fine cells, with masks and wall speeds, every step, which grows with the
objects' surface and the fineness of their cells, not with the domain.

Since 18 October 2026 the remap redistributes only the cells that open or close, finds each
cell's new outline in slabs side by side, finds patches through the blocks' map rather than
scanning the pool, and writes back only what changes; the loads are gathered side by side and
summed in the blocks' order. On the same inputs it writes the same gas, outlines and walls to
the bit as before, step by step, and the three scenes run to the bit as they did with the two
fixes that came with it. Groups of boxes whose spans meet are now remapped together: a box in
the corner of an L of others had been opened by their remap and closed by its own, and the
pieces in the room now move up to 5 mm differently out of 0.13–1.9 m. And loads are summed in
the blocks' order, not the pool's, so a run repeats to the bit (the room's had parted after
0.05 s). Over the scenes' first 0.1 s on the CI Mac mini (base M4, shared with other work, so
indicative), the coupling's time fell from 3 to 1 s in the pen, 41 to 13 s in the room and 66
to 32 s in the car park, against the air's 14, 85 and 225 s there. At the scenes' full lengths,
free, on the same Mac:

| Scene | Simulated | Coupling before / after | A step before / after | Run before / after |
| --- | ---: | ---: | ---: | ---: |
| Car park with parked cars | 0.5 s | 611 / 155 s | 56 / 15 ms | 1,417 / 771 s |
| Furnished room | 0.3 s | 67 / 21 s | 13 / 4.1 ms | 155 / 85 s |
| Crowded pen | 0.3 s | 8 / 3 s | 3.4 / 1.3 ms | 17 / 11 s |

The car park's run before shared the Mac with more work (load averages of 12 to 25 against 3 to
8), which flatters the change there; the room's and the pen's ran alike. Held, reading the loads
alone, the coupling fell from 48 to 34 s, 9 to 3 s and 2 to 1 s.

Motion and contact together stay under 1% of the time even for 48 boxes; mechanics alone, 256
boxes take 39 ms a step (the contact table above). No throughput is promised from these figures.

## In the app

The layout editor's "Freestanding objects (experimental)" section adds boxes, cars and a row
of four cars, duplicates and removes them, and edits position, heading, mass, a box's size and
friction through the definitions' validation. They are saved in the project as before
([save files](save-files.md)); older projects have none. They do not take part in the ordinary
run. Compute Motion runs `FreestandingMotion` in the background: the scene cropped to the
objects and the charge with 2.4 m around them (at most 3 million air cells), every object in
the air, on 0.2 m air with 0.05 m cells around each for up to four objects and on 0.15 m air
with 0.075 m cells beyond that. The section lists each object's displacement, peak speed, peak
tilt and outcome, and whether it left the air, with the cost, and a slider shows the poses in
the 3D view, which draws freestanding objects as oriented boxes. A result is marked out of
date when the layout changes. A deformable structure in the scene is refused. The layouts
"Car park with parked cars (freestanding)" and "Furnished room (freestanding)" open the
populated scenes above.

## The staged plan

The four milestones the work followed, with what was done at each (moved from the
[roadmap](roadmap.md#freestanding-objects-and-supports) on 11 October 2026). The studies behind
milestones 1 and 2 are in [rigid-box coupling studies](rigid-box-coupling-studies.md).

A fixed base, the default, represents an intact attachment to a rigid foundation. A base can
instead stand on connections that deform, open, slide and fail, or on a footing on soil (see
the [structural model](structural-model.md#base-connections)). Independent rigid objects, boxes
and a simplified car, move under gravity, friction and contact, coupled to the air. These are
mechanics checked against theory, not validated vehicle or furniture models.

1. **One rigid box, without blast.** Add scenario objects with shape, pose, mass, centre of
   gravity, rotational inertia and contact properties, with backward-compatible persistence.
   Keep rendering geometry separate from simple collision shapes. Implement translation,
   rotation, gravity, unilateral ground contact and static/sliding friction. Verify rest under
   gravity, the sliding threshold, response to prescribed linear and angular impulses, and
   rocking and tipping without artificial energy gain; check timestep convergence.
2. **One box coupled to the air.** Integrate surface pressure into force and torque, and
   update moving boundaries on the coarse and refined air grids. Handle exposed air cells,
   moving-wall velocity and motion beyond the initial coupling region. Check gas conservation,
   momentum exchange and sensitivity to air resolution and timestep before adding scenes.
3. **One simplified car.** Use a rigid body with four tyre contact locations and an explicit
   all-wheels-locked assumption, initially with rigid suspension. Friction depends on each
   contact's normal force and vanishes on lift-off. Check sliding and load transfer, then
   rocking and tipping; distinguish these mechanical checks from validation against a blast
   experiment. Crushing, wheel rotation and fragmentation are later extensions. (Done: the
   mechanics in `RigidCarBody`, the box reference with the box as the shell and four
   tyre contacts at the corners of a wheelbase × track rectangle, each with its own load and
   Coulomb friction; the shell's corners catch a car that has tipped. `RigidCarDefinition`
   saves the locked wheels and rigid suspension explicitly, as `Scenario.rigidCars` beside
   rigid objects. Rigid suspension leaves four tyre loads indeterminate; the reported split is
   the one equal tyre stiffnesses give, which leaves the motion unchanged. Tests check rest
   loads against statics, the sliding threshold μW, load transfer of μWh/L under braking and
   μWh/t sliding sideways, a sideways push holding below the static stability factor t/2h and
   tipping above it, rocking back below the balance angle atan(t/2h) and tipping onto the side
   above it, no energy gain, first-order timestep convergence and saved-file round trips.
   These are mechanical checks; none is a validation against a blast experiment, and the
   illustrative saloon's values are typical magnitudes, not a measured car. `swift run
   rigidboxdemo` adds five car cases to the replay. Coupled to the air as the box is:
   `ExperimentalRigidCarSimulation` puts the shell in the air, held clear of the ground so the
   blast reaches the underside, and drives the car with the air's impulse and torque; the
   tyres are contact points only. Tests check ambient balance on the static tyre loads, the
   momentum budget, the force and torque of a pressure gradient about the low centre of mass,
   and a blast loading the far tyres. `swift run -c release rigidboxdemo --car-blast` replays
   the saloon 1.5 m from 1, 5 and 10 kg for 2 s (`--fine` for 0.05 m cells around the car). These are not
   converged: the 0.15 m gap under the shell spans at most one cell, and from 0.2 to 0.1 m
   cells the 10 kg air impulse goes from 6.4 to 9.0 kN s sideways and from 8.2 to 3.7 kN s
   up, and the car rocks to 25° and back instead of overturning. Resolved: whole-cell masks made
   the gap 0.2 m on 0.2 m cells and 0.1 m on 0.1 m ones, and patches started with gas packed
   under the shell. With patches resolving the gap exactly, 10 kg overturns on near-car cells
   from 0.075 to 0.025 m, the blast's load converging (passing the balance angle at 0.41 s on
   the two finest); 5 kg rocks to 10° and 1 kg barely moves. Flow after the blast, with the car
   steeply tilted, is not converged. See [freestanding objects](freestanding-objects.md).)
4. **Several objects and populated scenes.** Add collisions with static scenery, deformable
   structures and other objects, using spatial filtering. Expose placement, duplication,
   properties, animated poses and displacement/speed/tipping results in the app. Progress
   from a row of cars to a populated car park and a furnished room, with explicit friction
   and support assumptions. Benchmark each against identical geometry held stationary,
   reporting air-grid cost separately from motion, coupling and contact; include a crowded
   collision case. Do not promise a throughput target before these measurements. (Done:
   contact between bodies, blocks and the ground with a sweep over grown bounds; every object
   in the air with its own moving boundary and patches, tested against one box of the same
   size, a sheltered box and the gas's budget; objects striking solids and shells, with
   momentum and energy budgets; a populated car park, a furnished room and a crowded pen in
   the app or the study, each against the same geometry held, the coupling costing more than
   the air. See [freestanding objects](freestanding-objects.md#several-objects).)

## Limitations and future work

- Late flow is not converged (above), for one object or many; objects that touch share whole
  cells, and a cell trapped between them trades gas with air a cell or two away.
- The coupling still runs on the CPU every step, now well below the air's time in populated
  scenes (above); moving the outline pass to the GPU would cut it further.
- Objects striking a deformable structure do so without air, and corners pressed into a face
  between its nodes are not found; the motion run in the app refuses a deformable structure.
- Edge-on-edge contact between boxes crossed at an angle is not found; contact is inelastic
  and first order in time; the stack test settles but does not prove stability of tall piles.
- Locked wheels, rigid suspension, no crushing; the saloon is illustrative, and furniture is
  solid boxes.
- Next: a fractional shell boundary, the air's gravity with these objects (it is now an
  [option](air-blast-model.md#gravity) for the air alone), objects and a deformable structure in
  the air together.
- **Objects and a deformable structure in the air together, stage 1** (19 October 2026, on the
  coarse grid). Their masks and wall velocities now coexist:
  - (a) With objects installed beside a structure, the structure's coupling is laid over the
    whole grid, so one wall-velocity buffer, a cell's at three times its index, serves both.
  - (b) The structure's remask leaves the objects' cells solid at the objects' velocities.
  - (c) The objects' remap keeps the cells the structure holds, with their velocities.

  `ObjectsBesideStructureTests` holds a 0.4 m box, given 2 m/s, beside a steel plate that 1 kg
  bends, in a closed domain, over 300 steps:
  - **The box's cells** never open or lose their velocity.
  - **The box's remaps** change no cell, while the plate's outline moves through 221.
  - **The gas** changes by 16.3 g with both, against 16.8 g with the plate alone (its remask's
    refills) and nothing with the box alone.

  Scenes with one kind take their old paths unchanged.

  **Refused for now.** The objects' own fine resolution
  (`SolverConfiguration.refinement`) and refined air are refused beside a structure, and
  structures must be set before the objects. The whole-grid layout costs a remask over every cell
  at each structure step, and that has not been timed on a large scene. Contact between the objects
  and the structure (d), and the app's and headless runs (e), are the stages left.
- Objects and a deformable structure in the air together need, as found on 18 October 2026:
  (a) one layout for the coarse wall velocities, which a structure's coupling indexes by its
  region or sparse tiles and the objects over the whole grid; (b) the structure's remask, coarse
  and fine, keeping the objects' cells and their wall velocities (it rebuilds the outline from
  the rigid mask and the elements, and the fine pass drops the objects' mark); (c) the objects'
  remap keeping the structure's cells (it rebuilds from the scenery and the objects, so would
  open and close them every step, moving gas about); (d) contact between the objects and the
  structure's nodes at the structure's own step, the air's step held to it while an object is
  near; (e) the app's and headless motion runs taking the structure. In stages: masks and walls
  that coexist, tested with held objects beside a moving structure; then the contact, with a
  car thrown against a wall against the reference without air; then the app.
