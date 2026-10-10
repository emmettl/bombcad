# Freestanding objects

Experimental. Rigid boxes and simplified cars that slide, lift, tip and strike each other, the
scene's blocks and deformable structures, every one of them coupled to the air. Nothing here is
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

`ExperimentalRigidStructureSimulation` steps the objects with a structure of solid elements or
shells, without air, at the structure's own time step. After each structure step the nodes
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

The coupling costs as much as the air or more in every scene: it is the CPU remapping each
object's region of fine cells, with masks and wall speeds, every step, which grows with the
objects' surface and the fineness of their cells, not with the domain. Motion and contact
together stay under 1% of the time even for 48 boxes; mechanics alone, 256 boxes take 39 ms a
step (the contact table above). No throughput is promised from these figures.

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

## Limitations and future work

- Late flow is not converged (above), for one object or many; objects that touch share whole
  cells, and a cell trapped between them trades gas with air a cell or two away.
- The coupling's cost, the CPU remap of each object's fine cells every step, exceeds the air's
  in populated scenes; it would fall if only cells whose occupancy changes were remapped, or
  if the remap moved to the GPU.
- Objects striking a deformable structure do so without air, and corners pressed into a face
  between its nodes are not found; the motion run in the app refuses a deformable structure.
- Edge-on-edge contact between boxes crossed at an angle is not found; contact is inelastic
  and first order in time; the stack test settles but does not prove stability of tall piles.
- Locked wheels, rigid suspension, no crushing; the saloon is illustrative, and furniture is
  solid boxes.
- Next: a fractional shell boundary, the air's gravity, objects and a deformable structure in
  the air together.
