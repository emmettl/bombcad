# Cloud report: protective design (Horizons 6), scoped and prototyped

Branch `cloud/protective-design`, 19 October 2026, based on `main` at `830cb1f`. One commit
adds:

- [docs/protective-design.md](docs/protective-design.md), the survey and the design;
- the prototype in [Scripts/protective/](Scripts/protective/), with its tests in `make ci-test`;
- a line for the prototype in `Scripts/check-affected.py`, so that changes to it count as
  scripts and not as code;
- a pointer from [Horizons](docs/roadmap.md#horizons) item 6;
- this report.

No Swift or Metal changed or was built. Everything here ran in Python 3 with NumPy on Linux.
SciPy is not installed in the cloud session, so the prototype does without it.

## Summary

- **The public criteria give levels, not designs.**
  - UFC 4-010-01 gives deemed-to-satisfy stand-offs.
  - GSA-TS01, ASTM F2912 and ISO 16933/16934 grade glazing by where its fragments land, and rate
    a product only at its test load.
  - UFC 3-340-02 and PDC-TR 06-08 give members' response limits, from superficial to blowout.

  BombCAD already grades glass by GSA's conditions and ASTM's ratings, and members by the PDC's
  levels. What a protective design needs on top is a search, costs, and probabilities.
- **Published optimisation is thin and mostly paywalled.** It covers:
  - probabilistic glazing risk and the cost-benefit of retrofits (Stewart, Netherton);
  - multi-objective site layout with scaled-distance loads (Schuldt, El-Rayes);
  - barrier studies by FE or CFD.

  None joins 3-D loads with shielding, per-component response, probabilities and a cost search.
- **The search is easy.** With per-side targets, the sides separate once the site-wide changes
  (stand-off lines, barriers) are fixed. Enumerating those changes gives the exact optimum.
  Greedy and simulated annealing matched it on all four of the prototype's scenarios.
- **The loads are not ready.** In the prototype's courtyard, the cheapest plan costs 1,260 cost
  units with assumed shielding, and 1,972 (+57%) with shielding near what BombCAD's surrogate
  fits. The surrogate's loads are also those of 4 m cells (about half the reflected peak in sight
  of the charge), and design threats stand closer than its fit (Z under 4.6 m/kg^(1/3)).
