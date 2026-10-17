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
| 3 | Afterburning's burning time is fitted, and its fireball never cools       | Afterburning and hot air are the default since 15 October 2026 (1.3–2 times slower; off still selectable): incident and suction impulses within a few per cent, rooms within 8%, but the burning time was fitted to the open blast's impulse, and the gas keeps the heat it radiates (21% of the charge's energy against a TNT fireball's 4–7%) unless radiative cooling is on; turned off, incident impulse is 13–22% low and rooms' gas 48–114% of the design value | [Air-blast model](air-blast-model.md#afterburning) |
| 4 | Peak pressure is under-resolved near the charge                         | Peaks read low, the unsafe side: close-in loading needs fine or twice-refined air; spall needs cells of 0.005 W^(1/3) and 12 elements through a slab | [Validation](validation.md#what-stops-the-spall-and-the-breach) |
| 5 | Collapse compared once, blind, and missed (two of Mendonça's slabs under an open-air charge); debris twice, off slabs under contact charges and brick walls under blasts | Debris held back rather than thrown, the unsafe side for a hazard (as rubble particles, an option, thrown at nearer the measured speed); brick walls crack at the measured heights but fall as one column, shattering on a rigid ground in the open (soft ground, an option, halves that) and thrown half as far as measured in a shock tube; collapse looks plausible, that is all | [Validation](validation.md#slabs-under-contact-charges), [brick walls](validation.md#brick-walls-debris) |
| 6 | Moving solids are a staircase of whole cells                            | Either way, to a cell: wall positions are good to a cell; small fragments are crude | [Structural model](structural-model.md#coupling-to-the-air) |
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
- **Next:** Peterson's short beams under impact: bond splitting along the bars and the strut's
  crushing ([Peterson](validation.md#short-beams-struck-to-a-shear-failure)); then stage 2's
  embedded cracks where members fail in shear, if Peterson's and OA1's modes call for them.
- **In reserve:** stage 4, a peridynamic zone, only if stage 3 cannot hole the right slabs.
- **Deferred:** embedded strong discontinuities (E-FEM) until the data decides between them and
  the alternatives ([alternatives](concrete-strategy.md#3-alternatives-for-the-failure-zones-only)).
- **Blocked:** the tensile strain-rate law at 1 to 10 per second needs tests that separate the
  material from the specimen's inertia; fragment sizes need Kasun-III's debris.

### Air

- **Done:** afterburning, hot air and dissociation; refinement in one or two levels; gravity,
  sub-grid mixing and radiative cooling as options ([air-blast model](air-blast-model.md));
  terrain on cut cells ([terrain](terrain.md#cut-cells)); bursts checked to 40 m/kg^(1/3) ([large scenes](large-scenes.md)).
- **Next:** a refinement criterion that follows weak shocks over kilometres; close in, a mapped
  one-dimensional start or the products' own composition for the hottest gas.
- **Deferred:** cut cells for moving solids.

### Structures and supports

- **Done:** shells and beams with solids in one body; several materials, masonry as units and
  joints, steel and glass; up to sixteen bodies meeting by contact
  ([multiple-object scene](multiple-object-scene.md#implemented-contact-between-bodies)); base
  connections, joints at any angle and between parts, and footings on soil checked against FoRCy
  and FoRDy ([supports, as they were built](structural-model.md#supports-and-connections-as-they-were-built)).
- **Next:** the rebound after a slab's peak; a shaken footing's lurch, and the rest of its
  energy (sand crushed across the whole contact, the shaken sand's own); pads' and dowels'
  laws; footings on a slope.
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

- **Done, illustrative:** [fragments](fragments.md); the fireball's
  [thermal radiation](thermal-radiation.md) and [surface heating](surface-heating.md); its
  [rise and cloud](fireball-rise.md); [ground shock](ground-shock.md), as the manuals'
  estimate or a layered soil column, against one measured 1 t burst 20 to 80 times too high in
  the vertical, near the outrunning limit; [gas deflagrations](deflagration.md), started: FM Global's
  vented tests within 0.4–1.6 of the measured peaks, with sub-grid turbulence and the measured
  cellular instability.
- **Now:** why the deflagration's flame stalls when lit in the middle (0.4–0.6 there), a young
  flame's speed on coarse cells, and a thinner front, without which K_G cannot converge.
- **Paused:** the fireball's radiation, about 21% radiated against Dial Pack's 5.1%; if it
  resumes, flame sheets round a fuel-rich core and the missing hot shock layer.
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

### Distributed computing

- **Done:** sweeps and ensembles shared across Macs by measured speed; the effects beside the
  blast placed on other Macs by cost
  ([several consumers](distributed-computing.md#several-consumers-on-several-machines)).
- **Next:** single-GPU gains first: refined patches taking shorter steps, and cheaper contact
  ([better first](distributed-computing.md#better-first)).

### Usability, in parallel

- **Done:** each result's [standing and error bands](standing.md); export for rendering as USD
  and OpenVDB, from the command line and the app ([USD export](usd-export.md)); saved runs and
  comparison ([run comparison](run-comparison.md)); an offscreen review of the panels in both
  appearances ([review log](native-interface-review.md#review-log)), and of every sidebar section and
  editor at the sidebar's width, with six layout fixes; release 0.2.0.
- **Next:** keyboard focus, VoiceOver and the window at its minimum on a real screen, which offscreen
  tests cannot reach ([remaining checks](native-interface-review.md#remaining-checks)).

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
