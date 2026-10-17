# Congestion below the grid

Pipes, bars and vessels too small for the air's cells, in a plant's racks or a test rig's
lattice, change a gas explosion. Each row a flame passes through stretches it and stirs the gas
ahead, so its speed grows row by row, to hundreds of metres a second. The model treats them as
industry codes do (FLACS; Shell's model as OpenFOAM's PDRFoam): as a porous, resisting medium in
each cell. It is being built in stages, after [the proposal](congestion-proposal.md):

1. **The obstacles and the porous flow** (built, 17 October 2026).
2. **The turbulence they make and the flame's folding** (built, 17 October 2026).
3. **Validation** against MERGE's rigs, the Baker–Strehlow–Tang flame speeds and Texas City (to
   come).

Until stage 3 holds, the process plant sample keeps its fitted factor.

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
  the cell's width, the largest of the three. For a uniform array it is the diameter, once a cell
  holds a pipe or more of each set; a cell's size where there are too few obstacles.
- **their counts and blockage, for the flame's folding:** the count N of obstacles crossing the
  cell, (Δ/p)² for each set, and of those along each axis, ns, less what all three share (as
  PDRsetFields does); and the area blockage across each axis, B, (crossing sets) × D Δ / p², with
  bars counted at their larger drag.
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
- **The obstacle turbulence's wrinkling,** by Bradley's correlation as the sub-grid turbulence's,
  1.48 a (u′/S_L)^½ (L/δ)^{1/6}. Here u′ = √(2k/3) and L = C_μ^¾ k^{3/2}/ε, the turbulence's own
  length scale, at most a cell. Bradley's form grows as (u′ L^{1/3})^½, so the two wrinklings add
  as their squares.
- **The flame's folding round the obstacles,** PDRFoam's sub-grid flame-wrinkling model
  (`basicSubGrid`), which multiplies the turbulent wrinkling:

    Ξ_sub = 1 + max(2.2 √b, min(0.34 |u| / u′ √b, 1.6)) min(n, 1).

  n is the count of obstacles across the flow, N − û·ns·û. b is their blockage across it per
  square root of that count, (û·B·û)/√n, which for a uniform array is √(crossing sets) × D/p,
  whatever the cell's size. u′ here is the sub-grid and obstacle turbulence's together.
  Through MERGE's array A, Ξ_sub is up to 2.6.
- **The open share.** As in PDRFoam's b equation, the front's area is the whole cell's but its
  mixture only the open share's, so the open volume's mixture burns faster by 1/β_v.

The cellular instability's growth with radius and the fitted factor still apply on top. Stage 3
validates the whole against MERGE and sets the factor back to 1.

**Checks** (`CongestionTests`):
- the fields for MERGE's array A, and for a rack's tier;
- still air in and around porous cells staying still, to 10⁻⁴ m/s and 0.05 Pa, over 60 steps;
- the mass conserved to 2 × 10⁻⁶ as a 3 bar pulse crosses the cells;
- a uniform stream slowing as u₀ / (1 + ½ CR u₀ t / β_v), within 1%;
- a stream through a rack making the k and ε that PDRFoam's equations, integrated finely, give
  (within 3% and 5%), within a fifth of their equilibrium;
- the turbulence carried downstream of a rack, and decaying;
- a flame running through a lattice of 20 mm pipes at 0.1 m (6% by volume) in a 2 m channel open
  at one end: it burns 99% of the cloud in 0.2 s, against 1.5% in the open (the test asks for ten
  times).

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
