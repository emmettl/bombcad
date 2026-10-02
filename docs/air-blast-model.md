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
- The sphere's radius is the physical charge radius (for a density of 1600 kg/m³) or two cells,
  whichever is larger.
- Cells are weighted by the fraction of their volume inside the sphere, and the totals are
  normalised over fluid cells only. A charge on the ground or against a wall therefore releases
  all of its energy into the air; a charge on rigid ground behaves like a free-air charge of
  twice the mass.

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
Against the Kingery–Bulmash reference for a surface burst, the impulse on a rigid wall is within
5% to 10%, the incident impulse is 13% to 23% low on every grid, and peak pressures are
under-resolved (74% to 81% of the incident peak on 0.25 m cells, improving with resolution).

## Limitations

1. **The source model is crude.** An ideal-gas balloon with γ = 1.4 ignores the detonation
   wave, the real equation of state of the detonation products, and afterburning. It is poor
   within a few charge diameters, or a few cells, of the charge, and it under-predicts incident
   impulse by 13% to 23% at all ranges tested. Impulse on a wall facing the charge is much
   better, within 5% to 10%.
2. **Shocks are smeared over two or three cells**, so peak overpressure is under-predicted near
   the charge, where the wave is thin compared with a cell. Impulse is much less affected.
3. **Open boundaries reflect a little.** Zero-gradient extrapolation is not a true
   non-reflecting condition for subsonic outflow.
4. **One gas.** Hot products and air share one γ, so the fireball's temperature and its late
   pressure history are not realistic.
5. **Moving solids are a staircase of whole cells.** A moving wall pushes the gas through its
   ghost states, and its surface jumps a cell at a time. The gas is conserved within 0.3% as it
   does; see the structural model's coupling notes.
6. **Single precision.** Pressure differences well below a pascal are lost in rounding against
   ambient pressure, which is harmless for blast but rules out acoustics.

## Future work

- **Compare with the full Kingery–Bulmash curves** (as simplified by Swisdak). The comparison so
  far uses three tabulated points, at scaled distances of 1.1, 2.3 and 5 m/kg^(1/3); the
  polynomial coefficients could not be retrieved from an accessible source during development.
- **Better source.** Two options, in order of effort: start from a one-dimensional, finely
  resolved spherical solution and map it onto the grid once the shock has grown to several
  cells; or carry the detonation products as a second gas with a Jones–Wilkins–Lee equation of
  state and optional afterburn energy.
- **Non-reflecting open boundaries** based on characteristic variables.
- **Adaptive resolution** near the charge and the shock, the standard answer to the
  thin-shock problem, at a large cost in complexity on the GPU.
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
  empirical overpressure and impulse curves used for validation.
- C. N. Kingery and G. Bulmash, *Airblast Parameters from TNT Spherical Air Burst and
  Hemispherical Surface Burst*, ARBRL-TR-02555, US Army Ballistic Research Laboratory, 1984;
  and M. M. Swisdak, "Simplified Kingery Airblast Calculations", 26th DoD Explosives Safety
  Seminar, 1994. The reference for design practice; used here through the worked examples in
  the next entry.
- United Nations Office for Disarmament Affairs, *International Ammunition Technical
  Guidelines*, IATG 01.80, "Formulae for ammunition management", 3rd ed., 2021, Table 5.
  Kingery–Bulmash values for a hemispherical surface burst at three scaled distances.
