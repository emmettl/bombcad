# Air-blast model

The air solver propagates the blast wave through the air around rigid obstacles and the
deformable structure. It lives in `Sources/BlastCore/BlastSolver.swift` and
`Sources/BlastCore/Shaders/Solver.metal`.

## What it solves

The three-dimensional compressible Euler equations for an ideal gas with a constant ratio of
specific heats γ = 1.4, on a uniform Cartesian grid of cubic cells. There is no viscosity, heat
conduction or chemistry, no gravity unless [gravity](#gravity) is on, and no radiation unless
[radiative cooling](#radiative-cooling) is. The conserved variables per cell are density, three momentum
components and total energy, stored as five single-precision numbers.

## Numerical scheme

| Aspect             | Choice                                                                         |
|--------------------|--------------------------------------------------------------------------------|
| Discretisation     | Finite volume, cell-centred                                                    |
| Order              | Second order in smooth flow, first order at shocks                             |
| Reconstruction     | MUSCL–Hancock: limited slopes of the primitive variables, half-step predictor  |
| Limiter            | Generalised minmod with θ = 1.5 (θ = 1 is minmod, θ = 2 is monotonised central) |
| Riemann solver     | HLLC, with Einfeldt's wave-speed estimates from Roe averages; HLL is selectable |
| Multi-dimensions   | Dimensional splitting; the sweep order alternates x-y-z and z-y-x each step    |
| Time step          | Courant number 0.45 per sweep, ramped up over the first six steps              |
| Positivity         | Reconstruction falls back to first order where it would give negative density or pressure; density and pressure floors |

Each directional sweep is one Metal compute kernel that reads a five-cell stencil and writes
the cell's new state, so a time step is three kernel dispatches. Neighbouring cells compute the
flux through their shared face from identical inputs, which makes the scheme conservative
without storing fluxes.

**Time-step control on the GPU.** The final sweep of each step records the fastest wave speed
with an atomic maximum. A one-thread kernel at the start of the next step turns that into the
time step, advances the clock and samples the gauges. Because nothing is read back to the CPU
between steps, up to 256 steps are queued in one command buffer.

**Recorded fields.** The final sweep also accumulates, per cell, the peak overpressure and the
positive-phase impulse (the time integral of overpressure while it is positive). These are what
the app paints on the ground and on rigid blocks.

![Peak overpressure on the ground and façades of a street canyon](street-canyon-peak.png)

## Obstacles and boundaries

- Rigid blocks and the structure are voxelised into a solid mask. A block cell is solid when
  its centre is inside the block; a structure cell is solid when at least a third of it is
  filled by intact elements (see [Structural model](structural-model.md#coupling-to-the-air)).
- At a solid cell or a reflecting domain face, the stencil is filled with mirrored ghost states
  (normal velocity reversed). The Riemann problem at the wall then has zero mass flux, so walls
  are exactly conservative and can be one cell thick.
- The ground can have a shape, a heightfield [terrain](terrain.md): a cell below its surface is
  solid, on the coarse grid and every refinement level, as for a block. The floor beneath it stays
  a reflecting face.
- The ground (z = 0) is a reflecting face. The other five faces of the domain are open: the
  stencil copies the last interior cell (zero-gradient extrapolation).

## The charge

The charge is a "bursting balloon": a sphere of hot, dense gas at rest.

- Its energy is the TNT-equivalent mass times 4.184 MJ/kg (the conventional energy of TNT;
  Cooper gives TNT's heat of detonation as 4.56 MJ/kg with the water liquid, about 4.07 with it
  as vapour, and 4.69 MJ/kg as the energy that fits a large set of air-blast tests), and
  its mass is added to the air's density in the sphere.
- The sphere's radius is the physical charge radius (for a density of 1600 kg/m³) or two cells
  (two fine cells where the air is [refined](#refining-near-the-shock)), whichever is larger.
- Cells are weighted by the fraction of their volume inside the sphere, and the totals are
  normalised over fluid cells only. A charge on the ground or against a wall therefore releases
  all of its energy into the air; a charge on rigid ground behaves like a free-air charge of
  twice the mass.
- A scenario can fire several charges at once (`additionalCharges`); each is laid down the
  same way.

### Afterburning

TNT is short of oxygen: its detonation products are mostly carbon monoxide, hydrogen and
carbon, which burn when they mix with air, releasing about twice the energy of the detonation
again. With `SolverConfiguration.afterburning` on:

- The air carries two more densities, of unburnt products ("fuel") and of oxygen (23.2% of
  air by mass). They move with the gas, each leaving a cell at that cell's mass fraction
  (first-order upwind), so they stay positive and are conserved.
- Where fuel and oxygen share a cell, the fuel burns, at TNT's ratio of 0.74 kg of oxygen per
  kg (C7H5N3O6 + 5.25 O2 → 7 CO2 + 2.5 H2O + 1.5 N2), releasing 10 MJ/kg (TNT's heat of
  combustion, about 15 MJ/kg, less its heat of detonation; Cooper's afterburn heat, the same
  difference, is 566 kcal/mol, 10.4 MJ/kg, and his oxygen demand the same 5.25 mol), over a time
  τ = 10 ms × W^(1/3) (W in kg). Mixing is the grid's own: products meet air as numerical
  diffusion spreads them.
- With τ = 0 everything at the charge's edge burns in the first steps and joins the leading
  shock, as if the charge were three times heavier: arrival times come 10–25% early and the
  incident impulse 8–22% high. τ was chosen to match the incident impulse of Kingery–Bulmash
  (see [Validation](validation.md#afterburning)); 46 ms for 100 kg is of the order of the
  fireball's life.

It is off by default: it costs about 1.8 times as much (more work per step, and a shorter step
in the hotter gas). With the ideal gas it overstates pressures in rooms by about 30%; with hot
air (next) it does not.

### A finely resolved start

`SolverConfiguration.mappedCharge` starts a lone charge from a one-dimensional solution
instead of the balloon. The blast is solved with spherical symmetry (the same MUSCL–Hancock
and HLLC scheme, with the face areas 4πr² and the pressure's geometric source), on a radial
grid of a few millimetres, from a sphere of the charge's own size (TNT's density), until its
shock reaches 0.8 of the distance to the nearest block, structure or open face, at most 16
cells; a charge on the ground spreads as one of twice the mass, mirrored. The state is then
laid onto the grid (each cell averaged over 64 samples, the radial momentum turned into
vectors) and the clock set to the time that took. Gauges and cells the shock has already
passed take their histories, peaks and impulses from the one-dimensional solution.

The one-dimensional solver keeps its energy within 1% and, from a point source, spreads as
Sedov and Taylor say within 8%. On the Kingery–Bulmash comparison (on 0.5 m cells, mapped out
to 8 m) the incident peaks inside the mapped region read 116% to 131% instead of 57% to 66%:
no longer smeared, but now high, as an ideal gas expanding from the charge's own size does
next to a real explosive. Beyond the mapped region nothing changes: within a couple of metres
the grid smears the shock again as much as before (62% to 73% from 9 m out, against 62% to
69%). So it gives exact one-dimensional records close in and a correct start, but no lasting
gain in resolution; refinement of the grid near the shock (below) does that. It is off by
default, and only for a single charge, an ideal gas and no afterburning.

### Hot air

The gas left by a charge, and burnt products all the more, is at 2000 to 3000 K, where the
molecules of air store energy in vibration as well as in motion and rotation, so a joule of
heat raises the pressure less than in cold air. `SolverConfiguration.airModel =
.thermallyPerfect` includes this:

- Internal energy per kilogram is e(T) = 5/2 R T + e_vib(T), with N2 and O2 (0.79 and 0.21 by
  moles) as harmonic oscillators of characteristic temperatures 3390 K and 2270 K:
  e_vib = R Σ x θ / (exp(θ/T) − 1). Pressure is ρ R T, R = 287.05 J/(kg K).
- The temperature is found from e by two Newton steps from the temperature without
  vibration, which reach single precision from room temperature to 20,000 K. The speed of
  sound uses the ratio of specific heats at that temperature, which falls from 1.4 to about
  1.29 near 3000 K. The Riemann solver's averaged sound speed is the Roe average of the two
  sides' speeds.
- Below about 500 K it is the ideal gas within 0.1%, so tests in units where the gas is cold
  (the shock tube, the point blast) are unchanged. Dissociation, above about 2500 K, is left
  out of it; `.dissociating` (below) adds it.

It costs about a quarter more. Together with afterburning (the app's "Afterburning and hot air"
switch) it brings the closed-room gas pressure within 8% of UFC 3-340-02's at every charge
density tested, with nothing fitted to it, and keeps the incident impulse in the open within
6% of Kingery–Bulmash (see [Validation](validation.md#afterburning)).

### An extinction limit for afterburning

`SolverConfiguration.afterburnLimit` (`--burn-limit [--ignition 800] [--limit-flame 1500]` in
`blastbench`; off by default) lets the products burn only where the mixture can keep a flame
going. The burning rate above the limit stays as it was: mixing-limited, as in Kuhl, Ferguson and
Oppenheim's account of TNT's afterburning. Two conditions:
- **ignition:** the cell must be at least 800 K, where Dryer and Glassman's global rate for the
  oxidation of carbon monoxide, the products' main fuel, becomes faster than the gas mixes;
- **flammability:** burning all the fuel its oxygen allows must take the cell to 1,500 K, about
  the flame temperature of mixtures at their flammability limits (Zabetakis). This is a lean
  limit and a rich one at once, and it widens as the mixture warms, as real limits do.

It is compiled in only when on, and changes nothing in a [deflagration](deflagration.md), which
never shares a run with afterburning. `AfterburnLimitTests` checks it:
- cold products in air do not burn, nor warm ones too dilute to reach the limit flame
  temperature;
- hot or rich ones do;
- what burns is what the gas gains.

**It moves the blast it was meant to leave alone, and does not cool the fireball.** With
afterburning and hot air, on 0.25 m cells:
- *Closed rooms* (UFC 3-340-02) are as before, 98–107% of the design curve: their gas is hot and
  dense enough to burn anyway.
- *In the open* the incident impulse beyond 1 m/kg^⅓ falls by 8–9%, from 94–100% of
  Kingery–Bulmash to 86–91%, the reflected impulse by up to 8.5% and the peaks by about 2%. Part
  of the burning that feeds the blast is in mixtures the limit calls too cool or too dilute.
- *A shorter burning time* restores the open impulse but not the rooms: 6 ms × W^⅓ gives 92–99%
  in the open and 104–114% in rooms, and 4 ms gives 98–109% and 107–117%.

So no refit holds both, and the fitted 10 ms stays. The fireball's luminous gas is no cooler
with it, because the fireball's hot core burns anyway (see
[Dial Pack](thermal-radiation.md#against-dial-pack)).

### Dissociating air

`SolverConfiguration.airModel = .dissociating` (`--air dissociating` in `blastbench`) is
thermally perfect air whose N2 and O2 also split into atoms once hot, in equilibrium, as
Lighthill's ideal dissociating gas:

- For each species, the fraction α of its molecules dissociated satisfies
  α² / (1 − α) = (ρ<sub>d</sub> / ρ<sub>s</sub>) exp(−θ<sub>d</sub> / T), ρ<sub>s</sub> being
  the species' own density: θ<sub>d</sub> = 113,000 K and ρ<sub>d</sub> = 130 g/cm³ for N2,
  59,500 K and 150 g/cm³ for O2 (Vincenti and Kruger, written from memory). At atmospheric
  pressure O2 is then 41% split at 3500 K and 79% at 4000 K, and N2 51% at 7000 K.
- Atoms carry 3/2 R T each, the molecules split take up the bond's energy, R θ<sub>d</sub> per
  kilogram of molecules, and the pressure is ρ T Σ y R (1 + α) over the species' mass
  fractions y (0.767 and 0.233).
- The temperature is found from the energy, or from the pressure, by Newton's method from the
  temperature of air that does not dissociate, which lies above it. The speed of sound uses
  the frozen ratio of specific heats, at the composition as it stands.

It changes little that has been checked. Every incident and reflected peak, impulse and
arrival time of the Kingery–Bulmash comparison, from 0.75 m/kg^(1/3) out, with afterburning,
moves by under 1%; closed rooms' gas pressure, 98–108% of UFC 3-340-02 with thermally perfect
air, becomes 92–107%, the densest rooms coming down by about 6% (their gas is the hottest).
It costs 3.6 times as long as thermally perfect air. It is therefore an option, not part of
the app's "Afterburning and hot air" switch. Where it would matter, within a charge diameter
or two, the products, still treated as air, and the cells, which resolve no detail of the
fireball, matter more.

### Radiative cooling

`SolverConfiguration.radiativeCooling` (`--radiate` in `blastbench`; off by default) takes from
the luminous gas the heat it radiates. Every fourth step, each cell at least 1,500 K hot absorbs
and emits as the [thermal radiation's volume](thermal-radiation.md#the-gas-losing-what-it-radiates)
takes it to, grey gas and the unburnt products' soot; the radiance is carried through the box
round those cells along the lattice's 26 directions, and each cell loses what it emits less what
it absorbs, κ(4πB − G), exactly what the beams carry away (the discrete transfer method of
Lockwood and Shah). It is a source in the energy equation, taken after the step's sweeps, so it
touches no flux; refined cells lose what their coarse cell loses a volume, which keeps the levels
conservative across their edges. The energy radiated is kept as `BlastSolver.radiatedEnergy`.

With afterburning and hot air it moves every Kingery–Bulmash incident and reflected impulse by
0.2% or less and every peak by 0.4% or less, and lowers a closed room's gas pressure after 80 ms by
2% to 4%, the heat the walls take; the street's fireball then radiates 12.8% of the charge's
energy by 170 ms rather than 21%. It costs about 5% more a step, and saves about as much in
steps, the cooler gas allowing longer ones.

### Gravity

`SolverConfiguration.gravity` (`--gravity [--lapse 6.5]` in `blastbench`; off by default) pulls
the air down at 9.81 m/s². The air then starts at rest in a hydrostatic atmosphere, its pressure
and density falling with height as the temperature does, at the standard atmosphere's 6.5 K/km
(as the [cloud's rise](fireball-rise.md) assumes) or, with a lapse rate of 0, isothermally. For a
blast it changes nothing; it lets hot gas rise.

**Well balanced.** Gravity's pull on air at rest is balanced by a pressure gradient that a scheme
of this kind reproduces only to its truncation error, so a plain source term would set the
resting atmosphere moving at millimetres a second. As atmospheric codes do (Botta, Klein and
others; Käppeli and Mishra; and the perturbation form of Giraldo and Restelli), the vertical sweep
works on each cell's deviation from the background:
- the slopes and the Hancock predictor are the deviations', with the background's own gradient,
  and gravity's pull on the deviation, in the predictor;
- each face carries the background at the face plus the reconstructed deviation;
- the background's pressure at the face is left out of the momentum flux, and gravity's pull on
  the background out of the source, which is −g(ρ − ρ_b);
- the energy gains −g times the mean of the cell's two faces' mass fluxes, so the gas's energy
  and its potential energy are conserved together, and refluxing corrects that term where the
  refined levels' fluxes replace the coarse one.

Air at rest in the background has no deviation, so its fluxes and its sources are zero exactly.
Getting that to the bit took three things:
- the background is worked out once for each level into a table, since the same expressions
  compiled into two kernels can differ in their last bit;
- a face whose two sides are identical takes the physical flux, which HLLC gives only to
  rounding;
- refined cells and their ghosts are filled with the coarse cells' deviations plus their own
  background.

Fine air under solid coarse cells, as over [terrain](terrain.md), takes the background at its
height. Gravity is compiled into the kernels only when on, so with it off they are unchanged:
`blastbench digest` gives the same hashes as before, with and without refinement.

**Checked** (`GravityTests`):
- Air at rest stays at rest to the bit for 200 steps: isothermal or cooling with height, ideal
  or thermally perfect, refined in two levels everywhere, and in a closed box over a hill.
- Its pressure 63.5 m up is the barometric formula's to 10⁻⁵.
- In a closed box a hot bubble's rise conserves the gas's energy and potential energy together
  to 10⁻⁶.
- A sphere of air twice as hot as its surroundings first accelerates at 90% of potential flow's
  g Δρ / (ρ + ρₐ/2), a sphere 8 cells in radius.

Followed for 20 s (`blastbench bubble`, a 4 m bubble at 576 K on 0.5 m cells), the bubble rises
as the cloud's integral model of a turbulent thermal says: its warm gas's centre is 13.2 m up at
2 s against 13.0, and 54.5 m at 20 s against 49.7, rising at 1.55 m/s against 1.41. Against
Kingery–Bulmash (0.5 m cells refined) every incident and reflected peak and impulse moves by
0.1% or less: on a blast's time scale gravity is nothing.

**Around it:**
- *Still air is skipped* as without gravity: still air is air at rest in the background at its
  height, which a sweep leaves to the bit, so the answer is the same as sweeping everything
  (`GravityTests` checks the street with afterburning). Skipped air counts towards the time step
  at the ground's sound speed, the column's fastest, which sets the step only while nothing
  moves.
- *Overpressure* (peaks, impulses, gauges and the air's sleep test) is measured against the
  ambient pressure at its own height, so air at rest records none anywhere. Exposure planes and
  envelopes still take the ground's.
- *In the app*, **Gravity in the air** in the Run tab's charge settings turns it on; it is saved
  with the project only when on, so projects and runs saved before it are unchanged.
- *The cloud's hand-over* relaxes each plane's gas to the ambient pressure at its height and
  judges its warmth against the air there, so gas the air model has lifted is handed over as it
  stands, and the hand-over can come later, after the air model itself has carried the
  fireball's first rise.
- *Not done*: the HLL solver balances only to rounding, and the experimental moving boxes have
  not been tried with it.

It costs about a fifth more a step (the street with afterburning to 170 ms: 11.2–11.4 s against
9.5 s).

### Sub-grid mixing

`SolverConfiguration.mixing` (`--mixing [--smagorinsky 0.17]` in `blastbench`; off by default)
lets the turbulence the grid cannot resolve carry momentum, heat and the products and oxygen.
Before each step every cell gets an eddy viscosity after Smagorinsky, ν = (C Δ)² |S|:
- |S| is the resolved rate of strain, and C = 0.17 is Lilly's value for the inertial range;
- Ducros's sensor, (∇·u)² / ((∇·u)² + |∇×u|²), switches it off where the flow is compression
  without rotation, so a shock keeps the scheme's own dissipation.

In each sweep, conservative face fluxes add −ρν ∂v/∂x of momentum, its work, and −ρ(ν/Pr) ∂h/∂x
of heat and ∂Y/∂x of each species, with Pr = Sc = 0.7. The face's ν is held under a quarter of
Δx²/Δt, so the explicit diffusion stays stable. Refined cells take their coarse cell's ν scaled
as an inertial range's, (Δ_fine/Δ_coarse)^(4/3). Like gravity, it is compiled in only when on.

**Checked** (`MixingTests`):
- In a closed box a swirling hot bubble keeps its mass and energy to 10⁻⁶.
- A planar shock passes with its pressures changed by under 10⁻⁴.
- A shear layer spreads faster with it than without.
- Against Kingery–Bulmash (0.5 m cells refined), peaks move by 0.3% or less and impulses by
  0.3% or less, with afterburning and hot air 0.45% and 0.2%.

It costs about 28% more a step (the street to 170 ms: 13.6–13.8 s against 10.5–10.9 s).

**It changes little that the grid resolves.**
- *A temporal mixing layer* (`blastbench mixinglayer`: ΔU 50 m/s, momentum thickness θ₀ two
  0.5 m cells, a box periodic in x and y) grows at 0.030 ΔU with it or without it, while θ goes
  from 2.5 to 10 m. Rogers and Moser's self-similar layer grows at 0.014 ΔU; layers measured
  in experiments, at 0.016 to 0.018. Over the first transition the model slows the growth a
  little (0.015 against 0.021 ΔU in a shorter box), as Smagorinsky models are known to.
- *The 4 m hot bubble* above rises to 55.2 m at 20 s against 54.4 m without it, both within 11%
  of the integral model of a thermal that entrains at Morton, Taylor and Turner's α = 0.25.

So on these cells the large eddies the grid resolves, and the scheme's own dissipation, do the
mixing.

**The σ-model, an option** (`SubgridMixing.model = .sigma`, coefficient 1.35). Nicoud et al.'s
(2011) operator σ₃(σ₁ − σ₂)(σ₂ − σ₃)/σ₁², from the singular values of the velocity gradient,
replaces |S|. It is zero wherever the resolved flow is one- or two-dimensional, axisymmetric, a
pure shear or a rigid rotation. So the laminar flow round a growing flame, an irrotational
spherical expansion that Smagorinsky's |S| takes for turbulence, gets none (`MixingTests`; on the
grid's differences a point source's flow keeps a share of Smagorinsky's that falls as (Δ/r)², a
quarter at five cells and a twelfth at ten). A [deflagration](deflagration.md#the-burning-velocity)
with flame turbulence turns it on and takes its sub-grid velocity from it, so the flame and the
air share one sub-grid model. Charges keep Smagorinsky's, bit for bit.

## Skipping still air

## Skipping still air

Air the blast has not yet reached is in exactly the uniform state it was filled with, and a
sweep leaves such a cell unchanged when every cell its update reads is in that state too. So
the grid is cut into tiles of 8 × 8 × 8 cells, and only the awake tiles are swept:

- A cell's update reads two cells either side along the sweep, so in one step (three sweeps)
  a change spreads at most two cells along each axis.
- After each step, a cell that differs from the uniform state by any amount wakes every tile
  within two cells of it. A tile is therefore awake before any change can reach its cells.
- At a restart, the tiles near every cell not in the uniform state are woken, and so are the
  tiles around a structure, where the moving mask and the debris trade with the air.
- Tiles never go back to sleep, and both state buffers start alike, so a skipped tile holds
  exactly the uniform state.
- Skipped air still counts towards the time step, with exactly the wave speed a sweep would
  have recorded for it.

The answer is therefore identical to the last bit; tests compare a street scene and a wall
broken by the blast with and without skipping, cell by cell. The list of awake tiles is built
on the GPU before each step and the sweeps are dispatched indirectly, so stepping still needs
no round trip to the CPU. Only the peak overpressure and impulse of air the blast never
reached can differ, by the rounding error that still air reads as overpressure (under 0.1 Pa).
`SolverConfiguration.skipStillAir` switches it off.

## Refining near the shock

A captured shock is smeared over two or three cells, so peak pressures read low unless the cells
are small, and a grid fine everywhere costs eight times as much for each halving.
`SolverConfiguration.refinement` (2 or 4; off by default) refines the air only where the shock
is, in one level or, with `refinementLevels` 2, in two (below). In the app it is the "Sharpen
shocks" switch (ratio 2) and, under it, "Twice over again" (two levels); `blastbench` takes
`--refine 2` and `--refine-levels 2`. The code is `Sources/BlastCore/Refinement.swift` and
`Shaders/Refine.metal`.

- **Where.** The grid is cut into blocks of 4 × 4 × 4 cells. A block is refined where the
  pressures of two neighbouring cells in it differ by more than `refinementThreshold` (10%) of
  the lower, and so is any block within two cells of such a pair: a shock moves under half a
  cell a step, and the blocks are placed afresh every step, so it cannot outrun them. Each
  refined block is a patch of (4r)³ fine cells, taken from a pool of fixed size
  (`refinementMemory`, 1 GB by default, about 63 kB a patch at ratio 2 and 364 kB at ratio 4).
  Where the shock would need more, the rest of it stays coarse.
- **Each coarse step:** the coarse cells around each patch are saved; the coarse grid is swept
  as usual, and every coarse cell beside a patch records the flux it used through their shared
  face; each patch takes r steps of its own of a coarse step / r, alternating the order of its
  sweeps, with two layers of ghost cells filled before each sweep from the neighbouring patch or,
  in unrefined air, from the coarse cells (limited linear in space, linear in time between the
  step's start and end); each coarse cell beside a patch then has the difference between the
  fine fluxes through their face and its own put right (refluxing), so mass, momentum and
  energy are conserved across the level's edge; each coarse cell under a patch becomes the mean
  of its fine cells; and the patches are placed afresh, new ones filled from the coarse cells.
- **The outline.** Fine cells have their own solid mask, at their own resolution: a fine cell
  is solid where its centre lies in a rigid block (or, where the mask was set by hand rather than
  from blocks, where its coarse cell is solid), or where a deformable structure fills a third of
  it, the structure's elements sampled at points no further apart than a fine cell and its shells
  and beams at half one. A fine cell that opens takes the mean of the fluid fine cells beside it.
  A coarse cell under a patch becomes the mean of its fluid fine cells. Refluxing does not ask
  what the coarse cell inside is: a coarse cell beside a patch records the flux it used, through
  fluid or wall, and the fine level gives the flux of every fine face, the wall's where the fine
  cell is solid. A ghost cell takes its kind, fluid or wall, from the fine outline of the patch
  that holds it, and only where no patch does from the coarse mask, so that the two sides of a
  fine face always agree. Where the two outlines differ, a new patch shares the gas of a coarse
  cell among those of its fine cells that are fluid, and fills fine cells that are fluid under a
  solid coarse cell with still air; such a patch is never released, since its gas could not be
  given back to the coarse cells. So a closed room with a block offset by a quarter of a cell
  gains still air once, 0.4% of its mass and energy, as patches go down along the block's faces,
  and conserves them to 10⁻⁴ from then on (where the outlines agree they are conserved to
  rounding).
- **Afterburning.** The fine cells carry their own fuel and oxygen as the coarse cells do:
  carried by the fine mass fluxes at the mass fraction of the cell they leave (a ghost from
  unrefined air at its coarse cell's fractions), burnt after each substep's final sweep,
  refluxed across the level's edge with the gas, averaged back into the coarse cells, and filled
  into new patches at the coarse cell's fractions, so that the fine cells' mean is the coarse
  cell's. In a closed room, mass, energy less the heat the fuel left will release, and oxygen less
  what that fuel will take are each conserved to 10⁻⁴. The fuel and oxygen take 8 bytes a fine
  cell, and a patch's share of the pool grows by about a fifth; without afterburning they take
  nothing.
- **The charge.** With refinement the charge is laid on the fine cells, its sphere two fine
  cells across at least, and the patches around it are placed before the first step. Laid on
  the coarse cells, it was a blocky cube of gas that the fine cells then resolved, and near the
  charge the peaks ran up to 30% above those of the uniform grid twice as fine.
- **What it records.** A coarse cell's peak overpressure is the largest its fine cells reach, and its impulse is what it had
  when the patch was placed plus the largest any of its fine cells has gathered since: in open
  air its fine cells agree, and against a wall, where impulse falls off steeply, it reads the
  wall's value as a coarse cell beside a wall does. A gauge reads the fine cell holding its
  point.
- **Around a deformable structure.** Each face of the structure is loaded by the first fluid
  fine cell beyond it, where the air is refined, not by the mean of a coarse cell: against a
  wall the pressure changes too steeply for that mean to stand for it. A fine cell in a moving
  solid's coarse cell mirrors the gas about the solid's speed, as a coarse cell does. After the
  structure's substeps, what it changed in the coarse cells under the patches is carried into
  their fine cells: the momentum and energy debris trades with the air are
  added evenly to each fluid fine cell (a cell nothing touched is left exactly as it was); the
  structure's own outline in the fine cells follows it as above, each solid fine cell moving with
  the mean velocity of the structure in it.
- **A second level.** With `refinementLevels` 2 the blocks of 4 × 4 × 4 fine cells that the
  shock crosses are refined again, by the same ratio, so that at the shock the cells are r² times
  finer than the coarse ones. The second level sees the first as the first sees the coarse grid,
  its parent: each of its steps is r substeps taken within one substep of the first level, after
  that substep's sweeps; its ghost cells come from a patch of its own or from the first level's
  cells, between their state at the start and the end of that substep; the first level's cells
  beside its patches record the fluxes they used, which its own then replace; and the first
  level's cells under its patches become the mean of its fluid cells, before the first level's
  own are averaged into the coarse cells. A block of the first level's cells is refined where two
  neighbouring cells of the first level differ by `refinementFinerThreshold` (by default the same
  10%), and only where the first level's patches hold every cell within two of it: so the second
  level never meets the coarse grid, and the first level is kept wherever the second wants or
  keeps a block, so that neither is released from under the other. It has its own outline (rigid
  blocks, and the structure counted at its own resolution, its points no further apart than one
  of its cells), loads a deformable structure from its cells beside the faces, carries the debris'
  trade from the first level's cells, and carries afterburning's fuel and oxygen, all as the
  first level does. Its patch list, cells, outline and structure counts lie in the first level's
  buffers after the first level's own, which lets the structure's kernels, whose buffer slots are
  all taken, reach both. A third of `refinementMemory` goes to the first level and two thirds to
  the second, whose blocks are an eighth the volume; at the shock it needs four to six times as
  many. A gauge reads the finest cell holding its point.
- **Exactness.** It is all done on the GPU, with no round trip to the CPU between steps, and
  every sum runs in a fixed order: runs repeat exactly, uniform air refined everywhere stays
  exactly uniform, and mass and energy in a closed box are conserved to rounding (within 10⁻⁴,
  as without refinement), with one level or two. When a pool is used up, the blocks asking for a
  patch get them in the order of the blocks, by a sum over them, so that a full pool refines the
  same blocks every run; until then the last patches went to whichever threads asked first,
  which conserved the gas but made a run that filled the pool differ from run to run. A centred
  burst stays mirror-symmetric to 10⁻⁶ until rounding tips the threshold for one block and not
  its mirror image; from then on the two sides are solved on different grids and differ by up
  to about 1%.

On Sod's shock tube, refinement by 2 takes the error two-thirds of the way to that of a grid
twice as fine. On the Kingery–Bulmash comparison a grid refined by 2 gives the peaks and
impulses of a uniform grid twice as fine, in half the time or less; refined in two levels by 2,
those of a grid four times as fine, in a quarter of its time or less, and 1.2 to 1.4 times faster
than refined by 4 in one level, which gives the same. Close in, 40 mm cells refined in two levels
give the reflected impulse of 10 mm cells within 1% (see
[Validation](validation.md#with-refinement), [close in](validation.md#close-in) and
[Performance](performance.md#refinement)). One level stays the default, and "Sharpen shocks" one
level by 2: on the same coarse cells a second level costs five to seven times as much again
(8.1 s against 1.6 s for the open-ground event on 0.5 m cells).

**How it got here.** The first version refined whole tiles of still air (8 × 8 × 8 cells) and
every tile around a flagged one, and was slower than the uniform grid it imitated: a sphere cuts
through many cubes, and with cubes that size the refined shell was 5 to 6 m thick around a shock
a metre wide. Blocks of 4 cells, widened only towards the shock, halved it; moving the ghost
cells' coarse interpolation out of the fine sweep into a kernel of its own made each fine
update about 1.6 times the cost of a coarse one instead of three. Refinement pays roughly in
proportion to the blast's radius over three times the refined shell's thickness, so it pays
more the further the blast has spread. And the reflected impulse on a wall first read 10% low:
the coarse cell's mean over its fine cells, which against a wall dilutes the wall's value with
that of the cells behind it; the solution itself was right. Around the chamber's walls
(see [Validation](validation.md#an-internal-explosion-in-a-reinforced-concrete-chamber)) the
refined air first lost 15% of its energy and the roof rose half as far: ghost cells took their
kind from the coarse mask even inside a neighbouring patch, so where the fine outline differed
the two sides of a face disagreed on whether it was a wall.

The threshold decides how far out the refinement follows a shock: at the default 0.1 to about
20 kPa, at 0.005 beyond 40 m/kg^(1/3), after which the peak falls to the coarse cells' share (see
[Large scenes](large-scenes.md#against-kingerybulmash-to-40-mkg13)).

## Freezing the air

When a deformable structure is present, the air is frozen (its sweeps are skipped) once either
no cell is more than 2 kPa from ambient pressure, or five acoustic crossing times of the domain
have passed, as checked every 64 steps (so that when it happens depends only on the step count,
not on how the steps were batched). The structure then advances alone at its own time step. The second condition
exists because a collapsing structure keeps disturbing the air near it through the moving solid
mask, so the pressure test alone may never be met. The threshold is not lower because the
winds left behind by a blast die away slowly: a second after a 50 kg charge, some cells were
still 0.8 kPa from ambient.

## Verification and validation

See [Validation](validation.md). In brief: the scheme reproduces Sod's shock tube, a reflected
normal shock and the Sedov–Taylor blast, and conserves mass and energy exactly in a closed box.
Against the Kingery–Bulmash curves for a surface burst, from 0.75 to 6 m/kg^(1/3), the impulse
on a rigid wall is within 6% on 0.25 m cells beyond 1.5 m/kg^(1/3) and within 6% everywhere on
0.125 m cells; the incident impulse is 13% to 22% low on every grid; and peak pressures are
under-resolved (76% to 82% of the incident peak on 0.25 m cells, improving with resolution).
In a closed room the gas pressure left after the shocks is 48% to 114% of the design curve of
UFC 3-340-02, lowest for light charges.

## Limitations

1. **The source model is crude.** An ideal-gas balloon with γ = 1.4 ignores the detonation
   wave and the real equation of state of the detonation products. It is poor within a few
   charge diameters, or a few cells, of the charge. By default (no afterburning, an ideal gas)
   it under-predicts incident impulse by 13% to 22% at all ranges tested, and a closed room's
   gas pressure is half the design value for light charges. With afterburning and hot air the
   incident impulse is within 6% beyond 1 m/kg^(1/3) and rooms within 8%, but the burning time
   is fitted, mixing is numerical, the products are treated as air, and dissociation is an
   option that changes little.
2. **Shocks are smeared over two or three cells**, so peak overpressure is under-predicted near
   the charge, where the wave is thin compared with a cell. Impulse is much less affected.
   Refinement (above) gives the peaks of a grid twice or four times as fine, in one level, or four
   times as fine in two; there are no more than two levels.
3. **Open boundaries reflect a little.** They copy the state inside outward (zero-gradient,
   or "transmissive"), which is not exactly non-reflecting. Measured: for 50 kg at the surface,
   a gauge 13 m away and 5 m inside a truncated boundary differs from the same gauge in a long
   domain by at most 1.2 kPa against a 61.5 kPa peak (2%), all of it in the negative phase,
   and its positive impulse by 1.3%. Keep gauges and structures a few metres inside open faces.

   A characteristic far-field condition (the incoming Riemann invariant taken from still air)
   was tried and was much worse: in a split scheme it treats each face as if waves met it head
   on, and a blast running along a side or top boundary, with full overpressure and almost no
   flow through it, was turned into a strong spurious outflow that doubled the impulse at the
   gauge.
4. **One gas.** Detonation products are treated as air: by default as an ideal gas of γ = 1.4,
   or as thermally perfect air, so the fireball's composition, and its temperature, are not
   realistic. It loses the heat it radiates only with radiative cooling on, and then only above
   the luminous temperature, as a grey gas with soot, into black, cold surroundings.
5. **Moving solids are a staircase of whole cells.** A moving wall pushes the gas through its
   ghost states, and its surface jumps a cell at a time. The gas is conserved within 0.3% as it
   does; see the structural model's coupling notes.
6. **Single precision.** Pressure differences well below a pascal are lost in rounding against
   ambient pressure, which is harmless for blast but rules out acoustics.

## Future work

- **The products' own composition** for the gas very close to a charge. (Dissociation of the
  air is done, as an option; it changes the checked loads by under 1%.)
- **Better source.** Two options, in order of effort: start from a one-dimensional, finely
  resolved spherical solution and map it onto the grid once the shock has grown to several
  cells; or carry the detonation products as a second gas with a Jones–Wilkins–Lee equation of
  state and optional afterburn energy.
- **Better open boundaries**, if they are ever needed: a perfectly matched or sponge layer
  works at any angle, unlike the one-dimensional characteristic condition that was tried.
- **More of the refinement**: patches placed and released over a fine outline without the gas
  they move between grids being gained or lost. Smaller blocks were weighed and would gain
  little (see [Performance](performance.md#refinement)): the cost is set by the area of the shock.
  A third level, or a second whose blocks follow only the strong shock near the charge
  (`refinementFinerThreshold`), are untried.
- **Cut cells**, so that moving solid surfaces need not follow cell faces (see the structural
  model's future work).
- **Burning in flame sheets rather than the bulk**: on metre cells the grid mixes a fireball's
  products and air through its whole volume, so it burns throughout near the flame temperature,
  where a real one burns in thin sheets round a fuel-rich core. Sub-grid mixing and an extinction
  limit, tried for this, change it little (see [Dial Pack](thermal-radiation.md#against-dial-pack));
  a mixture-fraction flame model might. Paused for now, with the fireball's radiation.

## Sources

- P. W. Cooper, *Explosives Engineering*, Wiley-VCH, 1996. TNT's heats of detonation
  (Table 9.4, p. 132; 1,090 cal/g with the water liquid, p. 161) and combustion (Table 9.3,
  p. 130), its afterburn heat and oxygen demand (§9.6, pp. 132–133), the energy that fits
  air-blast tests (1,120 cal/g, pp. 384 and 406), the yield a surface burst gains from real
  ground (160–180%, p. 407), and the residual pressure of a charge burnt in a closed vessel
  (pp. 153–158). Read from a scan.

- F. C. Lockwood and N. G. Shah, "A new radiation solution method for incorporation in general
  combustion prediction procedures", *18th Symposium (International) on Combustion*, 1981,
  1405–1414. The discrete transfer method behind the radiative cooling; M. F. Modest,
  *Radiative Heat Transfer*, Academic Press, for the radiation's term in the energy equation.
- A. L. Kuhl, R. E. Ferguson and A. K. Oppenheim, "Gasdynamics of combustion of TNT products
  in air", *Archivum Combustionis* 19 (1999) 67–89: afterburning limited by mixing. F. L. Dryer
  and I. Glassman, "High-temperature oxidation of CO and CH4", *Symposium (International) on
  Combustion* 14 (1973) 987–1003: the global rate behind the ignition temperature. M. G.
  Zabetakis, *Flammability characteristics of combustible gases and vapors*, US Bureau of Mines
  Bulletin 627, 1965: flammability limits and the flame temperatures at them.
- J. Smagorinsky, "General circulation experiments with the primitive equations", *Monthly Weather
  Review* 91 (1963) 99–164; D. K. Lilly, "The representation of small-scale turbulence in
  numerical simulation experiments", IBM Scientific Computing Symposium on Environmental
  Sciences, 1967; F. Ducros and others, "Large-eddy simulation of the shock/turbulence
  interaction", *Journal of Computational Physics* 152 (1999) 517–549. The eddy viscosity, its
  coefficient, and the sensor that keeps it out of shocks.
- M. M. Rogers and R. D. Moser, "Direct simulation of a self-similar turbulent mixing layer",
  *Physics of Fluids* 6 (1994) 903–923; B. R. Morton, G. I. Taylor and J. S. Turner, "Turbulent
  gravitational convection from maintained and instantaneous sources", *Proceedings of the Royal
  Society A* 234 (1956) 1–23. The mixing layer's growth and a thermal's entrainment.
- N. Botta, R. Klein, S. Langenberg and S. Lützenkirchen, "Well balanced finite volume methods
  for nearly hydrostatic flows", *Journal of Computational Physics* 196 (2004) 539–565; R. Käppeli
  and S. Mishra, "Well-balanced schemes for the Euler equations with gravitation", *Journal of
  Computational Physics* 259 (2014) 199–219; F. X. Giraldo and M. Restelli, "A study of spectral
  element and discontinuous Galerkin methods for the Navier–Stokes equations in nonhydrostatic
  mesoscale atmospheric modeling", *Journal of Computational Physics* 227 (2008) 3849–3877. Gravity
  balanced against a hydrostatic background, and the deviations from it.
- E. F. Toro, *Riemann Solvers and Numerical Methods for Fluid Dynamics*, 3rd ed., Springer,
  2009. The MUSCL–Hancock scheme, slope limiting and the HLL and HLLC solvers.
- E. F. Toro, M. Spruce and W. Speares, "Restoration of the contact surface in the HLL-Riemann
  solver", *Shock Waves* 4, 1994. HLLC.
- B. Einfeldt, "On Godunov-type methods for gas dynamics", *SIAM Journal on Numerical
  Analysis* 25(2), 1988. Wave-speed estimates.
- G. A. Sod, "A survey of several finite difference methods for systems of nonlinear hyperbolic
  conservation laws", *Journal of Computational Physics* 27, 1978. The shock-tube test.
- L. I. Sedov, *Similarity and Dimensional Methods in Mechanics*, Academic Press, 1959. The
  point-blast solution.
- H. L. Brode, "Numerical solutions of spherical blast waves", *Journal of Applied Physics*
  26(6), 1955. Blast from a sphere of hot gas, the idea behind the balloon source.
- G. F. Kinney and K. J. Graham, *Explosive Shocks in Air*, 2nd ed., Springer, 1985. The
  free-air overpressure and impulse formulae (equations 6-2 and 6-12) used for validation,
  both checked against the book.
- C. N. Kingery and G. Bulmash, *Airblast Parameters from TNT Spherical Air Burst and
  Hemispherical Surface Burst*, ARBRL-TR-02555, US Army Ballistic Research Laboratory, 1984;
  and M. M. Swisdak, *Simplified Kingery Airblast Calculations*, Naval Surface Warfare Center,
  1994. The reference for design practice; Swisdak's polynomials for a hemispherical surface
  burst are in `KingeryBulmash.swift`.
- United Nations Office for Disarmament Affairs, *International Ammunition Technical
  Guidelines*, IATG 01.80, "Formulae for ammunition management", 3rd ed., 2021, Table 5.
  Three worked Kingery–Bulmash examples, an independent check on the polynomials.
- US Department of Defense, UFC 3-340-02, *Structures to Resist the Effects of Accidental
  Explosions*, 2008. Peak gas pressure in a closed room (Figure 2-152), digitised in
  `UFC340.swift`.
- The vibrational energy of a harmonic oscillator and the characteristic vibrational
  temperatures of N2 (3390 K) and O2 (2270 K), as in any text on statistical thermodynamics,
  for example J. D. Anderson, *Hypersonic and High-Temperature Gas Dynamics*, 2nd ed., AIAA,
  2006, chapters 11 and 16. The temperatures were written from memory.
