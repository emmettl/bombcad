# Concrete strategy: options, limits and what to model failure with

A review, written on 10 October 2026, of where the concrete model stands and where it should
go. No model code was changed for it. It asks whether smeared cracks in one-point solid
elements can reach good fidelity at failure, or whether failure needs another representation
where it happens.

The short answer:

- **Bending.** The present model is good where members bend: within about 5–15% on the contest
  slab, Janney's beam, Saatci's beams with stirrups, Ando's beams up to 3 m/s and Wu's slabs
  under their largest charge, on 8 to 16 elements through.
- **Failure.** It is not good where members fail:
  - in shear on coarse meshes;
  - by breach;
  - by spall or fragmentation;
  - through bars' kinematics.

  No combination of the options it has accumulated fixes one failure without breaking another.
  The traces show why. The causes lie in the representation, not in a parameter:
  - a crack that is one element wide and locks stress when inclined;
  - smeared bars that see the strain at an element's centre;
  - holes made only by deleting elements.
- **Recommendation.** Keep the present model for the body of a structure, and change the
  representation in stages:
  1. discrete bars first;
  2. then embedded cracks for members failing in shear;
  3. then conversion of failed concrete to particles for breach and debris;
  4. a peridynamic failure zone only if the data can judge it.

  Before any of that, retire the options no case supports, and select the rest by regime instead
  of waiting for every case to agree.

The evidence is from [Validation](validation.md) and the [concrete model](concrete-model.md);
nothing new was run for this review. The literature survey's sources are listed at the end.

## 1. Taking stock

### The cases

| Case | Regime | Measured | Default, best mesh | Default, coarse mesh |
|---|---|---|---|---|
| Contest slab | Bending under blast | 108 mm | 121 mm on 16 (112%); 124 on 32 | 113–114 mm on 4–8 (105%) |
| Janney's beam | Bending, static | 41.5 kN m, failing at 42 mm | 41.2 kN m on 24, holding | 42.0 on 12, failing at 53 mm |
| OA1 | Shear, static, no stirrups | 332 kN, sudden | 368–384 kN on 24–36 (111–116%) | 456 kN on 12 (137%) |
| Push-off (Walraven and Reinhardt) | One crack sheared, restrained | 2.6–9.9 MPa | the cap alone, a twentieth to a fifth | same on 25–100 mm elements |
| Saatci, heavy drops with stirrups | Flexure under impact | 35–40 mm | −5% to +3% on 16 | +2% to +18% on 24 |
| Saatci, light drop without stirrups (SS0a-1) | Shear under impact, survived | 9.3 mm, whole | 17.0 mm, 246 removed on 16 | split along its bars on 24 |
| Ando, 19 beams without stirrups | Shear under impact | 1–6 m/s | within 16% on average on 16 | 53% too far on 24 |
| Peterson, 18 short beams | Shear under impact | modes by shear span | 2 of 6 groups wrong (16 only) | not run |
| Chiquito, close-in slabs | Close-in bending, breach | P7 340 mm; P2, S5 holed | P7 113–124 mm, never holed | |
| Hupfauf, contact charges | Breach and debris | 4 of 6 holed; debris speeds | none holed; loose cover held back | |
| Wu, 2 m slabs | Bending; spall; contact holes | 13.9–18.0 mm under 1.6 kg | within −20% to +7% under 1.6 kg; 40–70% under 0.2–0.8 kg | holes 14 and 8 cm against 27.5 and 23.5 |
| Wang, slabs | Bending under an aluminised charge | 14–20 mm | several times too stiff as supported | |
| Chamber | Joints of a box, internal blast | edge left 95 mm up; paper's model 87 mm peak | 38 mm peak, left 15 mm | 65 mm on 25 mm elements, not converged |

### Every option and default, and what each does

"Supported" means a case shows it right and none shows it wrong; "regime" means right in one
class of problem and wrong in another. Code sizes are in `Structure.metal` unless noted.

**On by default**

