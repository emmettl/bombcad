# Congestion below the grid

Pipes, bars and vessels too small for the air's cells, in a plant's racks or a test rig's
lattice, change a gas explosion. Each row a flame passes through stretches it and stirs the gas
ahead, so its speed grows row by row, to hundreds of metres a second. The model treats them as
industry codes do (FLACS; Shell's model as OpenFOAM's PDRFoam): as a porous, resisting medium in
each cell. It is being built in stages, after [the proposal](congestion-proposal.md):

1. **The obstacles and the porous flow** (built, 17 October 2026).
2. **The turbulence they make and the flame's folding** (to come).
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
  multiplied by PDRFoam's row-blockage factor (1 − ½b)/(1 − b)², b the diameter over the pitch, as
  inside a uniform array (`PDRsetFields`' `calc_drag_etc`).
- **its wall area per volume**, for the turbulence to come.

For MERGE's array A (43 mm pipes at 0.2 m along all three axes), β_v is 0.89 and CR, across any
axis, 3.7 m⁻¹ (2.6 m⁻¹ before the factor of 1.45).

## The porous flow

In each directional sweep a porous cell's update is the flux through each face times the face's
open share, over the cell's open volume β_v. A face takes the smaller of its two cells' β_v, so
the update never outruns the step's Courant number. The pressure on the obstacles' faces,
p (β_high − β_low), is added to the momentum, so still air stays still. Summed over the cells,
β_v ρ is conserved.

After each step the obstacles' drag takes momentum at ½ CR ρ|u| u per volume along each axis,
implicitly (u ← u / (1 + ½ Δt CR |u|)), so that it can only slow the flow. The kinetic energy it
takes stays in the gas as heat.

Its code is compiled into the air's kernels only where a scene has congestion, so every other
scene runs exactly as before.

**Checks** (`CongestionTests`):
- the fields for MERGE's array A;
- still air in and around porous cells staying still, to 10⁻⁴ m/s and 0.05 Pa, over 60 steps;
- β_v ρ conserved to 2 × 10⁻⁶ as a 3 bar pulse crosses the cells;
- a uniform stream slowing as u₀ / (1 + ½ CR u₀ t), within 1%.

**Not yet:**
- The face porosity is the smaller of its cells' volume porosities, not PDRFoam's own β_i from
  each direction's area blockage.
- The drag is diagonal.
- PDRFoam's wall-shear drag (C_su), which needs the turbulence, comes with stage 2.
- Congestion acts on the coarse cells only: a deflagration runs without refinement, but a charge
  in congestion would see it only where its air is not refined.
