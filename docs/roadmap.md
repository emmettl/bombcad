# Roadmap

Where the model is weakest, and what would be done about it. Each model document has its own
detailed list; this one puts them in order across the whole project.

A separate [RoomCAD and convolution reverb roadmap](roomcad-roadmap.md) covers shared SwiftPM
modules, acoustic impulse-response generation, WAV export and potential Driftbox rack
integration, with milestones and acceptance checks. It does not replace the blast-model work
below.

## Standing of the project

BombCAD answers its original question: blast on simple structures can be simulated on a laptop
GPU at tens to a hundred times slower than real time, with physics that is verified against
theory. Against measurements it is close on one test (a slab) and too stiff on another (a
full-scale internal explosion). It is not validated for engineering decisions, and nothing in
it should be used to judge the safety of a real structure.

## Limitations, most important first

| # | Limitation                                                              | Consequence                                                   | Detail |
|---|-------------------------------------------------------------------------|---------------------------------------------------------------|--------|
| 1 | The structural model has been compared with five tests, and springs back too far | On a slab test the peak converges to 105 mm against 108 measured; a beam bent to failure carries 97–99% of its measured moment; a beam failing in shear carries 111–112% of its measured load on fine meshes, 137% on coarse; beams struck by a falling weight with stirrups peak within 15% under light drops and −5% to +15% under heavy ones, and Ando's beams without stirrups break at the speed the tests did, while Saatci's without stirrups breaks under a drop it survived; full-scale slabs under close-in charges are left a third as far down as measured, barely spalled and not holed; in a full-scale internal explosion, with the chamber's detailing modelled, the roof peaks at 38 mm against 87 mm in the test paper's own model, and its edge is left 15 mm up against 95 mm measured; on the finest mesh the answer has not converged | [Validation](validation.md#an-internal-explosion-in-a-reinforced-concrete-chamber) |
| 2 | Shear failure and joints are the least reliable predictions             | Breach, punching, direct shear and wall–slab joints are indicative only | [Concrete model](concrete-model.md#limitations) |
| 3 | The default gas has no afterburning and treats hot air as cold          | Incident impulse 13–22% low and rooms' gas half the design value, unless afterburning and hot air (2 times slower) are switched on | [Air-blast model](air-blast-model.md#hot-air) |
| 4 | Peak pressure is under-resolved near the charge                         | Close-in loading and spall are unreliable                     | [Air-blast model](air-blast-model.md#limitations) |
| 5 | Collapse and debris have never been compared with anything              | They look plausible; that is all                              | [Structural model](structural-model.md#limitations) |
| 6 | Moving solids are a staircase of whole cells                            | Wall positions are good to a cell; small fragments are crude  | [Structural model](structural-model.md#coupling-to-the-air) |
| 7 | One bonded body of up to eight materials, lattice-aligned geometry; debris pushed crudely by the air | Real buildings only roughly; thrown debris is approximate | [Structural model](structural-model.md#limitations) |
| 8 | The rebound after a slab's peak is too large; close-in concrete is unchecked | Rebound is too large; compaction is modelled, but its strength does not grow with pressure | [Concrete model](concrete-model.md#limitations) |
| 9 | Ground restraints are permanent; independent rigid objects cannot move | Foundation failure is excluded; cars and furniture cannot slide, lift or overturn as independent bodies | [Freestanding objects and supports](#freestanding-objects-and-supports) |
| 10 | The app's interface has not been reviewed by eye                       | Layout or interaction problems may exist                      | Below |

On the last point: the app's logic is covered by tests that drive its model without a window,
and its rendering is checked through offscreen snapshots, but its panels, text fields and file
dialogs were written without being seen on screen.

## Planned work

### Validation first

More evidence is worth more than more features. The sources each step needs, and what is
needed from them, are listed in [Data wanted](data-wanted.md).

1. **The chamber's joints.** In the test they were cut through within milliseconds and the
   roof was left 95 mm up; the model's stay whole, carry an arching thrust that outlasts the
   load, and bring the roof back to 7 mm. And the 25 mm mesh, on which the peak (65 mm) has
   not converged and the wall tops tear on the rebound. (Done: bars resisting sliding across
   cracks, and cracks bridged across a section, which took the roof from thrown to about
   100 mm; cracks that turn with the stress until they open; then the detailing itself, as
   inclined bars across the chamfers and mats and ties in the down-stand, with a time step
   that allows for the bars and contact that holds eight nodes a cell. With the detailing the
   roof is about twice as stiff as the paper's model: 38 mm against 87 mm. The diagonal bars'
   size and the down-stand's steel are assumptions; see
   [Validation](validation.md#an-internal-explosion-in-a-reinforced-concrete-chamber).)
2. **A fourth and fifth structural test**, chosen to differ from those so far: a slab with
   steel in both faces, a member with stirrups, and a wall under an open-air charge. The
   high-strength slabs of the same contest are the obvious next case, since the geometry and
   loading are already set up; their data would have to come from Thiagarajan et al. (2015).
   (Done: a beam bent slowly to failure, Janney et al. (1956) via Xu and Lu (2016), whose
   peak moment the model gives within 3% on two meshes, with nothing fitted; it found
   splitting cracks along the bars softened over too wide a band, now fixed. See
   [Validation](validation.md#a-reinforced-beam-bent-to-failure). And Vecchio and Shim's beam
   OA1 without stirrups, via Bernardi et al. (2016), which fails in diagonal tension as the
   test did, 11–12% strong on fine meshes and 37% strong on coarse ones; see
   [Validation](validation.md#a-beam-failing-in-shear). And Saatci's drop-weight impacts on
   beams with and without stirrups (2007): light drops within 10%, heavy ones within −8% to
   +16% with the Model Code's tensile strain-rate law, the beam without stirrups broken only by the
   heavy drop as in the tests; beams' sectional shear check fails every beam under impact; see
   [Validation](validation.md#beams-struck-by-a-falling-weight). And Chiquito et al.'s
   full-scale slabs under 2–15 kg at 0.5 and 1 m (2023): the load within about a tenth of the
   empirical impulse, but the slab a third as far down as measured, barely spalled, not punched
   through under the charge, and falling apart once broken where the tests' hung on their bars;
   see [Validation](validation.md#slabs-under-close-in-charges).)

### Then the physics the evidence points to

3. **Charge model.** Close-in peaks are under-resolved: a mapped one-dimensional solution
   would help there; and the products' own composition for the hottest gas. (Close in, the
   reflected impulse converges to within 8% of Kingery–Bulmash from 0.3 m/kg^(1/3) on cells of
   a hundredth of the charge's cube root, or twice that refined, so the products' own equation
   of state is not needed for the load; see [Validation](validation.md#close-in).) (Done:
   afterburning, limited by mixing and oxygen, and thermally perfect air, which together bring
   the closed-room gas pressure within 8% of UFC 3-340-02 and the incident impulse in the open
   within 6% of Kingery–Bulmash; and the air's dissociation, as an option, which moves those
   by under 1% in the open and up to 6% in the densest rooms, at 3.6 times the cost; see the
   [air-blast model](air-blast-model.md#dissociating-air).)
4. **Shear in concrete.** A member that failed in shear under a blast, to judge a sectional
   check for shells; a sectional check that works under impact, where the present one breaks
   every beam; and solid elements that fail in shear on coarse meshes. (Beams now check each section's shear.) (Done: a test of a beam without stirrups that failed in shear; cracks whose axes
   turn with the stress until the crack opens, by default, after the lattice planes were
   found to mishandle inclined cracks, and a second crack once the tension has turned more
   than 30° from fixed axes; see [Cracking](concrete-model.md#cracking).)
5. **The concrete's tensile strain-rate law.** Saatci's heavy impacts were a quarter too
   stiff with Malvar and Ross's law, and the close-in slabs' spall had to overcome 17–21 MPa
   with it, where spalling tests find 10–15 MPa. (Done: the fib Model Code 2010's law, now the
   default, which brings the impacts within −5% to +15% and the contest slab to 96–103%; but
   under it the beam without stirrups breaks under the light drop it survived, split along its
   bars, so the shear such a beam carries across cracks at these rates is still open.) Which strengthening is the material's
   and which the specimen's inertia, already in the model, needs evidence from tests built to
   separate them.
6. **Close-in damage**: spalling of the faces, and a breach under the charge, which the
   close-in slabs show and the model does not produce on any mesh. (Done: bars that outlive
   the concrete around them, as bare elements, so that a holed member hangs on its bars; see
   [Removal](concrete-model.md#removal). And a fracture energy that grows more slowly with
   strain rate than the strength, after which the reflected wave spalls the far face under a
   close-in charge, over a tenth of the area the tests show.)
7. **The rebound.** The slab's mid-span hinge springs back twice as far as the specimen did on
   every mesh. (Done for beams: cracks that slide for good and ride up on their aggregate,
   after which beams struck by a falling weight keep their deflection as the tests did; the
   slab, whose hinge bends rather than slides, is unchanged.) (Done: compaction of the pores under very high confined pressure, after
   Holmquist, Johnson and Cook; unchecked against a close-in test.)
8. **Cut cells** between moving solids and the air. Moving walls already push the air (a
   piston test matches theory within 2%) and conserve the gas within 0.3%, so cut cells would
   now buy geometric precision only. Deferred.

### Then scale and scope

9. **Shells and beams that hold together like the solids.** (Done: the bars' dowel action in
   shells and beams, and punching at slab–column joints on Eurocode 2's strength, after which
   the slab hangs on its bottom bars; the shell frame now stands where the solid one does at
   250 kg, and the tall layouts need 4,000 kg to come down. Dowel action, Rasmussen's for a
   well-embedded bar, is probably too strong for bars near a face; see the
   [shell model](shell-model.md#limitations).)
10. **Contact that knows the shells' thickness.** (Done: shells and solids together, tied
   through the thickness, three times faster than all solid elements on the single-storey
   building with only its front wall solid, and in contact with each other once anything has
   failed; see the [shell model](shell-model.md#shells-and-solids-together).)
11. **Joints within materials**: bearings that separate; masonry's joints on coarse elements
   and in shells, as strengths that differ across and along the bed joints. (Done: several
   materials in one body; joints between materials that open at the bond of mortar to
   concrete; structural steel and annealed glass, the glass as shells in panes; and masonry
   as units and mortar joints in running bond, which open at the bond and slide by friction,
   on solid elements no more than half a course high: see the
   [concrete model](concrete-model.md#masonry-as-units-and-mortar-joints).)
12. **Adaptive resolution in the air**: several levels. (Done: one finer level, by 2 or 4, in
   blocks of 4 × 4 × 4 cells that follow the shock, conservative across its edge, with its own
   outline of blocks and structure, loading a deformable structure from the fine cells beside
   its faces, and carrying afterburning's fuel and oxygen; refined by 2, a grid gives the peaks of one twice as
   fine three to five times faster in the open. See the
   [air-blast model](air-blast-model.md#refining-near-the-shock). A finely resolved
   one-dimensional start, tried first, gave exact records close to a charge but no lasting gain.)
13. **Freestanding objects and supports.** Independent rigid bodies for parked cars and
   interior furniture, with gravity, friction, lift-off and collisions, coupled to the blast.
   Start with the staged checks below. Separately, make structural support assumptions visible
   and add connections with finite stiffness and strength where anchorage failure matters.

### Freestanding objects and supports

The current fixed base represents an intact attachment to a rigid foundation. Disabling it
does not supply a realistic friction model: ground contact prevents penetration and damps
horizontal velocity. Cars and furniture need independent motion and contact forces limited
by their actual ground reactions. This is planned work, not an implemented or validated
vehicle model.

Started: a standalone CPU reference for a rigid box, with analytical uniform-box mass properties,
linear and angular impulses, gravity, force/torque integration and orientation updates, plus
ground contact with lift-off and separate static/sliding friction. Thirteen tests cover
ballistic motion, rotated inertia, angular-momentum conservation, resting support, friction
thresholds and deceleration, lift-off, inelastic impact, rocking and tipping, and timestep
convergence. Contact uses a first-order impulse step with a small geometric tolerance and
positional correction; impacts have no rebound. This is a mechanics reference, not a measured
vehicle model or a performance-optimised production solver. Scenario definitions now persist
box shape, pose, mass, centre-of-mass offset, optional principal inertia and friction, and
convert into fresh reference mechanics state. Definitions validate on construction and load;
older layouts without them still open. JSON and project-package round trips are tested. A
nonzero centre-of-mass offset requires explicit inertia. These saved inputs are not yet used
by rendering or the blast solver. A standalone visual box demonstration is next; milestone 1
remains incomplete pending a reviewable demonstration.

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
   experiment. Crushing, wheel rotation and fragmentation are later extensions.
4. **Several objects and populated scenes.** Add collisions with static scenery, deformable
   structures and other objects, using spatial filtering. Expose placement, duplication,
   properties, animated poses and displacement/speed/tipping results in the app. Progress
   from a row of cars to a populated car park and a furnished room, with explicit friction
   and support assumptions. Benchmark each against identical geometry held stationary,
   reporting air-grid cost separately from motion, coupling and contact; include a crowded
   collision case. Do not promise a throughput target before these measurements.

Structural anchorage is a separate extension: retain ideal fixed supports as an explicit
option, then add connections that can deform, open and fail under tension or shear, with
contact and friction after separation. Compare fixed and finite-strength supports on a
freestanding wall or column before pursuing detailed footing and soil behaviour. Rigid-body
motion alone does not address foundation failure or deformable-object breakup.

Done from these lists: blast loads against the full Kingery–Bulmash curves; a coupled test
(the internal explosion); shell elements for walls and slabs and beam elements for columns (2
to 35 times faster coupled, see the [shell model](shell-model.md)); debris loaded by the air
(pressure gradient and drag on loose nodes, with the reaction given back to the air); still
air skipped, with an identical answer (1.6 to 1.7 times faster on the street scene, see
[Performance](performance.md#air-solver)); hollow concrete blockwork as a material; a
structure's largest deflection reported beside its deflection now; and layouts for a close-in
column, a wall in front of a building, a glass façade, a car park, an underpass, a
block-built house, a blockwork wall, an eight-storey frame and a twelve-storey tower, the last
two collapsing over several seconds.

### Usability, in parallel

- Review the app on screen and fix what is found.

## Things tried and set aside

- **Fixes for the wrong cause.** A fine mesh of the validation slab collapsed, and nonlocal
  crushing, a stronger hourglass cap, a frozen compressive rate factor and wider crushing
  bands were each tried before tracing one element through the collapse found the two real
  errors (Poisson swelling counted as cracking; a missing normalisation in the compressive
  rate law). Nonlocal crushing and a reduced form of the hourglass cap were kept, the first
  switched off by default; the rest were removed. The lesson: trace a failing element before
  changing the model.

- **Fixed design factors for strain rate** (UFC 3-340-02): deliberately conservative; they
  predict 121 mm for the slab test against 108 mm measured. The strain-rate laws are the
  default; the factors remain available as an option.
- **A rotating-crack concrete model**: simple and robust, but with no shear transfer across
  cracks it cannot hold together a slab without steel through its thickness.
- **Tension softening scaled by element size in reinforced concrete**: dissipates a crack's
  energy in every row of elements and makes the answer depend on the mesh.
- **Contact between nodes that were once neighbours**: creates energy when the element between
  them fails in compression, and blew a wall apart.
- **Retrieving the Kingery–Bulmash polynomial coefficients and a second open structural data
  set** automatically: the sources found either refused automated access or re-used each
  specimen for several shots. The coefficients, the design manual and the chamber test were
  later supplied by hand.