| Option | What it does | Evidence | Class | Keep? |
|---|---|---|---|---|
| Crack axes that turn until the crack opens (`crackAxes`) | Avoids the lattice's double count of inclined cracks | Slab, chamber, OA1, wall | Supported | Keep. **Retire `.lattice` and `.fixedAtFirstCrack`**: superseded, kept for the comparison tables only |
| Second crack (`secondCracks`) | Relieves stress locking past 30° | Slab unchanged, chamber towards the paper's model | Supported for concrete; masonry of the tall buildings comes apart far more, untested | Keep |
| Bars that outlive their concrete (`bareBars`) | Holed members hang on their bars | Chiquito P2's bars across the hole | Supported | Keep |
| Cracks that slide for good, and ride up (`crackSlip`, `crackDilatancy` 0.5) | Struck beams keep their deflection | Saatci, Ando | Supported for beams; does nothing for the slab's hinge | Keep |
| A crack's slide counts as opening (`slipWidensCracks`, true) | Default physics; `--slide-apart` turns it off | Off: one push-off crack right, every sliding beam too stiff | Off is unsupported | **Retire the option**, 10 lines; it is not even saved |
| Residual opening (`crackResidual` 0.1) | Cracks don't close fully | Slab insensitive 0–0.5; chamber left 5–19 mm | Supported (Birtel and Mark's b_t) | Keep |
| Rupture over a debonded length (`bondSpreading`) | Bars break at a mesh-independent opening | Slab on 32 | Supported | Keep while bars are smeared |
| Bars' rate over their debonded length (`barRateAlongBars`) | The hinge converges on fine meshes | Strip on 16–32 | Supported; `--element-bar-rate` superseded | Keep; **retire the flag** |
| MC2010 tensile rate law (`tensionRateLaw`) | Tensile strength with rate | Impacts within −5% to +15%; slab 96–103% | Supported; Malvar–Ross superseded (a quarter too stiff on Saatci, spall needing 17–21 MPa) | Keep; **retire Malvar–Ross** |
| Strain-rate window of 100 µs (`strainRateWindow`, since 12 October 2026) | The rate laws see the strain rate averaged over a fixed time, not the last 50 steps | The contest slab on 32 elements the same on half the step (default: ran away); the case matrix within a few per cent, Saatci's heavy drops within 5%, Ando's broken beams moving by up to two thirds either way, Hupfauf's speeds closer to the fit | Supported against the step; no help with mesh-dependent failure | Keep; `nil` (`--rate-window steps`) gives the 50-step average |
| CEB law for the bars (`steelRateLaw`) | Bars' strength with rate | Struck beams keep their deflection | Supported; Malvar–Crawford superseded (bars a fifth too strong at these rates) | Keep; **retire Malvar–Crawford** |
| Fracture energy as the tensile factor to ½ (`fractureRateExponent`) | Lets the reflected wave spall | Close-in spall under the charge | Regime: close-in; nothing else depends on it | Keep |
| Compaction (Holmquist–Johnson–Cook, always on) | Pores crush under confined pressure | Under 1% at Chiquito's rim, 11–18% on the axis; never what limits a case | Unsupported by any case, physically needed for contact charges | Keep; constants are for 48 MPa concrete |
| Confinement (Richart, 4.1) | Strength with lateral pressure | Slab and OA1 barely move without it | Supported, weakly | Keep |
| Masonry units and joints (`unitJoints`) | Joints where the mesh resolves courses | No test | Untested | Keep (separate domain) |
| Beams' sectional shear check (always on) | Fails beam sections in shear | OA1 99–103% with beams; every beam under impact fails within 0.5 ms | **Regime: static** | Make regime-selected: off under impact |

**Off by default**

| Option | What it does | Evidence | Class | Keep? |
|---|---|---|---|---|
| Bars that slip (`bondSlip`, ~250 lines) | Bond–slip at the nodes | Right: the slab's crack pattern, SS0a-1 whole, mesh independence. Wrong: slab 89%, OA1 ~150%, heavy drops 8–14% short, Ando a quarter short, four of Peterson's six groups, Wu's peaks a fifth low | Regime: crack patterns and splitting along bars; wrong for response | Keep frozen until discrete bars (stage 1) replace it; its bond law and tie check carry over |
| Interlock that grows with pressure (`pressedInterlock`, ~45 lines) | Walraven and Reinhardt's pressed cracks | Right: push-off 0.57–1.03, chamber towards the test. Wrong: Saatci's and Ando's beams broken, OA1 126–188% | **Regime: cracks restrained statically** (push-off, joints) | Keep as a regime option; save it in the model file |
| Crack shear stiffness falling with width (`crackShearStiffness`) | Walraven–Reinhardt stiffness | Moves nothing (slab, OA1, Janney) | Unsupported | **Retire**, 9 lines |
| Fragments removed (`removesFragments`) | Erodes concrete opened two ways | Holes Wu's and Hupfauf's 20 cm slabs, but also the 30 cm ones that held; misses Chiquito's holes; damages Saatci's beams | Regime: none found | Keep as a stop-gap until stage 3, then retire |
| Nonlocal crushing (`crushLength`, ~47 lines) | Averages crushing | Under 1% on the slab | Unsupported | **Retire the option**; reuse its double buffers for stage 2 |
| Crushing band (`crushBand`) | Minimum crush band | Sensitivity only | Unsupported | **Retire** |
| Shells' sectional shear (`shellSectionShear`) | One-way shear in shells | OA1 strip 298–319 kN; broke the contest slab at 6 ms | Regime: static | Regime-selected |
| Spread bars (bench only) | Steel smeared to the face | Removes mesh dependence; beams too stiff | Superseded by stage 1 | **Retire** |
| Fixed design factors, static strengths | UFC 3-340-02 | Slab 112% / 133% | Regime: design checks and static tests | Keep |
| Inclined bars, interface bond | Chamber detailing; masonry on concrete | Chamber | Supported | Keep |
| `--hourglass`, `--interlock`, `--dowel`, `--work`, `--stiffening` | Study knobs and traces | — | Diagnostic | Keep |

