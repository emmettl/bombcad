# Roadmap

Where the model is weakest, and what would be done about it. Each model document has its own
detailed list; this one puts them in order across the whole project.

The [long-term vision](long-term-vision.md) describes the broader ambition of exploring
“all explosions great and small”, with detail and physical scope appropriate to each scale.
It is a product direction rather than a delivery commitment; the validation priorities here
remain the immediate focus.

The [multiple-object scene architecture](multiple-object-scene.md) defines the first scene
requirements and minimum candidate ContinuumKit contracts supporting that vision. It keeps
application ownership, shared extraction and new numerical capabilities as separate steps.

A separate [RoomCAD and convolution reverb roadmap](https://github.com/emmettl/RoomCAD/blob/main/docs/roomcad-roadmap.md) covers shared SwiftPM
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
| 1 | The structural model has been compared with five tests, and springs back too far | On a slab test the peak converges at about 124 mm against 108 measured; a beam bent to failure carries 97–99% of its measured moment; a beam failing in shear carries 111–112% of its measured load on fine meshes, 137% on coarse; beams struck by a falling weight with stirrups peak within 11–26% under light drops and −6% to 0% under heavy ones on 16 elements, and Ando's beams without stirrups peak within 13% on average on 16 elements (53% too far on 24) and break at the speed the tests did, while Saatci's without stirrups is damaged, and on fine meshes split, by a drop it survived; full-scale slabs under close-in charges are left a third as far down as measured, barely spalled and not holed; in a full-scale internal explosion, with the chamber's detailing modelled, the roof peaks at 38 mm against 87 mm in the test paper's own model, and its edge is left 15 mm up against 95 mm measured; on the finest mesh the answer has not converged | [Validation](validation.md#an-internal-explosion-in-a-reinforced-concrete-chamber) |
| 2 | Shear failure and joints are the least reliable predictions             | Breach, punching, direct shear and wall–slab joints are indicative only | [Concrete model](concrete-model.md#limitations) |
| 3 | The default gas has no afterburning and treats hot air as cold          | Incident impulse 13–22% low and rooms' gas half the design value, unless afterburning and hot air (2 times slower) are switched on | [Air-blast model](air-blast-model.md#hot-air) |
| 4 | Peak pressure is under-resolved near the charge                         | Close-in loading and spall are unreliable                     | [Air-blast model](air-blast-model.md#limitations) |
| 5 | Collapse and debris have never been compared with anything              | They look plausible; that is all                              | [Structural model](structural-model.md#limitations) |
| 6 | Moving solids are a staircase of whole cells                            | Wall positions are good to a cell; small fragments are crude  | [Structural model](structural-model.md#coupling-to-the-air) |
| 7 | One bonded body of up to eight materials, lattice-aligned geometry; debris pushed crudely by the air | Real buildings only roughly; thrown debris is approximate | [Structural model](structural-model.md#limitations) |
| 8 | The rebound after a slab's peak is too large; close-in concrete is unchecked | Rebound is too large; compaction is modelled, but its strength does not grow with pressure | [Concrete model](concrete-model.md#limitations) |
| 9 | A base can be tied to rigid flat ground by a breakable joint, but footings and soil are not modelled; independent rigid objects cannot move | Foundation failure is excluded; cars and furniture cannot slide, lift or overturn as independent bodies | [Freestanding objects and supports](#freestanding-objects-and-supports) |
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
   +16% with the Model Code's tensile strain-rate law, the beam without stirrups broken by the
   heavy drop as in the tests and damaged by the light one, which it survived; beams' sectional shear check fails every beam under impact; see
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
   every beam; and solid elements that fail in shear on coarse meshes, which cannot separate
   cracks 100 mm apart on 46 mm elements; crack tracking did not help without bond slip (see
   [the concrete model](concrete-model.md#limitations)). Bars that slip, now an option, give
   discrete cracks at the Model Code's spacing on any mesh and a mesh-independent shear beam,
   but 42–47% strong, and the slab's peak 18% low. Across discrete cracks, a shear stiffness that
   falls as they open (Walraven and Reinhardt, now an option) barely moves either; the beam's
   strength follows the interlock cap alone, 108–109% on both meshes at a fifth of it, which
   nothing measured supports: checked directly against Walraven and Reinhardt's push-off tests,
   the cap is 3% to 24% above what an unpressed crack carried, not five times. Bond lost where bars yield (now part of slip) spreads yield
   along them but leaves the slab at 88 mm; its stiffness with slip comes from cracks that keep
   to one element each, 90 mm apart over a shorter zone (98 mm if spread over the crack spacing).
   A direct test of interlock across one crack, and the test slab's crack pattern, come next. (Beams now check each section's shear.) (Done: a test of a beam without stirrups that failed in shear; cracks whose axes
   turn with the stress until the crack opens, by default, after the lattice planes were
   found to mishandle inclined cracks, and a second crack once the tension has turned more
   than 30° from fixed axes; see [Cracking](concrete-model.md#cracking).)
5. **The concrete's tensile strain-rate law.** Saatci's heavy impacts were a quarter too
   stiff with Malvar and Ross's law, and the close-in slabs' spall had to overcome 17–21 MPa
   with it, where spalling tests find 10–15 MPa. (Done: the fib Model Code 2010's law, now the
   default, which brings the impacts within −5% to +15% and the contest slab to 96–103%; but
   under it the beam without stirrups breaks under the light drop it survived, split along its
   bars. Read over each crack's own band, the split's width was found four to six times too
   wide; corrected, the beam comes through on 16 elements and still splits on 24, and with bars
   that slip it comes through whole on both. Spreading the bars' steel through the concrete
   about them takes the mesh dependence away but leaves beams without stirrups too stiff and
   springing back from their peaks, keeping a third of the deflection the tests kept. So the bond between bars and concrete under
   impact, and the shear such a beam carries across cracks at these rates, are still open.)
   (Done: the bars' law, the CEB's as the fib Model Code 2010 re-adopted it, after a beam
   pushed slowly kept its deflection as the test's did and the same beam struck had yielded its
   bars half as far: Malvar and Crawford's law, which tension tests of bars find a fifth too
   strong at yield at these rates, held it elastic; with the bars taking their strain rate over
   their debonded length, not from the one element a crack runs through, so that the slab's
   hinge converges under it on fine meshes. Saatci's heavy drops now come within −6% to 0% on
   16 elements, Ando's within 13% on average; the contest slab goes 5–15% too far and its
   shells a quarter.) Which strengthening is the material's
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
   slab, whose hinge bends rather than slides, is unchanged. Since crack widths were read over
   each crack's own band, beams without stirrups keep about three quarters of the deflection
   the tests kept.) (Done: compaction of the pores under very high confined pressure, after
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
14. **Effects beside the blast**, one way and separable (see
   [Distributed computing](distributed-computing.md#the-long-term-visions-effects)). (Done,
   illustrative: a cased charge's [fragments](fragments.md), and the fireball's
   [thermal radiation](thermal-radiation.md) on the ground and faces of a scene, from the air
   model's own hot gas, which needs afterburning and hot air to make a fireball of plausible
   size; the fireball's [rise and cloud](fireball-rise.md), handed over from the air
   model's final state to an integral model of a rising thermal in a standard atmosphere and a
   wind growing with height, within a factor of 1.6 of an empirical fit to high-explosive cloud
   heights; and [ground shock](ground-shock.md) away from the charge, the manuals' one-dimensional
   estimate fed the overpressure on the rigid ground each frame. Next: radiation on the GPU's
   ray-tracing hardware, a fireball that is not one sphere, the cloud in moist and turbulent air,
   a layered soil column and a comparison with measured ground motion, and the app showing what
   the surfaces received, where the cloud went and how the ground shook. The crater and the
   ground shock near the charge act back on the blast and remain outside these.)

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
by the app renderer or blast solver. `swift run rigidboxdemo` generates a self-contained HTML
replay of six reference cases: resting, friction holding, sliding, lift-off, rocking and tipping.
Playback and scrubbing use recorded Swift trajectories, with no second physics implementation
in the viewer. This supplies milestone 1's standalone box demonstration.

Air coupling has started as `ExperimentalRigidBoxSimulation`, an explicit standalone driver
for one box on uniform ideal-gas air. It records impulses and torque from the air solver's
numerical wall traction, advances the reference body and updates the moving boundary.
Closed-domain gas mass and all five conserved quantities during local remapping are checked,
as are ambient balance, momentum exchange, pressure-gradient force/torque and grid/timestep
sensitivity. `swift run -c release rigidboxdemo --blast` compares held and free boxes and
reports diagnostic timings for this synchronous reference. Existing app simulations continue
to ignore these inputs. Adaptive coupling now supports translation, rotation and lift-off,
with factors two and four; fine masks retain box ownership and velocity, fine tractions
replace covered coarse loads, and insufficient patch coverage is rejected. CPU remapping and
patch initialisation share geometry; flux recording reads actual fine masks and wall speeds.
Redistribution crosses patch boundaries and is ordered spatially, independently of GPU pool
allocation. Opening and collapsing ground gaps conserve gas and energy. The tests compare identical analytic fields, since initial
prolongation next to a wall can otherwise flatten the coarse slope and obscure that comparison.
Chemistry, deformable structures and scenery contact are unsupported.
Whole-cell remapping can introduce pressure artefacts and does not
preserve the gas's angular momentum exactly; cut-cell accuracy, coupled-blast convergence and
broader performance measurements remain open before milestone 2 is complete.

`swift run -c release rigidboxdemo --convergence` writes a JSON study of held/free response on
0.2, 0.1 and 0.05 m uniform grids, a halved timestep on the finest, and adaptive held/free
comparison. Runs stop at the same 30 ms endpoint in a closed domain, separating gas mass
conservation from boundary outflow. Grid sensitivity is still substantial for free motion;
the study is a diagnostic, not a validation result. `swift run -c release rigidboxdemo --refined`
generates the refined held/free replay. Further spatial convergence and broader performance
measurements are next, before multiple objects and collision handling.

In the first matched-time study, factor-two adaptive held-box impulse is 36.18 N s against
37.04 N s on uniform 0.1 m air (2.3% lower). Halving the timestep on uniform 0.05 m air changes
free-box end speed from 12.30 to 12.21 m/s, while changing the grid from 0.1 to 0.05 m changes
it from 14.59 to 12.30 m/s. Closed-domain mass changes stay below three parts in ten million.
These numbers include resolution changes in charge initialisation as well as in the boundary;
they do not isolate remapping error. Further spatial convergence is needed before trusting
the free-box response.

With moving refined masks and remapping enabled, the factor-two free-box speed at 30 ms is
14.39 m/s against 14.59 m/s on uniform 0.1 m air (1.3% lower); its accumulated x impulse is
29.36 N s against 30.26 N s (3.0% lower). Gas mass change stays below one part in ten million
in that refined run. Remapping preserves mass, momentum and energy, but can still introduce
pressure artefacts and does not preserve angular momentum exactly.

Fine-cell remapping now gathers only complete coarse cells within the swept old/new box
bounds plus a one-coarse-cell donor margin. A direct translation/rotation field test matches
the retained whole-domain remapper exactly, including independence from patch allocation
order. In one profiled release study, the adaptive free-box run fell from 1.27 s to 0.32 s
(about four times faster); remapping phases fell from 0.95 s to 0.12 s. End velocity changed
by less than 0.000007 m/s and displacement by less than 0.00000002 m through floating-point
rounding. These measurements cover one synchronous reference case and do not establish a
production throughput target. The JSON study records phase timings for further profiling.

`swift run -c release rigidboxdemo --convergence --extended` adds 0.025 m uniform grids
at both CFL settings and adaptive runs with 0.05 m fine cells, using a 128 MiB patch budget.
The 18-case report includes initial gas mass/energy and final orientation/angular momentum.
The extended closed-domain study gives these results at 30 ms (CFL 0.45):

| Air grid | Held-box x impulse (N s) | Free-box displacement (m) | Free-box speed (m/s) |
| --- | ---: | ---: | ---: |
| Uniform 0.1 m | 37.04 | 0.11247 | 14.59 |
| Uniform 0.05 m | 40.35 | 0.14244 | 12.30 |
| Uniform 0.025 m | 41.89 | 0.13641 | 9.43 |
| Adaptive 0.1 m, factor 2 | 40.14 | 0.14447 | 13.12 |
| Adaptive 0.2 m, factor 4 | 39.26 | 0.14240 | 12.22 |

Held impulse changes by 3.8% between the two finest uniform grids, compared with 8.9%
between the previous pair. Free speed still changes by 23%, and rotational response is
also sensitive to the grid. Halving the finest timestep changes held impulse by 0.14%,
free displacement by 0.86% and free speed by 1.6%. Initial gas mass agrees within
0.00000004 kg and energy within 0.016 J across cases; this confirms consistent totals,
not identical spatial charge profiles. All 18 mass changes remain below one part per
million. The adaptive runs' free-speed differences from uniform 0.05 m are 6.6% and
0.7%, respectively; a close endpoint alone does not establish convergence.

Controlled diagnostics are now available with `swift run -c release rigidboxdemo --diagnostics`.
They compare prescribed ambient remapping without air evolution, a suspended box in uniform
20 m/s flow with gravity disabled, and contact-only mechanics under a centred 10 ms force
pulse of total impulse 5 N s. The last case runs to 30 ms with mechanical steps from 0.2 ms
to 0.025 ms; it has no gas or spatial grid. Between its two finest steps, displacement changes
by 0.000030 m and speed by 0.0000027 m/s, and the integrated contact/force/gravity impulse
balances body momentum.

Without ground contact, uniform-flow displacement at 10 ms changes from 0.04993 m on 0.1 m
air to 0.03944 m on 0.05 m air (21%); speed changes from 5.67 to 5.77 m/s. Halving the finer
timestep gives 0.04039 m and 5.86 m/s. The initial flow is uniform, but the stationary box
creates a startup transient; this is not an analytical steady-drag benchmark. Open boundaries
exchange gas, so their mass/energy changes are reported rather than treated as conservation
failures. Body momentum matches the recorded gas impulse without contact or gravity.

Remap-only cases translate by 0.12 m, optionally rotating 5 degrees, over twelve prescribed
updates. Gas mass and energy remain within one part in ten million and momentum is unchanged,
but peak local pressure departures from the initially uniform ambient field reach 100–400%
across the tested grids. These intentionally omit air evolution: their pressure errors expose
how strongly whole-cell redistribution perturbs the field, not the error in a coupled blast
trajectory. They also do not prove ground contact is converged under arbitrary blast loading.

The next priority is improving and checking moving-boundary occupancy/remapping accuracy.
Grid sensitivity persists without contact, and free response is not yet spatially converged,
so adding multiple objects remains behind those checks.

An opt-in connected-transport remapper now shifts complete conserved states along shortest
connected air paths from closing cells to newly exposed cells, instead of first concentrating
gas next to the closing surface and then diluting opening neighbours. Balanced occupancy
changes preserve a uniform field exactly; paths never cross permanently solid cells. Unpaired
or disconnected occupancy changes fall back to the existing conservative redistribution.
The usual driver still defaults to redistribution. `--diagnostics --transport` writes a
separate comparison report with the selected remapping mode recorded in each case.

In the same prescribed-motion study, all three translation cases now have zero pressure
departure; translation plus rotation is also uniform on 0.2 and 0.1 m air. On 0.05 m air,
rotation still produces a 100% peak departure through intermediate voxel-volume changes
(against 400% with redistribution), even though the final occupied volume is unchanged.
Mass, energy and momentum remain conserved. In suspended uniform flow, the 0.1-to-0.05 m
displacement difference falls from 21% to 4.5%, while speed changes by 4.7%. Halving the
finer timestep changes speed by 3.5%, so this is not yet a converged result.

Connected transport is a numerical reference, not a cut-cell/ALE treatment: greedy paths can
transport gradients anisotropically, do not preserve angular momentum, and require additional
CPU searches. Its blast response, refinement behaviour and cost need broader evaluation before
changing the default. The remaining volume-change disturbance motivates fractional occupancy
and a consistent treatment of gas displacement and moving-wall work.
Tests cover exact constant-field preservation, conserved gradient transport around a permanent
obstacle, rejection of disconnected paths, factor-two fine remapping across patches, ground-gap
opening/closure, and independence from patch-slot allocation and local-window selection.
Residual gas in a collapsing gap retains routes through already matched closing cells.

The matched blast study now accepts `--convergence --transport`, records the selected remapper
and separates accumulated air and ground impulses (linear and angular). Completed cases are
written incrementally, so an interrupted or failed run may leave a partial report. A regression
checks that air, contact and gravity account for body momentum; both ten-case release studies
also pass these budgets, share initial gas energy and the 30 ms endpoint, and preserve held-box
loads. Their closed-domain mass changes remain below three parts in ten million.

| Air grid / CFL | Free speed, redistribution (m/s) | Free speed, connected transport (m/s) |
| --- | ---: | ---: |
| Uniform 0.1 m / 0.45 | 14.59 | 8.93 |
| Uniform 0.05 m / 0.45 | 12.30 | 14.34 |
| Uniform 0.05 m / 0.225 | 12.21 | 14.01 |
| Adaptive 0.2 m, factor 2 / 0.45 | 14.39 | 9.25 |

Connected transport's speed changes by 61% between 0.1 and 0.05 m uniform air; halving the
finer timestep changes it by 2.3%. Its uniform-flow improvement therefore does not establish
blast convergence. At 0.1 m, forward air impulse rises from 30.26 to 32.94 N s, but opposing
ground x impulse rises from 1.15 to 15.22 N s. At 0.05 m, opposing ground x impulse instead
falls from 9.03 to 6.17 N s. The remapping choice affects the coupled load/contact response,
so neither method's free-box trajectory is ready for validation or a default change.

In this profiled pair, adaptive free runtime rises from 0.314 to 0.352 s; the remapping phase
rises from 0.0020 to 0.0300 s. Both take 294 steps, but their trajectories differ; these are
whole-run diagnostics rather than isolated algorithm benchmarks. The next implementation
step is an isolated fractional-occupancy geometry reference, before changing gas transport or
moving-wall work. This must address changing voxel volume and under-box gaps consistently,
rather than relying on constant-field preservation alone.

That geometry reference is now implemented as double-precision convex clipping of a cell
against the six planes of an oriented box. It measures occupied cell volume and open area on
each grid face, including sub-cell under-box gaps. It uses the geometric centre even when the
centre of mass is offset. Six tests cover analytical axis-aligned intersections, a 45-degree
cube's octagonal intersection, adjacent-face agreement and exact face contact, mass offsets,
partitioned volume under translation/rotation, and gaps down to 10 micrometres on 0.2 m cells.

`swift run -c release rigidboxdemo --geometry` generates a CPU-only 90-case comparison on
0.2, 0.1 and 0.05 m grids. The 0.8 m cube's summed volume stays at 0.512 m³, with maximum
absolute error below 0.00000000000005 m³. In the matching translation/rotation sequence,
the finest grid's centre-point mask instead ranges from 0.508 to 0.512 m³ before recovering
its original volume. Analytical thin-gap volume and side-face openings agree throughout.

This is geometry only: it changes neither air masks nor fluxes and does not establish blast
accuracy. Conservative gas transport, moving-wall work and treatment of very small fluid volumes
must be designed together before enabling fractional occupancy in the solver.

Clipped box-wall areas and centroids are now available. Walls exactly on a grid face belong
only to the fluid-side cell, preventing double counting; open grid-face centroids include the
first moment of the remaining area. Each cell passes vector surface closure, moment closure
and the volume identity from its boundary surface. Complete-box wall area is 3.84 m² in all
90 cases, and ambient-pressure residual force/torque stay below 0.000000003 N and
0.0000000003 N m. Ground cases include virtual cells below z=0 for full-surface identities;
these are not predictions of physical pressure on a ground-contacting box.

Eight geometry tests now include coincident-wall ownership and analytical pressure loads on
rotated boxes with offset centres of mass. Degree-two triangle quadrature integrates linear
pressure force and torque, avoiding the torque error from placing all pressure at a patch's
centroid. The maximum per-cell area and volume residuals in the 90-case report are below
0.000000000000007 m² and 0.0000000000000003 m³, respectively. No solver fluxes change.
Next, verify moving-cell volume changes against swept wall motion and wall work before
introducing conservative transport of fractional gas volumes.

Those moving-geometry checks are now available with `--motion-geometry`. The CPU-only
27-case study prescribes translation, rotation and thin-gap opening on three spatial grids,
using 8, 32 and 128 temporal midpoint samples over 20 ms. Swept solid volume is the integral
of wall velocity dotted with its outward area normal; positive sweep shrinks gas volume.
Gas pressure work has the opposite sign to body pressure work. Triangle quadrature checks
this exchange for linear pressure and rigid translation/rotation, including torque power.

Smooth rotation's volume residual drops about sixteenfold each time the sample count rises
fourfold. Thin-gap opening matches the endpoint volume change to numerical precision.
However, the selected crossing on 0.1 and 0.05 m cells misses 100%, 25% and 6.25% of the
swept volume at 8, 32 and 128 samples. This is an intentional quadrature diagnostic: spatial
geometry is accurate, but sampling a moving wall in time does not automatically conserve
geometric volume. The 0.2 m crossing happens to align with interval boundaries and is exact;
that alignment must not be treated as general accuracy.

All 27 gas/body work balances close within 0.00000000000002 J. Work agrees with pressure
times the sampled swept volume, but differs from pressure times the exact endpoint change
when temporal volume is wrong. Ten geometry tests now cover these motion and work checks.
Next, split time integration at wall/cell crossing events (or use equivalent consistent
space-time geometry), then address transport and stability of small fractional gas volumes.
The current air solver still uses its existing whole-cell boundaries.

Event-aware translation is now implemented as a separate reference. For an axis-aligned box
moving at constant velocity, it finds every box-face/cell-face crossing time and splits the
interval there. Two-point Gaussian quadrature integrates the quadratic swept-volume rate
between events, including simultaneous motion along multiple axes. Non-axis-aligned boxes
are explicitly rejected; this is not a general rotating-body event solver.

The motion report now has 33 cases: the retained 27 midpoint cases plus six event-split
translation/gap comparisons. The translation crossings use four temporal evaluations instead
of 128 and reduce the previous 6.25% volume mismatch to numerical precision (maximum
absolute event-split residual below 0.000000000000000012 m³). Gas pressure work also matches
pressure times the exact endpoint volume change within 0.000000000002 J, while remaining
equal and opposite to body work. Eleven tests include diagonal translation, reverse motion,
stationary geometry and rejection of unsupported orientations.

This removes the demonstrated translation-crossing error without correcting an already
computed flux after the fact. Rotated motion needs the broader space-time reference below,
before conservative fractional gas transport and small-volume stabilization.
The reference remains separate from the air solver and does not change the blast demo.

An adaptive reference now supports arbitrary initial pose, constant world spin and constant
centre-of-mass velocity. It checks endpoint solid-volume changes against integrated wall
motion, compares coarse/fine Gaussian quadrature, and refines the interval with the largest
combined error indicator until the summed indicator meets the requested tolerance. Initial
subdivision limits wall travel and angular excursion; a refinement limit causes an explicit
failure rather than returning an unchecked result. No flux is corrected to force agreement.

The motion report now contains 48 cases, including rotated translation and six adaptive
comparisons with tolerances of one billionth of a full cell's volume. All six meet their
reported tolerance and constant-pressure work checks. Smooth rotation uses 12–30 temporal
geometry evaluations, while rotated translation uses 258–312 (including evaluations discarded
during refinement). On 0.05 m air, rotated translation's volume residual falls from
0.00000000687 m³ with 128 midpoint samples to 0.00000000000000150 m³ adaptively.
Twelve tests include combined translation/rotation with an offset centre of mass and failure
at a refinement limit.

This is a numerical reference, not a complete rotating-wall event detector. Volume checks and
excursion limits do not prove detection of arbitrarily brief grazing contacts or certify
force-impulse accuracy. Those stress cases and consistent space-time force/transport checks
remain necessary before coupling fractional gas volumes into the solver. Small-volume
stabilization and the blast-convergence study also remain open.

Grazing-contact and force-impulse checks are now implemented. Adaptive refinement compares
linear and angular impulse estimates as well as volume. An endpoint-inclusive force estimate
checks jumps that Gaussian nodes can sample on only one side. When temporal samples appear
empty, separating-axis projections of the midpoint box are inflated by maximum corner travel;
the interval is refined unless those projections prove separation over the whole interval.
This also investigates short contact tails at occupied endpoints, rather than assuming that
small endpoint volume implies small pressure impulse. Roundoff-sized clipped volumes are not
used as evidence that a whole interval has been sampled adequately.

`--grazing-geometry` compares 1 ms, 100 µs and 10 µs corner encounters over a 0.4 s sweep.
Each selected cell has zero endpoint volume change, but nonzero pressure impulse. At
101325 Pa, analytical x and y impulses are −0.0101325, −0.000101325 and −0.00000101325 N s,
respectively. All three adaptive results agree within the requested impulse tolerances, with
zero analytical angular impulse and balanced gas/body work. A uniform 128-sample midpoint
integration misses all three encounters entirely. These are cell-pressure contributions,
not net loads on a complete box in uniform ambient pressure.

Thirteen tests pass, including these three analytical grazing cases and the previous motion
checks. The grazing references require 1161–1197 geometry evaluations: useful for checking
correctness, not a production throughput result. Coarse/fine and endpoint estimates remain
numerical indicators rather than rigorous general force-error bounds; geometry tolerance,
refinement limits and more complex near-contact motion remain relevant. The next step is a
standalone conservative fractional gas-transport reference using the checked volume/work
budgets, followed by small-volume stabilization before solver integration.

The first fractional gas-transport reference is now implemented on the CPU. Each cell stores
extensive mass, momentum and total energy together with its prescribed gas volume. Supplied
directed transfers carry frozen donor states, with total outgoing volume bounded by the
donor's old volume. Equal/opposite transfer amounts conserve the five gas quantities; supplied
wall impulses and pressure work enter separately. New states are validated before returning,
rejecting donor overdraw, residual gas in a zero-volume cell and nonpositive internal energy.
Only relative roundoff-sized residuals may be cleared when a cell becomes completely dry.

Six tests cover uniform-state preservation while cells close/open, nonuniform mass/momentum/
energy budgets, independence from face traversal order, positive opening-cell states at
volumes down to 0.000000000002 m³, invalid-update rejection and compression-work convergence.
`--fractional-gas` generates a sealed ideal-gas compression study from 1 to 0.9 m³ with
first-order pressure work. Fixed and moving wall impulses balance, while the moving boundary
does work. Pressure error against adiabatic compression falls from 0.292% in one update to
0.00486% in 64; mass is unchanged and energy-budget residuals remain below 0.00000000005 J.
The opposing body-work entry is recorded from the supplied gas work; no free-body dynamics
are simulated in this compression test.

This is conserved-state accounting for prescribed transfers and volumes, not yet a moving-box
gas solver. It does not construct an adjacent-face displacement field, solve numerical gas
fluxes or choose a timestep. Tiny positive states in an algebraic test do not establish
small-cell stability. Next, derive geometry-consistent face transfers and introduce a checked
small-volume treatment before connecting fractional transport to blast coupling.

Geometry-linked adjacent transfers are now implemented as a capacity-network reference.
Contracting and expanding gas cells supply the volume constraints; each cell's outgoing
volume is bounded by its old inventory. Positive shared face openings define the graph.
Residual network paths can revise earlier transfers to preserve a later cell's only escape
route, avoiding the failures of greedy routing. Initially dry cells can receive gas but cannot
relay it in the same frozen-donor update. Disconnected paths, insufficient transit inventory
and significant total-volume imbalance are rejected. Roundoff excess at a saturated donor
is adjusted on both sides of a transfer, with endpoint volume residuals checked afterward.

`--fractional-remap` compares a 0.01 m translation of the 0.8 m box on 0.2, 0.1 and 0.05 m
grids. Fractions within 0.000000000001 of dry/full are canonicalised as geometric roundoff.
Connectivity uses the maximum open area at start, midpoint and endpoint; this does not
provide a time-integrated face capacity. The three plans contain 102, 572 and 3046 transfers.
Mass and energy changes stay below one part in a trillion, momentum changes below
0.00000000000001 N s, and maximum relative pressure departure below 0.000000000002.
All donors stay within their old-volume limit; some reach it exactly on the finer grids.
These are uniform-state remapping checks, not a blast-convergence result.

Six planner tests cover moving-box geometry on all three grids, rerouting a contested exit,
dry/blocked paths, volume imbalance and small transit cells, alongside the six gas-accounting
tests. A 0.001 m³ transit cell cannot pass a 0.02 m³ displacement in one update, but forty
smaller prescribed steps preserve mass, energy and uniform pressure.

Automatic capacity-limited motion substeps are now implemented in the isolated CPU reference.
The controller queries prescribed endpoint volumes and interval face connectivity, retries an
unroutable interval by bisection, and recomputes donor inventories after each accepted step.
Refinement depth and total substeps are bounded. It returns a complete result only on success;
invalid geometry and volume imbalance propagate immediately. It cannot resolve disconnected
or permanently dry relay paths simply by refining time.

`--fractional-substeps` passes a 0.02 m³ displacement through transit cells of 0.004, 0.001
and 0.00025 m³. It automatically accepts 8, 32 and 128 steps after 7, 31 and 127 rejected
intervals, keeping every donor within its old gas inventory. Relative mass/energy changes
remain below 0.000000000000002, momentum changes below 0.000000000000001 N s and relative
pressure errors below 0.000000000000001. Three controller tests check automatic refinement,
budget exhaustion and invalid geometry, with all fifteen transport/planner/controller tests
passing. This is a capacity-controlled remap, not an acoustic stability controller or a
physical flux update. Next, add time-integrated face apertures and physical gas fluxes,
including small-cell acoustic stability treatment, before enabling fractional blast coupling.

Time-integrated open face areas are now available for axis-aligned constant translation in
the event-split geometry reference. Box-face/cell-face crossings partition time so that each
open area is a quadratic polynomial within an interval; two-point Gaussian quadrature
integrates it exactly up to floating-point geometry error. The six area integrals (m² s)
are included in `--motion-geometry` for midpoint and event-split results. Eight midpoint samples differ from the event-split
face integral by 4.17% of the full-face area-time on the 0.1 and 0.05 m crossing cases.
Three analytical tests check shared-face agreement, quadratic overlap and a brief closure
missed by endpoint/midpoint samples; all sixteen geometry tests pass.

An area-time integral alone is not a transported gas volume: a numerical flux must be
integrated with the aperture, preserving the timing of openings as states evolve. The
capacity remapper still uses its supplied connectivity graph.

The adaptive rotated-motion reference now also integrates all six open face areas.
Its interval refinement includes the largest per-face discrepancy between coarse/fine
Gaussian quadrature and endpoint-inclusive Simpson estimates. A separate area-time tolerance
defaults to one part in 100 million of the full-face area-time; the report records this
tolerance and the sum of interval error indicators. Existing separation bounds still
investigate intervals whose quadrature could miss a brief encounter. These are numerical
error indicators, not certified bounds or a complete grazing-event detector.

Three additional tests verify an analytical rotating-box secant integral, agreement across
a shared face, a brief closure with zero pressure (so face refinement is independent of
force checks), and explicit failure when the refinement budget is insufficient. All nineteen
geometry tests pass. The 48-case motion report now includes face integrals in every result;
all six adaptive rotated cases satisfy their face-area tolerance, using 45–621 temporal
evaluations. Next, use this geometry in a conservative physical gas-flux reference, including
wall work and small-cell acoustic timestep control.

An isolated first-order ideal-gas Euler flux reference is now implemented for stationary
positive fractional volumes. Paired internal or periodic interfaces use the Rusanov flux,
including pressure in momentum and enthalpy in energy, and exchange the same extensive
packet with opposite signs. The acoustic timestep is bounded by `0.4 * volume / sum(area *
maximum normal wave speed)` for every cell; the configurable CFL is restricted to at most
0.5. Oversized steps are rejected before updating, and nonpositive mass/internal energy
is rejected afterward without floors. This introduces a direct acoustic small-cell limit,
separate from remap inventory limits; it does not eliminate small-cell stiffness.

`--fractional-flux` evolves an eight-cell periodic pressure pulse for 0.5 ms. Reducing one
cell from 0.001 to 0.00025 to 0.0000625 m³ requires 10, 35 and 138 acoustic steps.
Relative mass and energy departures stay below 0.000000000000001, total momentum changes
below 0.000000000000001 N s, and all gas states remain positive. These cases change the
domain volume and measure timestep cost and budgets, not spatial convergence. Four flux
tests cover analytical momentum/enthalpy transport, uniform moving gas on unequal volumes,
pressure-driven conservative flow and volume-scaled timestep rejection.

This remains separate from the app solver and from the moving-box remapper. Boundary wall
loads, moving-wall work, chronological aperture/flux integration and closure/opening cells
still need to be combined consistently. Next, establish a closed stationary-wall pressure
budget, then couple prescribed piston motion before a freely moving rigid box.

Stationary reflecting slip walls are now included in the isolated Euler flux reference.
Initially a mirrored normal velocity supplied the Rusanov wall traction; wall mass and total-energy
fluxes are exactly zero. Each wall impulse is recorded opposite to the gas momentum update,
and its acoustic rate participates in the cell timestep limit. A resting six-wall box
preserves its gas state and recovers pressure-times-area loads. Tangential slip transfers
no tangential momentum. The initial approximate traction could become tensile for strongly
separating gas; such updates failed explicitly rather than clipping the load. That initial
wall law was unsuitable for all rarefactions or moving-piston conditions.

`--fractional-walls` applies an end-cell pressure pulse in a closed eight-cell tube for
0.5 ms. The three volume cases require 11, 38 and 141 steps, with gas-plus-wall momentum
residuals below 0.000000000000001 N s and relative mass/energy changes below
0.000000000000001. Reducing the end cell also reduces the initial pulse energy, so response
differences are not a convergence result. Four wall tests cover uniform-pressure balance,
closed-pulse impulse accounting, tangential slip, invalid geometry, excessive timesteps and
tensile-traction rejection; the four existing flux tests also pass.

The wall pressure now uses the exact planar ideal-gas shock and rarefaction relations for
a uniform incident state, with normal velocity measured relative to the wall. Compression
inverts the shock pressure/velocity relation analytically; expansion uses the rarefaction
invariant and reaches zero pressure at vacuum onset. This replaces the tensile Rusanov
traction failure. The wall timestep rate includes the compressive shock speed. These
relations follow the [Clawpack Euler reference](https://www.clawpack.org/riemann_book/html/Euler.html).

`--wall-pressure` records eight incident normal Mach numbers from -6 to +3. At Mach -2,
wall pressure is 0.0279936 times incident pressure; Mach -6 forms a vacuum gap with zero
wall load. Three analytical tests cover shock jump relations, the expansion invariant and
vacuum, and the weak-wave acoustic limit. The existing wall test now verifies positive
expansion traction and a zero-load vacuum update instead of tensile-traction rejection.
All eleven wall-pressure/wall/flux tests pass. The closed-tube study retains 11, 38 and
141 steps, with mass/energy and gas-plus-wall momentum budgets within floating-point
precision. The exact local wall law does not make the first-order spatial flux exact or
add moving geometry. Next, establish prescribed-piston volume and pressure-work consistency
before coupling freely moving bodies.

Prescribed planar piston motion is now implemented within intervals of fixed cell topology.
Each wall has a constant velocity: its swept volume is `area * normal velocity * dt`,
its impulse uses the wall pressure from relative gas/wall normal velocity, and its work
is the dot product of that impulse with wall velocity. Gas momentum and energy receive
the opposite impulse/work, while no mass crosses the wall. Acoustic timestep rates include
wall travel, and a separate contraction limit prevents a cell from closing in one step.
No independent endpoint-volume input is needed for this planar reference.

`--piston` compresses or expands a closed four-cell tube by 10% at 0.25, 0.5 and 1 m/s.
The six cases take 676–3519 steps. Swept-volume residuals stay below 0.00000000000000001 m³,
relative mass changes below 0.000000000000001, and gas-plus-wall energy residuals below
0.00000000001 J. Impulse budgets remain balanced. Mean pressure approaches the quasi-static
adiabatic value as speed decreases; at 0.25 m/s the relative departure is below 0.000005
for compression and expansion. This is a low-speed limiting check, not a spatial-convergence
result. Three piston tests cover signed volume/work exchange, a comoving translating cavity,
and the complete closed-tube pressure/budget study. The existing wall/flux checks also pass.

This reference assumes constant wall area and normal within a step, stationary internal
faces and no cell topology changes. Next, combine physical flux/work with chronological
cell-crossing geometry and face apertures, including gas transfer when cells open or close,
before coupling a freely moving rigid box.

The planar piston can now cross grid cells in a standalone one-dimensional tube reference.
Time intervals split at grid boundaries and at quarter-cell merge/split thresholds. Before
an end cell closes, it is joined to its neighbour; expansion creates a separate end cell
once it reaches one quarter of a full cell. Internal faces are rebuilt for each acoustic
step, and the physical flux and pressure-work update uses the current control volumes.
This avoids the vanishing acoustic timestep of an unmerged closing cell.

At topology changes, ordered volume overlaps conservatively rebin each donor's extensive
state. The last overlap receives the donor's remaining packet, keeping its complete mass,
momentum and energy inventory. Only endpoint geometric roundoff is normalised away; a
significant total-volume mismatch fails. Merging nonuniform gas mixes states and changes
spatial diffusion, so this is a small-cell treatment to test, not an accuracy validation.

`--piston-crossings` compresses a 0.655 m tube to 0.355 m and expands it back with prescribed
1 m/s motion. The 0.1 m grid crosses three boundaries and repartitions three times; the
0.05 m grid crosses/repartitions six times. The four cases take 7822–17732 acoustic steps,
with relative mass departures below 0.00000000000001, gas-plus-wall energy residuals below
0.00000000001 J and momentum residuals below 0.000000000000001 N s. Gas remains positive.
Three tests cover complete compression/expansion crossings, conservative nonuniform merging
and uniform splitting, invalid geometry and bounded-work failure.

General rotating boxes, transient face openings and arbitrary cut-cell adjacency are still
outside this tube reference. Next, test spatial and temporal sensitivity of the merge policy,
then combine swept box geometry and chronological aperture fluxes with conservative topology
changes before enabling freely moving bodies in the blast solver.

The end-cell merge fraction and acoustic CFL are now configurable in the tube reference,
with the existing quarter-cell/0.4 defaults retained. Merge fractions must be positive
and at most 0.5; CFL must be positive and at most 0.5. Event times follow the selected
merge threshold. Four tube tests cover the alternative policies and previous crossing,
repartition and failure checks.

`--piston-sensitivity` compares matched compression/expansion at 20 m/s on 0.1 and 0.05 m
grids, CFL 0.4 and 0.2, and merge fractions 0.125, 0.25 and 0.5. All 24 cases complete,
taking 306–2522 acoustic steps. The report records mean pressure, wall work, gas/wall
budgets and 64 pressure/normal-velocity samples at uniform fractional tube positions.
Relative mass departures stay below 0.000000000000001, energy residuals below
0.00000000001 J and momentum residuals below 0.000000000000001 N s.

Across merge thresholds at fixed grid/CFL, mean-pressure spread is at most 0.0044% and
wall-work spread at most 0.0176%. The largest mean absolute pressure-profile difference
over the 64 samples, normalised by reference mean sampled pressure, is 0.144%. The reference for
these normalisations is the matched 0.05 m/CFL 0.2/merge 0.25 case, not an exact solution.
At CFL 0.2 and merge 0.25, halving grid spacing changes mean pressure by 0.091% in
compression and 0.102% in expansion. These two grids do not establish convergence;
spatial errors exceed the mean-pressure response to merge policy in these cases.
Reports save completed cases incrementally, so a failed run can leave a partial array.

Next, add a finer spatial reference and check transient pressure profiles before combining
general swept-box apertures, topology changes and physical fluxes. The current comparisons
do not validate free-body blast response or choose a production merge policy.

Matched-time snapshots now split the piston integrator at requested physical times and
retain each snapshot's cumulative gas/wall budgets. Output times are validated, sorted and
recorded exactly; adding them can shorten integration steps and slightly change the numerical
trajectory. Five tube tests cover snapshots (including initial/final states), previous crossing
and merge policies, conservation and invalid inputs.

`--piston-transients` runs 20 m/s compression/expansion on 0.1, 0.05 and 0.025 m grids,
at CFL 0.4 and 0.2, with merge fraction 0.25. The twelve trajectories record 48 frames
at 0.5, 2, 5 and 15 ms, including complete ordered cell volumes/pressures/velocities and
64 sampled profiles. Relative mass departures stay below 0.000000000000001, gas-plus-wall
energy residuals below 0.000000000001 J and momentum residuals below 0.000000000000001 N s.
Completed trajectories save incrementally; a partial report is not a completed comparison.

`Scripts/summarize-piston-transients.py` integrates absolute pressure differences over
overlaps of the complete piecewise-constant profiles, avoiding sampling aliasing. It normalises
by the finest CFL 0.2 run's mean pressure; this run is a numerical reference, not exact truth.
At 0.5 ms, coarse/medium relative L1 differences are 0.615%/0.291% in compression and
1.010%/0.526% in expansion. Finest-grid CFL differences remain below 0.039% at all four
times. At 5 ms in expansion, the medium-grid difference (0.230%) exceeds the coarse-grid
difference (0.205%); transient profile convergence is not uniformly monotone. At 15 ms,
coarse/medium differences fall to 0.139%/0.053% in compression and 0.241%/0.149% in expansion.
These profiles expose spatial and phase errors hidden by final mean-pressure comparisons.

Next, check the initial compression/expansion wave against an analytical planar-piston
solution before extending to arbitrary swept-box aperture and topology changes.

An analytical initial planar-piston wave reference is now implemented from the
[Euler shock and rarefaction relations](https://www.clawpack.org/riemann_book/html/Euler.html).
Compression has a constant shocked state behind a moving front; expansion has an isentropic
fan and constant wall state. The reference rejects times after the leading wave reaches
the opposite wall, and currently excludes vacuum gaps. It integrates conserved cell averages
after splitting at wave boundaries. Four-point Gaussian quadrature integrates the degree-seven
fan states for gamma 1.4; pressure is derived from those averaged conserved quantities.

`--piston-wave` compares 20 m/s compression/expansion on 0.1, 0.05, 0.025 and 0.0125 m grids
at CFL 0.4 and 0.2, taking snapshots at 0.5 and 0.8 ms. Pressure and density L1 errors are
normalised by incident pressure/density times final gas volume; momentum uses incident
density times piston speed and volume, and energy uses incident internal-energy density
times volume. Wall work is compared with the constant analytical wall pressure times wall
area, speed and elapsed time. All sixteen cases save incrementally.

At CFL 0.2 and 0.8 ms, pressure L1 errors fall from 1.212% to 0.542% in compression
and 1.959% to 0.908% in expansion across the four grids. Finest-grid momentum L1 errors
remain 6.725% and 9.875% under the stated normalisation. Finest-grid wall-work errors
are below 0.01%, while gas-plus-wall energy residuals stay below 0.000000000001 J.
Four tests check analytical jump conditions, integrated mass/impulse/work budgets, reference
scope and decreasing numerical pressure error with refinement. All pass.

These checks reveal substantial first-order wave diffusion despite tight global budgets;
they do not validate freely moving blast objects. Next, reduce spatial flux diffusion with
an opt-in limited reconstruction and repeat the analytical wave checks before combining
general box aperture and topology changes.

An opt-in tube reconstruction now limits density, pressure and velocity increments with
minmod gradients using nonuniform centre spacing. Face traces are additionally bounded
by neighbouring primitive states; boundary-cell slopes remain zero. The paired Rusanov
flux accepts validated face states, exchanges one packet with opposite signs, and uses
their wave speeds for the acoustic limit. Constant-state fluxes remain the default.

The reconstructed tube uses an SSP two-stage update of extensive state and gas volume.
Wall impulse and work use the same stage weights, so their budgets remain paired with
the gas update. If a stage violates its timestep bound or produces an invalid state,
the entire trial is discarded and its duration halved, with at most 24 attempts. No
density/pressure floors are added. This is not a proof of second-order accuracy through
cell merging, nor a general multidimensional positivity guarantee.

`--piston-wave --limited` records the same sixteen analytical wave cases in a separate
report, including accepted steps and rejected trials. At CFL 0.2 and 0.8 ms on the
0.0125 m grid, pressure L1 errors improve from 0.542% to 0.257% in compression and
0.908% to 0.422% in expansion. Momentum L1 errors improve to 3.189% and 4.974%; wall-work
errors stay below 0.005%. Relative mass residuals stay below 0.00000000000001 and
gas-plus-wall energy residuals below 0.000000000001 J. Four reconstruction tests cover
bounded face states, resting gas, conservative crossings and analytical improvement;
all seventeen selected reconstruction/flux/tube/wave tests pass.

The improvement has a measurable cost. Finest-grid CFL 0.2 compression takes 802 accepted
steps and 787 rejected trials versus 409 baseline steps; expansion takes 400 steps and
24 trials versus 388 baseline steps. Each accepted reconstructed step has two flux stages.
The current halving strategy is deliberately simple and often too conservative for the
second-stage compression bound. Next, choose timesteps using the stage limits to reduce
unnecessary retries, then check stronger waves and merge-policy sensitivity before general
moving-box aperture coupling or any default change.

The reconstructed tube now reports a failed second stage's allowable duration, instead
of losing that information in a generic unstable-step error. Stage-aware control starts
with a 1% margin below the first-stage acoustic bound; on a second-stage violation, it
retries at 99% of the smaller stage limit/current duration. Invalid gas states still trigger
halving, and every stage remains subject to validation and the 24-attempt budget. Event
times continue to cap the duration. This improves scheduling without relaxing a stability
or positivity check. The constant-state mode is unchanged.

`--piston-wave --limited --halving` retains the previous controller and writes a separate
comparison report; each trajectory now records its step-control mode. Across the sixteen
wave cases, rejected trials fall from 2091 to 274 (about 87% fewer). At finest-grid CFL 0.2,
compression drops from 802 accepted steps/787 retries to 412 steps/no retries, and expansion
from 400 steps/24 retries to 392 steps/no retries. At CFL 0.4, compression still has 168
retries, so more headroom may be useful for rapid stage changes. These are work counts,
not measured speedups; reconstructed steps still require two flux stages and limit checks.

Finest-grid pressure errors at 0.8 ms change by less than 0.0005 percentage points between
controllers. Conservation budgets remain within floating-point precision. Regression tests
check the reduction in accepted steps/retries, unchanged wall work and gas budgets, and
positive conservative cell crossings at prescribed speeds of -100 and +100 m/s. All nineteen
selected limited/flux/tube/analytical tests pass. Stronger-motion tests check robustness and
budgets, not analytical accuracy. Next, extend the analytical wave study to stronger motion
and compare merge policies before general moving-box aperture coupling.

The analytical wave study now supports 100 m/s compression/expansion and a merge-policy
sweep. `--piston-wave --strong --merge-study` and the same command with `--limited`
each run 48 cases on four grids, two CFL limits and three merge fractions, retaining
pre-reflection snapshots at 0.5 and 0.8 ms. Reports now include swept-volume and gas-plus-wall
momentum residuals alongside mass/energy budgets. The comparison script rejects incomplete
48-case reports and summarises matched cases at CFL 0.2. All 96 runs complete; across
their 192 frames, relative mass residuals remain below 0.00000000000001, energy residuals
below 0.000000000001 J, volume residuals below 0.00000000000000001 m³ and momentum residuals
below 0.000000000000001 N s.

At 0.8 ms, finest-grid/quarter-cell/CFL 0.2 pressure L1 errors improve from 2.642% to
0.905% in compression and 3.150% to 1.197% in expansion with reconstruction. Finest-grid
reconstructed wall-work errors remain below 0.1% across the three merge policies. Coarse-grid
reconstructed compression error changes from 4.531% at merge 0.125 to 6.203% at merge 0.5;
the corresponding finest-grid range is 0.902–0.915%. Finest-grid expansion ranges from
1.187% to 1.253%. Merging larger volumes has a clearer accuracy cost in these faster cases.

At finest-grid CFL 0.2, compression takes 693/504/359 accepted steps as the merge fraction
increases from 0.125 to 0.25 to 0.5, with 647/422/208 rejected trials. Expansion takes
608/459/338 steps with no retries. The 1% stage margin is insufficient to avoid repeated
compression retries at this speed, although stage-limit retries remain bounded and accurate.
These counts expose a performance tradeoff, not a reason to choose a default from one test.

Analytical conservation tests now include both 20 and 100 m/s waves. A new regression
checks strong-wave refinement, improvement over constant-state fluxes and complete budgets
across merge policies; all eleven selected analytical/reconstruction tests pass. The
constant-state flux and quarter-cell merge defaults remain unchanged. Next, generalise
conservative merging/splitting to connected cell graphs with geometry/face-balance checks,
while retaining these tube studies as regression references for accuracy and work.

Static connected control-volume aggregation now accepts general shared-face graphs.
Underfilled groups join an adjacent group through positive open area, prioritising the
largest shared area, then neighbour volume and stable cell index. Groups reach a quarter
of nominal cell volume by default, with a configurable 64-member bound. Disconnected
undersized components and exhausted member bounds fail explicitly. Dry cells have no group
and receive no gas. Internal faces cancel; exterior face patches retain their individual
normals and centroids instead of being combined into an approximate face.

Geometry validation checks both cells and resulting groups: outward area vectors must
close, and the centroid tensor integral must equal gas volume times the identity matrix.
Area residuals are scaled by total surface area; tensor residuals by the larger of nominal
and gas volume. Aggregation sums extensive mass, momentum and total energy. Splitting
distributes a constant group state by member volume, assigning the packet remainder to a
largest-volume member so it does not corrupt tiny members. Significant group-volume changes
are rejected by this static split operation. Mixing nonuniform members remains diffusive,
and angular-momentum conservation is not supplied by these extensive-state sums.

`--connected-gas` links this graph reference to clipped 0.8 m boxes in a 2 m domain on
0.2 and 0.1 m grids, at rotations 0 and 0.23 radians. Fractions and face areas below
0.000000000001 of their nominal measures are canonicalised as geometric roundoff.
All four cases pass shared-face and surface/tensor checks. Rotated cases contain gas
fractions as small as 0.000000129 and 0.000000410; aggregation raises their uniform-gas
acoustic timestep bounds by 162× and 128×, respectively. Axis-aligned gains are about
1.98× and 1.50×. The largest group has two members in these cases.

One grouped uniform-gas flux update followed by splitting preserves pressure to below
0.000000000000001 relative, with mass/energy changes within floating-point precision and
momentum changes below 0.00000000000001 N s. Six tests cover translated/rotated geometry,
clipped-box integration, tiny-member roundoff, nonuniform inventory conservation, bad
centroids/volumes, chained merges, isolated components, dry cells and member limits.
The reference remains CPU-only and static; timestep gains do not measure grouping cost
or validate blast loading. Next, check nonuniform pressure transport and held-box load
budgets through these groups before allowing geometry to move.

Nonuniform pressure transport around a held box is now exercised on the grouped clipped
geometry. Boundary patches carry an owner identifier through aggregation so box loads
remain distinct from enclosing-domain loads. Each box patch's impulse uses the same
Riemann pressure as the gas update; its angular impulse is computed at the retained
centroid about the box centre. The box pose stays fixed, representing an external holding
constraint, and all boundary work is zero. This computes pressure torque but does not
audit or conserve the gas's angular momentum.

`--connected-loads` evolves an initial smooth Gaussian pressure excess of peak 40000 Pa,
centred at (0.45, 1.18, 1.10) m with widths (0.14, 0.18, 0.18) m, for 0.5 ms. It runs
axis-aligned and 0.23-radian boxes on 0.2 and 0.1 m grids at CFL 0.2, using 71–142 steps.
The gas remains positive, with speeds reaching roughly 10–16 m/s. Compensated extensive
totals distinguish cell-sum roundoff from transport drift; mass and energy changes stay
within floating-point precision, and gas-plus-box-plus-domain linear-momentum residuals
stay below 0.0000000000001 N s.

The forward box impulse changes from 2.105 to 2.383 N s for the axis-aligned box and from
1.924 to 2.158 N s for the rotated box when grid spacing halves: 13.2% and 12.1% increases.
The rotated box's z angular impulse changes from -0.189 to -0.243 N m s. These two grids
do not establish load convergence. Sampling the initial pressure field at cell centres also
changes excess pulse energy by about 1.2% and 0.7%, respectively; initial mass and energy
are reported so forcing differences remain visible. This is a pressure-pulse diagnostic,
not detonation or freely moving-body validation.

Eight grouping/load tests pass, covering boundary-owner retention, pulse-induced linear
and angular load, closed gas/wall budgets and zero load/flow under uniform pressure, along
with the preceding geometry and aggregation checks. Next, compare finer-grid and timestep
response with matched pulse energy before changing the box pose or coupling free-body motion.

The held-box study now optionally normalises the initial pressure pulse to a prescribed
excess energy. A compensated sum of Gaussian weight times gas volume determines the effective
peak amplitude, and initialization rebuilds the gas states with that amplitude. Reports
record requested/deposited pulse energy, effective amplitude and CFL. Matching energy controls
total forcing but does not make the sampled spatial field identical between grids or rotations.

`--connected-loads --convergence` compares three grids (0.2, 0.1 and 0.05 m), CFL 0.2 and
0.1, and both box orientations at 0.5 ms with 6400 J excess energy. All twelve cases complete
in an optimised CPU build, using 71–559 steps. Pulse energy agrees across cases to floating-point
precision; actual initial gas energy above its ambient background is independently checked.
Mass/energy budgets remain within floating-point precision, with gas/box/domain momentum
residuals below 0.000000000001 N s. Ten selected grouping/load tests pass, including energy
matching, identical initialization across CFL settings and invalid configuration rejection.

At CFL 0.1, forward impulses on the three grids are 2.085/2.390/2.585 N s for the
axis-aligned box and 1.980/2.238/2.438 N s for the rotated box. The last refinement still
changes them by 8.16% and 8.91%, respectively. Angular-impulse vector changes across that
refinement are 9.08% and 17.62%. Halving CFL changes forward impulse by at most 0.226%
on any grid, falling below 0.092% on the finest grid. This separates temporal and spatial
sensitivity; three grids do not yet establish reliable load convergence.

`Scripts/summarize-connected-loads.py` reproduces the grid/CFL comparison and rejects
partial or unmatched-energy reports. The box remains held, gas angular momentum is still
not audited, and this pressure pulse is not a detonation model. Next, improve the spatial
representation of the pulse and pressure transport around clipped geometry, then repeat
these load checks before allowing free-body motion.

The held-box study now has opt-in `--volume-average` pressure initialization. Positive
quadrature integrates the Gaussian over the gas portion of each cell: full-fluid cells use
eight tensor Gauss nodes, while cut cells are partitioned into disjoint convex gas pieces
and tetrahedralized with a positive degree-two rule. No quadrature node samples the solid.
The quadrature volume is checked against the existing clipped gas volume, and its weighted
pressure average is normalized by quadrature volume before the existing matched-energy
normalization. This is approximate Gaussian integration, not an exact spatial solution.
The default point sampling and normal application simulations retain their existing behavior.

All twelve `--connected-loads --convergence --volume-average` cases complete at 6400 J and
0.5 ms. Quadrature-volume discrepancies are below 0.000000000000004 of nominal cell volume;
mass and energy budgets close to floating-point precision and momentum residuals remain
below 0.000000000001 N s. Twenty-six selected geometry/grouping/load tests pass, including
analytical quadratic moments, positive gas-only nodes in rotated cut cells, clipped-volume
agreement and independent matched-energy checks. The summary script also rejects mixed
initialization methods.

At CFL 0.1, forward impulses are 1.983/2.375/2.587 N s for the axis-aligned box and
1.896/2.231/2.437 N s for the rotated box. Relative to point sampling, coarse-grid changes
are −4.89%/−4.26%, but finest-grid changes are only +0.080%/−0.052%. The last refinement
still changes forward impulse by 8.92%/9.21%, and angular-impulse vectors by 10.81%/18.67%.
CFL effects remain below 0.222%. Correcting initialization therefore does not resolve the
spatial load sensitivity. Next, develop bounded spatial pressure/velocity reconstruction
on the stationary grouped geometry, verify uniform and affine-field behavior, then repeat
these load comparisons before adding moving geometry or free-body coupling.

Stationary grouped transport now has opt-in `--limited` reconstruction. Area/distance-squared
weighted least squares estimates density, velocity and pressure gradients from neighbouring
group means. A component-wise limiter bounds all face and wall traces to the group's
one-ring extrema, with trace-roundoff clamping to those same bounds. Rank-deficient or
poorly conditioned stencils retain constant states. This is a bounded reconstruction,
not a proof of positivity of the complete multidimensional update.

Reconstruction locations use quadrature-derived gas-volume centroids aggregated by member
volume; the existing grouping reference centres and geometry checks are unchanged. Supplied
wall traces now determine both exact wall-Riemann traction and the wall contribution to CFL.
SSPRK2 averages extensive gas updates and matching wall impulse/work from both stages.
The driver checks stage-two CFL, retries shorter steps on failed stages, and records
rejections without pressure/density floors. Fixed geometry and wall ordering retain the
existing owner-based budget attribution.

`Scripts/check-grouped-gas-reference.py` builds the selected implementations and tests in
an isolated temporary CPU-only package. All 32 tests pass without application imports or
Metal, including affine primitive reconstruction, analytical interior pressure-gradient
momentum, bounded sharp-gradient face/wall states, singular-stencil fallback, resting clipped
groups, supplied-wall traction/CFL validation, transport budgets and existing planar piston
accuracy cases. This demonstrates a source-level numerical boundary suitable for future
extraction; it does not replace a public API, provenance or fetched-release consumer check.

All twelve `--connected-loads --convergence --volume-average --limited` cases complete,
using 72–569 accepted steps and no rejected steps. At CFL 0.1, forward impulses on
0.2/0.1/0.05 m grids are 2.572/2.765/2.808 N s for the axis-aligned box and
2.427/2.610/2.661 N s for the rotated box. Last-refinement forward changes fall from
8.92%/9.21% with gas-average constant-state transport to 1.57%/1.96%; angular-impulse
vector changes fall from 10.81%/18.67% to 4.57%/6.66%. Across the limited cases, halving
CFL changes forward impulse by less than 0.001%. Mass and energy residuals are below
0.000000000000001 relative, and linear-momentum residuals below
0.000000000001 N s. Additional whole-domain first, squared and cross moments match the
analytical cube-complement moments, independently checking the gas centroids.

These results support the reconstruction, but three grids are not an independent load
accuracy reference. The comparison changes both spatial reconstruction and time integration;
small CFL sensitivity separates temporal effects without proving a formal convergence order.
Pressure traction is still evaluated once per patch at its centroid, and angular impulse
uses that point force. Even affine pressure requires second surface moments for exact torque;
centroid evaluation does not supply them. Gas angular momentum remains unaudited.

Next, introduce surface quadrature with matching gas impulse and integrated body torque,
verify affine pressure loads independently and repeat this comparison. Then establish a
bounded reflection/load benchmark before prescribed moving grouped geometry and free-body
coupling. The independently verified wall law and gas reference primitives can be proposed
for individual ContinuumKit extraction with explicit public contracts, source provenance,
fetched-consumer checks and BombCAD parity. Scene ownership, scenario construction and replay
remain here; the complete experimental coupling is not yet a verified shared product.

Held-box loads now have opt-in `--surface-quadrature`. Positive degree-two triangle nodes
are exposed by the clipped wall geometry and carried with boundary patches through grouping.
Grouping checks their positive areas, total area, first moment and coplanarity; unsupported
sample measures fail explicitly. Expansion into individual wall evaluation points preserves
owner and gas-group identity. Reconstruction limits all these locations, and both SSPRK2
stages use their wall-Riemann tractions for the matching gas impulse and integrated body
angular impulse. Domain walls retain centroid sampling. Constant-state pressure/velocity
per group gives the same integrated loads as centroid evaluation to floating-point precision.

Analytical checks demonstrate the previously missing patch torque: a unit square with
pressure `2 + y` and outward solid normal +x has torque 1/12 N m about its centroid in the
+z direction, while centroid-only evaluation gives zero. Whole clipped rotated and
axis-aligned boxes under affine pressure match the divergence-theorem force `-V grad(p)`
and torque about an arbitrary origin. Samples preserve resting uniform gas, positive
states and closed extensive gas/wall budgets. The selected geometry/grouping/reconstruction
suite passes 30 tests; the final CPU-only package passes 37 tests, including the
sampled-uniform-state regression. This is exact polynomial integration for the supported
pressure fields, not an independent transient blast-load validation.

All twelve `--connected-loads --convergence --volume-average --limited --surface-quadrature`
cases complete with 72–569 accepted steps and no rejections. At CFL 0.1, forward impulses
on 0.2/0.1/0.05 m grids are 2.571/2.763/2.808 N s for the aligned box and
2.418/2.606/2.660 N s for the rotated box. Last-refinement forward changes are 1.64%/2.08%,
compared with 1.57%/1.96% for centroid wall evaluation. Angular-vector changes are
4.05%/6.18%, compared with 4.57%/6.66%. The corrected integration therefore does not resolve
the remaining bulk spatial sensitivity. At the finest grid, surface sampling changes
forward impulse by −0.0052%/−0.0536% and angular vectors by 0.175%/0.151%.

The finest cases use 10,404/12,732 body-wall evaluation points for 1,734/2,122 patches;
this adds boundary work rather than gas cells. Mass and energy residuals remain below
0.000000000000001 relative, linear-momentum residuals below 0.000000000001 N s, and CFL
changes in forward impulse below 0.001%. Reports record the wall integration method and
sample counts; the summary rejects comparisons mixing wall integration methods.

Next, establish a stationary reflection benchmark with an independently specified wall
pressure and impulse history, separating spatial transport error from wall integration.
An analytical weak-wave case must explicitly quantify its finite-amplitude approximation;
an exact shock/rarefaction case must restrict the time before other boundaries interfere.
Only after these bounded checks should prescribed moving grouped geometry and free-body
feedback proceed. Gas angular momentum is still unaudited, and the degree-two rule is
approximate for nonlinear Riemann traction. No normal application simulation is enabled by
these experiments; stable primitives remain candidates for separately verified extraction.

An independent normal-shock reflection benchmark now supplies a transient load reference.
A leftward shock starts at x=0.655 m in a 2 m slip-wall channel. The incident state follows
[NASA's calorically perfect normal-shock relations](https://www.grc.nasa.gov/WWW/k-12/airplane/normal.html).
We apply the relations again in the reflected shock's frame, choosing its Mach number so
that downstream laboratory velocity is zero. Wall pressure changes from ambient to the
reflected value at the analytically determined shock-arrival time. Its integrated pressure
and excess impulse are piecewise linear. The reference does not call `IdealGasWallRiemann`;
independent tests check both shocks' mass, momentum and enthalpy jumps, and the Mach-2
special case gives reflected pressure 15 times ambient and density six times ambient.

The opposite wall starts in moving gas and creates a rarefaction. The reference calculates
when its head could first meet a shock, rejects configurations interacting before the
initial reflection, and refuses later times. Runs stop at 1.4 arrival times, safely before
interaction (the earliest cutoff is more than 1.42 run durations). Three cells across each
transverse axis provide full-rank stencils for the same 3D reconstruction used in the held-box
study; transverse slip walls preserve the planar solution. Initial cells contain conservative
averages of the sharp incident shock. Output and timesteps split at 0.8/1.0/1.2/1.4 arrival
times, including the pressure-history discontinuity.

`--wall-reflection` and `--wall-reflection --limited` complete sixteen cases each: 0.1,
0.05, 0.025 and 0.0125 m streamwise cells, CFL 0.2/0.1 and incident Mach 1.2/2. There are
242–2143 accepted steps and no rejected steps. At CFL 0.1, first-order step-average pressure
history L1 errors on the finest grid are 17.93%/12.11%; reconstruction reduces these to
5.11%/6.24%. Reconstructed history errors decrease on every grid for both shock strengths
and timestep settings. Halving CFL changes reconstructed history error by less than 0.085%
relative. The normalized final excess-impulse errors are only −0.103%/−0.262%, versus
−0.336%/−0.805% with first-order transport: good total impulse can conceal a blurred load
history. These pressure-history percentages normalize the integrated absolute error by the
exact excess impulse over the entire run, not by ambient pressure or instantaneous pressure.
The calculation uses accepted-step average traction, with the exact history constant within
each event-split interval; it is not a pointwise peak-pressure error measure.

Mass/energy residuals stay below 0.000000000000001 relative and linear-momentum residuals
below 0.000000000001 N s. The 41-test CPU-only suite passes, covering the independent oracle
and coarse channel budgets; an added regression checks that reconstructed history improves
with refinement and against first-order transport. `Scripts/summarize-wall-reflection.py`
rejects incomplete/mismatched reports and checks history refinement before reporting errors.

This supplies a bounded propagation/load benchmark without a weak-wave amplitude floor.
It has regular stationary cells and normal incidence; oblique clipped-wall accuracy, gas
angular momentum and moving group topology remain separate gates. Next, refine the shock
history further and extend this reflection case to prescribed planar wall motion using the
existing moving-wall/piston references, before rebuilding moving clipped groups or coupling
free-body feedback. The normal application
solver remains unaffected, and verified reference components can be extracted individually.

Further static reflection refinement now accepts `--wall-reflection --limited --refined`,
adding 0.00625/0.003125 m streamwise cells at CFL 0.2 for both Mach numbers. All four cases
complete with 1855–3913 steps and no rejections. The ordinary sixteen-case limited report
is regenerated with identical transport results and added timing diagnostics. The general
reference limit increases to 800 streamwise cells; this does not change the app air grid.

At CFL 0.2, pressure-history L1 errors on 0.0125/0.00625/0.003125 m grids are
5.12%/2.56%/1.28% for Mach 1.2 and 6.24%/3.32%/1.69% for Mach 2. Normalized final
excess-impulse errors on the finest grid are −0.024%/−0.072%. Mass and energy residuals
remain below 0.000000000000001 relative and momentum residuals below
0.000000000001 N s. Finer cases use CFL 0.2; the preceding CFL-pair comparison remains
the temporal sensitivity evidence, rather than a new finest-grid timestep study.

First 10/50/90% crossings of the exact pressure jump are interpolated between numerical
accepted-step mean tractions. The exact step crosses every threshold at arrival, giving
zero rise width. Numerically, 10–90% widths on the three fine grids are
105.8/52.9/26.5 microseconds for Mach 1.2 and 60.5/30.2/15.1 microseconds for Mach 2.
The finest half-rise timing biases are −0.080%/−0.100% of exact arrival time. These widths
shrink almost in proportion to cell size; smearing dominates the remaining arrival bias.
The diagnostic is a measure of numerical step-average load history, not a reconstruction
of within-step instantaneous pressure or a physical shock thickness.

A threshold not reached before the supported cutoff remains absent; the coarse first-order
Mach-1.2 run does not reach 90%. Very coarse inputs can average the initial shock into the
wall cell; levels already exceeded by the numerical initial traction are recorded at zero.
Tests cover ordered finite crossings, missing late levels, initially exceeded levels and
rise-width reduction with refinement. All 42 CPU-only tests pass. The summary's optional
`--refined` mode checks matching references, ordered rise times and decreasing history errors
and rise widths across all three fine grids. Next, extend the reflection benchmark to
prescribed planar wall motion with independently predicted impulse/work, using the existing
piston references, before moving clipped groups or enabling free-body feedback.

The shock-reflection reference now has a prescribed moving-wall extension. Mirroring x
and adding a constant Galilean velocity places the piston at `L + v t`; unshocked gas
initially moves at v, so there is no additional wave at that piston. Incident and reflected
pressure/density are unchanged, reflected gas moves with the wall, and exact piston work
is `v * impulse`. The fixed opposite wall still launches a rarefaction when its incident
gas moves away; its head in the transformed frame has the same path and inherited cutoff.
Velocities that put that opposite wall on the compression branch are explicitly unsupported.
This is a deliberately controlled reference, not a piston driven into initially stationary air.

`PrescribedPistonTube` accepts an optional conservative initial profile over each physical
interval. It checks returned volume against the prescribed geometry, aligns only volume
roundoff, retains the supplied extensive inventory and validates gas states. Default uniform
initialization is unchanged. Snapshots now attribute right-piston impulse separately from
all-wall impulse. An optional accepted-step observer receives interval time/duration and
piston impulse/work; rejected trial stages emit no observations. This lets the benchmark
compare the complete accepted-step mean pressure history with its event-split exact reference,
rather than using final impulse alone.

`--moving-reflection` and `--moving-reflection --constant` complete 32 cases each on
0.05/0.025/0.0125/0.00625 m cells, Mach 1.2/2, piston speeds −20/+20 m/s and CFL 0.2/0.1.
The tube records 0–7 full-cell crossings and 0–7 merge/split remeshes per run. There are
258–4724 accepted steps; the reconstructed runs retry 213 failed stages in total, while
first-order runs have none. These are discarded trials, with accepted loads accumulated
only after a valid update. Existing stage-aware shorter-step control remains in use.

At CFL 0.1 on the finest grid, reconstructed final impulse errors normalized by exact excess
impulse are −0.065%/−0.068% for Mach 1.2 at −20/+20 m/s and −0.127%/−0.125% for Mach 2.
First-order errors range from −0.185% to −0.430% there. Reconstruction is not uniformly
better in coarsest-grid total impulse: the coarse Mach-2 cases show cancellation in the
first-order integrated load. Reconstructed pressure-history L1 errors on the finest grid
are 3.62%/4.00% for Mach 1.2 and 3.30%/3.45% for Mach 2, versus first-order 9.91%/10.71%
and 5.97%/6.32%. History errors decrease on every grid for every direction/CFL/method.
Halving CFL changes reconstructed history error by less than 0.12% relative and final
impulse error by less than 0.0024 percentage points of the exact excess-impulse normalization.

The paired work errors have the same magnitude as impulse errors and opposite sign for
negative v, as required by the normalization using `abs(v)`. They are not independent
accuracy measures at constant speed. Independent consistency checks give mass residuals
below 0.000000000000003 relative, gas-energy-plus-wall-work residuals below
0.000000001 J, momentum residuals below 0.000000000001 N s, volume residuals below
0.000000000000001 m³ and `W - v I` below 0.000000000001 J. All 47 CPU-only tests pass,
including transformed states, unsupported inputs, conservative custom initialization,
signed work through crossings and accepted-observation accumulation; 16 selected legacy
piston/reconstruction tests also passed before the additional observer regression.

A prescribed translating-box space/time geometry reference is now implemented. With fixed
orientation and constant velocity, all feasible three-plane intersections of the six cell
and six box planes identify topology changes, including edge/edge crossings. Two-node Gauss
time quadrature then integrates quadratic areas and cubic spatial first moments/volumes.
Wall normals point out of gas; their integrated areas give pressure impulse, and time-weighted
areas keep torque measured about the translating centre of mass. Bounds skip cells proved
clear or solid throughout the interval; clear endpoints alone do not justify skipping.
Nearly parallel plane triples are rejected, and tolerance-scale grazing contacts are not
certified. This geometry is separate from the existing adaptive rotation sweep.

`--translating-box-geometry` completes aligned/0.23-radian cases on 0.2/0.1 m grids, moving
the 0.8 m box at (3,1,-0.4) m/s for 0.08 s inside a 2 m cube. Each case crosses fully dry
and wet cells: dry→wet counts are 9/6/133/129, and wet→dry counts 9/11/133/125, respectively.
The finer aligned/rotated cases also detect 18/5 cells occupied only between clear endpoints.
Maximum normalized swept-volume error is below `6e-15`; area/moment closure and
shared-face area/first-moment discrepancies are below `3e-14`. Whole-domain gas
volume differs from 7.488 m³ by less than `1e-12` m³; uniform-pressure body impulse,
torque impulse and work vanish to below `1e-11` in their SI units.

An exact-trace probe integrates uniform Euler fluxes and moving-wall pressure work with gas
velocity equal to box velocity and supplied matching outer inflow/outflow. Maximum nominal-cell
mass/energy errors are below `5e-15`, and momentum error below `5e-10`.
Dry-cell predicted volumes can be negative at roundoff scale (about `4e-18` m³);
the diagnostic retains this residual without applying a floor. This is a geometry identity
check, not a numerical gas update or validation of newly exposed-cell initialization.
All 55 tests in the CPU-only reference package pass, including analytical slab moments,
transient occupancy, rotated closure, motion reversal, offset-centre torque, coincident
stationary contact and rejected configurations. The four release study reports also pass
the conservation and transition checks; strict formatting and diff checks are clean.

Moving interval groups now use time-averaged gas volumes and aperture/first-moment measures
for support geometry, including members that are initially or finally dry. After geometric
closure checks, adjacent support groups are merged until both old and final gas capacities
exceed 0.25 nominal cell volume (maximum 64 members). Actual extensive group states are
summed exclusively from old gas inventories; geometric unit-state placeholders never become
physical inventories. A newly exposed cell with no connected old support is rejected.
Accepted packets scatter in proportion to final wet volumes, giving a largest wet member
the floating-point remainder and exactly zero to final dry members.

One frozen-state Rusanov/local wall update now uses these averaged areas. The existing Euler
reference checks acoustic/contraction CFL and state positivity; computed wall displacement
must match endpoint group volumes before those geometric volumes are used for scattering.
No second remap flux is added. Each outer opening receives a prescribed reservoir buffer;
its paired inventory change is reported in the global mass/momentum/energy budget. Pressure
impulses, work and area/time-weighted application locations retain the paired body loads.

Rotated crossings exposed cancellation in almost-solid cells and almost-blocked faces.
Thin gas volume now uses the existing positive tetrahedral quadrature, and thin open faces
use disjoint positive polygons classified by the first violated solid plane. This preserves
emerging gas corners below the precision of full-volume subtraction; an independent
tetrahedron/triangle test checks their volume, area and centroid. The original clipping
tolerances and unsupported near-parallel/grazing configurations still apply. Crossing times
use complete corner containment, rather than a gas-fraction threshold that would delay a
rotated corner's first appearance.

`--moving-groups` completes eight single-interval cases: two grids, aligned/0.23-radian boxes,
and opening/closing windows. Aligned windows contain simultaneous dry→wet and wet→dry counts
of 9 on 0.2 m grids and 49 on 0.1 m grids; each rotated window crosses one selected cell.
Opening/closing windows coincide in the aligned geometry. Initial durations are 4 microseconds;
the finer rotated opening rejects one trial and rebuilds geometry for 2 microseconds.
The accepted minimum group capacity exceeds 0.25 at both endpoints, with two members at most.
Numerical comoving gas preserves density and pressure within `6e-15` relative and velocity
within `5e-11` m/s, including newly exposed members. Swept-volume residuals are below `2e-15`
of a nominal cell. Budget residuals are below `1e-14` kg, `4e-14` N s and `3e-9` J;
`W - v·I` is below `3e-16` J. Uniform-pressure net body impulse/work are below `1e-11`
in SI units. These are numerical conservation/constant-state checks, not nonuniform moving
wave accuracy measurements.
All 61 CPU-only tests in 12 suites pass, including conservative endpoint scatter, rejected
unsupported groups and inconsistent volumes, the thin tetrahedral corner, nonuniform static
pressure budgets and finer-grid CFL retry. Both geometry and moving-group release reports
pass their conservation/transition checks; formatting and diff checks are clean.

Sustained prescribed translation now repeats interval geometry, grouping, paired Euler flux
and final-volume scatter while retaining each accepted gas inventory. The next interval checks
those volumes against its initial geometry and uses the existing extensive packets unchanged.
A prescribed pose copy preserves orientation exactly, so repeated construction does not
renormalize it or recompute the accepted position from a separate clock. CFL/invalid-state
rejections keep gas, pose and cumulative loads untouched and rebuild the shorter interval.
Four matched-time snapshots split steps at their physical output times. Compensated sums
audit gas, outer-reservoir exchange and body impulse/work throughout the trajectory.

`--moving-trajectory --halving` runs 0.2/0.1 m grids, aligned/0.23-radian boxes and CFL
0.2/0.1. Gas and box move together at (300,100,-40) m/s for 0.8 ms: a prescribed stress
trajectory with ambient density/pressure and displacement (0.24,0.08,-0.032) m. The faster
translation exercises several cell crossings without changing the initial thermodynamic
state. The eight cases take 141–692 accepted steps. Aligned trajectories open/close 9/9 cells
on the coarse grid and 147/147 on the finer grid; rotated counts are 9/14 and 137/133.
An independent reference intersects six linear corner-containment inequalities to count
fully solid intervals, including cells wet at both endpoints that become solid in between.
Every numerical transition count agrees, at both CFL settings.

`--moving-trajectory --ambient-window --halving` retains (3,1,-0.4) m/s and evolves 64-microsecond
windows straddling an opening event, with 9–40 accepted steps and the same output-time checks.
These windows exposed a roundoff contact where tetrahedral gas volume was positive while
all face apertures were zero. Quadrature now uses the same geometric contact tolerance as
open-face clipping, preventing isolated phantom support; gas inventories are still neither
reset nor floored. A dedicated dry-volume/face regression covers this case, alongside the
existing analytically resolved thin tetrahedral corner.

Across all sixteen trajectories and their snapshots, maximum density/pressure errors stay
below `4e-14` relative, and velocity error below `1e-11` m/s. Cumulative budget residuals
are below `3e-14` kg, `8e-12` N s and `2e-9` J; gas-volume change is below `2e-15` m³,
and paired `W - v·I` below `2e-13` J. Every endpoint group retains at least 0.25 nominal
cell volume, with two members at most. These residuals assess conservation and preservation
of an exact constant state, rather than spatial or temporal accuracy of a nonuniform wave.

`Scripts/summarize-moving-trajectory.py` requires both complete eight-case matrices and checks
positivity, endpoint group capacity, prescribed displacement, matched snapshots, cumulative
mass/momentum/energy and paired impulse/work. Its independent Rodrigues-rotation/projected-cube
reference also verifies the Swift oracle and all transition counts. Tests additionally carry
a nonuniform accepted packet into a second interval to detect accidental ambient reinitialization,
reject inconsistent inventories, and preserve mechanical state during prescribed pose copies.
All 67 CPU-only tests in 13 suites pass. The sixteen final release reports pass the independent
summary checks; strict formatting and diff checks are clean.

Nonuniform moving transport now has an exact quadratic-density advection reference:
`rho = rho0 [1 + a ((x - u_x t - c)/L)^2]`, with rho0 = 1.225 kg/m³, a = 0.2, c = 1 m,
L = 1 m, pressure 101325 Pa and velocity (300,100,-40) m/s. Continuity reduces to scalar
advection; constant pressure/velocity make momentum and energy consistent with it. A box
moving at the same velocity has exact wall pressure p despite the density variation.
This isolates transport from pressure-wave or free-body errors.

Positive degree-two gas quadrature initializes conservative cell averages and evaluates
matched-time references, normalizing only the roundoff difference between volume formulas.
An independent whole-domain integral subtracts the translating box's invariant density
moment from the 2 m cube. Reference mass changes by 0.112896 kg over the trajectory,
consistent with the prescribed exterior flow. Boundary-specific reservoir callbacks now
accept spatial/time-dependent states. The reference integrates quadratic density on full
fixed outer faces using spatial and temporal variances; each numerical reservoir packet
remains paired and its inventory change audited. The engine carries accepted gas through
every interval and never substitutes the exact interior reference for evolved inventories.

`--moving-entropy` completes twelve 0.4/0.2/0.1 m grid, aligned/0.23-radian box and CFL
0.2/0.1 cases over the same 0.8 ms prescribed trajectory. At matched output times,
extensive density L1 error is divided by the exact excess density mass above rho0.
Final errors are about 30.1%, 17.9% and 10.1%; observed refinement rates are 0.75 then
0.82. Errors decrease at both orientations and CFL values. Halving CFL changes final L1
error by at most 0.265% relative, exposing dominant spatial diffusion/group homogenization
rather than timestep error. The maximum density error in newly exposed cells over the
fine-grid trajectory is about 3.4% aligned and 4.0% rotated relative to their exact density.
These errors are material transport errors, distinct from conservative budget residuals.

Pressure stays within `5e-14` relative and velocity within `3e-12` m/s of their exact constants.
Cumulative budget residuals are below `3e-13` kg, `7e-11` N s and `7e-8` J;
reference clipped-cell quadrature matches independent whole-domain mass within `4e-15` kg.
All wet/dry transition counts agree with the geometric oracle. The independent Python
summary checks the complete matrix, closed-form mass/energy, positivity, paired work,
conservation, transition counts and spatial refinement. Density diagnostics are sampled
at matched times; newly exposed-cell errors and pressure/velocity preservation are monitored
throughout accepted steps. Tests check full/half-cell quadratic averages, independent
spatial/time Gauss boundary samples, rotated whole-domain mass, exact mass gain, coarse-grid
transport refinement and rejected mismatched frame velocities/invalid exterior traces.
All 72 CPU-only tests in 14 suites pass; formatting and diff checks are clean. The full
release build succeeds with the incoming main's existing AirSlice concurrency warnings.

Limited spatial reconstruction now reduces moving transport diffusion and member mixing.
Optional interval metadata supplies true old/final gas-volume centroids and final open-face
adjacency. Old group centroids weight only existing inventories; final centroids weight
final wet capacities. Primitive least-squares face/wall traces reuse the existing one-ring
limiter on time-averaged evaluation points. Reflected exterior stencil points sample supplied
old-time states, while fluxes retain the prescribed area/time-averaged external states.
Wall velocities and paired impulse/work remain explicit. The stationary SSPRK2 helper is
not used for moving volumes; this update still uses one frozen-state Euler time step.

Endpoint splitting reconstructs conserved densities at final member centroids. A common
slope factor keeps each component inside its final-neighbour extrema, and weighted member
offsets preserve the group inventory. A largest wet member takes the packet remainder.
Euler positivity is checked on the constructed member packets; inadmissible slopes are
reduced by bisection without mass/pressure floors or inventory changes. Rank-deficient
multi-member groups split at constant state. Final adjacency uses actual endpoint openings,
rather than interfaces that were open only earlier in the interval.

`--moving-entropy --limited` completes the same twelve reference cases in a separate report.
L1 errors are about 2.9%, 1.0–1.1% and 0.3–0.4% on 0.4/0.2/0.1 m grids, normalized by
the same excess density mass as before. At CFL 0.1, fine-grid error improves 26.8× aligned
and 32.2× rotated. Observed refinement rates range from 1.39–1.49 on the first halving
to 1.46–1.68 on the second. Fine-grid maximum newly exposed-cell density errors fall from
3.4%/4.0% to 1.19%/0.96% aligned/rotated. These are substantial spatial improvements,
not a claim of a second-order moving solver: CFL halving now changes L1 error by as much
as 5.81% relative, making the remaining first-order time integration measurable.

Pressure/velocity remain within `5e-14` relative/`5e-12` m/s of their exact constants.
Budget residuals stay below `2e-13` kg, `3e-11` N s and `5e-8` J, with paired work below
`3e-13` J. No positivity backoff or rank fallback occurs in these smooth advection cases;
the limiter activates near constrained member stencils. Both limited uniform trajectory
matrices also pass (sixteen fast/original-speed cases), including every geometric transition.
The summaries accept `--limited` and check complete matrices, independent reference integrals,
positivity, conservation, spatial refinement and improvement against the constant-state method.

All 78 CPU-only tests in 15 suites pass. New tests independently check affine conserved
member averages and packet budgets, a nonlinear kinetic-energy case requiring positivity
backoff, deficient-neighbour fallback, affine interior face traces with exterior stencil
points, original-speed uniform crossings and limited advection refinement. Strict formatting
and diff checks are clean. The release builds retain the incoming AirSlice concurrency warnings.

An opt-in `--heun` update now integrates interval-local moving groups in two stages.
The time-averaged faces and wall measures remain fixed for the accepted interval. The
first Euler stage takes old inventories at V0 to the true endpoint V1; the second starts
there and temporarily extrapolates capacity to V2 = V0 + 2(V1 − V0). Averaging old and
second-stage extensive inventories returns the true endpoint capacity V1. This preserves
the moving geometric conservation law and uniform comoving states. No raw-member scatter
occurs between stages; only the final averaged group packets are reconstructed/split.
Both Euler stages and the final state must pass CFL/positivity checks transactionally.
Wall impulse, wall work and reservoir exchange use the same half-stage weights as gas.

Limited traces use old gas centroids/old-time exterior stencil points in stage one and
final gas centroids/endpoint-time stencil points in stage two. Prescribed flux reservoirs
are sampled once per interval and retain the same area/time averages in both stages,
avoiding an additional time shift of already averaged boundary data. The default Euler
mode and its separate reports remain available for comparisons.

A single-group expanding piston separates temporal error from clipping, changing partitions
and spatial reconstruction. An independent dense RK4 integration of its local pressure ODE,
using V(t) directly, provides a reference. Halving steps from 4 to 8 to 16 to 32 gives
rates between 1.9 and 2.1 for Heun, versus 0.9–1.1 for Euler. Every step preserves gas/wall
momentum and energy, with work equal to piston speed times impulse. Additional tests check
second-stage CFL rejection, one reservoir sample per patch, endpoint stencil evaluation
and aligned/rotated uniform wet/dry regrouping with constant and limited reconstruction.

The twelve `--moving-entropy --limited --heun` cases retain decreasing spatial errors:
about 2.8–2.9%, 0.98–1.03% and 0.30–0.36% on the three grids. Observed spatial rates
range from 1.47 to 1.71. Maximum relative L1 sensitivity under CFL halving falls from
5.81% to 0.087%, with improvement at every grid/orientation. Fine-grid maximum newly
exposed-cell density errors remain about 1.19% aligned and 0.96% rotated; time integration
has not removed bounded member mixing near walls. Pressure stays within `5e-14` relative,
velocity within `5e-12` m/s, and cumulative budget residuals below `7e-14` kg, `2e-11` N s
and `3e-8` J. Paired work residuals stay below `5e-13` J. No member positivity backoff
or rank fallback occurs. The entropy summary checks all three method matrices and verifies
improved CFL sensitivity, along with independent integrals and geometric transition counts.

Both two-stage uniform trajectory matrices pass all sixteen fast/original-speed cases,
including every independently predicted wet/dry transition and cumulative reservoir/body
budget. All 82 CPU-only tests in 16 suites pass, and the twelve advection cases pass the
independent summary. Strict Swift formatting and diff checks are clean. The full release
build succeeds with main's existing AirSlice concurrency warnings.

Known-pressure moving loads now isolate the surface/time quadrature gate. Optional wall
samples combine positive degree-two triangle nodes with four positive Gauss nodes per
clipping-event interval. Their weights are area × time, with actual world positions and
relative times. They recover existing area, spatial first moments and time-weighted area;
samples follow the translating wall plane rather than its time-averaged plane. Four time
nodes integrate the degree-six products arising from clipped areas, moving lever arms
and affine pressure with quadratic time coefficients. The original two-node geometric
integrals remain unchanged when sampling is disabled.

`--moving-pressure` imposes p(x,t) = b(s) + g(s)·(x − c0 − vt), s = t/T, on a translating
0.8 × 0.6 × 0.4 m box with an offset centre of mass. Both b and g are quadratic in s.
For this imposed trace, the divergence theorem gives impulse −VT(g0 + g1/2 + g2/3),
angular impulse (c0 − COM0) × impulse, and work v·impulse. The rectangular box, rotated
orientation and offset COM exercise force and torque separately. This pressure field is
not a source-free Euler solution: no gas state or numerical reflection is evolved here.

Twelve cases cover 0.4/0.2/0.1 m grids, aligned/rotated boxes and one/four time slices over
0.8 ms at (300,100,−40) m/s. Joint centroid evaluation gives 2.84–3.49% impulse error and
9.23–16.84% angular-impulse error with one slice. Four slices reduce impulse error to
0.237–0.259%, but torque error still spans 0.65–9.42%; spatial refinement is not uniformly
monotonic for centroid loads. Temporal subdivision alone does not remove surface covariance
error. Positive samples match exact impulse, angular impulse and work within `4e-14`
relative, and work/impulse consistency within `6e-12` J. Sample moment residuals remain
below `2e-14` relative; minimum prescribed sample pressure exceeds 81 kPa. These load
accuracy errors are separate from the roundoff-scale paired exchange budget.

The sampled load kernel validates positive finite weights, time bounds, translating-plane
positions, area/space/time moments and positive finite pressure. It provides the same
pressure impulse and work with opposite signs as a gas reaction packet. Tests check exact
local force/torque/time integration, a paired extensive gas-buffer update, transient wall
intersections with clear endpoints, malformed samples/pressures and full-box exact loads.
The independent Python summary uses Simpson integration of the quadratic gradient and
Rodrigues rotation for the offset COM; it checks all twelve reports and their errors.
All 86 CPU-only tests in 17 suites pass. Strict formatting and diff checks pass; the release
build succeeds with the existing AirSlice warnings. These initial sample probes remained
separate from the numerical moving-group wall traces.

Optional positive wall samples now pass through numerical moving-group updates. The builder
validates their area/space/time moments and translating-plane positions before grouping,
restricts them to body walls, and preserves their world positions and times when cell
ownership is remapped. Euler stages expand each wall into its positive samples; limited
primitive traces include all sample positions in their bounds. Local moving-wall Riemann
pressures, acoustic/contraction limits and the geometric conservation law use these same
sample weights. Returned loads retain one entry per original wall patch.

For sampled Heun walls, alpha = sample time / interval duration interpolates the two
endpoint pressure packets: (1−alpha) I0 + alpha I1. The ordinary half-stage update receives
the difference as a gas momentum/energy correction, paired with exactly the same body
impulse/work. Reservoir and internal-face updates retain their half-stage weights. The
corrected final state must pass Euler positivity before member scattering; this correction
has no separate SSP positivity guarantee. Euler mode uses frozen old traces. The numerical
Heun pressure history is linear between stage traces, unlike the preceding known-pressure
probe which supplies its full quadratic time dependence at every node.

Angular impulse now sums each sample lever arm at its actual time, rather than applying an
aggregate force at the joint centroid. A moment about a translating origin is returned;
subtracting COM0 × impulse gives torque impulse about the translating centre of mass.
This changes body load evaluation and does not add conserved gas angular momentum.
`--surface-quadrature` selects separate numerical entropy/trajectory reports; centroid
updates remain the default.

All 91 CPU-only tests in 18 suites pass. New checks independently compare uneven-time
pressure packets with constant-area Euler stage pressures, including their gas correction
and a torque missed by centroid evaluation; compare constant Euler sampled/centroid loads
through a rotated wet/dry crossing; audit nonuniform reconstructed pressure momentum/energy
and wall work; and carry uniform/advected-density states through repeated sampled updates.
The nonuniform-pressure interval has real evolving gas states but does not establish
pressure-load convergence or shock accuracy.

The fast rotated trajectory exposed a tolerance-scale corner contact: its integrated wall
measure was about `4e-17` of a full cell-face interval. The instantaneous wall polygon rule
already discards areas below `h² × 1e-14`; two and four Gauss rules can sample that cutoff
differently during an extremely short contact. For integrated wall measures at or below
`h² dt × 1e-14`, one positive joint-centroid sample now preserves the canonical area and
space/time moments. The validation tolerances stay unchanged. This geometric quadrature
fallback introduces no gas inventory or pressure floor. Accepted fallback counts are
reported cumulatively, and a dedicated short-corner-contact regression checks positivity
and exact preservation of the canonical measures.

All twelve sampled advection cases and sixteen uniform fast/original-speed trajectories
pass the independent summaries, including every wet/dry transition and the new cumulative
fallback counters. Fine-grid density L1 is 0.309–0.362% of the imposed excess mass, with
observed spatial rates from 1.47 to 1.67. CFL halving changes L1 by at most 0.070% relative.
The additional limiter evaluation locations increase L1 by at most 3.16% relative to
centroid Heun walls; no density improvement is claimed from changing wall integration
in this constant-pressure probe. Across these 28 cases, pressure remains within `6e-14`
relative and velocity within `1.1e-11` m/s. Budget residuals stay below `8e-14` kg,
`3e-11` N s and `3e-8` J, and paired work below `7e-13` J.

One fast rotated case uses one accepted sub-resolution wall fallback. Three original-speed
aligned cases use 14, 14 and 28 accepted fallback instances; the other trajectories and
all advection cases use none. The full known-pressure twelve-case probe also still matches
its independent exact loads. Strict Swift formatting and diff checks pass, and the release
build succeeds with main's existing AirSlice concurrency warnings.

A sustained nonuniform-pressure study now reuses the moving transport loop. An internal
initial-state override checks cell count, clipped capacities, dry status and Euler positivity;
existing uniform/analytic drivers keep their initialization. The pressure-load wrapper
renames uniform-reference diagnostics as ambient departures, since the evolving pulse has
no exact solution. Minimum density joins minimum pressure in the shared accepted-step audit.

`--moving-loads` seeds p = p0 + a exp(−|q|²/2), with q = (x − (0.45,1.18,1.10)) /
(0.14,0.18,0.18), uniform density 1.225 kg/m³ and velocity (300,100,−40) m/s. Positive
clipped-gas quadrature supplies cell pressure averages. Amplitude a normalizes realized
excess internal energy to 6400 J independently for each grid/orientation, avoiding different
input energy in the load comparison. Initial mass and total energy are checked against
whole-domain gas volume and independently realized pulse energy. Each CFL pair shares the
same immutable initial packets. Outer reservoirs remain prescribed ambient gas; the box
translates at the initial gas velocity, with no free-body response or ground contact.

The default twelve cases cover 0.2/0.1/0.05 m grids, aligned/rotated boxes and CFL 0.2/0.1.
Over 200 µs the body moves (0.06,0.02,−0.008) m. Four matched cumulative snapshots report
impulse, angular impulse, body work, pressure/density departures, perturbation speed,
positivity, geometry transitions and complete gas/reservoir/body budgets. The Python summary
independently checks initial energy/mass and geometric transitions, then compares CFL pairs
and load histories against the 0.05 m/CFL 0.1 numerical case. That finest case is a
comparison, not exact truth; neither observed refinement nor conservative budgets validate
blast loads by themselves.

All 96 CPU-only tests in 19 suites pass. New tests independently audit pulse energy and
inventory across grids/orientations, recover the existing uniform trajectory at zero pulse
energy, check repeated evolving pressure with positive gas and paired loads, and reject
invalid pulse/grid/CFL parameters or incompatible initial inventories. Strict formatting
and diff checks pass. The full release study is also checked independently.

All twelve release cases complete and pass the independent energy, positivity, transition
and exchange audits. Initial excess energy matches within `1.2e-11` J. Across the run,
minimum density/pressure remain above 1.15 kg/m³/101 kPa and maximum perturbation speed
is about 23.1 m/s. Cumulative budget residuals stay below `3e-12` kg, `6e-10` N s and
`6e-7` J; moving-volume residuals stay below `9e-16` m³ and paired work below `2e-13` J.
No member positivity backoff or deficient-neighbour fallback occurs. Tiny wall-sample
fallbacks are recorded rather than hidden.

CFL-halving differences in final impulse/angular impulse stay below 0.064%/0.095%.
Grid dependence is much larger. At CFL 0.1, final aligned impulse differs from the 0.05 m
case by 20.9% on 0.2 m cells and 10.8% on 0.1 m cells; angular impulse differs by
13.8% and 9.18%. The rotated differences are 5.56%/5.79% for impulse and 22.0%/1.95%
for angular impulse. Rotated final impulse does not improve monotonically at these grids.
Matched cumulative-history differences decrease under refinement, but still reach
14.6%/13.7% aligned and 7.16%/4.51% rotated on the 0.1 m grid. Temporal consistency
and conservation therefore do not establish spatial load accuracy; these loads are not
settled across grids. The summary reports this without imposing a convergence assertion
or calling the finest solution exact.

The finer rotated case exposed an ill-conditioned raw-cell area check. The captured cell
had mean gas capacity `9.86e-26` m³ and total surface area `4.81e-17` m²; dividing its
roundoff-scale imbalance by that vanishing surface gave a relative residual just above
`1e-8`. Moving grouping now supplies nominal cell-face area for raw-cell closure scaling,
consistent with the geometry reference's nominal volume/moment scales. After merging,
closure still uses the original actual group-surface scale. Static callers retain their
original raw-cell check. The captured interval is tested with positive old/final group
capacities and uniform pressure/velocity preservation through the sampled update.

Next, isolate initial wall-trace error against independently integrated Gaussian surface
loads, then assess the remaining spatial load error before free-body feedback. Local second-order time
convergence does not establish second-order accuracy across changing group partitions and
bounded member scatter. Frozen interval measures also require further checks when pressure
and velocity vary, especially near shocks and geometric contacts.
Constant-pressure advection does not measure blast-wave or pressure-load accuracy. The
conservative reconstruction still does not preserve gas angular momentum. Coupled free-body
velocity, rotation, ground contact and gas angular momentum remain subsequent gates. Ordinary
simulations are unchanged, and stable kernels remain candidates for separately reviewed shared
extraction.

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

Started: a solid body's base can now be tied to the ground by a connection that deforms, opens
and slides, and fails in tension and shear, with contact and Coulomb friction after separation
(`StructureModel.baseAnchorage`; ideal clamping stays the default). Resting, construction-joint
and dowelled connections are provided, checked against statics, and compared on a freestanding
wall under a Kingery–Bulmash pulse (`blastbench anchorage`): on starter bars the wall sways
within 10% of the clamped one at a distance and up to 39% more close in; on a plain joint or
resting on the ground, a pulse that sways the clamped wall 11 mm tips it over. See the
[structural model](structural-model.md#base-connections). Shells and columns of beam elements
have them too, at points across their footprint, and give the wall the same answers. A base
can also stand on soil, as a Winkler bed that settles, turns and yields past its bearing
capacity, checked against settlement, rotation and the overturning moment of a footing whose
toe crushes the soil.

The app now edits base and per-support horizontal bearing connections, including custom
strength, opening, slip, friction, bearing capacity and stiffness. Independent raised-bearing
reactions, lift-off, clamp precedence, imported-source refinement, save/reopen and undo are
checked. Finite support regions select initial lower-face/footprint points and use stationary
horizontal bearing planes; they do not model a footing's finite contact extents. See
[structural editing](structural-editing.md#restraints). Still open: arbitrary joint orientations
and moving-component connections; bounded footings, and soil with mass, radiation damping and
layers; and a measured connection case. Loaded by the air instead of a pulse
(`blastbench anchorage --air`), the freestanding wall sways about a third as far: the wave
wraps over and round it and loads its back face, so at 25 m walls without bars stand that the
pulse throws over.

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
- **Export a run for rendering elsewhere**, so a finished simulation can be rendered in
  Blender's Cycles with hardware ray tracing instead of a renderer of our own (see
  [Ray tracing](ray-tracing.md#the-shortcut-export-to-blender)). The app keeps no frames today,
  only gauge and deflection histories, so the frames would be written during the run, most
  simply as an option of [`BombCAD run`](run-comparison.md#headless-runs) at a chosen frame
  rate. In two steps:
  1. **Geometry as USD**, in its text form (`.usda`), which needs no library: the blocks and
     ground once, the structure's surface with its points sampled per frame and failed elements
     dropped, and the charge and gauges as markers. (Done: `BombCAD run --usd`, with the
     project's view as a camera, and checked in Blender 5.2; see
     [Exporting a run for rendering](usd-export.md).)
  2. **The blast as OpenVDB volumes**, one file per frame, from the overpressure the renderer
     already ray-marches (the solver's visualisation volume). Blender reads volumes only as VDB,
     so this needs either the OpenVDB library (a large C++ dependency) or a small writer of our
     own for dense float grids. The size wants watching: a medium grid is 8.4 million cells, about
     34 MB a frame before VDB's sparseness, so a few gigabytes for a 0.17 s event at 1,000 frames
     a second of simulated time.
     (Done: `BombCAD run --vdb`, with a writer of our own, checked against OpenVDB through
     macOS's USD; overpressure and the pressure gradient, about 14 MB a frame on the medium
     street grid. See [Exporting a run for rendering](usd-export.md#the-air).)
  3. **In the app**: File ▸ Export for Rendering… runs a copy of the project in the background
     and writes both, with peak overpressure and impulse as further grids. (Done.)

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
