# Congestion below the grid

Pipes, bars and vessels too small for the air's cells, in a plant's racks or a test rig's
lattice, change a gas explosion. Each row a flame passes through stretches it and stirs the gas
ahead, so its speed grows row by row, to hundreds of metres a second. The model treats them as
industry codes do (FLACS; Shell's model as OpenFOAM's PDRFoam): as a porous, resisting medium in
each cell. It is being built in stages, after [the proposal](congestion-proposal.md):

1. **The obstacles and the porous flow** (built, 17 October 2026).
2. **The turbulence they make and the flame's folding** (built, 17 October 2026).
3. **Validation** against MERGE's rigs, the Baker–Strehlow–Tang flame speeds and Texas City
   (17 October 2026; [below](#merge)). It does not yet hold: the rigs with the finer pitch come
   within a factor of about two, those with the coarser three to five times too high.

So congestion stays illustrative, and the process plant sample keeps its fitted factor.

## The obstacles

A scene's congestion is a list of arrays (`Scenario.congestion`, `CongestionArray`). Each is a
region filled uniformly with pipes (cylinders) or square bars of one diameter, a given pitch
apart, running along one, two or three axes: one for a rack's tier, three for a rig's lattice.
Obstacles a cell or more across belong in the scene as blocks, which the air resolves.

From the arrays and each cell's overlap with their regions (`CongestionField`), every cell gets:
- **its volume porosity β_v:** one less the arrays' volume blockage, the pipes' cross-section per
  pitch² summed over their axes, times the cell's share in the region. It is held at 0.2 or more,
  since anything denser is a solid.
- **its drag across each axis, CR:** PDRFoam's C_D × frontal area per volume (the pipes along the
  other axes, a diameter every pitch²), with C_D 1.2 for a cylinder and 2.0 for a bar. It is
  multiplied by PDRFoam's row-blockage factor α = (1 − ½b)/(1 − b)² (α^1.09 for bars), as inside a
  uniform array (`PDRsetFields`' `calc_drag_etc`). b is the row's blockage as PDRsetFields
  idealises a cell's obstacles, their area blockage over the square root of their count: for a
  uniform array, (crossing sets) × D / (√(sets) × p).
- **its turbulence generation across each axis, CT:** C_b × CR, with C_b 0.035 for a cylinder and
  0.08 for a bar.
- **the obstacles' length scale L_obs:** the area blockage per obstacle across each axis times
  the width w below, the largest of the three. For a uniform array it is the diameter; a cell's
  size where there are too few obstacles.
- **their counts and blockage, for the flame's folding:** the count N of obstacles crossing a
  width w, (w/p)² for each set, and of those along each axis, ns, less what all three share (as
  PDRsetFields does); and the area blockage across each axis, B, (crossing sets) × D w / p², with
  bars counted at their larger drag. PDRsetFields counts over the cell. Here w is the larger of
  the cell and the pitch: an evenly spread array in a cell smaller than its pitch would otherwise
  count less than one obstacle, and the folding would vanish as the grid is refined (see
  [MERGE](#merge)).
- **their wall area per volume A_w.**

For MERGE's array A (43 mm pipes at 0.2 m along all three axes), β_v is 0.89 and, across any
axis, CR is 4.0 m⁻¹ (2.6 m⁻¹ before the factor of 1.55), CT 0.14 m⁻¹ and L_obs 43 mm.

## The porous flow

In each directional sweep a porous cell's update is the flux through each face times the face's
open share, over the cell's open volume β_v. A face takes the smaller of its two cells' β_v, so
the update never outruns the step's Courant number. The pressure on the obstacles' faces,
p (β_high − β_low), is added to the momentum, so still air stays still. Summed over the cells,
β_v ρ is conserved.

After each step the obstacles' drag takes momentum, as PDRFoam's drag model has it, at
(½ CR |u| + C_su β_v ν_eff A_w²) ρ u per volume along each axis. C_su is 0.5, and ν_eff is the
air's viscosity plus the obstacle turbulence's. Over the cell's open volume that is the drag over
β_v, applied implicitly (u ← u / (1 + Δt (½ CR |u| / β_v + C_su ν_eff A_w²))), so that it can only
slow the flow. The kinetic energy it takes stays in the gas as heat.

The solver's totals (mass, energy, momentum, a cloud's unburnt mixture) count each porous cell's
open share, and a charge in congestion is laid down over the gas's share of its sphere.

Its code is compiled into the air's kernels only where a scene has congestion, so every other
scene runs exactly as before.

## The obstacles' turbulence

Flow past the obstacles makes turbulence in their wakes, at scales well below the cell. It is
carried as PDRFoam's PDRkEpsilon carries it: a kinetic energy k and dissipation ε per mass,
transported with the air, made by the obstacles and dissipated:

  dk/dt = G_R / β_v − ε,
  dε/dt = 1.5 C_μ^¾ (G_R / β_v) √k / (C_4 L_obs) − C_2 ε² / k,

with the obstacles' generation per mass G_R = ½ |u| u·CT·u + C_sk β_v ν_eff A_w² |u|². The
constants are k–ε's own, C_μ 0.09 and C_2 1.92, with PDRFoam's C_4 0.1 and C_sk 0.05.
- **The equilibrium.** Where the generation holds, ε = 1.5 C_μ^¾ k^{3/2} / (C_2 C_4 L_obs), so
  the turbulence's length scale is about a tenth of the obstacles'. Through MERGE's array A, k is
  then about 0.017 |u|²: a turbulence intensity u′ = √(2k/3) of 11% of the stream.
- **What is left out.** PDRFoam's own production by the resolved shear is not used: the air
  resolves its large eddies, and its sub-grid mixing (the σ-model) models the cell-scale ones.
- **The scheme.** Each step the cell's k and ε are taken from where its gas was a step before
  (semi-Lagrangian, trilinear; a solid neighbour takes the cell's own values), which is stable
  at any Courant number. The sources are then applied over the step with each sink implicit.
- **Elsewhere.** Every cell starts with a trace (k 10⁻⁶ m²/s², ε 10⁻⁷ m²/s³). Downstream of the
  obstacles their turbulence decays as k–ε's does.

## The flame in congestion

The flame's burning velocity (docs/deflagration.md) takes three more terms in congestion:
- **The obstacle turbulence's wrinkling,** as PDRFoam's validated set-up has it (its tutorial's
  `SCOPEBlend` of Gülder's and SCOPE's correlations):
  - u′ = √(2k/3), plus PDRFoam's sub-grid Schelkin term u′_C √(û·CT·û |u|² w) (n^¼ − 1), for the
    wakes within the width w;
  - Gülder's 1 + 0.62 √(u′/S_L) u′/(ν ε)^¼;
  - SCOPE's 1.6 (K Ma)^−⅓ u′/S_L, with K = 0.157 (u′/S_L)/√(u′ l/ν) and l = 0.336 √(3/2) u′ k/ε.
    Ma is the mixture's Markstein number: the gas's own where it has one
    (`FlammableGas.marksteinNumber`, hydrogen's), otherwise propane's 3.74 from PDRFoam's SCOPE fuel
    data. Without a positive Ma, SCOPE drops out.
  - The two are blended as (Ξ_G⁻⁴ + Ξ_S⁻⁴)^−¼. ε is taken as at least C_μ^¾ k^{3/2}/Δ (turbulence
    below the grid is no larger than a cell).

  The larger of this and the sub-grid turbulence's wrinkling (Bradley's, as outside congestion)
  holds. Stage 2 used Bradley's form for the obstacle turbulence too, at its own length scale. That
  gave MERGE's array A with methane a tenth of its measured peak, so stage 3 put PDRFoam's own in
  its place.
- **The flame's folding round the obstacles,** PDRFoam's sub-grid flame-wrinkling model
  (`basicSubGrid`), which multiplies the turbulent wrinkling:

    Ξ_sub = 1 + max(2.2 √b, min(0.34 |u| / u′ √b, 1.6)) min(n, 1).

  n is the count of obstacles across the flow, N − û·ns·û. b is their blockage across it per
  square root of that count, (û·B·û)/√n, which for a uniform array is √(crossing sets) × D/p,
  whatever the cell's size. u′ here is the sub-grid and obstacle turbulence's together.
  Through MERGE's array A, Ξ_sub is up to 2.6.
- **The open share.** As in PDRFoam's b equation, the front's area is the whole cell's but its
  mixture only the open share's, so the open volume's mixture burns faster by 1/β_v.

The cellular instability's growth with radius does not multiply this in congestion: the larger of
it and the turbulent wrinkling holds, as PDRFoam's own instability term (XiEqIn/Ξ + Ξ) fades into
the turbulent one. Multiplied, it gave methane, the one gas with a measured onset, faster flames
than propane, against MERGE's twice as much from propane. The fitted factor still applies on top.

**Checks** (`CongestionTests`):
- the fields for MERGE's array A, and for a rack's tier;
- still air in and around porous cells staying still, to 10⁻⁴ m/s and 0.05 Pa, over 60 steps;
- the mass conserved to 2 × 10⁻⁶ as a 3 bar pulse crosses the cells;
- a uniform stream slowing as u₀ / (1 + ½ CR u₀ t / β_v), within 1%;
- a stream through a rack making the k and ε that PDRFoam's equations, integrated finely, give
  (within 3% and 5%), within a fifth of their equilibrium;
- the turbulence carried downstream of a rack, and decaying;
- a flame running through a lattice of 20 mm pipes at 0.1 m (6% by volume) in a 2 m channel open
  at one end burning more than ten times what it does in the open in 0.2 s;
- on cells smaller than the pitch, the counts and blockage are a pitch's, with the drag and
  generation per volume unchanged;
- MERGE's rigs' lattices and scenes.

**Not yet:**
- The face porosity is the smaller of its cells' volume porosities, not PDRFoam's own β_i from
  each direction's area blockage.
- The drag and generation are diagonal.
- PDRFoam transports the flame's wrinkling Ξ, with an extra rate of approach behind obstacles
  (`basicXiSubG`) and a flame-brush diffusion. Here Ξ is at its equilibrium.
- The obstacle turbulence has no diffusion of its own beyond the scheme's, and no
  compressibility term (−⅔ k ∇·u).
- Congestion acts on the coarse cells only: a deflagration runs without refinement, but a charge
  in congestion would see it only where its air is not refined.

## MERGE

MERGE (Modelling and Experimental Research into Gas Explosions, Mercx 1994) lit stoichiometric
methane and propane clouds at the centre of lattices of pipes along all three axes, twice as
wide as high, standing on the ground. Four of its rigs are compared here
(`CongestedRigStudy`, `blastbench merge`), each a tenth of its volume blocked:

| Rig | Width × height (m) | Pipes | Methane (barg) | Propane (barg) |
|---|---|---|---|---|
| A | 4.5 × 2.25 | 43 mm at 0.2 m | 0.74 | 1.77 |
| C | 4.5 × 2.25 | 86 mm at 0.4 m | 0.113 | 0.223 |
| E | 9 × 4.5 | 168 mm at 0.8 m | 0.183 | 0.35 |
| C* | 9 × 4.5 | 86 mm at 0.4 m | 1.04 | 2.89 |

**The data.**
- **Where the peaks come from:** Arntzen's 1998 thesis (Figure 8.6), digitised to about ±5%.
  MERGE's own tables (Mercx 1994; Popat et al. 1996) and PDRFoam's comparison with them (Puttock
  et al. 2021) are not open.
- **The geometry:** from Gexcon's MERGE validation case.
- **C\*:** Arntzen's large rig with twice E's pipes across. It is taken here as C's pipes in the
  9 m rig, which is what his labels (pipes across the rig) give. Gexcon's CS rig is not it: its
  117 mm pipes at 0.384 m would block 22%.
- **Gexcon's E with propane (L2):** 0.22–0.23 barg in the rig, against the figure's 0.35.

**The trends:** propane about twice methane, half the pitch about seven times, and twice the
size 40–60% more.

The model's peak is the largest at gauges on the ground in the rig, outside the cell the flame
is lit in. That cell burns almost at constant volume as its kernel grows to its size, whereas
MERGE's gauge 5 cm from ignition reads as the others do.

**Results** (the model's peak over the measured, methane / propane; outputs in
`/Volumes/StudioData/bombcad/merge/`):

| Cells (A, C; E, C*) | A | C | E | C* |
|---|---|---|---|---|
| 0.25 m; 0.5 m | 0.91 / 0.51 | 4.1 / 2.9 | 4.0 / 2.8 | 1.16 / 0.61 |
| 0.125 m; 0.25 m | 0.73 / 0.43 | 5.2 / 3.5 | 4.8 / 3.4 | 0.84 / 0.43 |

- **What holds:** the rigs with the finer pitch (A, C*) come within 0.43–1.16, and twice the size
  gives 1.5–1.9 times the peak (measured 1.4–1.6).
- **What does not:**
  - Those with the coarser pitch (C, E) come three to five times too high, so half the pitch gives
    about the same peak, not seven times more.
  - Propane is only 1.3–1.5 times methane.
- **Grid:** halving the cell moves each result by under a third.

**A coincidence of grid, stated plainly.** Counting the obstacles over the cell, as PDRsetFields
does, gave all eight within a factor of two on the cells above: 0.54–1.16 (A 0.96/0.55, C
0.72/0.54, E 0.70/0.55, C* 1.16/0.60). But C's and E's cells were then smaller than their pitch,
so they counted less than one obstacle, which cut their folding. The agreement came from the grid:
- On half those cells, the same model gave 0.02–0.2.
- At the same cells per pitch for every rig, it gave 0.5–14 (1.25 cells per pitch) and 2.5–32
  (2.5).

Counting over the larger of the cell and the pitch, as now, takes the collapse away.

**Why the pitch does not count.** With an array spread evenly through its cells, two rigs of the
same D/p (A and C) get the same folding (b depends on D/p) and the same turbulence: its
equilibrium k grows as (U³ CT L_obs)^⅔, and CT L_obs depends only on D/p. So the model's pitch
effect is only what Gülder's and SCOPE's correlations give the length scale, which is the other
way. PDRFoam and FLACS place each obstacle in the cells that hold it and, on cells finer than the
pitch, partly resolve the rows the flame passes; MERGE's own FLACS runs (Arntzen) used 27 cells
across a quarter rig. The flow, the turbulence and the burning also feed each other without
limit: the model's flames reach Mach 0.5–1 across the rigs.

**Against Baker–Strehlow–Tang.** BST's flame Mach numbers for free expansion (3D) at medium to
high congestion (DNV, *Obstructed Region Explosion Model – Theory*, Table 2) are 0.23–0.34 for
methane (low reactivity) and 0.44–0.5 for propane (medium). The model's mean flame speeds across
the rigs, from the arrival times at the gauges, are Mach 0.45–0.84 for methane and 0.54–1.04 for
propane. Propane's are at or above its class, and methane's about twice its class.

**The process plant.** The [process plant sample](process-plant-explosion.md) does not use
congestion, so its fitted factor (6.5) is unchanged. With its racks' pipes as congestion instead
of blocks and the factor at 1 (`ProcessPlantScene.congestedScenario`, `blastbench snapshot --preset
plant --congested`), it gives 0.01 psi at 37 m, as the model alone does, against the CSB's 2.5–2.8.
The racks' tiers stand at 4, 7 and 10 m in a cloud 6 m deep, lit on the ground between them. So
little of the congestion is in the flame's path. The unit's congestion at grade, which the CSB
describes but does not measure, is not in the layout.

**Next** (in this order):
1. A transported flame wrinkling, with PDRFoam's rates of approach (G, R) and its flame-brush
   diffusion: a lag that limits the feedback.
2. Obstacles placed in the cells that hold them where the cells are finer than the pitch.
3. A grid guideline the app advises.