**Done on 11 October 2026**: the seven are retired (see the roadmap's things set aside), with
`blastbench digest` and the case matrix unchanged; old files read with today's behaviour and a
note (`StructureModel.retiredOptions`).

**What retiring buys.** It drops about 120 shader lines and seven flags:

- the two old crack-axis models;
- slide-apart;
- crack shear stiffness;
- nonlocal crushing and the crushing band;
- the element-rate and Malvar laws;
- spread bars.

It also drops the comparison tables that only exist to justify them. The evidential standing
list (`EvidentialStanding.swift`) shrinks with them. Fewer switches means fewer cases to rerun
when the model changes.

Two defects were found on the way, and are fixed:

- `blastbench`'s `--bond` turned on the masonry interface joint (`interfaceBond`) on preset
  commands whatever followed it, and bars that slip were not set there at all. Now
  `--bond pullout`, `splitting` or `confined` make bars slip everywhere, `--bond none` keeps them
  bonded, and `--bond` alone or `--bond mortar` is the joint (`BondArgument`).
- `pressedInterlock` and `slipWidensCracks` were not saved in a model file. They are now, only
  where they differ from the standard, so older files read as before.

### Selecting by regime instead of waiting for agreement

The rule "default only if every case agrees" assumes one model can be right everywhere. The
cases fall into regimes that the options split along:

- bending;
- shear in members;
- restrained single cracks;
- close-in breach.

Cases in one regime agree with each other far better than across regimes.

Proposed instead:

- An option becomes the default **within a regime** when every case in that regime agrees and
  no case outside it is affected.
- The regime is chosen per member, from what the model already knows:
  - shear span to depth and stirrups, for shear-critical members;
  - scaled distance, for close-in;
  - load rate, static or impulsive.
- `EvidentialStanding` reports which regime each result was judged in.

Two candidates today: the beams' sectional shear check (static only), and pressed interlock
(statically restrained cracks only). A third came since: hourglass control that softens with
cracking, quasi-static only. All three are now done (see the
[concrete model](concrete-model.md#defaults-by-regime)): `StructuralRegime` uses the standing's
own placement by scaled distance and enclosure, with the loading static or impulsive. Bending and
shear in members are not told apart yet, since no option differs between them.

## 2. The limits of the model class

Each limit below is from a trace, not a guess.

1. **A crack is one element wide.** With bars that slip, every crack softens over its own
   element, and the trace shows where the slab's stiffness then goes: elements between cracks
   are loaded through the bond to their rate-raised strength and hold most of it at the start of
   their softening. Several neighbours soften together, each as if it were the crack. Taking
   them as one crack brought the slab to 101% but cost the Model Code's crack spacing in a tie
   (see [the concrete model](concrete-model.md#bars-that-slip-an-option)). With perfect bond the
   band is the crack spacing instead, and a crack that no bar crosses, such as one splitting a
   beam along its bars, has nothing to stop it. The same split appears in four places:
   - the slab on 32 elements, the row above the bottom bars;
   - SS0a-1 on 24;
   - Peterson's beams without stirrups;
   - the bonded strip on 32, which now collapses.
2. **Shear depends on the mesh, and inclined cracks lock stress.** On 12 elements (46 mm) the
   lattice cannot separate cracks 115–140 mm apart, and OA1 carries 137%; on 24, 111%. Ando's
   beams go 53% too far on 24 elements against 16% on 16. Fixed axes carry 0.6 f_t across a
   diagonal however far it is pulled, 0.35 with the second crack, and tension within 30° of a
   crack's axes still locks; no third crack is opened. Slip removes the mesh dependence and
   leaves OA1 about 150% on every mesh: the diagonal crack still cannot run through the
   compression zone. Crack tracking without slip, the band across inclined cracks, and pressed
   interlock did not change this.
3. **Hourglass control does work it should not.** It does 7% of the slab's work, 4% of OA1's
   and 18% of Wu's at the peak. Halving it moves OA1 on 12 elements from 456 to 431 kN, a
   quarter to 397 kN. It makes bending 10–15% strong where a compression zone is thinner than an
   element. It is not the cause of the slab's rebound or the chamber's return. (The hourglass
   session is working on this now.)
4. **Holes only by deletion.** Nothing removes broken concrete by default, so no slab is ever
   holed: not Chiquito's P2 and S5, nor four of Hupfauf's six. Every erosion rule that holes the
   20 cm slabs also holes the 30 cm ones that held, and removes elements in hinges. Deleting
   loses the mass and momentum that the debris and the far face carry. Hupfauf's loose cover is
   held back instead of thrown.
5. **Smeared bars see the strain at an element's centre.** Wu's slabs with one layer of steel
   and with two come out the same (14.4 and 14.9 mm, against 18.0 and 13.9 measured): the slab
   is barely cracked through, and a bar layer an eighth of the depth from the face sees its
   element's average. Bars cannot bridge a hole except as bare elements. Bars along a lattice
   axis only: inclined bars need their own scheme.
6. **Spall needs very fine meshes.** It needs air cells of about 0.005 W^(1/3) and 12 elements
   through a slab, and then comes off under the charge only, over a fiftieth of the tests' area.
   The tensile rate factor is frozen when an element first cracks, from an average that has
   caught only part of a wave rising in 30 µs.
7. **What the traces ruled out:**
   - interlock under pressure, for the slab and OA1;
   - tension stiffening counted twice, with slip;
   - compaction and confinement, under the close-in slabs;
   - the residual opening, the bars' hysteresis and hourglass control, for the rebound.

Items 1, 2 and 5 are consequences of smeared cracks and bars on a lattice of one-point
elements. Item 4 is a consequence of having no state between "attached" and "deleted". Item 3
is the element. None is a parameter the data could fit.

## 3. Alternatives for the failure zones only

The present elements stay for the body of a structure. The alternatives are judged on what they
would add where it fails.

Costs are measured against the present throughput: about 300–480 million element updates per
second on the M-series GPUs used (see [performance](performance.md)). On that GPU the contest
slab's 68,608 elements run 80 ms in about 35 s. A failure zone 0.3 × 0.3 × 0.15 m on
12.5 mm elements is about 7,000 elements. The multipliers below are rough estimates from the
literature, not measurements.

| Family | Fixes | Cost in the zone | Couples to the air | Size | Evidence for RC under blast or impact |
|---|---|---|---|---|---|
| **Discrete bars with bond** (truss bars in the hexes, tied by trilinear interpolation; LS-DYNA's constrained beams in solids; Schwer 2014) | Items 1 (splitting above smeared bars), 5; bars across holes; bars' slip and yield penetration in hinges | Bars 1–5% of the elements; negligible | Through the hexes | Weeks; the bond law and tie check exist | Standard practice in blast analysis |
| **Nonlocal averaging** of the strain that drives cracking (Bažant and Jirásek 2002) | Item 2 in part: mesh bias, spurious splitting; partly stress locking | 1.2–1.5×; a gather of 30–100 neighbours; no time-step penalty | Unchanged | Small; nonlocal crushing's buffers exist | Widely used; crack tracking, its cousin, did not help OA1 here |
| **Embedded strong discontinuities** (E-FEM, statically and kinematically consistent; Simo, Oliver and Armero 1993; Jirásek 2000; Oliver, Huespe and Sánchez 2006; Linder and Armero 2007) | Item 2: sharp inclined cracks, no stress locking, on coarse meshes | About 1.2–2× per cracked element; element-local; no time-step penalty | Unchanged (cracks do not open to the air) | Moderate; 3D crack continuity is the risk; one-point hexes need care | Mostly static RC beams; a few impacts |
| **Conversion of failed elements to particles** (Johnson and Stryk 2003; Rabczuk and Eibl 2003; Chuzel-Marmot, Combescure and Ortiz 2008; LS-DYNA's solid-to-SPH/DES) | Item 4: crater and spall debris keep their mass and momentum, load the far side and the air | Only failed elements; particles in compression and contact only (no SPH tension instability) | Particles as momentum sinks in the air's cells, as freestanding objects are now | Moderate; contact already exists | The industry route for contact charges; craters and spall within about 10% where calibrated |
| **Peridynamics on the existing nodes** (Silling 2000; Silling et al. 2007; Gerstle, Sau and Silling 2007; Shende, Behzadinasab, Moutsanidis and Bazilevs 2022) | Items 4 and 6, and 2 in the zone: cracks branch and holes open without tracking or deletion | 10–30× per node in the zone (about 100–300 bonds); same time step; 0.5–1 kB per node | Bazilevs's group coupled it to an Eulerian blast solver on concrete slabs | Months; correspondence models have zero-energy modes, as hourglassing; crushing still needs a continuum law | Point charges on slabs (Shende et al.), impact |
| **Phantom-node / X-FEM** (Moës, Dolbow and Belytschko 1999; Song, Areias and Belytschko 2006; lumping by Menouillard et al. 2006) | Items 2 and 4: separation with mass kept | About 2× where cut; time step kept with proper lumping | Exposed faces | Large on a GPU: topology updates, 3D crack paths, branching | Spall by cohesive insertion (Camacho and Ortiz 1996); little for blast on RC |
| **Lattice discrete particles** (LDPM: Cusatis, Pelessone and Mencarelli 2011; RC flexure, Alnaggar, Pelessone and Cusatis 2019; GPU solvers, Lale et al. 2026) | Everything in the zone: cracking, shear, compaction, fragmentation, size effect | Particles affordable (4,000–40,000 in the zone); the time step about 10⁻⁷ s, 20–50× more steps, so subcycled | Penalty or volume coupling | Large: mesostructure and about ten calibrated parameters | The strongest, including blast and penetration |
| **Rigid-body–spring and applied elements** (Kawai 1978, unverified; Bolander and Saito 1998; Meguro and Tagel-Din 2000) | As LDPM, coarser | Lower than LDPM | Through the elements | Large | ELS predicted the contest slab at 99%; contact-charge evidence mostly the vendor's |
| **Fully integrated or higher-order elements** | Item 3 only | 4–8× the material calls everywhere; 20-node lumping is poor | Unchanged | Moderate | Stress locking is the crack model's, not the element's (Jirásek 2000) |
| **Phase field** (Borden et al. 2012; Ziaei-Rad and Shen 2016) | Branching, nucleation | 3–5 elements across its length: fine meshes | Unchanged | Moderate | Almost none for RC under blast |

## 4. A staged plan

Ranked by fidelity gained for compute and effort. Each stage has the data that decides it and
a point to stop at.

**Stage 0: clear the ground (days).**

1. Retire what section 1 names (done).
2. Fix the `--bond` clash, and save `pressedInterlock` (done).
3. Make the beams' sectional shear check and pressed interlock regime-selected (done).
4. Turn the sweep used for bars that slip (`$BOMBCAD_DATA/tension-stiffening/sweep.sh`) into a checked-in case matrix that every concrete change runs. The matrix covers:
   - the slab on 4–16;
   - Janney, OA1 and Saatci on two meshes;
   - Ando and Peterson on 16;
   - Chiquito, Wu, Hupfauf and the chamber.

   It reports each result against the measurement and its regime. (Done: `Scripts/concrete-matrix.py`,
   its table on the defaults of 11 October 2026 in `Benchmarks/ConcreteMatrix/defaults.md`.)

Decided by: nothing new; it changes no result.

**Stage 1: discrete bars with bond (weeks).** Bars as trusses inside the hexes, their
displacement interpolated from the hex's nodes, bonded by the Model Code law already in
`BondSlip`. They replace smeared bars where bars are explicit, which is where they are drawn.
It should:

- stop the split in the plain row above smeared bars;
- let a bar layer near a face act at its own depth;
- let bars bridge a hole as themselves;
- carry the slip and yield penetration that hinges need.

Decided by:

- Wu's slabs with one layer and two (rank 1 in [Data wanted](data-wanted.md));
- Peterson's beams without stirrups, which split now;
- SS0a-1 on 24 elements;
- the slab on 32;
- the tie, for the bond.

Also: whether the slab's tension between cracks is then too stiff, as smeared slip is. Hrynyk's
impacted slabs (rank 4), plain and with fibres, separate what the concrete between cracks
carries.

Stop if Wu's one and two layers are still told apart no better than now. Then the cause is the
element's depth resolution, not the bars, and stage 2's elements, not more bar physics, are next.

**Stage 1, as far as it went (11 October 2026).** Discrete bars are in, as an option (see the
[concrete model](concrete-model.md#discrete-bars)). A tie with them cracks at the Model Code's
spacing and carries its tension stiffening within 5% on two meshes, and Janney's beam is within
4%. But they do not tell Wu's one layer of steel from two: 14.5 and 15.1 mm bonded, 11.4 and
12.0 mm with pull-out bond, where the tests gave 18.0 and 13.9 and the smeared bars 14.4 and
14.9. That is the stopping point above: the cause is the element's depth resolution, as the
hourglass session also found (the two-layer slab's compression layer is fully engaged, and its
bars do a quarter of the work). And the contest slab comes apart with them on 4 and 8 elements:
its hinge gathers into one crack and its bars rupture there at 23 ms, softer from 15 ms than with
smeared bars though its bars carry more. Traced, it is the concrete's crack at mid-span gathering
into one element column, which the bars follow (see the
[concrete model](concrete-model.md#discrete-bars)): the localising that stage 2's nonlocal
cracking is meant to cure. So the contest slab with discrete bars, holding together within the
measured scatter, is part of stage 2's acceptance. Discrete bars stay an option meanwhile, for
the holes of stage 3 to hang on.

**Stage 2: embedded cracks for members failing in shear (one to two months).**

- First the cheap step: nonlocal averaging of the crack driving strain within the failure zone,
  reusing the nonlocal crushing buffers.
- Then a consistent embedded discontinuity, an opening and slip inside the element with no
  stress locking, in elements whose crack has opened past a threshold.

Both stay in the present elements, so coupling and cost change little (about 1.5× where
cracked).

Decided by:

- OA1 on 12 elements, which should come within the 11–15% that 24 gives;
- Peterson's failure modes, all six groups;
- Ando's beams on 24, which go 53% too far now;
- the push-off tests, for the crack's own law.

Peterson's high-speed images (rank 2) give the crack's opening and slip against time, the first
direct check of a crack's kinematics under impact.

Stop if OA1 on 12 and Peterson's modes come right: shear in members is then as good as the data
can say, with one static beam and one impact programme. If neither moves, the lattice
representation of shear is exhausted. LDPM in the shear span is then the next step, but only
with a second shear-under-impact programme to judge it (Zhao, Yi and Kunnath 2017, which needs
the user to obtain it).

**Stage 2, its first step (11 October 2026).** Nonlocal cracking is in, as an option (see the
[concrete model](concrete-model.md#nonlocal-cracking)). At the length the literature supports it
barely moves OA1 on 12 elements (134%) and breaks the slab on 16 and Janney's beam early; only over
a band three times the crack spacing does OA1 come within 8% on both meshes, and there Ando's and
Saatci's struck beams go further from the tests. Peterson's modes do not move, nor is the slab
with discrete bars held together.

**The embedded crack: deferred, not abandoned (11 October 2026).** In one-point elements a crack
embedded in each element mostly changes the crack's statics, which the second crack already
solves; what cures stress locking is a crack path continuous between elements, and tracking one
did not help here before. No data at hand could tell such a model from today's: it waits for
measurements of a crack's own opening and slip under impact, such as digital image correlation
of Peterson's high-speed images ([Data wanted](data-wanted.md), rank 2). Meanwhile shear in
members stays bounded honestly, by the standing's error bands (OA1's 111–137% by mesh) and
the ensembles that spread a result over the model's options, rather than corrected.

**Peterson's images, read (11 October 2026).** The high-speed frames were read for every beam
recorded (see [Validation](validation.md#read-from-the-high-speed-images)): when the first
inclined crack forms, the main crack's angle, its opening and slip, and when the strut spalled or
burst. They do not decide for the embedded crack. Where the model forms the diagonal crack it
forms it when and at the angle the tests did: 52–56° against 50–51° in the short beams, 80–83°
against 76–78° in the deep ones, the first inclined crack 0.9–1.3 ms after impact against
0.7–2.0. The tests' shear cracks opened far more than they slid (slip a tenth to a third of the
opening), so a discontinuity's slip, which an embedded crack adds, carried little. What the model
gets wrong is elsewhere: its short and slender beams split along their bottom bars, the row of
elements above the bars removed along the beam, which no test image shows and which discrete bars
do not remove from the slender beam; its struts do not burst or spall where the tests' did (at
the support 3.8–4.3 ms after impact in the deep beams with stirrups, under the load 5.7–6.2 ms in
others); and its main crack lies 20–35° flatter than the tests' in the short beams with
stirrups. So before the embedded crack, the data point to the split along the bars (the bars'
splitting of their cover, and whether the row above them should be removable at all) and to the
strut's crushing under impact (the compression law's strength and softening at these rates, and
the removal rule for crushed concrete). The embedded crack stays the step for OA1 on 12 elements,
which these images do not test.

**The embedded crack, tried (14–15 October 2026).** The user chose to try it after the punching
trace showed that a 45° crack in one-point hexes cannot slide. Three attempts freed the 45° band by
three-quarters, but softened Hrynyk's undamaged slabs to 1.4–1.7 times their measured peaks, and
were not adopted ([record](concrete-model.md#embedded-cracks-tried-and-not-adopted)).

**Stage 3: failed concrete to particles, for breach and debris (one to two months).**

- An element past an erosion rule is converted into particles carrying its mass and velocity,
  and is not deleted.
- Particles are in compression and contact only, and are seen by the air as freestanding
  objects already are.
- The bars stay, as bare elements now or as stage 1's trusses.

The erosion rule then only decides when concrete is rubble, not whether its mass is lost. That
should make the rule less critical: a wrong choice moves debris rather than deleting a slab's
cover.

Decided by:

- Hupfauf's debris speeds and craters (rank 3), and which of his slabs holed;
- Wu's hole diameters;
- Chiquito's P2 and S5, which punched through;
- the spalled areas of each.

Stop when the holes are within about a quarter of their measured size, and which slabs hole is
right. Fragment sizes and their spread need Kasun-III's mapped debris (rank 12, needs the user);
without it the data cannot judge a finer model of fragmentation.

**Stage 3, as far as it went (11 October 2026).** Rubble is in, as an option
(`rubbleParticles`; see the [concrete model](concrete-model.md#removal) and
[Validation](validation.md#rubble-kept-as-particles-stage-3)). Mass, momentum and energy pass to
the particles exactly. Alone, rubble throws Hupfauf's debris at nearer the measured speed (about
22% off against 45%) but holes less than today, no slab the tests holed; with fragments removed it
holes every slab tried, those that held too, at sizes its threshold sets (Wu's S4 at 38, 38 and
14 cm as the opening goes from 0.5 to 0.7 to 1 mm, D4 at 28, 12 and 10), and not robustly (a node
of S4 went to NaN). Chiquito's slabs lose no
element at all. So the erosion rule was not made less critical: which concrete fails decides the
holes, and the present elements do not fail the right concrete. No regime's cases support a
default; rubble stays an option, for debris. Stage 4 stays in reserve for the user's decision,
after the next two.

**Next, before stage 4: what Peterson's images found (from 11 October 2026).** Judged by
Peterson's image fixture (`Samples/Peterson2026Images`) and the case matrix, regime by regime, with
no default unless a regime's cases support it:

1. **Splitting along the bars under impact.** The model's short and slender beams without stirrups
   split along their bottom bars, the row of elements above the bars removed along the beam, which
   no test image shows. Trace why: the splitting stress the bars' bond puts on their cover (the
   Model Code's bond and splitting, fib MC2010 6.1), the cover's tensile capacity and its rate
   law, and the removal rule that takes the row.
2. **Strut crushing and spall under impact.** The tests' struts crushed or spalled at the support
   3.8–4.3 ms after impact and under the load 5.7–6.2 ms; the model's do not. Trace the
   compression law's strength and softening at these rates and the removal rule for crushed
   concrete.

   Traced (11 October 2026; see [Validation](validation.md#read-from-the-high-speed-images)): the
   split is a shear band above perfectly bonded bars, which bond that slips removes, bringing the
   main cracks to the tests' angles but leaving the beams without stirrups whole; the struts crush
   but are not shed, held in the width's middle by confinement and on the face by removal coming
   only at 27% crushing. Neither crack-holding by the longitudinal bars, removal at the end of
   softening, a tenth of the crushing energy, nor cover that spalls at Mander's strain gives all six
   kinds their failures; nor, tried next at the user's choice (12 October), does a crushing zone
   of its own length, with bond that slips, nor cracked concrete made weaker in compression (the
   modified compression field theory): a strut must shorten about 2.5 mm to crush through and
   these shorten about 0.3 mm. Where the model's strut gets its strength and toughness under
   impact (confinement from the stresses carried, the ductility Mander's law gives confined
   concrete, the crushing energy) was traced next (12 October): confinement from the short
   bearings is real but larger than Eurocode 2 allows, the hooped concrete's ductility is not
   these beams', and evenly spread crushing is too tough; but none decides the beams, which fail
   or hold the same without each. Nor does confinement explain OA1's strength or the close-in
   slabs' stiffness. The open question for these beams is the face's crushed concrete coming
   away, which the cover-spalling rule tried could not time.
3. **Masonry that breaks too late and too coarsely.** Against Keys's trials the Windrush walls on
   their mortar bed break at one joint and topple whole about 1.5 s after 41 kg of TNT, two of them
   towards the charge, where the trials' broke in three within 20 ms and folded near the base; the
   debris lands 1.9 m out on average against 0.23 m. Trace the mortar joints' strength and
   fracture energy at these rates, the units' and joints' tension and shear under fast loading,
   and the bed joint's friction, with the Coulomb ground friction for debris added for Keys.
   Judged by Keys's fixture and the matrix's masonry cases.

**Stage 4, only if stage 3 cannot hole the right slabs: a peridynamic zone (months).** Bonds
between the existing nodes within a horizon of three elements, in a zone around a close-in or
contact charge. A correspondence law carries the present concrete's compression and crushing.
The zone is converted to particles as stage 3's are.

The cost is 10–30× per node in the zone. For a 7,000-element zone that is less than the slab's
own 68,608 elements already cost. Shende et al. give the precedent with an Eulerian blast
solver.

Decided by: the same data as stage 3, and spall's area on Wu's smaller charges, which the
present elements miss on any mesh tried.

Stop there: no open data says more about fragmentation.

**Not recommended now:**

- **LDPM**, until shear in members is shown to need it and a second data set can judge it.
- **Phantom-node X-FEM**: its topology work on a GPU buys what stage 3 and 4 do more simply.
- **Fully integrated elements**: several times the cost, for a defect the hourglass session can
  address directly.
- **Phase field**: no evidence for RC under blast.

**Where the data cannot judge further**

- One static shear beam (OA1) and one impact shear programme (Peterson) can say whether a beam
  fails in shear at about the right load. They cannot rank two models that both do.
- No open test measures tension stiffening in a yielding hinge at blast rates. Hrynyk's slabs
  are under impact, not blast.
- No open fragment data exists: Kasun-III needs the user to obtain it.
- The contest's high-strength slab (rank 10, needs the user) would be the second bending case at
  the contest's own loading. Without it, the slab's 5–15% cannot be told from luck.

## Sources

The literature survey checked these against publishers' and authors' pages. Those marked
unverified could not be confirmed. Costs above are estimates from them, not measurements.

- J. C. Simo, J. Oliver and F. Armero, strong discontinuity analysis, *Computational
  Mechanics* 12 (1993) 277–296, doi:10.1007/BF00356478.
- M. Jirásek, "Comparative study on finite elements with embedded discontinuities", *Computer
  Methods in Applied Mechanics and Engineering* 188 (2000) 307–330.
- J. Oliver, A. E. Huespe and P. J. Sánchez, E-FEM against X-FEM, *CMAME* 195 (2006) 4732–4752,
  doi:10.1016/j.cma.2005.10.023.
- C. Linder and F. Armero, *International Journal for Numerical Methods in Engineering* 72
  (2007) 1391–1433.
- N. Moës, J. Dolbow and T. Belytschko, *IJNME* 46 (1999) 131–150; J.-H. Song, P. M. A. Areias
  and T. Belytschko, *IJNME* 67 (2006) 868–893; T. Menouillard, J. Réthoré, A. Combescure and
  H. Bung, *IJNME* 68 (2006) 911–939; G. T. Camacho and M. Ortiz, *International Journal of
  Solids and Structures* 33 (1996) 2899–2938.
- G. Cusatis, D. Pelessone and A. Mencarelli, "Lattice Discrete Particle Model (LDPM) for
  failure behavior of concrete", I and II, *Cement and Concrete Composites* 33(9) (2011);
  M. Alnaggar, D. Pelessone and G. Cusatis, *Journal of Structural Engineering* 145(1) (2019),
  doi:10.1061/(ASCE)ST.1943-541X.0002230; Lale et al., LDPM solvers including GPU (2026),
  arXiv:2603.13190; J. Rezakhani and G. Cusatis, adaptive homogenisation, arXiv:1702.00695.
- T. Kawai, rigid-body–spring models (1978), unverified; J. E. Bolander and S. Saito,
  *Engineering Fracture Mechanics* (1998); K. Meguro and H. Tagel-Din, "Applied element method
  for structural analysis", *JSCE Structural Engineering/Earthquake Engineering* 17(1) (2000).
- S. Hentz, F. V. Donzé and L. Daudeville, *Computers and Structures* 82 (2004) 2509–2524;
  J. Rousseau, E. Frangin, P. Marin and L. Daudeville, *Computers and Concrete* 5(4) (2008).
- S. A. Silling, *Journal of the Mechanics and Physics of Solids* 48 (2000) 175–209; S. A.
  Silling et al., "Peridynamic states and constitutive modeling", *Journal of Elasticity* 88
  (2007) 151–184; W. Gerstle, N. Sau and S. Silling, *Nuclear Engineering and Design* 237
  (2007) 1250–1258; R. W. Macek and S. A. Silling, *Finite Elements in Analysis and Design* 43
  (2007) 1169–1178; S. Shende, M. Behzadinasab, G. Moutsanidis and Y. Bazilevs, "Simulating
  air blast on concrete structures using the volumetric penalty coupling of isogeometric
  analysis and peridynamics", *Mathematical Models and Methods in Applied Sciences* (2022),
  doi:10.1142/S0218202522500580.
- G. R. Johnson and R. A. Stryk, "Conversion of 3D distorted elements into meshless particles
  during dynamic deformation", *International Journal of Impact Engineering* 28(9) (2003)
  947–966; T. Rabczuk and J. Eibl, *IJNME* 56 (2003) 1421–1444, doi:10.1002/nme.617;
  B. Chuzel-Marmot, A. Combescure and R. Ortiz, *European Journal of Computational Mechanics*
  17 (2008).
- Z. P. Bažant and M. Jirásek, "Nonlocal integral formulations of plasticity and damage",
  *Journal of Engineering Mechanics* 128 (2002) 1119–1149; R. H. J. Peerlings et al., *IJNME* 39
  (1996) 3391–3403; M. Cervera and M. Chiumenti, *CMAME* 196 (2006) 304–320.
- M. J. Borden et al., *CMAME* 217–220 (2012) 77–95; A. Ziaei-Rad and Y. Shen, *CMAME* 312
  (2016) 224–253.
- L. Schwer, "Modeling rebar: the forgotten sister in reinforced concrete modeling", 13th
  International LS-DYNA Users Conference (2014).
