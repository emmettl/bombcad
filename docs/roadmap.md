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
[structural model](structural-model.md#base-connections). Still open: footings, soil and
foundation rotation; connections for shells and support regions; and a measured case.

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
     project's view as a camera; see [Exporting a run for rendering](usd-export.md). Not yet
     opened in Blender.)
  2. **The blast as OpenVDB volumes**, one file per frame, from the overpressure the renderer
     already ray-marches (the solver's visualisation volume). Blender reads volumes only as VDB,
     so this needs either the OpenVDB library (a large C++ dependency) or a small writer of our
     own for dense float grids. The size wants watching: a medium grid is 8.4 million cells, about
     34 MB a frame before VDB's sparseness, so a few gigabytes for a 0.17 s event at 1,000 frames
     a second of simulated time.

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
