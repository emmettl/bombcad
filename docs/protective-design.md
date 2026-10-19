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
  - a design threat stands close, at Z under 4.6 m/kg^(1/3), outside its fit.
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
| Site and constructions | `Scenario`, `EnvelopeConstruction`, `GlazingMix`, `LaminatedGlass` | Security film (a membrane with an anchorage); wall retrofits; a cost per construction |
| Threats | `Scenario.charge`; `scenebench infer-charge --samples` | Several charges as one weighted threat; the surrogate takes one charge per estimate |
| Stand-off and barriers | `FacadeLoadSurrogate.Raster` (solids in the plan) | A barrier or stand-off line as a scene element; an edit API that applies a plan to a copy of the scene |
| Loads | `FacadeLoadSurrogate.estimate` | Converged (not 4 m-cell) loads; terms for close-in Z below 4.6 m/kg^(1/3); shielding by thin barriers (fitted on buildings only); channelling |
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
    {"name": "toughened", "kind": "toughened", "costPerM2": 4},
    {"name": "laminated", "kind": "laminated", "costPerM2": 5},
    {"name": "infill", "kind": "infill", "costPerM2": 6}
  ],
  "standOffs": [{"name": "close the crossing", "cost": 80, "moves": [{"threat": 0, "x": 700, "y": 640}]}],
  "draws": 32
}
```

- **Sides and chances.** Each map building side (those with a glazing mix) is one side of the
  search. Its chance of failing is the chance that some pane is thrown worse than its target
  condition, from the façade load surrogate's loads under each threat (moved by the stand-offs in
  place), drawn over the surrogate's scatter and each building's glass strength
  ([glass by chance](glass-probability.md)), the threats weighted. `--samples` takes the threat
  from `infer-charge --samples` instead, places about the scene's charge.
- **Options.** The side as built (its map glazing mix, annealed), or any glazing allowed:
  toughened (the panes' strength times E1300's factor of 4 unless said), laminated (each pane
  `LaminatedGlass.facade` unless said: held cracked, or torn and thrown, by its interlayer), or
  infill (no glass). Walls are not searched: the surrogate's walls are not to be relied on.
- **Search.** Exact over the stand-offs (to 12), with greedy and annealing beside it; the same
  draws for every option and stand-off, so that plans are compared on the same luck. On the sparse
  made-up district (51 buildings, 204 glazed sides, 4 options, 2 stand-offs, 32 draws) every chance
  the exact search needs takes 18 s on the Studio.
- **Output.** The ranked plans as JSON and a table: cost, whether the target is met, the sides
  expected to fail, the worst side's chance, the sides passing narrowly (within a third of the
  target) and the standing: `illustrative` (the user's costs and threat, the surrogate's loads, the
  glass's chances a run's spread), `approximation` once a run confirms the plan.
- **Confirmation** (`--confirm`). The plans that leave the threat where a run of the scene had its
  charge are judged again on that run's saved façade histories (`district-compare --save-loads`),
  each side under the plan's glazing, its glass strength drawn as the chances draw it. On the sparse
  district at 20 t, the cheapest plan without a stand-off meets the target on the surrogate's loads
  (3.1 sides expected to fail, the worst 10%) but not on the run's (1.3 expected, but one side at
  18%): one of its narrow passes. That run's loads were saved capped at 65.5 kPa, before 983409a8.

What it still lacks:

- **Barriers** (roadmap #63): a wall the surrogate's raster sees, and terms for thin walls, which
  the surrogate was not fitted on. The inputs file's `barriers` is refused until then.
- **Stand-off lines from the scene:** today each stand-off is given as moves of the threats it keeps
  back; #63's lines will give the stopping place.
- **Glazing as a construction.** `EnvelopeDamageAssessment` takes constructions apart from the
  scene, but a map façade's glazing is a `GlazingMix` of annealed panes with no glass type, so a
  plan's toughened or laminated glazing cannot be written as an `EnvelopeConstruction` and judged
  by it. Both the chances and the confirmation judge those panes directly (strength ×4, the
  laminate's SDOF), as `GlazingMix` judges annealed ones.
- **Film, wall retrofits, close-in loads** (the surrogate's terms are held below Z = 4.6), and the
  app's panel.

## Open questions

- **Shielding.**
  - How much does a building, or a barrier wall a few metres tall, take off the load behind it
    at design stand-offs? BombCAD's surrogate was fitted at Z of 4.6–38.7 m/kg^(1/3) on 4 m
    cells, where shielding was weak.
  - Barriers were not in its training at all.
  - Fitting this needs runs on fine cells of barriers and building pairs, judged against the
    published barrier tests where they can be found.
- **Close-in loads.**
  - Design threats are close: a vehicle at the kerb, Z of 2–5 m/kg^(1/3). On 4 m cells the runs'
    façade peaks are half the reflected value.
  - Either the surrogate is refitted on finer runs, or close sides are given Kingery–Bulmash's
    reflected loads directly, as the prototype does.
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
- **Film and anchorage.** The prototype's film is a guess: 20 kN/m plateau tension, and an
  anchorage of 3 or 30 kN/m. BombCAD would need a film model judged against tests: published
  shock-tube tests of filmed glass, and the GSA's window-film studies, if they can be found open.
- **Walls.** Arching in unreinforced masonry, and the response of retrofits (catcher systems,
  polymer coatings), are both missing. PDC-TR 06-08's 2025 limits for them have not been read.
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
- Only the search, the glass's chances and their confirmation on a run are built in BombCAD
  (`scenebench protect`); walls, film, barriers and the app are not.

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
- Royal Canadian Mounted Police, *GCPSG-002, Guide to Blast Mitigation* (stand-off and its costs).
- S. Timoshenko and S. Woinowsky-Krieger, *Theory of Plates and Shells*, 2nd ed., 1959 (plate
  coefficients); J. M. Biggs, *Introduction to Structural Dynamics*, 1964 (the SDOF closed forms).