- **Recommended first step: per-side chances of passing a level, judged for calibration.** This
  is a small `scenebench` step on existing parts, and it is Horizons 4's first step for glass
  ([below](#4-a-staged-plan)).

## 1. The survey

Searches only: fetching failed in this container. The sources are cited in the design's
[sources](docs/protective-design.md#sources). In brief:

| Source | What it gives | What it needs | Open? |
|---|---|---|---|
| UFC 4-010-01 (2018, Change 3 2024) | Minimum and conventional-construction stand-offs (Table B-1) by category and construction; laminated glass and other requirements without analysis | Category, construction, stand-off | Open; the weights behind it (UFC 4-010-02) are FOUO; stand-offs of about 10/25/45 m seen only second-hand |
| GSA-TS01 (2003), ISC | Glazing performance conditions 1–5 by landing distance and witness panel | A test or a landing model | Open; the ISC's Appendix B (levels against threats) is FOUO |
| ASTM F1642-25 / F2912-25 | Test method and hazard ratings, No Break to High Hazard | A test at a stated load | Paywalled |
| ISO 16933 / 16934 (2007) | Classes A–F for arena and shock-tube tests | A test at a stated load | Paywalled |
| UFC 3-340-02 (2008, Change 2 2014) | Loads, SDOF response, rotation and ductility limits (6° flexure, 12° membrane for category 2, second-hand) | Member properties, a pulse | Open; Table 4-1 not read |
| PDC-TR 06-08 (Rev 1 2008; 23 April 2025) and SBEDS | Ductility and rotation bounds for superficial, moderate, heavy, hazardous and blowout, mapped to levels of protection via B1–B4 | A response per component | 2008 open; 2025 refused here; SBEDS's manual controlled |
| Stewart and Netherton; Stewart | Glazing fragility, life-cycle cost, break-even attack probability | Fragilities, costs, threat probability | Abstracts only |
| Schuldt and El-Rayes; El-Rayes et al. | NSGA-II Pareto fronts of layout cost against damage | A fast load model | Abstracts only |
| FEMA 426; RCMP GCPSG-002; vendors | Stand-off cheapest where land allows; film cheaper than laminate; frames drive retrofit cost | — | Open (FEMA, RCMP) |

## 2. The design and its open questions

The design is in [docs/protective-design.md](docs/protective-design.md#the-design).

**Inputs:**

- the site's envelope buildings;
- a threat: a charge, weighted places, or `infer-charge` posterior samples;
- a target per side: the worst glazing condition, the worst wall level, and the largest accepted
  chance of passing them;
- the user's changes with costs.

**The search:**

1. Surrogate loads for each site-wide choice and threat.
2. A limit multiplier per side, option and threat.
3. A lognormal chance per side, using the surrogate's scatter and E1300's.
4. Exact enumeration of the site-wide changes, or annealing when there are many.
5. Confirmation of the best few plans by full or hybrid runs. One run's recorded histories judge
   every per-side variant with the same site-wide changes.

**Output:** ranked plans, each with its cost, residual hazard and standing. A table maps each step
to the BombCAD parts it calls and what is missing from them.

The open questions:

- **Shielding.** It sets the price, and the surrogate was fitted where it is weak. Barriers were
  not in its training.
- **Close-in loads.** Design stand-offs sit at Z = 2–5 m/kg^(1/3), outside the surrogate's fit,
  where 4 m cells halve the reflected peak.
- **Costs.** They should be the user's, with no shipped prices.
- **The target's form.** Per side, per building or district-wide (district-wide couples the sides
  into a knapsack); and how levels of protection map onto it.
- **Correlation.** Load scatter along a street and glass strength within a batch are correlated.
  The prototype's independence understates the chance that many sides fail together.
- **Film and retrofits.** BombCAD has no model of either. The 2025 PDC limits for retrofits are
  unread.
- **The threat's response to stand-off.** A closed car park moves the attacker, not only the
  charge, so plans should be judged over every reachable place.

## 3. What the prototype shows

`python3 Scripts/protective/plan.py` prints each scenario's plans; `test-protective.py` has 23
tests, all passing. Its model is a toy built from `Scripts/reference/`:

- Kingery–Bulmash with oblique reflection, and assumed shielding per building or barrier crossed;
- glazing as a plate SDOF in closed form, with membrane film and laminate and GSA landing;
- brick and concrete walls in `sdof.beam`, judged by PDC rotation.

| Scenario | As built, sides missing target (expected) | Cheapest plan | Cost, CU | After | Worst side |
|---|---:|---|---:|---:|---:|
| courtyard | 18.6 of 24 | Close the car park, barrier wall, film on 15 sides | 1,260 | 0.29 | 6% |
| street (5 places) | 29.2 of 32 | Close all three thirds of the street, film on 30 sides | 3,218 | 0.30 | 7% |
| uncertain (12 samples) | 17.9 of 24 | As the courtyard | 1,260 | 0.47 | 8% |
| weak-shielding | 20.9 of 24 | Close the car park, barrier wall, film on 19 sides | 1,972 | 0.36 | 8% |

- **Stand-off came first in every cheapest plan.** Film beat laminated and toughened glass at the
  assumed costs.
- **Unreinforced brick without arching drives many as-built failures.** No glazing change fixes
  them.
- **Four to eight sides per plan pass narrowly,** within a factor of three of the target chance.
  These are the ones to confirm with a run.
- **The forward model is the cost, not the search.** A single charge takes 5–8 s, the street's
  five places 14–16 s, and twelve samples about 100 s, all three searches included.

## 4. A staged plan

Each stage is judged before the next starts.

1. **Per-side chances, judged for calibration (small; first).**
   - **What it adds:** `scenebench surrogate-chance`. For each building side's glass, it reports
     the chance of breaking and of passing condition 3b. The chance comes from:
     - the surrogate's load with its fitted scatter, as a lognormal factor;
     - a limit multiplier found by bisection over `SDOFResponseMemo`'s responses;
     - `GlazingMix`'s E1300 chance per pane.

     It adds no physics and no changes.
   - **Judged on:** calibration against the full runs the surrogate was not fitted to (Beirut at
     0.2, 0.5 and 1.1 kt). Among sides given 20–40% chance of some glass broken, about that share
     should have it in the run. It passes if every decile bin with 200 or more sides lies within
     0.1 of the diagonal.
   - **Cost:** a few hundred lines, and runs already on StudioData.
   - **Why first:** it is the probability every later step ranks plans by, and Horizons 4's first
     step for glass.
2. **Shielding and close-in loads.**
   - **What it adds:** fine-cell runs (0.5–1 m) of a façade behind one building, two buildings,
     and a 2–4 m barrier wall, at Z = 2–10 m/kg^(1/3).
   - The surrogate's shielding and facing terms are refitted, or given a close-in branch on
     Kingery–Bulmash's reflected loads.
   - **Judged on:** held-out pairs within the surrogate's present scatter (σ 0.24 on peak), and
     against published barrier tests if open ones are found.
3. **Changes as constructions.**
   - **What it adds:**
     - security film (a membrane with a tear strain and an anchorage) in `LaminatedGlass`'s
       framework;
     - wall retrofits as `EnvelopeConstruction` options;
     - a barrier wall and a stand-off line as scene elements that the surrogate's raster and the
       solver both see.
   - **Judged on:** film against open shock-tube tests of filmed glass; a barrier run against
     stage 2's.
4. **The search, headless.**
   - **What it adds:** `scenebench protect` with:
     - the inputs above, the user's cost file, and exact and annealing searches;
     - the prototype's table as JSON, with standing from `EvidentialStanding`.
   - **Confirmation:** the best plans are run, and stored histories are re-judged under each
     plan's constructions without re-running the air. This needs the damage step to accept
     constructions apart from the scene.
   - **Judged on:** the Swift search matching the prototype's plans on the same toy inputs, and
     the confirmed ranks agreeing with the surrogate's for the top three on a made-up district.
5. **In the app.** A protective-design panel:
   - targets per building;
   - the changes and costs;
   - the ranked plans, with each building coloured by its worst side's residual chance and the
     narrow passes listed.

## What the Studio should check

- That `make ci-test` passes with the new line, `python3 Scripts/protective/test-protective.py`.
  It takes about 10 s here.
- That `Scripts/check-affected.py`'s `DOCUMENT` pattern now matching `Scripts/protective/*.py` is
  wanted. `Scripts/test-check-affected.py` covers it.
- The survey's unverified numbers before any of them reaches the app:
  - UFC 4-010-01's stand-offs;
  - UFC 3-340-02 Change 2's rotations;
  - PDC-TR 06-08's slab limits.

The branch is ready for review.
