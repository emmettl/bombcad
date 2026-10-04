# Air-blast model

The air solver propagates the blast wave through the air around rigid obstacles and the
deformable structure. It lives in `Sources/BlastCore/BlastSolver.swift` and
`Sources/BlastCore/Shaders/Solver.metal`.

## What it solves

The three-dimensional compressible Euler equations for an ideal gas with a constant ratio of
specific heats γ = 1.4, on a uniform Cartesian grid of cubic cells. There is no viscosity, heat
conduction, gravity or chemistry. The conserved variables per cell are density, three momentum
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
- The ground (z = 0) is a reflecting face. The other five faces of the domain are open: the
  stencil copies the last interior cell (zero-gradient extrapolation).

## The charge

The charge is a "bursting balloon": a sphere of hot, dense gas at rest.

- Its energy is the TNT-equivalent mass times 4.184 MJ/kg (the conventional energy of TNT), and
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
  combustion, about 15 MJ/kg, less its heat of detonation), over a time
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
  out.

It costs about a quarter more. Together with afterburning (the app's "Afterburning and hot air"
switch) it brings the closed-room gas pressure within 8% of UFC 3-340-02's at every charge
density tested, with nothing fitted to it, and keeps the incident impulse in the open within
6% of Kingery–Bulmash (see [Validation](validation.md#afterburning)).

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
is. In the app it is the "Sharpen shocks" switch (ratio 2); `blastbench` takes `--refine 2`. The
code is `Sources/BlastCore/Refinement.swift` and `Shaders/Refine.metal`.

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
- **Exactness.** It is all done on the GPU, with no round trip to the CPU between steps, and
  every sum runs in a fixed order: runs repeat exactly, uniform air refined everywhere stays
  exactly uniform, and mass and energy in a closed box are conserved to rounding (within 10⁻⁴,
  as without refinement). A centred burst stays mirror-symmetric to 10⁻⁶ until rounding tips the
  threshold for one block and not its mirror image; from then on the two sides are solved on
  different grids and differ by up to about 1%.

On Sod's shock tube, refinement by 2 takes the error two-thirds of the way to that of a grid
twice as fine. On the Kingery–Bulmash comparison a grid refined by 2 gives the peaks and
impulses of a uniform grid twice as fine, in half the time or less (see
[Validation](validation.md#with-refinement) and [Performance](performance.md#refinement)).

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

## Freezing the air

When a deformable structure is present, the air is frozen (its sweeps are skipped) once either
no cell is more than 2 kPa from ambient pressure, or five acoustic crossing times of the domain
have passed. The structure then advances alone at its own time step. The second condition
exists because a collapsing structure keeps disturbing the air near it through the moving solid
mask, so the pressure test alone may never be met. The threshold is not lower because the
winds left behind by a blast die away slowly: a second after a 50 kg charge, some cells were
still 0.8 kPa from ambient.

## Verification and validation

See [Validation](validation.md). In brief: the scheme reproduces Sod's shock tube, a reflected
normal shock and the Sedov–Taylor blast, and conserves mass and energy exactly in a closed box.
Against the Kingery–Bulmash curves for a surface burst, from 0.75 to 6 m/kg^(1/3), the impulse
on a rigid wall is within 6% on 0.25 m cells beyond 1.5 m/kg^(1/3) and within 5% everywhere on
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
   is fitted, mixing is numerical, the products are treated as air, and dissociation is left
   out.
2. **Shocks are smeared over two or three cells**, so peak overpressure is under-predicted near
   the charge, where the wave is thin compared with a cell. Impulse is much less affected.
   Refinement (above) gives the peaks of a grid twice or four times as fine, but only one finer
   level.
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
   realistic.
5. **Moving solids are a staircase of whole cells.** A moving wall pushes the gas through its
   ghost states, and its surface jumps a cell at a time. The gas is conserved within 0.3% as it
   does; see the structural model's coupling notes.
6. **Single precision.** Pressure differences well below a pascal are lost in rounding against
   ambient pressure, which is harmless for blast but rules out acoustics.

## Future work

- **Dissociation**, and the products' own composition, for the gas very close to a charge.
- **Better source.** Two options, in order of effort: start from a one-dimensional, finely
  resolved spherical solution and map it onto the grid once the shock has grown to several
  cells; or carry the detonation products as a second gas with a Jones–Wilkins–Lee equation of
  state and optional afterburn energy.
- **Better open boundaries**, if they are ever needed: a perfectly matched or sponge layer
  works at any angle, unlike the one-dimensional characteristic condition that was tried.
- **More of the refinement**: several levels, so that a ratio of 4 is reached in two steps of 2;
  patches placed and released over a fine outline without the
  gas they move between grids being gained or lost; and smaller blocks, or blocks that follow
  the shock's shape, since the shell's thickness sets the cost.
- **Cut cells**, so that moving solid surfaces need not follow cell faces (see the structural
  model's future work).

## Sources

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
