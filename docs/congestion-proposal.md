# Proposal: flame acceleration by congestion below the grid

Scoped 17 October 2026; not built. It would let an open vapour cloud explosion in a congested
plant be predicted rather than fitted.

## Why

In an open, congested cloud the model's flame barely speeds up. In the [process plant
sample](process-plant-explosion.md), after Texas City, it gives 0.01 psi 37 m from the drum
against the CSB's estimated 2.5–2.8 psi. The layout therefore multiplies the burning velocity by
6.5, fitted to that one estimate.

A real flame accelerates because each row of obstacles it passes stretches it and stirs the gas
ahead of it. At plant scale the pipes are 0.1–0.5 m and the cells 0.5–1 m, so the obstacles that
matter are below the grid, and nothing in the model sees them.

## The approach: porosity and distributed resistance

Industry codes treat obstacles smaller than a cell as a porous, resisting medium that generates
turbulence and folds the flame:
- FLACS (Arntzen 1998, Lucas et al. 2019);
- EXSIM;
- Shell's PDR model, as OpenFOAM's PDRFoam (Puttock 2006).

PDRFoam's flame model is Weller's b–Ξ, the same as BombCAD's, with obstacle terms added. So the
proposal follows it, term by term.

1. **Obstacle fields.** Congestion is described where it is, as arrays of pipes, beams or vessels
   given by diameter, pitch and orientation, or as meshes too fine to resolve. From these, each
   cell gets:
   - a volume porosity β_v and face porosities β_i;
   - a drag tensor CR and a turbulence-generation tensor CT;
   - an obstacle count per direction (N, n_s), a blockage B and an obstacle length L_obs.

   This is CADPDR's job in PDRFoam. Obstacles a cell or more across stay resolved, as now.
2. **The air.** The fluxes are scaled by the face porosities, and the cell volume by β_v. A drag
   −½ρ|U|U·CR is applied implicitly, plus PDRFoam's wall-shear term with obstacle surface area
   per volume (C_su 0.5).
3. **Turbulence.** A transported sub-grid k gains the obstacles' production ρ(½|U| U·CT·U + C_sk
   β_v ν_eff A_w²|U|²), with C_sk 0.05. Its dissipation is tied to L_obs, so that the length
   scale follows the obstacles rather than the cell. Arntzen's thesis shows why this matters: a
   length scale from the cell size made FLACS-96's production grid-dependent and additive across
   cells. This u′ joins the σ-model's.
4. **The flame.** Bradley's Ξ_t, as now, uses the larger u′. A sub-grid folding factor Ξ_sub
   multiplies it: Ξ_sub,eq = 1 + max(2.2√b, min(0.34|U|/u′·√b, 1.6))·min(n, 1), relaxed towards
   at a rate 0.5|U|/L_obs (PDRFoam's `basicXiSub`). The cellular instability stays as it is.

PDRFoam's header comments and its code disagree on some constants: min(n/4, 1) against min(n, 1),
and K with u′/S_L against (u′/S_L)². The code is what was validated, so any port should take it
from the code.

**Alternatives considered:**
- **A congestion-class factor**, from the Baker–Strehlow–Tang flame Mach numbers. This
  generalises the fitted factor. It is cheap but empirical, and needs the user to judge the
  congestion class.
- **An equivalent blast source** (TNO multi-energy or BST curves). It is fast, but not a flame,
  and it loses the interaction with the buildings.
- **Resolving the obstacles.** This needs 2–5 cm cells over the whole plant, which is out of reach.

## What it builds on

- The b–Ξ solver.
- The σ-model's sub-grid u′.
- Bradley's correlation, with Bauwens's constant.
- The measured cellular onset.
- Fractional geometry: terrain cut cells already scale fluxes by open face areas, and the
  structures' overlap count already measures how much of a cell a body fills. Both are what the
  porosities need.

Neither ContinuumKit nor Edgerton has porosity, flame or obstacle-turbulence code (checked
17 October 2026), so nothing would be duplicated. The obstacle preprocessing and the porous
fluxes could later move to ContinuumKit's CompressibleFlow.

## Cost

- About twelve more numbers per cell, in congested cells only (the refinement's sparse tiles fit
  this).
- A transported k.
- Perhaps 20–40% more work per step in those cells.
- Gexcon's guidance for FLACS is at least fifteen cells across the cloud, with 0.5–1 m cells at
  plant scale. At 0.5 m, the process sample's domain runs in 1–4 minutes today.
- **To build:** the preprocessing and porous fluxes first, then the turbulence and Ξ_sub, then
  the validation. That is several sessions.

## The data to judge it

**Open now:**
- **MERGE's peak pressures** (Gexcon's knowledge base, with array E's geometry). These are uniform
  pipe arrays at 10% and 20% blockage, 2–9 m across, with methane and propane. Its trends are the
  first targets: propane about twice methane, half the pitch about seven times, and doubling the
  scale +60–100%.
- **The BST flame Mach number table** (DNV, *Obstructed Region Explosion Model – Theory*, 2026).
- **DNV's OREM validation report**, with summaries of EMERGE, BFETS and CostFX.
- **HSE RR718 on Buncefield**, through the National Archives.
- **BakerRisk's ammonia-rig paper** (Thomas et al. 2017) and Melton and Marx (2008), on the BST
  rigs' congestion.
- **Arntzen's thesis** and **PDRFoam's source**: the equations.
- **The CSB's Texas City estimates**, at scene scale.

**To fetch** (listed in [Data wanted](data-wanted.md#to-fetch)):
- the EMERGE final report;
- Popat et al. (1996), comparing codes on MERGE;
- Pierorazio et al. (2005), the BST tests;
- Puttock et al. (2021), PDRFoam against MERGE, ERGOS and Buxton;
- Johnson, Allason and Cronin (2024), Spadeadam's programmes;
- the BFETS Phase 2 report;
- the CCPS VCE guidelines.

**Not public:** MERGE's time series, Phase 3B and CostFX.

**The bar to aim for:** PDRFoam is reported within a factor of two of the peak overpressure on
MERGE, ERGOS and Buxton (Puttock et al. 2021).

## How the fitted factor would retire

1. MERGE's peak pressures within a factor of two, with methane, propane, both pitches and every
   scale, and its trends reproduced.
2. The BST tests' flame speeds within their congestion classes.
3. The process plant sample rerun with its racks given as congestion and the factor set back to 1.
   The CSB's estimates then become a comparison, not a fit.
4. `FlameAcceleration.factor` stays, as a sensitivity option the standing reports. The open-cloud
   caveat in the standing narrows from "compared with no test" to MERGE's errors.

## Sources

- B. J. Arntzen, *Modelling of turbulence and combustion for simulation of gas explosions in
  complex geometries*, Dr.Ing. thesis, NTNU, 1998 (FLACS-96).
- Lucas et al., HySafe 2019, paper 197 (FLACS3's Ξ transport).
- OpenFOAM's PDRFoam: `PDRModels`, `XiModels/XiEqModels`, `XiGModels` (Puttock 2006's model).
- Puttock et al., *J. Loss Prev. Process Ind.* (2021), 104659.
- DNV, *Obstructed Region Explosion Model – Theory* and its validation report (Phast, 2026).
- Gexcon, MERGE validation case: knowledge.gexcon.com/docs/merge-validation-case.
- HSE Research Report RR718 (2009).
