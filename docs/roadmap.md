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
chosen with these tests in view; of three tests since run blind, two erred on the unsafe side, a
slab never punching and two slabs under a blast collapsing that the model left standing (see the
[independent review](validation-review.md)). It is not validated for engineering decisions, and
nothing in it should be used to judge the safety of a real structure.

## Limitations, most important first

| # | Limitation                                                              | Consequence                                                   | Detail |
|---|-------------------------------------------------------------------------|---------------------------------------------------------------|--------|
| 1 | The structural model has been compared with eleven member tests, and springs back too far | Mostly on the unsafe side, predicting too little damage: shear 11–15% too strong (37% on coarse meshes), the chamber's roof and close-in slabs too stiff (a quarter and a third to a half as far), small charges' slabs 40–70%, struck beams' struts holding where the tests crushed, six elements through 17% strong in bending, bars that slip too stiff nearly everywhere. In detail: on a slab test the peak rises to 124 mm on 32 elements against 109 measured (113 in its repeat), not converged (a strip of it runs away on 32), and under the contest's lower shot reaches about 80% of the peak; a beam bent to failure carries 98–101% of its measured moment; a beam failing in shear carries 111–115% of its measured load on fine meshes, 137% on coarse; beams struck by a falling weight with stirrups peak within 12–24% under light drops and −5% to +3% under heavy ones on 16 elements, and Ando's beams without stirrups peak within 15% on average on 16 elements (53% too far on 24), and A36 breaks at the speed its test did where B36 holds, while Saatci's without stirrups is damaged, and on fine meshes split, by a drop it survived; Peterson's short beams struck to a shear failure (2026) give the forces at a shear span of one depth, the deep ones too stiff, and fail without stirrups, but by splitting along their bars, while those with stirrups that crushed their strut in the test hold; full-scale slabs under close-in charges are left a third to a half as far down as measured, barely spalled and not holed; 2 m slabs with steel in one face or both bend within −20% to +7% under 1.6 kg at 0.5 m but 40–70% as far under smaller charges, and are holed by contact charges at a stable step to a half and a third of the measured size; in a full-scale internal explosion, with the chamber's detailing modelled, the roof's edge peaks at 49 mm against 87 mm in the test paper's own model and is left 25 mm up against 95 mm measured, with cracks that press as they slide, now the confined regime's default (38 and 15 mm without); on the finest mesh the answer has not converged. Bars that slip converge on every mesh but are too stiff nearly everywhere; hourglass control does 7–18% of the work at the slabs' peaks, where an element's own bending would be under 2%, and the struck beams' agreement leans on it (an element that bends in its cracked concrete without it sends Saatci's heavy drop 20% further), so their standing is low | [Validation](validation.md#an-internal-explosion-in-a-reinforced-concrete-chamber) |
| 2 | Shear failure and joints are the least reliable predictions             | The unsafe side where they err, shear too strong: breach, punching, direct shear and wall–slab joints are indicative only | [Concrete model](concrete-model.md#limitations) |
| 3 | Afterburning's burning time is fitted, and its fireball never cools       | Afterburning and hot air are the default since 15 October 2026 (1.3–2 times slower; off still selectable): incident and suction impulses within a few per cent, rooms within 8%, but the burning time was fitted to the open blast's impulse, and the gas, which since 19 October 2026 loses the heat it radiates, still radiates more than a TNT fireball's 4–7%; turned off, incident impulse is 13–22% low and rooms' gas 48–114% of the design value | [Air-blast model](air-blast-model.md#afterburning) |
| 4 | Peak pressure is under-resolved near the charge                         | Incident peaks close in come within a sixth of Kingery–Bulmash from 1 m/kg^(1/3) for 10–100 kg since the mapped start (18 October 2026; 63–99% for 1 kg), where the balloon left 32–84% (11–47%); reflected peaks near walls still read low, the unsafe side, and need fine or twice-refined air; spall needs cells of 0.005 W^(1/3) and 12 elements through a slab; the comparisons have moved to the mapped start, the long ones on 20 October 2026 with every band kept, but for a few harnesses still on the balloon ([list](validation.md#still-on-the-balloon-start)) | [Validation](validation.md#what-stops-the-spall-and-the-breach) |
| 5 | Collapse compared once, blind, and missed (two of Mendonça's slabs under an open-air charge); debris twice, off slabs under contact charges and brick walls under blasts | Debris held back rather than thrown, the unsafe side for a hazard (as rubble particles, an option, thrown at nearer the measured speed); brick walls crack at the measured heights but fall as one column, shattering on a rigid ground in the open (soft ground, an option, halves that) and thrown half as far as measured in a shock tube; collapse looks plausible, that is all | [Validation](validation.md#slabs-under-contact-charges), [brick walls](validation.md#brick-walls-debris) |
| 6 | Moving solids are a staircase of whole cells                            | Either way, to a cell: wall positions are good to a cell; small fragments are crude. Cut-cell outlines for structures before failure (an option, unrefined air) take the offset out of a wall's impulse but not its peak. A car beside a deformable structure, or on a slope, has its underbody gap taken up to a cell narrower or wider, which can turn whether it overturns (warned, with finer cells offered where they fit) | [Structural model](structural-model.md#coupling-to-the-air) |
| 7 | Up to sixteen bodies of up to eight materials each, bonded within and meeting each other only by contact, lattice-aligned geometry but for planes at one pitch (roof slopes); debris pushed crudely by the air | Real buildings only roughly (IFC buildings import as shells and beams where square to the axes, roof slabs at one pitch if asked, their materials, ties and supports inferred and listed); thrown debris and contact between buildings are approximate | [Structural model](structural-model.md#limitations) |
| 8 | The rebound after a slab's peak is too large; concrete broken under a close-in charge is never removed by default | Too stiff close in, the unsafe side: no hole under a close-in charge, and rebound too large (strength with pressure, and cracks pressed shut, checked: not the cause); removing fragments, an option, holes slabs both ways; rubble kept as particles, an option, holes none | [Validation](validation.md#holes-under-close-in-and-contact-charges) |
| 9 | Supports and freestanding objects are checked against statics and theory, and footings against nine centrifuge events on one sand (FoRCy, FoRDy) | Either way for a footing's rocking moment, settlement within a factor of 1.7, energy a sixth to two thirds of a shaken test's; footings on soil and connections that open and slide are in, as are boxes and cars that slide, lift and overturn; every object takes the air's load, but late flow is not converged and the cars and furniture are illustrative | [Freestanding objects and supports](#freestanding-objects-and-supports) |
| 10 | Only selected panels and document workflows have had visual review      | Other layouts and native interactions may still have problems | Below |

On the last point, see the [native interface review](native-interface-review.md#review-log).

## The plan

The aim is the best fidelity given the constraints of compute and available empirical data:
spend computation where the [error bands](standing.md#error-bands) say it buys accuracy, and seek
data where they say the model cannot be judged. Each stage ends with something a user gets, or
with a recorded stop. The plan as it stood item by item before 11 October 2026, with the account
of each step, is in the [roadmap history](roadmap-history.md). This page was last refreshed on
21 October 2026, after release 0.6.0 ([its notes](release-notes/0.6.0.md)).

### At a glance

**Now**
- **The learned field model** ([learned models](learned-models.md)): a network trained on 200 of
  BombCAD's own district runs gives the ground-floor peaks in the quick estimate, as an option, off
  ([`4543c5ce`](https://github.com/emmettl/bombcad/commit/4543c5ce)). Being extended to roofs and
  upper storeys, and its 4 m cells' bias measured. Whether it becomes the default *waits on the user*.
- **Dragging the charge** ([dragging the charge](surrogate-first-look.md#dragging-the-charge-20-october-2026)):
  the damage follows the charge in about half a second a frame on Beirut, and the close calls are
  then run in the air within a budget
  ([`94be0a6c`](https://github.com/emmettl/bombcad/commit/94be0a6c)). Its refined runs were checked
  against finer air ([`3afdd0c9`](https://github.com/emmettl/bombcad/commit/3afdd0c9)).
- **People in the scene:** injuries by building from the glass, walls and roofs, for injury and
  evacuation planning. Just started.
- **CUDA training data, gated:** the PC's CUDA worker misses a few first-phase and peak targets
  on terrain and Beirut; bulk generation waits until the labels are reproducible and the tiled and
  full-grid peaks agree ([below](#distributed-computing)).

**Next**
- **The façade surrogate close in among buildings:** 1.3–2.1 times high within 350 m, most of it
  behind buildings, traced to the close-in branch dropping shielding
  ([`f5412c09`](https://github.com/emmettl/bombcad/commit/f5412c09)). A refit is to be proposed;
  adopting it is *the user's decision*.
- **Full Keyboard Access and VoiceOver on a real screen.** *Waits on the user* for a screen session.

**Later**
- The fireball's radiation (*the user chooses the route*, or leaves it paused), cratering coupled to
  the blast, cladding torn off a purlin that deforms (stopped for the test rig's dimensions), soil
  with a fast elastic front, the ground-shock half-space in three dimensions, and the mini's slow
  sending over Wi-Fi.
- Sources to obtain for validation: *the user obtains them* ([data wanted](data-wanted.md)).

**Big bets**, apart, each with a cheap first step: [below](#big-bets).

### Validation

More evidence is worth more than more features.

- **Done:** eleven member tests and the air's references compared ([validation](validation.md#summary));
  an [independent review](validation-review.md) of the record; the model's spread over uncertain
  inputs ([ensembles](validation.md#the-models-spread-from-uncertain-inputs)); the reference curves'
  own scatter ([data survey 3g](data-survey.md#3g-the-reference-curves-own-scatter)); each result's
  [standing and error bands](standing.md), direction first; a
  [mesh-refinement study](validation.md#convergence-on-todays-defaults): nothing converges with the
  measurement inside the change, and failures flip with mesh and step.
- **Done:** blind test 1, Hrynyk's slabs struck by a falling weight, scored *between*; tests 2 and
  3, Mendonça's slabs under an open-air charge and Reynolds's high-strength slabs, scored *worse*
  ([validation](validation.md#blind-test-1-hrynyks-slabs-struck-by-a-falling-weight)).
- **Done:** collapse a result of its own, illustrative until a compared collapse of that
  structural system agrees ([standing](standing.md#collapse)).
- **Done, 20 October:** the long comparisons off the balloon start: Beirut and the districts,
  terrain, the landscape, ground motion, Dial Pack and the panel block, every band kept
  ([record](validation.md#off-the-balloon-on-20-october)).
- **Waits on the user:** the sources marked *needs the user to obtain* in
  [data wanted](data-wanted.md), chiefly ACI SP-306 for the high-strength slabs, Saatci's
  records, Kasun-III's mapped debris, shear across cracks at high rates, a footing under fast
  loading, and the references behind Kingery–Bulmash's and UFC 3-340-02's scatter.

### Concrete

Strategy and decisions: [concrete strategy](concrete-strategy.md).

- **Done:** options no case supports retired; defaults chosen by regime
  ([selecting by regime](concrete-strategy.md#selecting-by-regime-instead-of-waiting-for-agreement));
  stages 0–3 of the [staged plan](concrete-strategy.md#4-a-staged-plan), the last (failed concrete
  as rubble particles) an option for debris ([rubble](validation.md#rubble-kept-as-particles-stage-3));
  hourglass control traced ([validation](validation.md#hourglass-control)).
- **Stopped, 20 October:** an element that bends in its cracked concrete without hourglass control
  (`assumedStrainCracking`, an option, off). It is sound in dynamics, but struck beams go 20%
  further than their tests and a slab loses three to four times the elements. What it showed lowered the
  struck beams' standing to low ([`19ae1630`](https://github.com/emmettl/bombcad/commit/19ae1630)).
  The next attack on limitation 1 is cracked concrete's stiffness and shear, not the element; it is
  not yet taken up.
- **Stopped, for data:** Peterson's short beams under impact
  ([Peterson](validation.md#short-beams-struck-to-a-shear-failure)): the crack angles are right, the
  failures wrong, and strut tests that could say why are in [data wanted](data-wanted.md).
- **In reserve:** stage 4, a peridynamic zone, only if stage 3 cannot hole the right slabs.
- **Deferred:** embedded strong discontinuities (E-FEM), tried three times and not adopted
  ([alternatives](concrete-strategy.md#3-alternatives-for-the-failure-zones-only)).
- **Blocked:** the tensile strain-rate law at 1 to 10 per second needs tests that separate the
  material from the specimen's inertia; fragment sizes need Kasun-III's debris.

### Air

- **Done:** afterburning, hot air and dissociation; refinement in one or two levels; gravity and
  sub-grid mixing as options ([air-blast model](air-blast-model.md)); radiative cooling
  ([thermal radiation](thermal-radiation.md#against-clough-and-clubleys-41-kg-fireball)); terrain
  on cut cells ([terrain](terrain.md#cut-cells)); bursts checked to 40 m/kg^(1/3)
  ([large scenes](large-scenes.md)); the mapped one-dimensional start for each charge, under the
  comparisons since 20 October ([a finely resolved start](air-blast-model.md#a-finely-resolved-start)).
- **Done, 20–21 October:** refinement's fixed cost among many blocks cut (a corridor's GPU time
  2.71 to 2.02 s, [`3c57b09b`](https://github.com/emmettl/bombcad/commit/3c57b09b)); walls at
  400–600 m of 0.5 kt against finer air: 4 m cells read their peaks 13–19% low, 2 m corridors
  are converged against 1 m
  ([walls against finer air](surrogate-first-look.md#walls-at-400600-m-against-finer-air-21-october-2026)).
- **Next:** reflected peaks near walls; the products as a second gas only for contact charges
  (their own equation of state in the mapped start moved open-air loads too little,
  [record](validation.md#the-products-own-equation-of-state-18-october)).
- **Deferred:** cut cells for moving solids.

### Structures and supports

- **Done:** shells and beams with solids in one body; several materials, masonry as units and
  joints, steel, glass and timber; up to sixteen bodies meeting by contact
  ([multiple-object scene](multiple-object-scene.md#implemented-contact-between-bodies)); base
  connections, steel connections, joints at any angle, precast seats, and footings on soil and on
  a slope ([supports](structural-model.md#supports-and-connections-as-they-were-built),
  [footings on a slope](validation.md#footings-on-a-slope)); the cap on cut slivers under
  structures on refined levels ([terrain](terrain.md#cut-cells)).
- **Done, approximation:** [profiled steel sheeting](profiled-sheeting.md), its flanges buckling
  and keeping their folds, screwed by screws that pull through; every envelope component judged on
  its [equivalent uniform load](building-envelopes.md#envelope-components-and-their-pressure-histories);
  unreinforced masonry arching between returns, an option, off
  ([arching](building-envelopes.md#arching-between-returns)).
- **Traced to an end:** the rebound after a slab's peak, set by the mid-span hinge turning back
  about its bars ([concrete model](concrete-model.md#how-the-model-got-here), step 16).
- **Stopped, for data:** dowelled seats and CLT's screwed angle connections; a shaken footing's
  lurch and the rest of its energy, which want the sand as a continuum
  ([validation](validation.md#a-footing-shaken-on-dry-sand)); cladding torn off a purlin that
  deforms, its ADBLAST reference prepared
  ([`5b4b4fc8`](https://github.com/emmettl/bombcad/commit/5b4b4fc8)) but the blast rig's layout
  and support spacing not given.
- **Next, for sheeting** ([what is left](profiled-sheeting.md#what-is-left-scoped)): buckled shapes
  snapping through after the blast; buckling earlier than plate theory says.
- **Blocked:** a footing or connection under fast loading ([data survey 3b](data-survey.md#3b-a-footing-or-connection-under-fast-loading)).

### Freestanding objects and supports

Supports are under [structures and supports](#structures-and-supports) above.

- **Done:** boxes, a simplified car and populated scenes
  ([staged plan](freestanding-objects.md#the-staged-plan)); objects and a deformable structure in
  the air together, striking it at its own step. A car beside a structure whose underbody gap the
  cells take up is warned of, with finer cells offered.
- **Deferred:** a fractional shell boundary to converge the late flow, and the objects' finer
  patches beside a structure ([limitations and future work](freestanding-objects.md#limitations-and-future-work)).
- **Blocked:** no blast test of a vehicle or furniture is known; the cars stay illustrative.

### Effects beside the blast

One way and separable ([distributed computing](distributed-computing.md#the-long-term-visions-effects)).

- **Done, an approximation:** [fragments](fragments.md) and their [hazard](fragments.md#hazard);
  [blast hazards](hazards.md), K-factor distances and injury from the run's own peaks, and debris
  from failed envelope components ([hazards](hazards.md#debris-from-failed-envelope-components));
  [an empirical crater](cratering.md) by Cooper's scaling, five of six measured craters within a
  third.
- **Done, illustrative:** the fireball's [thermal radiation](thermal-radiation.md) and
  [surface heating](surface-heating.md); [ground shock](ground-shock.md) as the manuals' estimate,
  a layered soil column or an elastic half-space; [gas deflagrations](deflagration.md), FM Global's
  vented tests within 0.4–1.6.
- **Done, 20 October:** the cloud's top in Church's measured air stays with his tops to five
  minutes, 0.88–0.98 of them from three minutes on
  ([fireball rise](fireball-rise.md#in-churchs-own-air-20-october-2026)); ground points labelled
  where the ground's wave outruns the blast, which finds Prairie Flat's outrunning limit, and the
  half-space carries the motion ahead of it within a factor of two
  ([Prairie Flat](ground-shock.md#against-prairie-flat)).
- **Stopped, 20 October:** the deflagration's flame stalling when lit in the middle (0.4–0.6 of the
  tests), traced to the vent drawing unburnt gas from the back front faster than it burns
  ([the stall](deflagration.md#the-centre-lit-stall-traced-20-october-2026)); nothing adopted.
- **Paused, the user's choice:** the fireball's radiation, about 21% radiated against Dial Pack's
  5.1%. Mixing-limited afterburning was tried and stopped
  ([an option](thermal-radiation.md#mixing-limited-afterburning-20-october-2026)); what remains is a
  turbulence measure that holds at the fireball's edge, or flame sheets per cell.
- **Later:** a crater coupled to the blast near the charge, for close-in work, if an open
  measurement can judge it; soil with a fast elastic front ahead of its crushing, to give Prairie
  Flat's arrivals and peaks together; the half-space in three dimensions on the GPU.
- **Blocked:** measurements wanted in [data wanted](data-wanted.md) 3a (ground shock), 3d (a
  cloud's growth), 3e (fireball radiation) and 3f (a vented deflagration).

### Scale and import

- **Done:** [large scenes](large-scenes.md) of hundreds of tonnes to kilotonnes; exposure-only
  [building envelopes](building-envelopes.md) from IFC, mesh and floor-plan imports and
  OpenStreetMap footprints, with a [one-way damage model](building-envelopes.md#one-way-damage-single-degree-of-freedom);
  a cost-against-fidelity advisor ([choosing settings](performance.md#choosing-settings)); the
  [large-panel flats](large-panel-flats.md) and the [process plant](process-plant-explosion.md).
- **Built, building types** ([what each needs](new-materials.md#what-each-building-type-needs)):
  - UK terraced houses ([the terraced houses](shell-model.md#the-terraced-houses)). Since
    21 October the sample is the pre-1919 solid one-brick row, within a category of the wartime
    surveys at every distance by 0.3 s, its fronts standing by arching
    ([validation](validation.md#solid-one-brick-walls-20-october-2026)); the 1930s cavity row, a
    second sample, still grades one or two categories too severe beyond 11 m.
  - Steel portal-frame warehouses with profiled cladding
    ([warehouse](profiled-sheeting.md#the-portal-frame-warehouse-sample)).
  - Transport hubs with long-span steel and glass roofs ([transport hub](transport-hub.md)),
    laminated glass and buckling checked; a dynamic buckling test is still wanted.

### Distributed computing

- **Done:** sweeps and ensembles shared across Macs by measured speed; the effects beside the
  blast placed on other Macs by cost
  ([several consumers](distributed-computing.md#several-consumers-on-several-machines)); Macs
  nearby as workers without SSH ([Macs nearby](distributed-computing.md#macs-nearby-without-ssh)).
- **Done, 20–21 October, Linux:** the CPU-only models in a module of their own that builds on Linux,
  `blastmodel` to run their studies there, CPU sweeps sent to a Linux PC, and a Linux lane in the
  pre-push check ([on Linux](linux.md),
  [`781c6204`](https://github.com/emmettl/bombcad/commit/781c6204)), its shared copy protected from
  concurrent senders ([`34c28008`](https://github.com/emmettl/bombcad/commit/34c28008)). The PCs
  also train the learned models ([learned models](learned-models.md)).
- **A portable compute backend (a big bet), Codex's CUDA work** ([CUDA backend](cuda-backend.md),
  [heterogeneous compute](heterogeneous-compute.md)):
  - **Done:** a CUDA worker, derived from the production kernels, that generates training targets
    for uniform and static-terrain air on the NVIDIA PC
    ([`0181b978`](https://github.com/emmettl/bombcad/commit/0181b978)), each case checked against
    its Metal reference before it is accepted
    ([`64df301c`](https://github.com/emmettl/bombcad/commit/64df301c)). A flat full-size case
    passes.
  - **Now, the gate:** terrain and Beirut miss a few targets. The first-phase misses trace to
    decisions near zero pressure ([`900a646b`](https://github.com/emmettl/bombcad/commit/900a646b)),
    and the peak differences to the compiler's floating-point contraction, which also separates
    Metal's own tiled and full-grid paths
    ([`68f1fafb`](https://github.com/emmettl/bombcad/commit/68f1fafb)). Through the damage model
    the differences changed no outcome on the cases judged so far. Bulk CUDA data waits for
    reproducible labels and agreeing peaks; no tolerance has been relaxed to admit it.
  - **Measured:** a queue that sends each field job to Metal or CUDA by cost took 12.5% less time
    on eight full-size replays of one case ([`55b4ed89`](https://github.com/emmettl/bombcad/commit/55b4ed89));
    the thermal model on the PC is deferred, since sending its inputs costs more than computing
    them on the Mac ([`e38b75cb`](https://github.com/emmettl/bombcad/commit/e38b75cb)); the
    worker's costs profiled and the PC's clock audited before timings are compared
    ([`25736353`](https://github.com/emmettl/bombcad/commit/25736353)).
  - **Not yet:** refinement, structures or the app on CUDA. The subset is air for training data,
    not a full backend.
- **Later:** the mini's slow sending to a Mac nearby over Wi-Fi, measured in a quiet window.

### Usability, in parallel

- **Done:** each result's [standing and error bands](standing.md); export as USD and OpenVDB
  ([USD export](usd-export.md)); saved runs and comparison ([run comparison](run-comparison.md));
  the offscreen and real-screen reviews' fixes
  ([review log](native-interface-review.md#review-log)); materials that look like what they are.
- **Done, in 0.6.0 and since:** replay a run and scrub through it, and continue from any saved
  state, the same to the bit ([replaying a run](using-the-app.md#replaying-a-run),
  [checkpoints](checkpoints.md)). Since 0.6.0 the replay keeps vents, envelope damage, the thermal
  paint and the cloud as they change, and recording costs the main thread under a millisecond a
  frame ([`48a8d354`](https://github.com/emmettl/bombcad/commit/48a8d354)). Settled structures are
  kept between runs, and a run's envelope judgement is 2.3 times faster
  ([`b8cd063c`](https://github.com/emmettl/bombcad/commit/b8cd063c)).
- **Next, waits on the user:** Full Keyboard Access and VoiceOver on a real screen
  ([remaining checks](native-interface-review.md#remaining-checks)).

## Horizons

Longer aims, set on 18 October 2026. The binding limit is how long a run takes on one Mac, so
most are about reaching an answer for less, with the full solver kept as the referee. Each has its
first step done:

1. **Refinement steered by the decision.** A corridor from the charge gives one building full
   refinement's answer at a fraction of its cost; refining toward chosen buildings is in the app
   ([refinement steering](refinement-steering.md)). Since 21 October the quick estimate's close
   calls, buildings with a chance between 0.2 and 0.8, are run in the air within a budget: on
   Beirut the first answer in 13 s, eight in 22 s
   ([close calls](surrogate-first-look.md#close-calls-refined-by-the-solver-21-october-2026)).
2. **Answers in seconds.** The façade surrogate gives a district's glass in half a minute
   ([first look](surrogate-first-look.md)); since 20 October roofs take their own terms and walls
   are judged on loads saved without the old 65.5 kPa cap
   ([walls and roofs](surrogate-first-look.md#walls-and-roofs-20-october-2026)), and streets and
   close-in façades are loaded as fine runs load them. The learned field model is the next step
   ([in the quick estimate](learned-models.md#in-the-apps-quick-estimate-21-october-2026)): on
   Beirut, never seen in training, glass by side is exactly right on 0.942 of sides against the
   surrogate's 0.916, and concrete walls' skill is 0.68 against 0.60. Whether it becomes the
   default *is the user's decision* ([the decision](learned-models.md#the-decision-for-the-user)).
3. **City scale in minutes.** File ▸ New District runs the air to a hand-over radius and the
   surrogate beyond it: Beirut at 0.5 kt in about 7 minutes against 34, its glass within 0.04
   ([a city in minutes](hybrid-far-field.md)). Channelling down streets matters at tonne-scale
   yields (1.2–2 times the peak) but not at the far field's, so it went into the surrogate, not a
   far-field term.
4. **Uncertainty by default.** Each building side's chance of broken, blown-out and thrown glass
   ([glass by chance](glass-probability.md)), and since 20 October its walls' and roof's
   ([walls and roofs](glass-probability.md#walls-and-roofs)): concrete walls calibrated, roofs a
   little low in the middle, masonry high, and failure not given a chance. The same scene gives the
   same chances every time.
5. **From damage back to the explosion.** Yield and place inferred from arrival times, in the app
   ([charge inference](charge-inference.md)). Through the quick estimate, Beirut's surveyed stone
   buildings agree with the arrivals, its concrete ones do not
   ([surveyed damage](charge-inference.md#beiruts-surveyed-damage-20-october-2026)).
6. **Protective design.** The cheapest glazing, film, stand-off and barrier changes that meet a
   glass hazard target, in the app since 0.6.0 ([protective design](protective-design.md)). Fine
   runs behind buildings and barriers gave the surrogate its close-in branch and street gains; a
   shielding factor for barriers was not adopted, so barriers still barely change the estimate,
   on the safe side
   ([fine runs](protective-design.md#shielding-barriers-streets-and-close-in-loads-on-fine-cells-20-october-2026)).

Under all of them is raw speed: everything kept on the GPU, compact storage for coarse levels,
smarter steps, and work spread across machines ([distributed computing](#distributed-computing)).

## Big bets

Apart from the main line, each with a cheap first step and a stated way to fail:

- **Calibrate the whole model against the whole record at once.** Three parameters against 21
  comparisons ([`f91024bc`](https://github.com/emmettl/bombcad/commit/f91024bc)); a fourth, the
  concrete's fracture energy, is being added.
- **BombCAD's validation as an open benchmark** others can run and be scored on
  ([open benchmark](open-benchmark.md)): ten cases and a scorer; two of them now with reproducible
  input decks and history readers ([`a163e9f9`](https://github.com/emmettl/bombcad/commit/a163e9f9)).
  Next, a second code's entry.
- **Run the solver on other GPUs: a portable compute backend.** The CUDA work under
  [distributed computing](#distributed-computing) is its first step.
- **Whole-event simulation:** blast, collapse, debris and dust in one run. Not before limitation 1
  improves: collapse on a model that springs back is unearned.
- **Blasts near and under water**, for ports, quays and ships. First, a one-dimensional underwater
  burst against Cole's similitude.
- **Fire after the blast**, from the ignitions to spread across a district.
- **Forensics from photographs:** damage read from images into the charge inference.
- **A district's result walked at full scale** on a Vision Pro or iPad, from a kept timeline.

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
