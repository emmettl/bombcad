# New building types and their materials

Three building types are planned for the [roadmap](roadmap.md#scale-and-import): UK terraced brick
houses, steel portal-frame warehouses, and transport hubs. This page says what each needs and
which of those needs are new materials: timber, and thin profiled metal sheeting with its
fasteners. It also checks whether timber can use ContinuumKit's orthotropic law rather than a new
BombCAD law, as the shared-numerics rule asks
([ContinuumKit adoption](continuumkit-adoption.md)). It was written as a plan and a feasibility
check. Both materials have since been built (17 October 2026): timber in shells and beams
([shell model](shell-model.md#timber)), compared with the Ottawa shock tube's CLT panels and glulam
beams, its strength calibrated on their static tests; and [profiled steel
sheeting](profiled-sheeting.md), illustrative.

Two other sample buildings have since been built: a precast [large-panel block](large-panel-flats.md)
and a [process plant](process-plant-explosion.md) with its control room. They are not covered here.

## What each building type needs

| Building | Structure | Already in BombCAD | New |
|---|---|---|---|
| UK terraced brick house | Two leaves of brick with a cavity and wall ties; timber joist floors bearing in the brick; a timber roof under slates or tiles; party walls shared with the neighbours; sash or casement windows | Masonry as units and mortar joints, debris from brick walls compared with Keys ([validation](validation.md#brick-walls-debris)); annealed glass in openings; several bodies meeting by contact | Timber: joists and rafters as beams, boards and sheathing as shells. Wall ties: a few axial links per square metre, with pull-out, between two shells or solids. Roof coverings as debris (slates are loose pieces, not a continuum) |
| Steel portal-frame warehouse | Hot-rolled portal frames at 5–8 m; cold-formed purlins and girts; profiled steel cladding screwed to them; base plates on pads; one large internal volume | Steel beams and shells with plasticity; base connections and footings; room filling and venting in the envelope model | Profiled sheeting: thin steel whose stiffness depends on direction, with a fastener law for pull-out and pull-over. Thin cold-formed members that buckle locally |
| Transport hub | Long-span steel trusses or arches; large glass roofs and façades; concourses of tens of metres | Steel beams; large scenes at kilometre scale; annealed glass | Laminated glass: an interlayer that holds the broken glass as a membrane, and glass falling from overhead. Slender long members that buckle under blast, to be checked in the existing beams |

The terraced house is the most demanding of the three: every one of its parts depends on
connections (ties, joist bearings, roof fixings) that the tests show decide how it fails.

## Timber

### What timber needs

- **Orthotropic stiffness.** Along the grain timber is about ten times stiffer than across it. A
  shell needs a grain direction in its plane, and plywood or CLT need the direction per layer.
  BombCAD's shell layers already exist; each would carry its own angle.
- **Failure that depends on direction.** Along the grain timber is brittle in tension and ductile
  in compression, where it crushes. Across the grain it splits at a few MPa. In rolling shear
  (between CLT layers) it fails at about 1 MPa. Glued joints delaminate.
- **Rate effects.** In shock-tube tests, CLT panels resisted 1.28 times their static strength,
  with no rise in stiffness, and glulam beams 1.14 times (University of Ottawa, below).
- **Connections.** Nails, screws, angle brackets and joist hangers. In the Ottawa tests on stud
  walls, typical connection detailing performed poorly under blast: the connections, not the
  timber, set how the walls failed.
- **Moisture and defects.** Knots and moisture change the strength a lot. Strength grades
  (C16, C24, GL24h) cover this statistically, and the error bands would need to carry it.

### Can it use ContinuumKit's law?

ContinuumKit has three of the laws, all from Edgerton's plywood coupons, all released (BombCAD
pins alpha.30; alpha.26 added `TimberFailure`, BombCAD's):

- `SolidMechanics.OrthotropicPlaneStress` (alpha.22): small-strain linear orthotropic plane
  stress in a frame with a grain angle. It has no damage, plasticity or rate effects, and it
  rejects strains above a declared bound (at most 1%).
- `VeneerCompression` (alpha.24): one-axis compression with linear hardening and unloading. It
  has no tensor coupling, rate effects or finite-strain crushing.
- `VeneerDamage` (alpha.24): scalar tension or shear damage in a declared band, with its
  fracture energy regularised by the band length. Tension and shear are not combined.

Edgerton's own plywood plan has since been parked. Edgerton is a visual tool, and the plan says
to rescope it from visual guidance. Its glue and delamination coupons (P3) were never extracted.
All the coupons' parameters are invented stand-ins, not measured plywood, and none of them was
tested under impact.

**Yes, timber shells should adopt the orthotropic law rather than a new BombCAD law.** The
elastic part is exactly what a timber shell layer needs, and its frame and grain-angle contract
fit BombCAD's layered shells. But BombCAD's shell law runs on the GPU in single precision, while
ContinuumKit's laws are CPU Swift in double precision. There are two ways to adopt it:

1. Port the law into `Shell.metal`, and test it against the released Swift law, called from
   BombCAD's tests as the reference, at the coupon samples. This is quick and keeps one source
   of truth for the physics.
2. Extract a Metal version into ContinuumKit, as `ContactSearchMetal` was. This is better if
   Edgerton or RoomCAD will run it on the GPU too. ContinuumKit's process applies, and so does
   the user's approval of a release.

Start with the first. Propose the second once the law has been tested on blast loads.

**What is missing, and would be new work:**

- **A failure criterion over the whole stress state.** Something like Hashin's, or a
  Tsai–Wu-type surface: tension along the grain brittle, compression along it plastic (from
  `VeneerCompression`'s one-axis law), splitting across the grain and shear through a damage
  band (from `VeneerDamage`). Combining them in one tensor law is the main research step. It
  belongs in ContinuumKit if Edgerton resumes plywood, so coordinate before starting.
- **Rate effects.** A dynamic increase factor on strength alone, about 1.1–1.3 from the tests
  below, applied as BombCAD's concrete applies its rate law.
- **Rolling shear and delamination** between CLT or plywood layers. BombCAD's layered shells
  share one set of nodes through the thickness, so a slip between layers needs either a
  through-thickness interface or separate shells tied by a cohesive law.
- **Connections.** A nail, screw or bracket law for the existing joints between parts: slip,
  withdrawal and the European yield model's modes (EN 1995-1-1). Timber beams need only a
  one-axis law along the grain in their fibres, plus shear, so beams can come before shells.
- **Large strain.** Crushing beyond 3% compression, and catenary action after failure, lie
  outside both ContinuumKit laws.

### Data that would judge timber

| Source | What | Open? |
|---|---|---|
| Poulin, Viau, Lacroix and Doudak, *J. Struct. Eng.*, 2018, [doi:10.1061/(ASCE)ST.1943-541X.0001915](https://ascelibrary.org/doi/abs/10.1061/%28ASCE%29ST.1943-541X.0001915), and Poulin's thesis ([uOttawa](https://ruor.uottawa.ca/items/29e2b68c-8fd2-4e1b-b0fa-b650bd8aeccb/full)) | 18 CLT panels, 3-ply 105 mm and 5-ply 175 mm, in four-point bending, in a shock tube and statically; dynamic increase factor 1.28; residual strength after the peak | Thesis open; paper behind a paywall |
| Lacroix and Doudak, 2018 (glulam beams, dynamic increase factor 1.14); Viau's thesis, 2016, 25 light-frame stud walls ([uOttawa](https://ruor.uottawa.ca/items/686b13ce-636a-4af7-bef7-0d623221a0ec/full)) | Glulam beams; stud walls from heavy damage to blow-out, sheathing tearing, connections failing | Theses open |
| Karagozian & Case TR-17-17.1 and TR-18-06.2, for WoodWorks ([phase 1](https://www.woodworks.org/resources/results-from-blast-tests-of-full-scale-clt-structures), [phase 2](https://www.woodworks.org/resources/results-from-phase-2-blast-tests-of-full-scale-clt-structures/)) | Three two-storey CLT buildings with windows and doors, at Tyndall AFB, under open-air charges; screws and angle brackets; a nail-laminated wall in phase 2 | Reports open; levels of detail not yet read |
| Czorny and Viau, *Constr. Build. Mater.*, 2026 | CLT panels under near-field charges | To check |

The full-scale CLT buildings are the best match to BombCAD's air-and-structure coupling. The
Ottawa shock-tube series would judge the law and rate effects member by member, as the concrete
was judged on slabs and beams.

## Thin profiled metal sheeting

Built since (17 October 2026) as a steel skin with its ribs as beams, as recommended below, and as
an envelope construction: see [profiled steel sheeting](profiled-sheeting.md), with its comparison
against Langdon's panels.

### What it needs

- **Stiffness that depends on direction.** A trapezoidal or corrugated sheet is stiff in bending
  along its ribs and nearly free across them, where it opens like an accordion. BombCAD's shells
  are flat plates between axis-aligned boxes, so the profile cannot be meshed at rib scale on
  a building. Either:
  - a flat steel shell with the ribs as beams along the span, using the existing shells and beams
    in one body. This needs no new law and keeps the steel's plasticity. It is the first choice;
  - or an equivalent orthotropic plate, whose membrane and bending stiffness are set separately.
    ContinuumKit's plane-stress law gives the membrane. The bending needs its own section
    stiffness, which BombCAD's layered shells cannot give from one law.
- **A fastener law.** Cladding fails at its fixings first: the screw pulls out of the purlin, or
  the sheet pulls over the screw head. Once a fixing fails, the sheet is free and becomes debris.
  This is a link law at points on the existing joints between parts: tension and shear capacity
  per fastener, with a rate factor. The capacity comes from the sheet's thickness and strength
  and the screw's diameter and pitch.
- **Local buckling** of the rib crests and of cold-formed girts and purlins. At blast rates a
  section's rotation capacity is set by local buckling, which shells resolve only if the crests
  are meshed. Beams would need a reduced plastic capacity.
- **Membrane action.** Large deflections, where the sheet hangs between supports as a membrane,
  carry most of the load after yield. BombCAD's shell nodes carry finite rotations, so its shells
  should carry this; it is to be checked against the panel tests.

### Data that would judge it

| Source | What | Open? |
|---|---|---|
| Langdon and Schleyer, *Int. J. Impact Eng.*, 2005–2006, three parts, and Langdon's thesis, 2003 ([Liverpool](https://livrepository.liverpool.ac.uk/id/eprint/3167700)) | Quarter-scale stainless corrugated panels with their connections under pulses like gas explosions; experiments, analysis and FE | Thesis open; papers behind paywalls |
| HSE RR102 ([HSE](https://hse.gov.uk/Research/rrhtm/rr102.htm)) | Corrugated stainless panels under hydrocarbon-explosion pressure histories, numerical: sensitivity to mesh and load | Open (numerical, a cross-check only) |
| Cladding–girt systems under blast, *J. Struct. Eng.*, 2023, [doi:10.1061/JSENDH.STENG-11724](https://ascelibrary.com/doi/10.1061/JSENDH.STENG-11724) | Small-scale blast tests of cladding on girts, two stiffnesses | Behind a paywall |
| DTIC ADA114540 ([pdf](https://apps.dtic.mil/sti/pdfs/ADA114540.pdf)) | A full-scale strengthened steel building for ammunition plants, with 18- and 20-gauge cold-formed panels, under about 900 kg charges; about 48 kPa resisted | Open |
| Screw pull-out from steel cladding under wind uplift, *J. Struct. Eng.* 124(10), 1998, [doi:10.1061/(ASCE)0733-9445(1998)124:10(1192)](https://ascelibrary.com/doi/10.1061/%28ASCE%290733-9445%281998%29124%3A10%281192%29) | Static pull-out capacity, the design formula and its shortfall | Static only |

No blast test of cladding fastener pull-out has been found. The fastener law would be judged
statically, with a rate factor only assumed. It belongs in the [data survey](data-survey.md#3b-a-footing-or-connection-under-fast-loading),
next to the connection tests.

## Brick cavity walls and ties

Masonry is already in BombCAD. What the terraced house adds is the second leaf and the ties
between the leaves. Blast tests of cavity walls exist for reinforced block with a brick veneer
([DTIC ADA555022](https://apps.dtic.mil/sti/pdfs/ADA555022.pdf), and Hoemann et al., *J. Perform.
Constr. Facil.*, 2015, [doi:10.1061/(ASCE)CF.1943-5509.0000509](https://ascelibrary.com/doi/10.1061/%28ASCE%29CF.1943-5509.0000509)),
but none was found for the UK's unreinforced brick cavity walls with steel ties. For whole houses,
the UK's Second World War records of damage to brick houses underlie Jarrett's damage distances
(Jarrett, *Ann. N.Y. Acad. Sci.* 152, 1968). These would judge an envelope-scale damage level,
not a detailed model.

## Order of work

1. **Timber beams**: a one-axis law along the grain in beam fibres, with brittle tension, plastic
   compression and a rate factor, judged against the Ottawa glulam beams. *Done 17 October 2026*
   ([shell model](shell-model.md#timber),
   [validation](validation.md#glulam-beams-in-a-shock-tube)).
2. **Timber shells**: ContinuumKit's orthotropic law ported to the shell layers and tested
   against the released Swift law, then the combined failure criterion, judged against the
   Ottawa CLT panels. Coordinate with Codex first, in case Edgerton's plywood resumes.
   *Done 17 October 2026:*
   - Edgerton is parked, so the criterion was proposed to ContinuumKit as `TimberFailure` (its
     PR 93, merged and since released in alpha.26).
   - It is in the shells with CLT layers and equilibrium shear
     ([shell model](shell-model.md#timber)).
   - It is compared with Poulin's panels
     ([validation](validation.md#cross-laminated-timber-panels-in-a-shock-tube)).
   - The fibres break at once, as the Ottawa members did.
3. **Profiled sheeting** as a steel shell with rib beams, and a fastener law, judged against
   Langdon's panels and the cladding–girt tests.
4. **Wall ties and joist bearings** for the terraced house, then the three building types as
   samples, as the precast block and the control room are now. *The terraced row is a sample
   since 17 October 2026* ([shell model](shell-model.md#the-terraced-houses)), with its floors
   smeared, its cavity leaves untied and its roof flat; the ties and bearings remain.

Each step ends with a product proposal or a stop: a material preset and a building sample in the
app, or a recorded reason not to go further.
