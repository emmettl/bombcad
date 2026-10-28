# Protective design: the least change that meets a hazard target

Given a site, a threat and a hazard target for each building, protective design looks for the
cheapest set of changes that meets the target. The changes are glazing, walls, stand-off lines,
barriers and openings. This is [Horizons](roadmap.md#horizons) item 6. This page scopes it:

- what the public criteria and methods give, and what they need;
- how BombCAD would do it, which of its parts each step would call, and what is missing from them;
- what a prototype on a toy model shows.

The prototype is in `Scripts/protective/`. Its search is built in BombCAD as `scenebench protect`
([below](#in-bombcad-scenebench-protect)), headless; nothing is in the app yet. The
prototype's numbers are illustrative: its loads, shielding and costs are assumptions, not
BombCAD's runs or anyone's prices.

## What holds and what does not

- **Holds: the search is the easy part.** Choose the site-wide changes first (stand-off lines and
  barriers, a few of them), and a per-side target makes each building side's choice independent.
  An exact search then enumerates the site-wide combinations and picks each side's cheapest
  option: about 2^k full evaluations for k site-wide changes. That is the optimum an integer
  program over the same choices would give. On the prototype's four scenarios, a greedy search
  and simulated annealing both found the exact optimum.
- **Holds: stand-off is usually worth buying first.** It changes every side's load at once. In
  all four scenarios, the cheapest plan closed the car park or the street and added security
  film, as FEMA 426 and the cost studies below would lead one to expect.
- **Does not, yet: the loads.** The answer is set by how much a building in the way shields the
  one behind it. With the shielding assumed in the prototype's courtyard, the cheapest plan costs
  1,260 cost units. With the much weaker shielding BombCAD's own surrogate finds, it costs 1,972,
  57% more. Two further problems make the surrogate's loads unfit as design loads today:
  - it gives a 4 m-cell run's loads, which are 0.45–0.57 of the reflected peak even in sight of
    the charge ([surrogate](surrogate-first-look.md#limitations));
  - a design threat stands close, at Z under 4.6 m/kg^(1/3), outside its fit. Since 20 October a
    close-in branch from fine runs covers Z 1.5–4.6, and the fine runs measure shielding that the
    surrogate does not carry ([below](#shielding-barriers-streets-and-close-in-loads-on-fine-cells-20-october-2026)).
- **Does not, yet: what BombCAD can change.** Its envelope constructions have no security film,
  no wall retrofit, no barrier or stand-off as a scene element, and no costs. Its results are not
  yet probabilities (Horizons item 4).

## What the public criteria give

The survey used web searches only (16–19 October 2026). Nothing was downloaded, and several
documents were found only as citations and catalogue pages. Each item below says:

- what the source gives;
- what it needs from a model;
- whether it is open.

"Unverified" marks a number seen only in a secondary source.

### UFC 4-010-01: minimum standards for DoD buildings

- **What it gives.** A deemed-to-satisfy route. *UFC 4-010-01, DoD Minimum Antiterrorism
  Standards for Buildings* (2018, with Change 3 of May 2024) tabulates minimum stand-off
  distances, and the larger "conventional construction stand-off distances" (CCSD), by building
  category and construction type. Since the 2012 edition, this is in its Appendix B, Table B-1.
  - At or beyond the CCSD, ordinary construction is taken to meet the low level of protection.
  - Inside it, the walls, windows, doors and roofs must be designed for the design-basis threat,
    to the response limits of PDC-TR 06-08 (below).
  - It also sets requirements without a calculation, such as laminated glass in all exterior
    windows and limits on controlled parking.
- **What it needs.** A building category, a construction type and a measured stand-off.
- **Open?** The standard is open on WBDG. The explosive weights behind its tables are in
  UFC 4-010-02, which is For Official Use Only (FOUO).
- **Unverified numbers.** A secondary source quotes minimum stand-offs of about 10, 25 and 45 m
  (33, 82 and 148 ft) for the three building categories. The standard's own figures were not
  read. A 20 ft (6 m) minimum for controlled parking was also seen only second-hand.
- **For BombCAD:** UFC 4-010-01 is a lookup, not an analysis. It gives a cheap first check, and
  a baseline any optimised plan should be compared against: "the CCSD would need 45 m here; this
  plan reaches the same response limits with 25 m and film".

### GSA and ISC: performance conditions for windows

- **What it gives.** A hazard scale for glazing, graded by where the glass lands.
  - The scale comes from *GSA-TS01, Standard Test Method for Glazing and Window Systems Subject
    to Dynamic Overpressure Loadings* (GSA, 2003). The Interagency Security Committee's (ISC)
    *Risk Management Process* uses it.
  - Its performance conditions run from 1 to 5:
    - 1: no break;
    - 2: cracked but retained;
    - 3a: lands within 1 m (3.3 ft) of the window;
    - 3b: lands within 3 m (10 ft);
    - 4: strikes a witness panel 3 m in, no higher than 0.6 m (2 ft) above the floor;
    - 5: strikes it higher.
  - Sources differ on where the boundary between 4 and 5 falls. BombCAD's `GlazingHazard` uses
    0.6 m (building envelopes, [laminated glass](building-envelopes.md#laminated-glass)).
- **What it needs.** A test, or a model of the glass's breaking, flight and landing. This is the
  scale BombCAD already grades.
- **Open?** The ISC's tables of levels of protection against threats are in its Appendix B,
  which is FOUO. A target by level of protection must therefore be given by the user as a
  condition, not looked up.

### ASTM F1642 and F2912; ISO 16933 and 16934

- **What it gives.** The same idea for testing.
  - ASTM F1642 (the latest edition is F1642/F1642M-25) is a test method for glazing under
    airblast.
  - ASTM F2912 (F2912-25) is its companion specification. It gives the hazard ratings:
    - No Break;
    - No Hazard;
    - Minimal Hazard;
    - Very Low Hazard;
    - Low Hazard;
    - High Hazard.
  - ISO 16933:2007 (arena tests) and ISO 16934:2007 (shock tube; confirmed in 2023) classify
    glazing from A (no break) to F (high hazard) in the same spirit.
  - Both tie a rating to the test's blast: a glazing is rated for a named charge and stand-off,
    or a named shock-tube pulse. It is not rated in general.
- **What it needs.** A test, or a model, at the stated load.
- **Open?** All four standards are paywalled; only their abstracts were read.
- **For BombCAD:** a manufacturer's rating says a product meets a level at one load. It does
  not say what it does at another. BombCAD would need each product's construction (glass,
  interlayer or film, anchorage) to grade it at the site's loads. A rating could serve as a check
  on that model, not as the model.

### UFC 3-340-02: structures to resist accidental explosions

- **What it gives.** The design method, with loads and response limits.
  - *UFC 3-340-02, Structures to Resist the Effects of Accidental Explosions* (2008, with
    Change 2 of 2014) gives the methods:
    - loads, including the reflection by angle that `oblique.py` follows ([reference
      calculations](reference-calculations.md));
    - single-degree-of-freedom response;
    - response limits as support rotation and ductility, by member, material and protection
      category.
  - Change 2 raised some limits. Flexure in reinforced concrete is allowed 6° and tension
    membrane action 12°, for protection category 2. These are as reported second-hand; Table 4-1
    itself was not read.
- **What it needs.** A member's resistance, stiffness and mass, and the load as a pulse.
- **Open?** The UFC is open on WBDG.

### PDC-TR 06-08 and SBEDS: component damage levels

- **What it gives.** The levels a design target is set in. *PDC-TR 06-08, Single Degree of
  Freedom Structural Response Limits for Antiterrorism Design* comes from the US Army Corps of
  Engineers' Protective Design Center. Its April 2025 edition supersedes Rev 1 of 2008.
  - It tabulates, per component type, the ductility and support rotation that bound five damage
    levels:
    - superficial;
    - moderate;
    - heavy;
    - hazardous;
    - blowout.
  - It maps them to UFC 4-010-01's levels of protection, through component categories B1–B4
    (primary and secondary members, and so on).
  - A reinforced-concrete slab in flexure is quoted, second-hand and unverified, at:
    - ductility 1 for superficial;
    - 2° for moderate;
    - 5° for heavy;
    - 10° for hazardous.

    The prototype uses these for its walls.
  - SBEDS (Single degree of freedom Blast Effects Design Spreadsheet, the Protective Design
    Center with Baker Engineering and Risk Consultants) is the PDC's tool that applies these
    limits. Version 6.2 is said to comply fully with UFC 3-340-02 for two-way members. Its
    methodology manual (2012) has controlled distribution. Several papers about it are public on
    DTIC (see [data wanted](data-wanted.md)).
- **What it needs.** A response (ductility or rotation) per component.
- **Open?** The 2008 edition is open on USACE's ContentDM. The 2025 edition is on USACE's
  site, which refused the connection here. BombCAD's envelope damage already uses PDC-TR 06-08's
  levels ([damage references](building-envelopes.md#damage-references)).

### Optimising protective design

Published work on optimising protective design is thinner than the criteria, and mostly behind
publishers' paywalls. Abstracts and citing pages were read, not the papers.

- **Risk and cost of glazing.**
  - Stewart and Netherton, with colleagues, built probabilistic models of glazing hazard: glass
    strength and load as random, and fragility curves for hazard ratings (*Reliability
    Engineering and System Safety*, 2008; *International Journal of Impact Engineering*, 2009).
    The Blast-RF tool came from this work.
  - They then compared retrofits by life-cycle cost and expected losses.
  - Stewart's cost–benefit work (*ASCE Journal of Performance of Constructed Facilities*, 2008;
    *International Journal of Critical Infrastructure Protection*, 2010) asks how likely an attack
    must be for a protective measure to pay for itself: the "break-even" attack probability.
  - **What it gives:** a framework for chance and cost together, and the finding that a measure's
    worth depends strongly on the threat's probability, which is rarely known.
  - **What it needs:** fragilities per component, costs, and a threat probability.
- **Site layout by multi-objective search.**
  - Schuldt and El-Rayes (*International Journal of Safety and Security Engineering*, 2018) used
    a genetic algorithm (NSGA-II) to trade the cost of a site's layout and perimeter against blast
    damage.
  - El-Rayes and colleagues followed with a further study in the *Journal of Performance of
    Constructed Facilities* (2020).
  - **What it gives:** Pareto fronts of cost against damage.
  - **What it needs:** a fast load model (they used scaled-distance curves, without shielding).
- **Barriers.** University and industry studies, among them work at Birmingham and Riga
  Technical University, placed and sized blast walls by finite-element or CFD runs and
  parametric sweeps. They give barrier height and distance rules for a few layouts, not a search.
- **Façade design tools.** A façade contractor (Permasteelisa, 2013, a conference paper) described
  an SDOF-based tool for sizing blast-resistant curtain walls. It is paywalled.
- **Guidance on cost.**
  - FEMA 426 (*Reference Manual to Mitigate Potential Terrorist Attacks Against Buildings*, 2003)
    says stand-off is the cheapest protection where there is land for it.
  - The RCMP's *GCPSG-002* says stand-off costs land and perimeter control.
  - Vendors' guidance agrees on the usual order: film is cheaper than laminated glass, and the
    frame and its anchorage drive a retrofit's cost.

None of these joins:

- a 3-D load model with shielding;
- per-component response to the PDC's limits;
- probabilities;
- a search for the cheapest plan.

That join is where BombCAD could add something.

### What it means for BombCAD

| Criterion | Judges | BombCAD has | Missing |
|---|---|---|---|
| UFC 4-010-01 stand-offs | Stand-off by category and construction | Distances, in any scene | The table's values (open, not read here); its FOUO weights |
| GSA conditions, ASTM F2912 | Glass by where it lands | `GlazingHazard` grades both | Film; a frame's anchorage |
| ISO 16933/16934 classes | Glass by test class | The same landing model | The standards (paywalled) |
| UFC 3-340-02, PDC-TR 06-08 | Members by ductility and rotation | `EnvelopeDamageAssessment`'s levels | The 2025 limits; retrofits |
| Risk and cost studies | Chance and cost together | Per-pane E1300 chances (`GlazingMix`) | Load scatter as probability (Horizons 4); costs |

## The design

### What the user gives

- **A site.** A project with envelope buildings, each with an `EnvelopeConstruction` (walls,
  roof, glazing mix or panes, laminate), as today.
- **The threat**, as one of:
  - a charge and its place;
  - a set of them with weights (each gate, road or car park a vehicle could reach);
  - the samples of a posterior from `scenebench infer-charge --samples`
    ([charge inference](charge-inference.md)).

  Each is a TNT-equivalent mass on the ground.
- **A target per building, or per side.** It has three parts:
  - the worst glazing condition allowed (for example 3b on occupied floors, 4 elsewhere);
  - the worst wall level allowed (for example heavy);
  - the largest chance of passing them that is accepted (for example 10%).

  A UFC 4-010-01 level of protection maps to such a target through PDC-TR 06-08's component
  categories, so a preset can fill it in.
- **The changes allowed, with rough costs.** Each change has a cost per square metre or per
  metre:
  - **glazing:** another glass type or thickness, a laminate, film with or without anchorage;
  - **walls:** a retrofit (catcher system, sprayed polymer, bonded steel) or replacement;
  - **openings:** infilling a window, or adding one;
  - **site-wide:**
    - a stand-off line (bollards, a closed road or car park), which moves the threats it covers
      to where it would stop them;
    - a barrier wall, which stands in the air.

  Costs are the user's. BombCAD should ship none: published prices are local, dated and mostly
  paywalled, and wrong defaults would look authoritative.

### The search

1. **Loads for each threat and site-wide choice.** For each combination of stand-off lines and
   barriers, the site's loads come from the façade load surrogate, one estimate per threat
   sample. A stand-off moves the charge; a barrier is a solid in the plan raster.
2. **A limit per side and option.** For each side, glazing and wall option, and threat, find the
   factor m on the load's peak and impulse at which the side first passes its allowed level. A
   few bisection steps of the damage model find it. Glazing and wall changes do not change the
   outer loads in BombCAD's model (an envelope's geometry stays rigid), so these limits are
   computed once per site-wide choice, not per plan.
3. **A chance per side.** Take the load's scatter as a lognormal factor of standard deviation σ
   (the surrogate's 0.24 on peaks and 0.17 on impulses, from [estimates beside a
   run](validation.md#estimates-beside-a-run)).
   - The chance of passing the limit for one threat is ½ erfc(ln m / (σ√2)).
   - A side's chance is the weighted sum over the threats or posterior samples.
   - Glass breaking adds its own scatter: E1300's per-pane probability, as `GlazingMix` gives it.
     Combined with the load's, it widens σ for the glass.

   This is Horizons item 4 for one quantity, and it does not need item 4 built first.
4. **The search over plans.**
   - **Exact search.** Given the site-wide choice, a per-side target makes each side's choice
     its own: the cheapest option whose chance is under the target. Enumerate the site-wide
     combinations (2^k, so practical to about k = 12) and keep the cheapest.
   - **Many site-wide changes.** Simulated annealing over them, or an integer program with one
     binary per site-wide change and per side option. The integer program needs SciPy's `milp`
     or a solver, and a linearised load model.
   - **District-wide targets.** A target set over the district rather than per side, for example
     "at most two sides fail in expectation", couples the sides into a knapsack. A Lagrange
     multiplier on the coupling restores the per-side split.
5. **Confirm the best few with runs.**
   - Take the best three to five plans that differ in their site-wide changes. Run each as a full
     scene, or as the [hybrid far field](hybrid-far-field.md) for a district.
   - Judge the per-side changes on the run's recorded histories with `--envelope-damage` under
     each plan's constructions. One run serves every plan with the same site-wide changes.
   - Recompute each side's chance with the run's loads, and the scatter of a run against
     measurement in place of the surrogate's.
   - Re-rank. If the leader changes, run the new leader.

   Plans whose sides pass narrowly are the ones to confirm first: within a factor of three of the
   target chance in the prototype.
6. **Refine where it is close.** Horizons item 1 would refine the cells near the sides whose
   chance sits near the target, since the decision depends on them.

### What it gives back

A ranked table of plans, as the prototype prints it. Each row gives:

- the cost;
- the changes;
- the expected number of sides missing the target and the worst side's chance;
- its standing (`EvidentialStanding`).

A plan's standing is the lowest of its parts:

- **illustrative** while costs or construction are assumed;
- **approximation** when confirmed by a run, at the standing of BombCAD's façade loads and its
  envelope damage for those constructions;
- never **compared**, since no protective-design plan has been tested.

The app would colour each building by the residual chance of its worst side, with and without
the plan, and list the sides that pass narrowly. A comparison with UFC 4-010-01's deemed-to-satisfy
route ("CCSD: 45 m") gives the user a baseline.

### Which BombCAD parts each step calls, and what is missing

| Step | Calls | Missing |
|---|---|---|
| Site and constructions | `Scenario`, `EnvelopeConstruction`, `GlazingMix`, `LaminatedGlass`, `SecurityFilm`, `WallLiner`, `EnvelopeConstruction.glassToughened` (stage 3, [below](#changes-as-constructions-stage-3)) | A cost per construction; retrofits other than polyurea on masonry (no open tests) |
| Threats | `Scenario.charge`; `scenebench infer-charge --samples` | Several charges as one weighted threat; the surrogate takes one charge per estimate |
| Stand-off and barriers | `Scenario.addBarrier`, `Scenario.standOffLines` and `StandOffLine.stopPoint(for:)`, `FacadeLoadSurrogate.Raster` (envelopes and fixed blocks in the plan) | An edit API that applies a plan to a copy of the scene |
| Loads | `FacadeLoadSurrogate.estimate`; its close-in branch and canyon terms (20 October) | Converged (not 4 m-cell) loads beyond Z 8; the fine runs' shielding by barriers and buildings in front (measured, not adopted: [stage 1](#stage-1-shielding-as-a-factor-stopped)); streets off the charge |
| Response and limits | `EnvelopeDamageAssessment`, `SDOFResponseMemo`, `GlazingHazard` | A limit multiplier per component (bisection on the memoised responses); levels for retrofitted walls |
| Chance | `GlazingMix`'s E1300 chance; the surrogate's scatter in `ValidationTables.figures` | Horizons 4's load scatter as a probability per side; correlated scatter between neighbouring sides |
| Search | — | The search itself (Swift, a few hundred lines; exact enumeration and annealing need no solver) |
| Confirmation | Headless `--envelope-histories` and `--envelope-damage`; `HybridFarField` | Re-judging stored histories under another construction without re-running (the damage step reads constructions from the scene) |
| Standing | `EvidentialStanding`, `ValidationTables` | A row for protective-design plans |

## The prototype

`Scripts/protective/` uses Python and NumPy only (SciPy is not installed in the cloud sessions),
with `Scripts/reference/`:

- `model.py`, the forward model;
- `search.py`, the searches;
- `scenarios.py`, four made-up sites;
- `plan.py`, which prints the table;
- `test-protective.py`, 23 tests, in `make ci-test`.

```sh
python3 Scripts/protective/plan.py                  # all four scenarios, about 2 minutes
python3 Scripts/protective/plan.py courtyard street --json plans.json
python3 Scripts/protective/test-protective.py       # about 10 s
```

### Its model

- **District.** Rectangular buildings of 3 m storeys. Each side is one façade with one
  representative pane (1.2 by 1.5 m, its middle 1.5 m up) and one wall, 30% glazed unless said.
- **Loads.**
  - The base is Kingery–Bulmash's hemispherical surface burst (`kingery_bulmash.py`) at the
    pane, with the charge 0.5 m up.
  - Facing the charge, the peak and impulse rise from the incident toward the normally reflected
    values by the share that the reflection coefficient at that angle (`oblique.py`) keeps of its
    head-on excess. Facing away, they are the incident values.
  - Each building crossed on the line from the charge multiplies the peak by 0.7 and the impulse
    by 0.85. Each barrier multiplies them by 0.6 and 0.8.

    These shielding factors are assumptions, chosen to give a visible effect. They are much
    stronger than what BombCAD's surrogate fits from its runs: its term in log(1 + n) takes about
    2% off the peak per building, and adds to the impulse as the streets fill. The
    `weak-shielding` scenario uses factors near the surrogate's.
- **Glazing.**
  - The pane is a simply supported plate as a single degree of freedom: Timoshenko's
    coefficients, and Biggs's closed form for a triangular pulse. The tests check it against
    `sdof.respond` to within 1%.
  - It cracks at E1300's 60 s strength carried to 10 ms: 74 MPa annealed, and four times that
    for toughened glass.
  - Monolithic glass then flies at its speed plus what the rest of the impulse gives it.
  - Laminated and filmed glass become a linear membrane spring, with a plateau tension (12–24
    kN/m), a tearing strain and an anchorage. It is held (GSA 2), tears or pulls out, as
    BombCAD's `LaminatedGlass` does in outline.
  - Where the glass lands gives its GSA condition.
- **Walls.** A storey-high one-way strip in `sdof.beam`, judged by support rotation against the
  PDC levels above. The options are:
  - unreinforced brick, 0.215 m thick, with no arching: a resistance of about 2.7 kPa, so it
    fails early;
  - the brick retrofitted, taken as three times as strong;
  - 0.2 m reinforced concrete.
- **Chance.** Each side, option and threat gets a limit multiplier by bisection. The scatter is a
  lognormal factor with σ = 0.25 on peak and impulse together.
- **Target.** On occupied buildings: glass 3b or better and walls heavy or better. On unoccupied
  ones: glass 4 and walls hazardous. Each side must pass with a chance under 10%.
- **Costs.** Made-up cost units (CU) per square metre of glazing or wall, in the order the
  sources give:

  | Change | CU per m² |
  |---|---:|
  | Daylight film | 1.0 |
  | Anchored film | 2.5 |
  | Toughened glass, 10 mm | 4 |
  | Laminated glass, 6.8 mm | 5 |
  | Infilling the window | 6 |
  | Laminated glass, 13.5 mm | 9 |
  | Wall retrofit | 1.5 |
  | Concrete wall | 4 |

  The site-wide changes cost 60–150 CU each.

### Its scenarios and plans

The four scenarios:

- **`courtyard`.** Six buildings round a courtyard, with 100 kg in the car park 14 m south of
  the south row. Its site-wide changes are:
  - closing the car park, which moves the charge to 45 m;
  - a barrier wall along the south row.
- **`street`.** Two rows of four buildings, with 100 kg at five equally likely places along the
  street between them. Its site-wide changes close the street's west third, middle or east third.
- **`uncertain`.** The courtyard, with the charge as twelve posterior-like samples: a median of
  100 kg, a factor of about 1.5 either way, and scattered by 4 m in each direction about the
  car park's spot.
- **`weak-shielding`.** The courtyard, with shielding near the surrogate's.

The cheapest plan in each, from the exact search (greedy and annealing found the same in every
scenario), timed on a cloud container's CPU for the whole table (all three searches):

| Scenario | Sides missing the target as built (expected) | Cheapest plan | Cost, CU | Sides missing it after (expected) | Worst side | Time |
|---|---:|---|---:|---:|---:|---:|
| courtyard (24 sides) | 18.6 | Close the car park, barrier wall, anchored film on 6 sides, daylight film on 9 | 1,260 | 0.29 | 6% | 8 s |
| street (32 sides) | 29.2 | Close all three thirds of the street, anchored film on 24 sides, daylight film on 6 | 3,218 | 0.30 | 7% | 14–16 s |
| uncertain (24 sides, 12 samples) | 17.9 | As the courtyard | 1,260 | 0.47 | 8% | 94–100 s |
| weak-shielding (24 sides) | 20.9 | Close the car park, barrier wall, anchored film on 14 sides, daylight film on 5 | 1,972 | 0.36 | 8% | 5–6 s |

The runners-up show the trade-offs:

- **Courtyard.** Closing the car park alone, with more film, costs 1,800. The barrier alone
  costs 1,870. No site-wide change costs 2,490: brick retrofits on 2 sides and film on 24.
- **Street.** Closing only the two outer thirds costs 3,630.
- **Weak shielding.** The barrier is worth much less, and the plan without it costs 2,016.

Each plan's standing says "illustrative (toy model, assumed shielding)". It also gives the number
of sides that pass narrowly, which are the ones to confirm with a run. The full tables are
printed by `plan.py`.

What the prototype shows:

- **The search is cheap.** The forward model is the cost: limit multipliers by bisection, once
  per side, option, threat and site-wide choice. Twelve threat samples took 100 s in pure Python,
  against 8 s for one. Memoised responses in Swift would cut this by orders of magnitude.
- **Film beats laminated glass at these costs.** Anchored film reaches 3b or better at half the
  cost of the thinner laminate, so no plan chose laminated or toughened glass. The costs decide
  this, so the costs must be the user's.
- **Unreinforced brick fails first.** Without arching, unreinforced brick fails at about
  2.7 kPa. Many as-built failures are walls, and no glazing change fixes them. Only stand-off or
  a wall change does.
- **Shielding sets the price.** It moves the cheapest plan by 57% and changes what the barrier
  is worth. It is the first thing to fit from BombCAD's runs before the design can be trusted.
- **Narrow passes are common.** Four to eight sides per plan pass within a factor of three of the
  target chance. A confirmation run is needed, not optional.

The tests check:

- the closed forms against `sdof.respond`;
- the loads' limits (head-on equals reflected, facing away equals incident);
- monotonic grading (more load is never better, and the heavier laminate is never worse than
  annealed glass);
- the limit multiplier's bracket;
- that the exact search's best plan meets the target;
- that greedy is never cheaper than exact and annealing matches it.

## In BombCAD: `scenebench protect`

The search is built in Swift (`ProtectionSearch`), with BombCAD's own forward model in place of
the prototype's toy (`ProtectionModel`). On the prototype's three problems, given the prototype's
own chances (`Scripts/protective/export.py` writes them to `Fixtures/ProtectiveDesign`), it finds the
prototype's plans exactly: the best of the exact search, its ranked list, greedy's and the district
as built; its annealing walks its own random path and reaches the same optimum
(`ProtectionSearchTests`).

```bash
scenebench protect <district-scene's inputs> --inputs protect.json [--samples posterior.csv] [--confirm loads-folder] --out plans.json
```

The inputs file gives the threat, the target and the changes allowed, with the user's costs (none
are shipped):

```json
{
  "threats": [{"mass": 500, "x": 700, "y": 700, "weight": 1}],
  "target": {"worseThan": "3b", "chance": 0.1, "buildings": {"Store": {"worseThan": "4"}}},
  "glazing": [
    {"name": "film", "kind": "filmed", "costPerM2": 2.5},
    {"name": "toughened", "kind": "toughened", "costPerM2": 4},
    {"name": "laminated", "kind": "laminated", "costPerM2": 5},
    {"name": "infill", "kind": "infill", "costPerM2": 6}
  ],
  "standOffs": [
    {"name": "close the crossing", "cost": 80, "line": "Crossing"},
    {"name": "bollards on the square", "cost": 150, "moves": [{"threat": 0, "x": 700, "y": 580}]}
  ],
  "barriers": [{"name": "wall on the quay", "cost": 120, "from": [650, 660], "to": [750, 660], "height": 4}],
  "draws": 32
}
```

- **Site-wide changes.** Stand-offs and barriers, each with the user's cost.
  - **A stand-off** names one of the scene's stand-off lines (`line`): each threat on the side it
    guards is stopped a metre outside it (`StandOffLine.stopPoint`). Or it gives the threats' new
    places as `moves`.
  - **A barrier** is a wall along x or y (`from`, `to`, `height`, `thickness`, 0.3 m unless
    given), built on the ground under it. The surrogate's lines over the ground cross it, as they
    cross a building.
  - A plan with a site-wide change is not confirmed on a run's histories, which were made without
    it.
- **Sides and chances.** Each map building side (those with a glazing mix) is one side of the
  search. Its chance of failing is the chance that some pane is thrown worse than its target
  condition, from the façade load surrogate's loads under each threat (moved by the stand-offs in
  place), drawn over the surrogate's scatter and each building's glass strength
  ([glass by chance](glass-probability.md)), the threats weighted. `--samples` takes the threat
  from `infer-charge --samples` instead, places about the scene's charge.
- **The façade terms** (`--terms deep-city|deep-city-outline|clear-top|fitted`): the deep-city
  terms and their scatter, by default since 25 October 2026 (kept when the quick estimate took
  `deep-city-outline` on 28 October, [kept](#kept-on-the-deep-city-terms-28-october-2026)); the
  clear-top terms (the default earlier that day) and the terms of 23 October by name
  ([adopted](#adopted-the-clear-top-terms-with-the-flag-margin-25-october-2026),
  [on the deep-city terms](#on-the-deep-city-terms-25-october-2026)).
- **A margin for the scatter between sides** (`--margin`, or the inputs' `margin`; `flag:2.5` by
  default since 25 October 2026, `none` for none). `flag:2.5` protects one step further each side
  whose plan passes on its chance but not with its load 2.5 standard deviations of its scatter up;
  `quantile:` and `target:` are the other two candidates judged. See
  [the margin](#a-margin-for-the-scatter-between-sides-25-october-2026). `--terms fitted
  --margin none` is the planner as it was before.
- **Options.** The side as built (its map glazing mix, annealed), or any glazing allowed:
  security film (7 mil, wet glazed, unless `film` says: the [film](building-envelopes.md#security-film)
  holds the cracked pane until it tears or its anchorage lets go), toughened (the panes' strength
  times E1300's factor of 4), laminated (each pane `LaminatedGlass.facade` unless `laminate` says:
  held cracked, or torn and thrown, by its interlayer), infill (no glass), or re-glazed with new
  annealed glass in the same panes (`reglazed`: 1.55 times E1300's strength while it is new,
  [glass strength](glass-strength.md#the-option-new-or-tested-glass)). Each is a glass type
  on the side's `GlazingMix`, so a plan's glazing is an `EnvelopeConstruction` (a mix per side,
  `sideGlazing`) that `EnvelopeDamageAssessment` judges as it judges any building; a map façade's
  own mix, with no glass type, is judged as before, bit for bit. Walls are not searched: the
  surrogate's walls are not to be relied on.
- **Search.** Exact over the stand-offs (to 12), with greedy and annealing beside it; the same
  draws for every option and stand-off, so that plans are compared on the same luck. On the sparse
  made-up district (51 buildings, 204 glazed sides, 4 options, 2 stand-offs, 32 draws) every chance
  the exact search needs takes 26 s on the Studio, and confirming two plans on a run another 20 s.
- **Output.** The ranked plans as JSON and a table: cost, whether the target is met, the sides
  expected to fail, the worst side's chance, the sides passing narrowly (within a third of the
  target) and the standing: `illustrative` (the user's costs and threat, the surrogate's loads, the
  glass's chances a run's spread), `approximation` once a run confirms the plan.
- **Confirmation** (`--confirm`). The plans that leave the threat where a run of the scene had its
  charge are judged again on that run's saved façade histories (`district-compare --save-loads`):
  the plan's glazing written as constructions and judged by `EnvelopeDamageAssessment` itself, each
  building's glass strength drawn as the chances draw it and the run's loads as they were. On the
  sparse district at 20 t (rerun after 983409a8, so its close-in peaks are no longer capped at
  65.5 kPa), the cheapest plan without a stand-off meets the target on the surrogate's loads (3.1
  sides expected to fail, the worst 10%) but not on the run's: 1.3 expected, and six sides over 10%,
  the worst at 15%. Three of the four worst passed narrowly on the surrogate's loads (4–7%); the
  fourth, at 0.3% there, is a side the surrogate misjudges. On the capped loads the worst side was
  at 18%, the rest as now.

What it still lacks:

- **Barriers that shield.** A barrier is a site-wide change: a wall along x or y, built as
  `Scenario.addBarrier` builds it on the ground, which the surrogate's raster sees as it sees the
  scene's fixed blocks (crossed, blocked length, shadow, and since 20 October the knife edge). The
  surrogate's shielding is the districts', though: a 10 m wall 10 m in front of a façade takes
  2–3% off its peak, where fine runs take half or more off within a couple of the wall's heights
  behind it. A shielding factor fitted on those runs did not pass on the barriers or the districts
  ([stage 1](#stage-1-shielding-as-a-factor-stopped)), so a barrier still rarely earns its cost in
  a plan; on the safe side.
- **Wall retrofits.**

In the app, **Simulation ▸ Protective Design…** runs the same search on the scene's charges and
glazing changes, colours each side by the chosen plan's residual chance, and writes a plan's
glazing into the project's constructions ([using the app](using-the-app.md#protective-design)).

## Changes as constructions (stage 3)

Built on 19 October 2026: the changes a plan can make, as parts of the scene.

- **Security film and toughened glass** (`EnvelopeConstruction.film`, `.glassToughened`):
  - The film is a membrane once the glass cracks, held by its anchorage.
  - Judged against 67 open GSA tests of filmed 1/4" panes:
    - wet-glazed film holds, as 18 of 24 were graded;
    - daylight film is one class lighter than most;
    - mechanical anchorage, on a vendor's capacity, is never better than its test.

  See [security film](building-envelopes.md#security-film).
- **Polyurea liners on masonry** (`EnvelopeConstruction.wallLiner`): Ciornei's membrane on the
  wall's backbone. It is judged against one lined blockwork wall, so it is illustrative. FRP,
  steel-stud liners and fabric catchers are left out: their tests are not open. See
  [liners](building-envelopes.md#polyurea-liners-on-masonry).
- **A barrier wall** (`Scenario.addBarrier(from:to:height:thickness:)`):
  - It is a fixed block along x or y, 0.3 m thick unless said, standing on the lowest ground
    under it. The air, freestanding objects and fragments see it as they see any block.
  - The façade load surrogate's raster now holds the scene's fixed blocks too, each its own
    owner (below −1, so that crossing two counts two). A block thinner than a cell is held on
    every cell it overlaps, so that a thin wall is not lost between cell centres, as it would be
    on 4 m cells.
  - Its shielding terms were fitted on buildings, so until they are refitted on fine-cell barrier
    runs (stage 2), a barrier counts as one more building crossed: it barely shades.
- **A stand-off line** (`Scenario.standOffLines`, `StandOffLine`):
  - It is a polyline on the plan guarding its left or its right.
  - `guards(_:)` tells a place it keeps charges from, and `Scenario.chargesInsideStandOff` lists
    the charges it guards against. The app warns of them in the charge section.
  - `stopPoint(for:)` moves a guarded charge to the line, a metre to its unguarded side, for
    the search.
  - It is saved with the layout but is not part of the numerical input: the air never sees it.

## Shielding, barriers, streets and close-in loads on fine cells (20 October 2026)

Stage 2 of protective design (emmettl/bombcad-work#4): what a building or a barrier wall in front
takes off a façade's load, what a street adds, and what a façade close in takes, all measured on
fine cells, then set against the surrogate. The runs, extracts and scripts are on StudioData under
`bombcad/protective/refit` (layouts) and `bombcad/canyon/gaps` (streets).

### The runs

- **Layouts** (`make_cases.py`, `make_cases2.py`; made up, not a real place): four arms round a
  1 t surface charge, each a 12 m target building in the open or behind something, run with
  `scenebench district-compare --save-loads` on 0.5, 1 and 4 m cells:
  - L1, open at Z 2, 4, 7 and 10;
  - L2 and L3, behind one and two blocks 20 m wide (gaps 5–25 m, heights 6–20 m);
  - L4 and L5, behind barriers 1.2 m thick, 24 m wide and 2–4 m tall, from just in front to
    34 m in front;
  - L6, behind 20 m-wide blocks at Z 9–20;
  - L7, behind rows 80 m wide;
  - L8, behind barriers and rows 60–80 m wide.

  L1–L5 were run on 19 October without saved loads and run again today; L1's peaks come out 8%
  above the first runs' (the solver has moved since). The 0.5 m runs took 1–4 minutes each on the
  Studio.
- **Features** (`FacadeLoadSurrogate.Raster.sight`, new outputs):
  - the knife edge: of the cells under the line from the charge, the one whose top stands
    furthest over the line for its distances a and b from the charge and the façade (the most
    over √(1/a + 1/b));
  - how far that obstruction reaches to the side of the line;
  - the last building's top above its ground.

  From these, v = over √(2 (1/a + 1/b) / λ) with λ = 2 W^(1/3), and ITU-R P.526's knife-edge loss
  J(v). The departure q is the distance behind the last obstruction over its height.

### Stage 1: shielding as a factor, stopped

Each facing strip's departure from an open façade at the same cell size and Z cancels the cells'
unconverged peak. There are 120 such strips on 0.5 m cells, scattered by 0.84 in log peak. Each
candidate was judged leaving one layout out, against the judge's peak log-SD 0.24 and median
within ±10%:

| Terms | Peak log-SD | Median | By layout (median) |
|---|---|---|---|
| J, J e^(−q/3), J log Z | 0.254 | +0.03 | L7 −0.33, L2 +0.15 |
| the same, never a gain, ×(2/Z)^γ | 0.251–0.258 | +0.01 to +0.05 | L7 −0.35 |
| + J (1 − e^(−side/2W^(1/3))) | 0.232 | −0.01 | L2–L8 within −0.11 to +0.12 |

- **The width term** failed while L7 was the only wide layout: left out, its median was −1.9.
  With L8 added, and the side reach a Raster output rather than given by layout, it passes
  pooled: log-SD 0.232 on 0.5 m cells and 0.237 on 1 m.
- **But barrier walls are over-credited by it**: on their 40 strips (L4, L5, L8's walls) its
  median is +0.19, so the walls shield 20% less than it says.
- **And the district runs show none of it.** One multiplier on the fine factor, fitted with the
  district terms on the made-up districts' 4 m runs, comes out +0.05 for the peak. Holding it at 1
  raises those runs' peak scatter from 0.23–0.29 to 0.36–0.43. It also breaks Beirut's glass
  gate, since nearly every Beirut strip has an edge over its line. On 4 m cells at 1 t the
  layouts keep about 0.55 of the fine factor, so in dense districts the shadow is lost to the
  cells and to the neighbours' reflections.
- **Converged.** The measured factor moves 2% between 1 m and 0.5 m cells (log-SD of the
  difference 0.08).
- **Not adopted** (the stop rule: two candidate sets failed on held-out layouts, and the third
  does not hold for the barriers or the districts). The surrogate keeps its own shielding: a
  barrier or a building in front takes 2–3% off.

What the fine runs say, as the product answer:

- **Close behind, a lot.** Within one or two obstacle heights behind a block or a wall, at
  Z 2–5, the façade takes 0.13–0.5 of the open peak (L2's first arm −1.1 to −1.3 in log, L5's
  4 m wall 5 m in front −2.0 at the lowest storey). A 10 m block 10 m in front takes 0.27–0.33
  of the peak at Z 3.5, 0.36–0.6 at Z 7–11 if it is 80 m wide, and 0.57–0.9 at Z 11–15 if it is
  20 m wide. The surrogate takes 2–3%.
- **Further behind, little.** Ten heights or more behind (L5's 3 m wall 34 m in front, the 2 m
  wall 39 m in front), nothing. Storeys above the obstacle's top recover first, though not at
  once: diffraction reaches over the line.
- So the surrogate under-credits barriers and buildings in front, which is on the safe side for a
  plan: it buys glazing that a wall close in front would have made unnecessary.

### Stage 2: the close-in branch

Design threats stand close, at Z 2–5, below the fitted terms' range (4.6–38.7). The branch takes
Kingery–Bulmash's base times the ratio an open façade takes on 0.5 m cells: a quadratic in log Z
fitted on the open façades of L1–L6, Z 1.5–8 (43 façades, `Scripts/fit-close-in.py`). It is
carried to the project's cells by the fitted terms' own cell term, and blended into the fitted
terms between Z 4.6 and 8.

- **Leaving one layout out:** peak log-SD 0.11, median −0.02; impulse 0.10 and +0.03.
- **On 1 m cells**, through the cell term: the peak's median +0.01 (log-SD 0.13). Fitted on 1 m
  alone, the peak branch moves 1–3%. The impulse branch moves 17%, so the impulse is **not
  converged** close in, and is given as the 0.5 m runs give it.
- **What it changes.** The fitted terms read an isolated façade at tonne scale low: the open
  façades on 0.5 m cells were ×1.6 the fit's peak and ×1.7 its impulse at Z 4.6–8, ×1.6–1.9 at
  Z 2.5–4.6. Beirut's near boxes, run with uncapped loads, agree: the fitted terms gave 0.66 of the
  run's peak at Z 3–5. With the branch that is 1.12. Close in, plans now see loads up to about
  twice the fitted terms' (the design-relevant direction).
- **Not fixed:** at Z 8 and beyond, an isolated façade at tonne scale is still under-read by the
  fitted terms (×0.6–0.8 at Z 7–10 on 0.5 m cells). They are the districts', where nearly every façade
  stands behind something.

### Stage 3: Xiao et al.'s blast wall

`blastbench barrier` reproduces test 1-1 of Xiao et al. (2023, CC BY): 1.5 kg of TNT 1.2 m up,
1.44 m in front of a sand-filled wall 2.1 m tall, 5 m wide and 1 m thick. Here the wall and the
ground are rigid, half the burst is modelled (mirrored on the line through the wall's middle), and
each gauge is set against the same point on the same grid with the wall taken away. The runs took
10–120 s on 4, 2.5 and 2 cm cells, and the ratios moved by 0.02 or less between them.

| Gauge behind the wall | Xiao, first / largest peak over free field | BombCAD, 2 cm | Candidate set 3 |
|---|---|---|---|
| ground, 3 m | 0.36 / 0.42 | 0.36 | 0.42 |
| ground, 7 m | 0.81 / 1.19 | 0.65 | 0.96 |
| 1.2 m up, 3 m | 0.65 / 0.65 | 0.29 | 0.49 |
| 1.2 m up, 7 m | 0.58 / 0.89 | 0.61 | 0.96 |

- Two gauges of four are within the measured scatter (0.8–1.25 of Xiao's ratio): the ground at
  3 m, and 1.2 m up at 7 m on its first peak. BombCAD shelters the 1.2 m gauge at 3 m twice as much
  as the test.
- **Xiao's free field is not ours.** Our open field at those ranges is 1.4–1.6 times his
  free-field gauges. Behind the wall our absolute peaks are 0.66–1.43 times his and our impulses
  0.78–1.14 times. His impulse ratios over his free field exceed 1 (0.90–1.26), so his free-field
  reference is low against his own gauges behind.
- Standing: illustrative. One test, with transcribed numbers, a narrow wall with a second peak
  round its ends, and a free field that does not match.

### Stage 4: streets

`blastbench canyon` (`--offset` new, for a street not pointing at the charge) at 1 t on 0.5 m
cells:

- **Radial streets**, 10 m wide, walls 7.5, 15 and 30 m tall: mouths at 20, 60 and 120 m.
- **The 500 t street** at 1 t scale.
- **Streets 75 and 130 m off the charge** behind a single row: 20–68° off radial along them.

On radial streets the peak's gain over open ground grows with the street's length against the
distance to its mouth, and falls as the walls let the shock out over the roofs. It is fitted (one
coefficient each, leaving one run out) as:

- **Peak:** ln gain = 0.68 u e^(−ℓ/8h);
- **Impulse:** 1.33 u e^(−ℓ/3h) (1 − e^(−(h − 0.6))), for walls above 0.6 W^(1/3).

Here u = ln(Z / Z at the mouth), ℓ is the length in the street and h the walls' height, each over
W^(1/3). The proposed 0.5 [1 − e^(−(h − 0.6))] puts 62% of the 146 wall gauges within 1.2× and misses
by up to 1.83×.

| | Within 1.2× of the fine runs | Worst |
|---|---|---|
| Peak, no term | 36% | ×2.74 |
| Peak, the term | 85% | ×1.91 high (7.5 m walls far down a street whose mouth is at Z 2) |
| Impulse, no term | 49% | |
| Impulse, the term | 75% | ×1.9 |

- **The terms are in the surrogate** (`Raster.canyon`: walking back from the façade along the
  line while there are walls on both sides within 25 m). At a tonne in 15–30 m streets the peak
  rises up to 1.4–2.0 times. At 500 t in 20 m streets it is a few per cent, as Beirut's residuals
  said.
- **Streets off the charge** also gain, which the line-of-sight term does not see. Behind a
  continuous row, over the façade's own base, the far wall takes +0.03 to +0.23 at 30° off radial
  and −0.4 at 60°; the lee wall +0.15 to +0.48; impulses 1.5–1.9 times open ground's. The surrogate
  gives these façades the line of sight's treatment (a row crossed: about open), so it reads the
  lee walls of such streets up to ×1.6 low in peak and ×1.7 in impulse.

### Stage 5: the refit, and what it changes for a plan

The surrogate's coefficients (`FacadeLoadSurrogate.Coefficients.fitted`) keep the district terms
as they were, add the two canyon terms held at the fine runs' values, and add the close-in branch.
The rise share's refit with the ground rise read as itself is 5480db20's and lands apart.

A refit of the district terms was tried, on the made-up districts with their clipped strips
mended from emmettl/bombcad-work#10's uncapped reruns. It moved the districts' peak scatter by −0.01 to +0.04 and
Beirut's glass agreement at 0.5 kt by −0.02, so it was not kept: the branch carries the close-in
loads instead.

- **Beirut's gate** (surrogate-judge glass against the full runs, at 0.2, 0.5 and 1.1 kt): the
  canyon terms and the branch leave the sides' agreement and the band shares as they were:
  0.841, 0.754 and 0.813 (0.814 before), every band's shares within 0.005 of before.
- **The rise share refitted with the load terms** (5480db20's correction, f3065fca) was tried with a
  bounded buildings-crossed term, (log(1 + crossed))², fitted on the districts (impulse −0.040;
  their impulse scatter 0.168 → 0.163). It brings Beirut's far impulses down (0.5 kt, Z 28–40:
  1.63 → 1.41 times the run's; 1.1 kt, Z 20–28: 1.86 → 1.60) and the glass chances back to passing
  the tenths test with the load scatter (blown out skill 0.80, thrown 3b 0.71, against 0.81 and
  0.72 as fitted and 0.78 and 0.68 with the rise alone). But sides agree a little less at 0.2 and
  1.1 kt (0.833 and 0.809), and the bands' largest difference to 2 km grows to 0.16–0.17. So it is
  held, with its numbers (`bombcad/protective/refit/fit-sq.json`, `gate/`), not landed.
- **`ProtectionSearchTests`** pass.
- **For a plan.** A tonne-scale threat in a street now loads the street's façades up to twice as
  hard, and a side close in is read at the fine runs' ratio, about 1.6–1.9 times the fitted
  terms' at Z 2.5–4.6. Plans buy more glazing for both. Barriers still count for little in the
  search (2–3%). The fine runs say a barrier earns its cost only for façades within one or two of
  its heights behind it; protective design does not yet credit that.

## On the clear-top façade terms (25 October 2026)

On 25 October the quick estimate, the glass chances and the far field took the clear-top façade
terms (`TermSet.clearTop`, emmettl/bombcad-work#99). The planner kept the terms of 23 October
(`TermSet.fitted`) and their scatter, because it had not been judged on the new ones. This
section judges it on both (emmettl/bombcad-work#100). `scenebench protect --terms clear-top|fitted`
(and `ProtectionModel.model(…, terms:)`) runs either set. Without `--terms` the planner took
`fitted` until the adoption [below](#adopted-the-clear-top-terms-with-the-flag-margin-25-october-2026).

**The judge** is the planner's own. On the sparse made-up district (51 buildings, 204 glazed
sides, a 3b target at 10%, with film, toughened, laminated or infill offered), each plan is judged
again on a run's saved façade histories (`--confirm`).
- **Before today** that was done at 20 t only. That run was in both term sets' fits, and every
  plan meets the target on it.
- **Today the district was also run at 1, 2 and 5 t**, which neither set was fitted on. The runs
  are on 4 m cells, as the planner predicts loads, run to 3.5 s, 3–6 s each. Each was run with a
  clear top (200 m, #96's rule as #98 used it) and with the 20 t judge's 112 m top. The two tops
  give the same plans and worst sides; the 112 m runs leave a side or two more over the target.
  The table gives the clear top.
- **Two seeds** of the planner's draws (`seed` 1 and 2: the glass strengths and the load scatter)
  show how much of a plan's outcome is luck.
- The inputs and outputs are in `$BOMBCAD_DATA/scratch/issue100/protect`.

| Threat | Terms | Cheapest plan, seed 1 | Cost, seed 1 / 2 | On the run, seed 1 / 2: meets? worst side; sides over 10% | As built: Brier against the run, seed 1 / 2 |
|---|---|---|---|---|---|
| 1 t | 23 Oct | film on 98 sides | 19,368 / 20,316 | **yes** 9.4%; 0 / no 28%; 2 | 0.037 / 0.043 |
| 1 t | clear-top | film on 71 sides | 14,776 / 15,400 | no 19%; 3 / no 28%; 4 | **0.014 / 0.017** |
| 2 t | 23 Oct | film on 156 sides | 29,758 / 32,034 | no 31%; 8 / no 34%; 7 | 0.063 / 0.061 |
| 2 t | clear-top | film on 133 sides | 27,660 / 28,276 | no 31%; 8 / no 34%; 6 | **0.027 / 0.025** |
| 5 t | 23 Oct | film on 189, infill on 8 | 46,414 / 45,428 | **yes** 6.2%; 0 / no 25%; 2 | 0.036 / 0.038 |
| 5 t | clear-top | film on 186, infill on 8 | 45,300 / 45,152 | no 16%; 2 / no 25%; 2 | **0.025 / 0.025** |
| 20 t | 23 Oct | film on 188, infill on 16 | 49,618 | yes 0%; 0 | 0.006 |
| 20 t | clear-top | the same | 49,618 | yes 0%; 0 | 0.005 |

- **The clear-top terms judge the sides better.** As built, each side's chance of glass worse
  than 3b is nearer the run's below 20 t: Brier 0.014–0.027 against 0.036–0.063. At 1–2 t the
  terms of 23 October call 45–55 sides over the target that the run leaves within it; the
  clear-top terms call 21–32.
- **Their plans are cheaper, and miss a little more often.** The terms of 23 October read high,
  and that was a margin. Without it, the clear-top plans cost 1–24% less.
  - On the run at 1–5 t the clear-top plans meet the target in none of six cases, with 25 sides
    over 10% in all. The plans of 23 October meet it in two of six, with 19 sides over.
  - Both seeds' worst sides are the same for both sets: 28%, 31–34% and 25%. The two wins of the
    terms of 23 October are seed 1's alone.
  - So the difference is about the draws' noise. What both sets show is that the planner misses
    its target at masses it was not fitted on. It misses on a few sides (2–8) that the surrogate
    reads well within the target and the run reads at 16–34%: its scatter between sides.
- **Stand-offs and barriers rank alike.** The test (`protect-site.json`) put each of the four
  nearest blocks behind a 4 m wall 7 m in front of it, and offered a stand-off keeping the threat
  450 m west of the district.
  - Both sets buy the stand-off at 2 and 20 t. At 2 t it comes with film on 61 sides on the terms
    of 23 October and on 54 on the clear-top terms (15,272 against 15,132).
  - Neither set finds a wall worth its cost: no wall saves a side's film.
  - A plan with a site-wide change cannot be confirmed on a run made without it.
- **The barriers' shielding is the same on both.** Stage 1's layouts (L1 open; L4, L5 and L8's
  walls; 1 t) were rerun on 1 m cells with their loads saved, and judged strip by strip
  (`surrogate-judge --strips-out`). The measure is the log of the run's load over the surrogate's
  behind the walls, less its median on the open layout's front strips.
  - For the peak it is −0.32 on the terms of 23 October and −0.33 on the clear-top terms (log-SD
    0.38 for both, 40 strips).
  - For the impulse it is −0.24 and −0.18.
  - So the walls take about a quarter more off than either set credits, the safe side, as stage
    1 found.
- **Film and liners keep their judges.** Film was judged on 67 GSA tests of filmed panes, and
  liners on Ciornei's lined wall. Neither test uses the façade terms. The terms change only how
  many sides a plan films (above). Liners are not in the search, because walls are not searched.

**Proposal: the planner keeps the terms of 23 October for now.** On its own judge the clear-top
terms are not better beyond noise. Their plans meet the target on the run in 0 of 6 cases at 1–5
t against 2 of 6, with 25 sides over it against 19, and both seeds' worst sides are the same. Their
better side-by-side calibration is real. But a plan fails on its worst side, and the old terms'
over-reading was the planner's only margin for the scatter between sides. Before the planner
moves, that scatter wants a margin of its own: a lower target chance for the search, or a test
that flags any side whose chance is within the surrogate's scatter of the target. That margin
should be judged on these runs. Moving would then be the user's decision.

## A margin for the scatter between sides (25 October 2026)

emmettl/bombcad-work#101 built that margin and judged it on the runs. It was built as an option,
off by default: `scenebench protect --margin flag:2.5`, or `"margin": {"kind": "flag", "value":
2.5}` in the inputs. It became the default, with the clear-top terms, the same day
([adopted](#adopted-the-clear-top-terms-with-the-flag-margin-25-october-2026)).

**Why plans miss.** A side's chance is averaged over its load's scatter. A run gives each side one
load, though, and a plan with 50–100 sides near the target leaves a few whose load is well up.
- **The scatter itself is honest.** Each side's load on the run, in the terms' own standard
  deviations, was read from where its chance at the load's quantiles meets the run's chance. On
  1,668 sides and options whose run chance is 3–97%, at 0.5–50 t, the clear-top terms give a
  median of −0.27, an 84th percentile of +0.88, a 95th of +1.57 and a 98th of +2.15. A normal
  gives 0, +1, +1.64 and +2.05.
  - The tail is a little heavier: 1.1% are more than 2.5 above, against 0.6%.
  - The terms of 23 October read higher (median −0.38), with about the same spread.
- **The misses are the scatter's tail.** In the plans at 1–2 t without a margin, a load 2.5
  standard deviations up would put 43–72 sides over the target (49–54 on the clear-top terms).
  About one side in a hundred is that far up on the run.
- **32 draws hardly see that tail.** One load draw in 44 is 2 standard deviations up, so a side
  read well within the target often reads 0. A lower target cannot find these sides, which is why
  it failed below.

**The candidates.** All three take the terms' own scatter, `TermSet.loadScatter`, as the planner
draws it.
- **`target:t`.** The search holds every side to a lower chance `t`.
- **`quantile:z`.** Each side's chance is taken with its load (peak and impulse) held `z`
  standard deviations up, over the glass's strength alone. The search picks each side's cheapest
  option that passes on that chance.
- **`flag:z`.** The chances are as today. A side whose chosen option passes on them, but not with
  its load `z` up, is flagged and given the next dearer option with a smaller chance: one step,
  not the cheapest option that passes at `z`.

**The judge.** It is #100's, at more masses.
- The sparse district at 0.5, 1, 2, 3, 5, 10, 20 and 50 t, two seeds, both term sets. 0.5, 3,
  10 and 50 t were run today, under the same 200 m clear top, 5–7 s each.
- With no site-wide change each side's choice is its own. So every candidate's plan was found
  from one table per case (`--option-table`): each side's cost and chance under each option, at
  15 load quantiles, and on the run. The planner itself with `--margin flag:2.5`, at 1, 2, 5 and
  20 t, both seeds and term sets, gives the table's plans: the same 16 costs, verdicts and worst
  sides.
- **Holding masses out.** Each candidate's setting is the weakest with which every training case
  (both seeds) meets the target on its run. Three ways of holding out were used: fit on 1 and
  5 t; fit on 2 and 10 t; and leave one mass out of the eight. 20 t is always judged.

| Terms | Candidate | Fit on 1, 5 t: setting; judged on 6 masses, meets; sides over; worst | Fit on 2, 10 t: the same | Leave one mass out: settings; meets; over; worst | Cost × today's plan |
|---|---|---|---|---|---:|
| 23 Oct | none | –; 5/12; 30; 43% | –; 6/12; 18; 43% | –; 7/16; 34; 43% | 1 |
| 23 Oct | target | 0.02; 8/12; 8; 34% | 0.001; 10/12; 3; 19% | 0.001 in all; 13/16; 6; 34% | 1.13 |
| 23 Oct | quantile | 1.0; 4/12; 19; 37% | 2.0; 10/12; 3; 37% | 2–2.75; 13/16; 4; 37% | 1.21 |
| 23 Oct | flag | 1.0; 5/12; 18; 37% | 3.0; 10/12; 2; 19% | 3 in all; 13/16; 4; 23% | 1.14 |
| clear-top | none | –; 5/12; 31; 37% | –; 4/12; 27; 37% | –; 5/16; 42; 37% | 0.97 |
| clear-top | target | 0.001; 11/12; 1; 15% | 0.001; 11/12; 1; 13% | 0.001 in all; 14/16; 2; 15% | 1.12 |
| clear-top | quantile | 2.0; 7/12; 6; 18% | 2.25; 11/12; 1; 12% | 2.5 (2.25 once); 15/16; 1; 12% | 1.14 |
| clear-top | **flag** | 2.0; 8/12; 5; 15% | 2.25; 11/12; 1; 12% | **2.5 (2.25 once); 15/16; 1; 12%** | **1.10** |

The costs are the leave-one-out plans' summed costs against today's default (the terms of 23
October, no margin). The target's settings sit at the grid's floor: no lower target makes every
training case meet.

**What it shows.**
- **Two training masses are too few.** They choose 2–2.25 standard deviations, and plans then miss
  on one to five held-out cases. With seven masses, seven folds of eight choose 2.5, and the
  held-out mass meets in 15 of 16 cases. That 2.5 is also where about one side in a hundred lies on
  the runs, about one side in a plan's 50–100 near the target.
- **The terms of 23 October cannot be mended so.** Whatever the margin, on its terms a side at
  0.5 t (14–19%) and one at 10 t (15%) miss. They read high on average and misjudge those sides.
  The clear-top terms, which judge the sides better (#100), meet everywhere with flag 2.5.
- **Flag is the cheapest margin that works.** It protects with one step what quantile protects with
  the cheapest option passing 2.5 up. Both meet in all 16 cases on the clear-top terms, and flag
  costs 4% less over them.

**The proposal, case by case** (judged on the clear-top runs). "Today" is the terms of 23 October
with no margin; the proposal is the clear-top terms with flag 2.5.

| Threat | Seed | Today: meets? worst; sides over | Today's cost | Clear-top, flag 2.5: meets? worst; over | × today's cost | Its glazing | 23 Oct, flag 2.5: meets? worst; over | × today's cost |
|---|---|---|---:|---|---:|---|---|---:|
| 0.5 t | 1 | no 19%; 2 | 10,438 | **yes** 2%; 0 | 1.23 | film 63 | no 19%; 1 | 1.60 |
| 0.5 t | 2 | no 37%; 4 | 10,962 | **yes** 6%; 0 | 1.20 | film 66 | no 14%; 1 | 1.63 |
| 1 t | 1 | **yes** 9%; 0 | 19,368 | **yes** 9%; 0 | 1.29 | film 122 | **yes** 9%; 0 | 1.52 |
| 1 t | 2 | no 28%; 2 | 20,316 | **yes** 9%; 0 | 1.20 | film 126 | **yes** 9%; 0 | 1.46 |
| 2 t | 1 | no 31%; 8 | 29,758 | **yes** 3%; 0 | 1.34 | film 181, infill 1 | **yes** 6%; 0 | 1.39 |
| 2 t | 2 | no 34%; 7 | 32,034 | **yes** 6%; 0 | 1.20 | film 181, infill 1 | no 23%; 2 | 1.35 |
| 3 t | 1 | no 28%; 5 | 39,309 | **yes** 8%; 0 | 1.13 | film 186, infill 6 | **yes** 6%; 0 | 1.19 |
| 3 t | 2 | no 43%; 3 | 39,591 | **yes** 0%; 0 | 1.13 | film 186, infill 6 | **yes** 0%; 0 | 1.15 |
| 5 t | 1 | **yes** 6%; 0 | 46,414 | **yes** 0%; 0 | 1.02 | film 191, infill 9 | **yes** 0%; 0 | 1.04 |
| 5 t | 2 | no 25%; 2 | 45,428 | **yes** 0%; 0 | 1.03 | film 193, infill 9 | **yes** 0%; 0 | 1.06 |
| 10 t | 1 | no 15%; 1 | 48,860 | **yes** 0%; 0 | 1.01 | film 189, infill 15 | no 15%; 1 | 1.01 |
| 10 t | 2 | **yes** 0%; 0 | 48,235 | **yes** 0%; 0 | 1.03 | film 188, infill 16 | **yes** 0%; 0 | 1.03 |
| 20 t | 1 | **yes** 0%; 0 | 49,618 | **yes** 0%; 0 | 1.05 | film 180, infill 24 | **yes** 0%; 0 | 1.03 |
| 20 t | 2 | **yes** 0%; 0 | 49,618 | **yes** 0%; 0 | 1.04 | film 181, infill 23 | **yes** 0%; 0 | 1.04 |
| 50 t | 1 | **yes** 0%; 0 | 51,872 | **yes** 0%; 0 | 1.11 | film 155, infill 49 | **yes** 0%; 0 | 1.01 |
| 50 t | 2 | **yes** 0%; 0 | 51,872 | **yes** 0%; 0 | 1.10 | film 156, infill 48 | **yes** 0%; 0 | 1.01 |

- **On the clear-top runs.** Today's plans meet the target in 7 of 16 cases, with 34 sides over
  and the worst at 43%. The proposal meets it in all 16, the worst at 9.4%, for 1.01–1.34 times
  the cost (1.13 on average).
  - On the six cases of #100 (1, 2 and 5 t) it meets in 6 of 6, against 2.
  - With flag 2.5 the terms of 23 October meet in 12 of 16.
- **On the 112 m-top runs** (#100's second reference, at 1, 2, 5 and 20 t) it meets in 6 of 8,
  against 3. The two misses are one side at 1 t at 10.9%, within a draw of the target (3.5 of 32).
  Today's misses there reach 34%.
- **The choices still make sense.**
  - Film stays the glazing nearly everywhere, and toughened and laminated are never bought, as
    today.
  - Infill grows where the load is high: at 50 t, from 24 sides to 48–49. Film's chance close in,
    with the load 2.5 up, exceeds the target. Toughened and laminated read no better than film
    there for a 3b target, so the next dearer option with a smaller chance is infill.
- **Stand-off before film holds** (#100's site test, `protect-site.json`).
  - At 2 t the exact search still buys the stand-off on both term sets: with film on 87 sides on
    the clear-top terms (22,136) and on 98 on those of 23 October (23,820). Today it buys it with
    film on 54–61 sides (15,132–15,272).
  - At 20 t it buys the stand-off with film on 196 sides and infill on 4 (48,676, against
    47,672–48,628 today).
  - No wall is bought.
  - Greedy misses the stand-off on the clear-top terms, with or without the margin, as it does
    today. The exact search is what the planner reports first.
- **Its standing.** The margin is set on one made-up district's runs at 4 m, on its 204 sides and
  one target (3b at 10%). The scatter it takes is the terms' own, and the residuals above say that
  scatter holds on these runs. A district whose sides the surrogate misjudges more, a finer run, or
  another target would want the judge again. The runs' own chances are 32 draws, so a side within
  a draw of the target (3%) is within their noise.

**Proposal: the planner takes the clear-top terms with the flag margin at 2.5 standard
deviations.** Both together, not either alone. The clear-top terms without a margin meet in 5 of
16, and the terms of 23 October with it in 12 of 16. Plans would cost 1–34% more and meet the
target on every run judged here. Defaults are the user's decision. Until then the planner keeps
the terms of 23 October with no margin, and `--terms clear-top --margin flag:2.5` gives the
proposal. The app's Protective Design sheet would take both when adopted. The tables and scripts
are in `$BOMBCAD_DATA/scratch/issue101` (`judge.py`, `heldout.py`, `doc_tables.py`).

## Adopted: the clear-top terms with the flag margin (25 October 2026)

The user adopted the proposal on 25 October 2026 ("Adopt both", emmettl/bombcad-work#102). The
planner now takes the clear-top terms and their scatter, with the flag margin at 2.5 standard
deviations, unless told otherwise.
- **`scenebench protect`** without `--terms` or `--margin` is what `--terms clear-top --margin
  flag:2.5` was. Its plans are those of the table above: all 16 cases meet the target on the
  clear-top runs, the worst side at 9.4%, for 1.01–1.34 times the cost of the plans before (1.13 on
  average).
- **In code**, `ProtectionModel.model` takes `ProtectionModel.adoptedTerms` (`TermSet.clearTop`).
  An inputs file without `margin` takes `Margin.adopted` (`flag:2.5`).
- **The app's Protective Design sheet** takes both. Its "Planner of 23 October (earlier plans)"
  toggle gives the planner as it was.
- **The settings before stay by name.** `--terms fitted --margin none` gives the earlier plans:
  `"margin": {"kind": "none", "value": 0}` in the inputs, or `Margin.off` in code.
- **Checked.** On the sparse district at 1, 2, 5 and 20 t, both seeds, confirmed on the clear-top
  runs, the defaults write #101's `--terms clear-top --margin flag:2.5` plans byte for byte. In
  each case `--terms fitted --margin none` writes the plans of the planner before (#101's build
  with `--terms fitted`) byte for byte (`$BOMBCAD_DATA/scratch/issue102/planner.sh`).
- **What it costs in time.** The flag asks each option's chance again with the load up. On the
  sparse district a search with its confirmation took 12–14 s on the defaults and 15–17 s on the
  settings before, on a loaded Studio, so the margin costs no noticeable time.
- **What it does not change.** The standing stays illustrative, as the margin's own was. The
  margin was set on one made-up district's runs at 4 m, on its 204 sides and one target (3b at
  10%). Another district, a finer run or another target would want the judge again.

## On the deep-city terms (25 October 2026)

That evening the user adopted the deep-city façade terms (`TermSet.deepCity`: the clear-top terms
with far terms for façades deep in a city, emmettl/bombcad-work#104) as the default wherever the
clear-top terms were, the planner included, the glass front still off ("Adopt deepCity, front
off", emmettl/bombcad-work#105). The planner was to move only if, with flag 2.5, it still met its
target in 16 of 16 cases on #101's judge.

**The judge** is #101's and #102's: the sparse district at 0.5, 1, 2, 3, 5, 10, 20 and 50 t, two
seeds, each plan confirmed on the clear-top run's façade histories (200 m top), with `--terms
deep-city --margin flag:2.5` and `--terms clear-top --margin flag:2.5`
(`$BOMBCAD_DATA/scratch/issue105/planner.sh`, `plansum.py`; the binary of b7372baa, which names
both; 12–14 s a search).

**It meets the target in 16 of 16 cases, for the same cost.** Every plan on the deep-city terms
is the clear-top terms' byte for byte, at every mass and seed: the worst side 9.4% (1 t, seed 1),
no side over 10% on any run, and 1.01–1.34 times the cost of the planner before 25 October (1.13
on average), as in the table [above](#a-margin-for-the-scatter-between-sides-25-october-2026). At
1, 2, 5 and 20 t they are also #101's confirmed plans byte for byte.

**Why nothing moves.** The far terms are nothing unless a side stands behind more than 30
buildings or faces away from a charge more than 1.75 km off. The sparse district has 51 buildings
within 700 m, so no side there reaches either. The judge shows that the planner keeps its record
on the new terms; it cannot show how the far terms plan, which would need a district deep and wide
enough to reach them, with its runs.

**So the planner takes the deep-city terms.** `ProtectionModel.adoptedTerms` is
`TermSet.adopted` again, the quick estimate's, with `Margin.adopted`. `scenebench protect` without
`--terms` or `--margin` is `--terms deep-city --margin flag:2.5`, and the app's Protective Design
sheet takes the same. The clear-top terms stay by name (`--terms clear-top`), and "Planner of 23
October (earlier plans)" still gives the planner before 25 October.

## Kept on the deep-city terms (28 October 2026)

That day the user adopted the deep-city terms refitted with each wall facing as its building's map
outline (`deep-city-outline`, emmettl/bombcad-work#109) for the quick estimate, the glass chances,
the far field and the close calls, and kept the planner on the deep-city terms, each wall facing as
the cells. On #101's cases (the sparse district at 0.5–50 t, two seeds, flag 2.5, each plan
confirmed on its runs) the outline's terms meet the 10% target in 15 of 16 plans, against 16: at
10 t, seed 1, one side reads 15%. The sparse district's blocks are square to the cells, so the
miss is the refit's terms, not the facing, and it is not yet understood
([the surrogate](surrogate-first-look.md#façade-incidence-from-map-outlines-28-october-2026)).

So `ProtectionModel.adoptedTerms` is `TermSet.deepCity` by name, no longer the quick estimate's
(`TermSet.adopted`). `scenebench protect` without `--terms` is `--terms deep-city --margin
flag:2.5`, and the app's Protective Design sheet takes the same; `--terms deep-city-outline` plans
on the outline's terms. A plan and the quick estimate beside it now read a side's glass on
slightly different terms: within 0.01–0.02 in a band on Beirut as it lies, more on fronts at a
slant to the cells.

## Open questions

- **Shielding.**
  - Measured on fine cells (20 October): a lot close behind, little beyond ten heights. The
    district runs on 4 m cells show none of it, and a single factor over-credits barrier walls
    by 20% on the median.
  - Open: shielding for barriers alone, fitted on barrier layouts with more heights and widths
    and judged on a second open barrier test; or a model of the edge's two paths (over the top,
    round the ends) instead of linear terms.
- **Close-in loads.**
  - Covered to Z 1.5 by the fine runs' branch since 20 October. The impulse there is not
    converged between 1 m and 0.5 m cells (17%).
  - Isolated façades at tonne scale beyond Z 8 are still read 0.6–0.8 of a fine run by the
    district terms.
- **Costs.** Whose, and how rough? BombCAD should take them from the user, perhaps with a
  relative default ("film 1, laminate 3–5, stand-off per metre") clearly labelled as such.
- **The target.**
  - Per side or per building?
  - A chance per side, or an expected count per building?
  - Occupied floors only?
  - UFC 4-010-01's levels of protection map to component damage levels. The ISC's do too, but
    its tables are FOUO.
  - A district-wide target couples the sides and needs the Lagrangian or integer-program route.
- **Independence.** The prototype treats panes, sides and threats as independent. Load scatter is
  correlated along a street, and so is the glass's strength within a batch. Ignoring it
  understates the chance that many sides fail together.
- **Film and anchorage.** The prototype's film was a guess. BombCAD's is now judged against 67
  open GSA tests ([security film](building-envelopes.md#security-film)). Mechanical anchorages
  still have no open capacity.
- **Walls.** Unreinforced masonry does not arch in the envelope's model. Of the retrofits, only
  polyurea liners have open tests ([liners](building-envelopes.md#polyurea-liners-on-masonry)).
  PDC-TR 06-08's 2025 limits for retrofitted walls have not been read.
- **Moving the threat.** A stand-off line moves the charge to where it would be stopped. The
  attacker might choose another place, so a plan should be judged against all reachable places,
  as the street scenario does, not one.

## Limitations

- The survey read abstracts, catalogue pages and secondary sources. The standards (ASTM, ISO)
  and the optimisation papers are paywalled. UFC 4-010-02 and the ISC's Appendix B are FOUO.
  Numbers marked unverified came second-hand.
- The prototype is a toy. It has:
  - one representative pane and one wall per side;
  - no roofs or interior;
  - no venting;
  - assumed shielding;
  - made-up costs;
  - Kingery–Bulmash outside its fits for the closest sides (counted in each plan's standing).

  Its plans illustrate the method, not any real building.
- Only the search over glazing (film among it), stand-offs and barriers, the glass's chances and
  their confirmation on a run are built in BombCAD (`scenebench protect`; the app's sheet for
  glazing and the scene's stand-off lines). Wall retrofits are not in the search yet, and barriers
  shield only as much as the surrogate's district terms allow (above), well under what fine runs
  measure close behind them.

## Sources

- *UFC 4-010-01, DoD Minimum Antiterrorism Standards for Buildings*, 12 December 2018, Change 3,
  May 2024 (WBDG).
- *UFC 3-340-02, Structures to Resist the Effects of Accidental Explosions*, 5 December 2008,
  Change 2, 1 September 2014 (WBDG).
- *PDC-TR 06-08, Single Degree of Freedom Structural Response Limits for Antiterrorism Design*,
  US Army Corps of Engineers Protective Design Center: Rev 1, 2008, and the edition of
  23 April 2025 (link in [data wanted](data-wanted.md)).
- *GSA-TS01, Standard Test Method for Glazing and Window Systems Subject to Dynamic Overpressure
  Loadings*, US General Services Administration, 2003; Interagency Security Committee, *The Risk
  Management Process for Federal Facilities* (its Appendix B is FOUO).
- ASTM F1642/F1642M-25, *Standard Test Method for Glazing and Glazing Systems Subject to Airblast
  Loadings*; ASTM F2912-25, *Standard Specification for Glazing and Glazing Systems Subject to
  Airblast Loadings* (both paywalled).
- ISO 16933:2007, *Glass in building — Explosion-resistant security glazing — Test and
  classification for arena air-blast loading*; ISO 16934:2007, *… by shock-tube loading*
  (confirmed 2023; both paywalled).
- ASTM E1300, *Standard Practice for Determining Load Resistance of Glass in Buildings* (the
  strength and glass type factors, as BombCAD takes them).
- M. G. Stewart and M. D. Netherton, papers on the reliability and risk of blast-loaded glazing,
  *Reliability Engineering and System Safety* (2008) and *International Journal of Impact
  Engineering* (2009); M. G. Stewart on the cost-effectiveness of protective measures, *Journal
  of Performance of Constructed Facilities* (2008) and *International Journal of Critical
  Infrastructure Protection* (2010). Abstracts only.
- J. Schuldt and K. El-Rayes, on optimising the security planning of building sites,
  *International Journal of Safety and Security Engineering* (2018); K. El-Rayes and colleagues,
  *Journal of Performance of Constructed Facilities* (2020). Abstracts only.
- FEMA 426, *Reference Manual to Mitigate Potential Terrorist Attacks Against Buildings*, 2003.
- D. Xiao et al., "Effects of an Explosion-Proof Wall on Shock Wave Parameters and Safe Area
  Prediction", *Sustainability* 15, 11164 (2023), open access under CC BY 4.0: test 1-1's
  gauges, transcribed (stage 3 above).
- ITU-R Recommendation P.526, *Propagation by diffraction*: the single knife-edge loss J(v) used
  for the shielding candidates.
- Royal Canadian Mounted Police, *GCPSG-002, Guide to Blast Mitigation* (stand-off and its costs).
- S. Timoshenko and S. Woinowsky-Krieger, *Theory of Plates and Shells*, 2nd ed., 1959 (plate
  coefficients); J. M. Biggs, *Introduction to Structural Dynamics*, 1964 (the SDOF closed forms).
