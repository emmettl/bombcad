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
Several deformable structures now share one scene's air and meet through contact, with each
building's results its own; see [contact between bodies](multiple-object-scene.md#implemented-contact-between-bodies).

A separate [RoomCAD and convolution reverb roadmap](https://github.com/emmettl/RoomCAD/blob/main/docs/roomcad-roadmap.md) covers shared SwiftPM
modules, acoustic impulse-response generation, WAV export and potential Driftbox rack
integration, with milestones and acceptance checks. It does not replace the blast-model work
below.

## Standing of the project

BombCAD answers its original question: blast on simple structures can be simulated on a laptop
GPU at tens to a hundred times slower than real time, with physics that is verified against
theory. Against measurements, eleven structural tests give a mixed picture: bending either way
(a slab 4–14% high under its test's load and 12–21% low under a lighter one, a beam's strength
within 2%), impacts on beams with stirrups within a quarter on one mesh but not on a
finer one, shear 11–15% too strong on fine meshes, and full-scale slabs close in and an internal
explosion's roof far too stiff, a quarter to a half of the measured deflection. The defaults were
chosen with these tests in view; two tests since run blind both erred on the unsafe side, a slab
never punching and two slabs under a blast collapsing that the model left standing (see the
[independent review](validation-review.md)). It is not validated for engineering decisions, and
nothing in it should be used to judge the safety of a real structure.

## Limitations, most important first

| # | Limitation                                                              | Consequence                                                   | Detail |
|---|-------------------------------------------------------------------------|---------------------------------------------------------------|--------|
| 1 | The structural model has been compared with eleven member tests, and springs back too far | Mostly on the unsafe side, predicting too little damage: shear 11–15% too strong (37% on coarse meshes), the chamber's roof and close-in slabs too stiff (a quarter and a third to a half as far), small charges' slabs 40–70%, struck beams' struts holding where the tests crushed, six elements through 17% strong in bending, bars that slip too stiff nearly everywhere. In detail: on a slab test the peak rises to 124 mm on 32 elements against 109 measured (113 in its repeat), not converged (a strip of it runs away on 32), and under the contest's lower shot reaches about 80% of the peak; a beam bent to failure carries 98–101% of its measured moment; a beam failing in shear carries 111–115% of its measured load on fine meshes, 137% on coarse; beams struck by a falling weight with stirrups peak within 12–24% under light drops and −5% to +3% under heavy ones on 16 elements, and Ando's beams without stirrups peak within 15% on average on 16 elements (53% too far on 24), and A36 breaks at the speed its test did where B36 holds, while Saatci's without stirrups is damaged, and on fine meshes split, by a drop it survived; Peterson's short beams struck to a shear failure (2026) give the forces at a shear span of one depth, the deep ones too stiff, and fail without stirrups, but by splitting along their bars, while those with stirrups that crushed their strut in the test hold; full-scale slabs under close-in charges are left a third to a half as far down as measured, barely spalled and not holed; 2 m slabs with steel in one face or both bend within −20% to +7% under 1.6 kg at 0.5 m but 40–70% as far under smaller charges, and are holed by contact charges at a stable step to a half and a third of the measured size; in a full-scale internal explosion, with the chamber's detailing modelled, the roof's edge peaks at 49 mm against 87 mm in the test paper's own model and is left 25 mm up against 95 mm measured, with cracks that press as they slide, now the confined regime's default (38 and 15 mm without); on the finest mesh the answer has not converged. Bars that slip converge on every mesh but are too stiff nearly everywhere; hourglass control does 7–18% of the work at the slabs' peaks, where an element's own bending would be under 2% | [Validation](validation.md#an-internal-explosion-in-a-reinforced-concrete-chamber) |
| 2 | Shear failure and joints are the least reliable predictions             | The unsafe side where they err, shear too strong: breach, punching, direct shear and wall–slab joints are indicative only | [Concrete model](concrete-model.md#limitations) |
| 3 | Afterburning's burning time is fitted, and its fireball never cools       | Afterburning and hot air are the default since 15 October 2026 (1.3–2 times slower; off still selectable): incident and suction impulses within a few per cent, rooms within 8%, but the burning time was fitted to the open blast's impulse, and the gas, which since 19 October 2026 loses the heat it radiates, still radiates more than a TNT fireball's 4–7%; turned off, incident impulse is 13–22% low and rooms' gas 48–114% of the design value | [Air-blast model](air-blast-model.md#afterburning) |
| 4 | Peak pressure is under-resolved near the charge                         | Incident peaks close in come within a sixth of Kingery–Bulmash from 1 m/kg^(1/3) for 10–100 kg since the mapped start (18 October 2026; 63–99% for 1 kg), where the balloon left 32–84% (11–47%); reflected peaks near walls still read low, the unsafe side, and need fine or twice-refined air; spall needs cells of 0.005 W^(1/3) and 12 elements through a slab; the comparisons of structures were run on the balloon start ([still on it](validation.md#still-on-the-balloon-start)) | [Validation](validation.md#what-stops-the-spall-and-the-breach) |
| 5 | Collapse compared once, blind, and missed (two of Mendonça's slabs under an open-air charge); debris twice, off slabs under contact charges and brick walls under blasts | Debris held back rather than thrown, the unsafe side for a hazard (as rubble particles, an option, thrown at nearer the measured speed); brick walls crack at the measured heights but fall as one column, shattering on a rigid ground in the open (soft ground, an option, halves that) and thrown half as far as measured in a shock tube; collapse looks plausible, that is all | [Validation](validation.md#slabs-under-contact-charges), [brick walls](validation.md#brick-walls-debris) |
| 6 | Moving solids are a staircase of whole cells                            | Either way, to a cell: wall positions are good to a cell; small fragments are crude. Cut-cell outlines for structures before failure (an option, unrefined air) take the offset out of a wall's impulse but not its peak | [Structural model](structural-model.md#coupling-to-the-air) |
| 7 | Up to sixteen bodies of up to eight materials each, bonded within and meeting each other only by contact, lattice-aligned geometry; debris pushed crudely by the air | Real buildings only roughly (IFC buildings import as shells and beams where square to the axes, their materials, ties and supports inferred and listed); thrown debris and contact between buildings are approximate | [Structural model](structural-model.md#limitations) |
| 8 | The rebound after a slab's peak is too large; concrete broken under a close-in charge is never removed by default | Too stiff close in, the unsafe side: no hole under a close-in charge, and rebound too large (strength with pressure, and cracks pressed shut, checked: not the cause); removing fragments, an option, holes slabs both ways; rubble kept as particles, an option, holes none | [Validation](validation.md#holes-under-close-in-and-contact-charges) |
| 9 | Supports and freestanding objects are checked against statics and theory, and footings against nine centrifuge events on one sand (FoRCy, FoRDy) | Either way for a footing's rocking moment, settlement within a factor of 1.7, energy a sixth to two thirds of a shaken test's; footings on soil and connections that open and slide are in, as are boxes and cars that slide, lift and overturn; every object takes the air's load, but late flow is not converged and the cars and furniture are illustrative | [Freestanding objects and supports](#freestanding-objects-and-supports) |
| 10 | Only selected panels and document workflows have had visual review      | Other layouts and native interactions may still have problems | Below |

On the last point, see the [native interface review](native-interface-review.md#review-log).

## The plan

The aim is the best fidelity given the constraints of compute and available empirical data:
spend computation where the [error bands](standing.md#error-bands) say it buys accuracy, and seek
data where they say the model cannot be judged. Each area below gives what is **done** (a line
each, linked), what a session is on **now**, what is **next**, and what is **blocked**, and on
what. The plan as it stood item by item before 11 October 2026, with the account of each step,
is in the [roadmap history](roadmap-history.md).

### Validation

More evidence is worth more than more features.

- **Done:** eleven member tests and the air's references compared ([validation](validation.md#summary));
  an [independent review](validation-review.md) of the record, its wording and numbers
  corrected; the model's spread over uncertain inputs in nine cases
  ([ensembles](validation.md#the-models-spread-from-uncertain-inputs)); the reference curves' own
  scatter ([data survey 3g](data-survey.md#3g-the-reference-curves-own-scatter)); each result's
  [standing and error bands](standing.md), direction first.
  A [mesh-refinement study](validation.md#convergence-on-todays-defaults) on one pinned commit:
  nothing converges with the measurement inside the change; failures flip with mesh and step.
  A strain-rate window of 100 µs, the default since 12 October 2026, removes the step dependence,
  not the mesh dependence of failure ([what moved](validation.md#convergence-on-todays-defaults)).
- **Now:** blind test 1, Hrynyk's slabs struck by a falling weight, predicted on frozen defaults
  ([blind tests](blind-tests.md#test-1-hrynyks-slabs-struck-by-a-falling-weight)).
- **Done:** blind test 2, slabs under an open-air charge (Mendonça et al.), frozen at `047cee3`,
  scored *worse* ([validation](validation.md#blind-test-2-mendonças-slabs-under-an-open-air-charge));
  test 3, Reynolds's high-strength slabs in the contest's blast load simulator, frozen at the
  released v0.3.0 (`b524a9d`), scored *worse* on one broken slab, the rest within the band
  ([validation](validation.md#blind-test-3-reynoldss-high-strength-slabs-in-the-blast-load-simulator)).
- **Blocked on the user:** the sources marked *needs the user to obtain* in
  [data wanted](data-wanted.md), chiefly ACI SP-306 for the high-strength slabs, Saatci's
  records, Kasun-III's mapped debris for fragment sizes, shear across cracks at high rates, a
  footing under fast loading, and the DTIC and paywalled references behind Kingery–Bulmash and
  UFC 3-340-02's scatter.

### Concrete

Strategy and decisions: [concrete strategy](concrete-strategy.md).

- **Done:** options no case supports retired; defaults chosen by regime
  ([selecting by regime](concrete-strategy.md#selecting-by-regime-instead-of-waiting-for-agreement));
  stage 0's case matrix; stage 1, discrete bars, and stage 2's first step, nonlocal cracking, both
  options ([staged plan](concrete-strategy.md#4-a-staged-plan)); hourglass control traced
  ([validation](validation.md#hourglass-control)); stage 3, failed concrete kept as rubble
  particles, an option for debris: speeds nearer the tests', no holes
  ([rubble](validation.md#rubble-kept-as-particles-stage-3)).
- **Stopped, for data:** Peterson's short beams under impact
  ([Peterson](validation.md#short-beams-struck-to-a-shear-failure)). Bars that slip by the Model
  Code's splitting law (`--bond splitting`) take away the false split along the bars and give
  the tests' crack angles, but then the beams without stirrups hold and those with stirrups at
  45 mm fail; compression softening of cracked concrete (the modified compression field theory's),
  crushing zones, less crushing energy, spalling and no confinement each fail nothing more, or
  the wrong beams. Rerun on 18 October's defaults, the forces and failures stand. The struts crush
  on their face, as the tests' spalled, but the beams never ask more of them, and the images
  cannot say whether the spalling caused the failure; strut tests that can are in
  [data wanted](data-wanted.md). Stage 2's embedded cracks were tried three times (14–15 October)
  and not adopted: they soften slabs that do not fail.
- **In reserve:** stage 4, a peridynamic zone, only if stage 3 cannot hole the right slabs.
- **Deferred:** embedded strong discontinuities (E-FEM) until the data decides between them and
  the alternatives ([alternatives](concrete-strategy.md#3-alternatives-for-the-failure-zones-only)).
- **Blocked:** the tensile strain-rate law at 1 to 10 per second needs tests that separate the
  material from the specimen's inertia; fragment sizes need Kasun-III's debris.

### Air

- **Done:** afterburning, hot air and dissociation; refinement in one or two levels; gravity and
  sub-grid mixing as options ([air-blast model](air-blast-model.md)); radiative cooling, the default
  since 19 October 2026 ([thermal radiation](thermal-radiation.md#against-clough-and-clubleys-41-kg-fireball));
  terrain on cut cells ([terrain](terrain.md#cut-cells)); bursts checked to 40 m/kg^(1/3) ([large scenes](large-scenes.md));
  the mapped one-dimensional start, the default since 18 October 2026, for each charge
  ([a finely resolved start](air-blast-model.md#a-finely-resolved-start)).
- **Next:** rerun the comparisons still on the balloon start
  ([list](validation.md#still-on-the-balloon-start)); reflected peaks near walls; the products
  as a second gas only for contact charges (their own equation of state in the mapped start was
  tried and moves open-air loads too little, [record](validation.md#the-products-own-equation-of-state-18-october)). Weak shocks to 40 m/kg^(1/3) need no new criterion: threshold 0.005 follows them
  at about the least it can cost, and 8 m cells refined twice give 84–94% of Kingery–Bulmash's
  peaks out to there ([large scenes](large-scenes.md#following-weak-shocks-further-tried-and-not-needed-to-40-mkg13)).
- **Deferred:** cut cells for moving solids.

### Structures and supports

- **Done:** shells and beams with solids in one body; several materials, masonry as units and
  joints, steel and glass; up to sixteen bodies meeting by contact
  ([multiple-object scene](multiple-object-scene.md#implemented-contact-between-bodies)); base
  connections, joints at any angle and between parts, and footings on soil checked against FoRCy
  and FoRDy ([supports, as they were built](structural-model.md#supports-and-connections-as-they-were-built)).
- **Traced to an end:** the rebound after a slab's peak, set by the mid-span hinge turning back
  about its bars once its crushed compression zone unloads; residual crack opening, the bars'
  hysteresis, hourglass control, tension stiffening and a crushing band ruled out; whether the
  specimen's hinge differed or its rig held the rebound back the record cannot say
  ([concrete model](concrete-model.md#how-the-model-got-here), step 16).
- **Done:** precast seats on neoprene pads, friction falling with pressure, within 0.91–1.09 of
  the measured energy ([measured seats](structural-model.md#base-connections)).
- **Stopped, for data:** dowelled seats, a pinched, degrading hysteresis three tests cannot fix
  (same section); CLT panels' screwed angle connections, measured only through the panels
  ([data wanted](data-wanted.md#to-fetch)).
- **Done, closed forms only:** footings on a slope, level and stepped, their sides and bearing
  capacity read from the terrain (Vesić's factor, 0.88-1.39 of Meyerhof's charts); structures
  held at the terrain's height and landing on it; a frame on a hillside
  ([validation](validation.md#footings-on-a-slope)). No measured footing near a slope under fast
  loading was found.
- **Next:** a shaken footing's lurch, and the rest of its
  energy (sand crushed across the whole contact, the shaken sand's own); the cap on cut slivers
  under structures on refined levels.
- **Done, approximation:** [profiled steel sheeting](profiled-sheeting.md) as a skin with its ribs
  as beams, its thin flanges buckling, screwed to its purlins by screws that pull through; Langdon's
  connections as spring supports. Against Langdon's corrugated panels 10 of 13 permanent sets are
  within half to twice of measured; against ADBLAST's screwed cladding in air the first deflection
  is 0.90–1.35 of measured. As an envelope construction, by UFC's method for cold-formed panels on
  its effective section, an approximation: on the strip of ribs across the span that it is judged
  on, the same ADBLAST tests read 0.65–1.09 of measured.
- **Done:** every envelope component judged on its equivalent uniform load, its faces weighted by
  its plastic mechanism's shape ([equivalent uniform
  loads](building-envelopes.md#envelope-components-and-their-pressure-histories)).
- **Next, for sheeting:**
  - what is left after the blast (buckled shapes snapping through);
  - buckling earlier than plate theory says;
  - cladding torn off a purlin that deforms, which ADBLAST's deliverables would judge
    ([data survey 3i](data-survey.md#3i-profiled-cladding-on-its-fixings)).
- **Planned, new materials** ([new materials](new-materials.md)): timber, solid and engineered
  (glulam, CLT, plywood), orthotropic with failure along and across the grain, rate effects and
  connections, its elastic part adopted from ContinuumKit's `OrthotropicPlaneStress`.
- **Blocked:** a footing or connection under fast loading ([data survey 3b](data-survey.md#3b-a-footing-or-connection-under-fast-loading)).

### Freestanding objects and supports

Supports are under [structures and supports](#structures-and-supports) above.

- **Done:** one box, one box in the air, one simplified car, and several objects in populated
  scenes ([staged plan](freestanding-objects.md#the-staged-plan); the studies behind it in
  [rigid-box coupling studies](rigid-box-coupling-studies.md)).
- **Next:** a fractional shell boundary to converge the late flow; objects and a deformable
  structure in the air together ([limitations and future work](freestanding-objects.md#limitations-and-future-work)).
- **Blocked:** no blast test of a vehicle or furniture is known; the cars stay illustrative.

### Effects beside the blast

One way and separable ([distributed computing](distributed-computing.md#the-long-term-visions-effects)).

- **Done, an approximation:** [fragments](fragments.md) from a casing's dimensions, Mott's
  masses within 1.4 of Cooper's counted bomb, measured drag; their [hazard](fragments.md#hazard)
  distance by DDESB's criterion, debris's alike, and glazing graded by GSA and ASTM F1642; what they
  strike judged by UFC 3-340-02 and THOR, panes holed before the blast (17 October).
- **Done, an approximation:** [blast hazards](hazards.md): DoD's K-factor distances, the minimum
  safe distance and what governs it, and injury at standing height from the run's own peaks
  (Bowen, Bass, UFC's eardrums), checked against Teland's distances within 6% (17 October).
  Debris from failed envelope components thrown and judged beside the fragments, and DESR's
  structure debris distance for a charge inside a building (18 October): Keys's walls' mean reach
  as measured, the Kasun cubicle's hazardous reach under half
  ([hazards](hazards.md#debris-from-failed-envelope-components)).
- **Done, illustrative:** the fireball's
  [thermal radiation](thermal-radiation.md) and [surface heating](surface-heating.md); its
  [rise and cloud](fireball-rise.md); [ground shock](ground-shock.md), as the manuals'
  estimate or a layered soil column, or an elastic half-space
  about the charge, elastic or with soil that yields, against one measured 1 t burst 15 to 90
  times too high in the vertical near the outrunning limit, the half-space's horizontal within
  1.5 (elastic) to 2.4 (yielding) times at 21 m but 10 to 20 times at 42 m; the yielding stage
  recorded and the line stopped until Prairie Flat or Pre-Dice Throw II; [gas deflagrations](deflagration.md), started: FM Global's
  vented tests within 0.4–1.6 of the measured peaks, with sub-grid turbulence and the measured
  cellular instability.
- **Now:** why the deflagration's flame stalls when lit in the middle (0.4–0.6 there), a young
  flame's speed on coarse cells, and a thinner front, without which K_G cannot converge.
- **Paused:** the fireball's radiation, about 21% radiated against Dial Pack's 5.1%; if it
  resumes, flame sheets round a fuel-rich core and the missing hot shock layer.
- **Cratering, stage 1, done (approximation for the diameter):** [an empirical crater](cratering.md)
  by Cooper's scaling for each soil and height of burst, with Kinney and Graham's scatter; it
  forms after the blast, so it is reported, drawn and exported when the run ends and does not
  act on the air; on earth or rock a charge keeps 0.9 of its mass for the air, the ground taking
  the rest (a ground setting, tied to the debris's soft ground). Five of six measured craters
  within a third, the 500-ton shots at Suffield among them; with a water-table setting (walls
  slumped to 10–15°, Glasstone and Dolan), the wet sites' depths within 0.84–1.41.
- **Cratering, stage 2, next:** a crater coupled to the blast near the charge, with soil that
  flows, ejecta and the shock driven into the ground, for close-in work. It starts with a
  ContinuumKit and Edgerton check under the sharing rule: neither had a cratering or soil-flow
  model on 17 October 2026, but Edgerton's volume solver and cohesive cracks overlap.
- **Next:** the cloud's top after two minutes; ground motion measured where the blast is
  superseismic (Prairie Flat, Pre-Dice Throw II), and the motion ahead of an outrunning blast.
- **Blocked:** measurements wanted in [data wanted](data-wanted.md) 3a (ground shock), 3d (a
  cloud's growth), 3e (fireball radiation) and 3f (a vented deflagration).

### Scale and import

- **Done:** [large scenes](large-scenes.md) of hundreds of tonnes to kilotonnes; exposure-only
  [building envelopes](building-envelopes.md) to 64 buildings, from IFC and mesh imports and
  OpenStreetMap footprints; a cost-against-fidelity advisor reading the error bands
  ([choosing settings](performance.md#choosing-settings)), its costs re-timed on an unloaded Mac
  at kilometre scale.
- **Next:** a cheaper damage model for envelope buildings. Its single-degree-of-freedom form is
  built and judged against the detailed buildings, with the cost of not venting
  ([one-way damage](building-envelopes.md#one-way-damage-single-degree-of-freedom)), and since
  16 October in the app (glass and concrete as approximations, brick and the inside illustrative).
- **Now:** two sample buildings being built, a precast large-panel block and a process-plant
  control room.
- **Planned, building types** (what each needs is in [new materials](new-materials.md#what-each-building-type-needs)):
  - UK terraced brick houses: built ([the terraced houses](shell-model.md#the-terraced-houses)):
    cavity walls tied across, timber joists seated in pockets, roof tiles thrown as debris.
    Judged against wartime bomb damage
    ([validation](validation.md#terraced-houses-against-wartime-bomb-damage)): right a tenth of
    a second in, but cracked front walls then go over that surveyed houses kept standing. SBEDS's
    rocking resistance would not hold them either (10–60 J/m² against about 600); stopped until
    tests of brick walls blasted past cracking ([data wanted](data-wanted.md)) can say what does.
  - Steel portal-frame warehouses with profiled metal cladding: a sample is built
    ([warehouse](profiled-sheeting.md#the-portal-frame-warehouse-sample)), its sheets screwed to
    its Zed purlins and rails and torn off as their screws pull through; the purlins at their
    maker's capacity, what follows its peak not modelled.
  - Transport hubs with long-span steel and glass roofs: a sample is built
    ([transport hub](transport-hub.md)). Its parts:
    - [laminated glass](building-envelopes.md#laminated-glass) on envelopes, compared with three
      open sets of tests;
    - [glass falling from overhead](building-envelopes.md#glass-falling-from-overhead);
    - [buckling](shell-model.md#buckling) checked against Euler and Lindberg, and steel members
      bowed by default to Eurocode 3's curves (within 3%).
    - [laminated glass in the structure model](shell-model.md#laminated-glass), its roof laminated
      as an option, judged on Osnes's and Hooper's panes.
    It still needs a dynamic buckling test (Kenny's thesis, in [data wanted](data-wanted.md)).

### Distributed computing

- **Done:** sweeps and ensembles shared across Macs by measured speed; the effects beside the
  blast placed on other Macs by cost
  ([several consumers](distributed-computing.md#several-consumers-on-several-machines)); Macs
  nearby as workers without SSH, paired once and over TLS
  ([Macs nearby](distributed-computing.md#macs-nearby-without-ssh)). The single-GPU gains put
  first are in: refined patches taking their own steps (`refinementOwnSteps`) and contact's exact
  pair skip ([better first](distributed-computing.md#better-first)).
- **Next:** the mini's slow sending to a Mac nearby over Wi-Fi, measured again in a quiet window,
  and a session's bulk carried on a plain socket if it holds; the Studio as the sharing Mac, for
  the thin client ([Macs nearby](distributed-computing.md#macs-nearby-without-ssh)).

### Usability, in parallel

- **Done:** each result's [standing and error bands](standing.md); export for rendering as USD
  and OpenVDB, from the command line and the app ([USD export](usd-export.md)); saved runs and
  comparison ([run comparison](run-comparison.md)); an offscreen review of the panels in both
  appearances ([review log](native-interface-review.md#review-log)), and of every sidebar section and
  editor at the sidebar's width, with six layout fixes; release 0.2.0.
- **Done, 18 October:** the real-screen review's labels and keyboard paths
  ([on the real screen](native-interface-review.md#on-the-real-screen-labels-and-keyboard)); materials
  that look like what they are in the viewport and snapshots (concrete, steel, sheeting, glass,
  timber, brick, blockwork, earth), the damage colouring and rubble apart from each to every common
  colour deficiency (`MaterialAppearance`).
- **Next:** the fixes seen on a real screen, Full Keyboard Access and VoiceOver's speech
  ([remaining checks](native-interface-review.md#remaining-checks)); exposure-only buildings drawn by
  their construction.

## Horizons

Longer aims, set on 18 October 2026. The binding limit is how long a run takes on one Mac, so
most are about reaching an answer for less, with the full solver kept as the referee. In order:

1. **Refinement steered by the decision** (started). Refine where the answer the user asked
   for is uncertain: a component near its damage threshold, an injury contour near a boundary,
   a pane near breaking. Today refinement follows pressure gradients everywhere. The first step
   is an error estimate on the advisor's target quantity driving the existing refinement flags,
   judged on whether refined districts then beat uniform cells by a clear factor at equal
   answers.
2. **Answers in seconds.** Surrogates trained on BombCAD's own runs (reduced-order loads by
   geometry and charge, or a small learned model of envelope response), giving an instant first
   look that real runs then refine where it matters, and inheriting the standing's error bands.
   The first step is a surrogate for envelope damage across a district, checked against Beirut's
   runs.
3. **City scale in minutes.** Gas dynamics only near the charge and in the streets that matter,
   and further out the blast carried by ray-traced shielding and channelling (the thermal model
   already uses Metal ray tracing) with scaled blast laws, handed over at a boundary. The first
   step is a ray-traced far field set against Beirut's full run beyond 1 km.
4. **Uncertainty by default.** Results as probabilities ("this façade fails with 70% chance")
   from the scatter in yield, materials and rounding, cheap once item 2 exists.
5. **From damage back to the explosion** (first step done). Infer yield, place and height from
   observed arrival times, broken glass and damage, as the Beirut page did by hand for its yield.
   `scenebench infer-charge` ([charge inference](charge-inference.md)) now samples the yield and
   place from arrivals, finding Beirut's 0.5 kt and Warehouse 12 from Rigby's observers; height
   and clock offset are not resolved by them, and GEER's glass biases the yield (the glass model
   breaks more than the survey saw). Next: damage that calibrates (the structural survey, or glass
   once the envelope model matches GEER), and BombCAD's own runs as the forward model in the loop.
6. **Protective design.** The least set of glazing, wall and stand-off changes that meets a
   hazard target, which needs item 2's speed.

Under all of them is raw speed: everything kept on the GPU (no CPU remaps), compact storage for
coarse levels, smarter steps, and work spread across Macs
([distributed computing](distributed-computing.md)).

## Things tried and set aside

- **Fixes for the wrong cause.** A fine mesh of the validation slab collapsed, and nonlocal
  crushing, a stronger hourglass cap, a frozen compressive rate factor and wider crushing
  bands were each tried before tracing one element through the collapse found the two real
  errors (Poisson swelling counted as cracking; a missing normalisation in the compressive
  rate law). Nonlocal crushing and a reduced form of the hourglass cap were kept, the first
  switched off by default (and retired in 2026); the rest were removed. The lesson: trace a failing element before
  changing the model.

- **Options retired on 11 October 2026**, after the [case matrix](concrete-strategy.md) found no
  case each served and removing them changed no default result (`blastbench digest` and the
  matrix bit-identical). A model saved with one reads with today's behaviour and a note of what
  was dropped (`StructureModel.retiredOptions`):
  - cracks on the lattice planes and cracks fixed at first cracking (`crackAxes`), which the
    turning cracks superseded; the lattice planes mishandle inclined cracks;
  - keeping a crack's slide out of its opening (`slipWidensCracks`, `--slide-apart`; below);
  - a crack's shear stiffness falling with its width (`crackShearStiffness`, `--crack-shear`),
    which moved no case;
  - nonlocal crushing and a shortest crushing band (`crushLength`, `crushBand`), under 1% on the
    slab;
  - bars taking the strain rate of the element they run through (`barRateAlongBars`,
    `--element-bar-rate`), which ran the fine slab's hinge away;
  - Malvar and Ross's tensile strain-rate law and Malvar and Crawford's for bars
    (`tensionRateLaw`, `steelRateLaw`, `--tension-law`, `--steel-law`): a quarter too stiff on
    Saatci's beams, the spall needing 17–21 MPa, and bars a fifth too strong at these rates;
  - bars spread through the concrete about them (`impact --spread`): mesh-independent, but
    beams too stiff.
- **Keeping a crack's slide out of its opening** (`--slide-apart`): right for one crack, which
  read a 1 mm crack slid 2 mm as 1.9 mm open, but on its own it stiffens every beam that
  depends on sliding cracks, Ando's without stirrups far too much. Kept as an option.
- **Interlock that grows with the pressure across a crack, by default** (Walraven and Reinhardt's
  relations; `--pressed-interlock`): it brings the push-off tests within 0.57–1.03 of the
  measured shear, but breaks Saatci's and Ando's beams under blows they survived and makes OA1
  126–188% strong. Kept as an option. The pressure on the cap alone, without the crack's own
  sliding pressing it, changed neither OA1 nor the push-off paths and stiffened Saatci's heavy
  drops by a tenth; it was not kept.
- **Softening the concrete between cracks sooner, with bars that slip**: a crack inclined to the
  lattice given a band as wide as the staircase of elements it crosses (Oliver), or neighbouring
  cracked elements taken as one crack. The first barely moved the slab or OA1; the second
  brought the slab to 101% but left OA1 40% strong and the tie with the Model Code's tension
  stiffening and crack spacing lost.
- **Bars that slip, by default**: mesh-independent on the slab, OA1 and Saatci's beams, and
  right where perfect bond splits a beam along its bars, but too stiff nearly everywhere else
  (the slab 89%, OA1 150%, heavy drops 8–14% short, Ando's beams a quarter short). Kept as an
  option.
- **Removing concrete cracked open every way, as rubble**, to let a close-in charge hole the
  slab, as the test authors' own model eroded fully damaged elements: it took the lower half of
  the slab over a circle 1.8 m across within 12 ms, made no hole and did not move the slab.
- **Rubble as particles, by default under close-in and contact charges** (stage 3): alone it
  holes less than removal did; with fragments removed it holes Hupfauf's slabs that held too, and
  Wu's S4 at 38, 38 or 14 cm as the threshold moves from 0.5 to 1 mm. Kept as an option, for debris.
- **A crushing zone of its own length, and cracked concrete weaker in compression**, for
  Peterson's struts (12 October): neither moves the six kinds of beam towards their failures; a
  strut must shorten about 2.5 mm to crush and these shorten about 0.3 mm.
- **Closing the space under the close-in slab**, to keep the wave from wrapping under it: the
  trapped air cushions the slab (126 mm peak against 161, and it springs back), so it says
  nothing about the open test.
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
