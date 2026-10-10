# Gas deflagrations

The second kind of source beside a high-explosive charge: a cloud of methane or propane mixed
with air, filling a box in a scene, lit at a point. A flame spreads from the ignition point
through the mixture, burning it and releasing its heat, and the gas the burning expands pushes
the air ahead of it and out of any openings. Vent panels close openings until the pressure
beside them reaches a release pressure. This is an accidental event of the kind the
[long-term vision](long-term-vision.md#a-broad-subject) names: a gas leak lit in a room.

**Standing: illustrative.** The flame's propagation, its heat and the closed-vessel pressure it
gives are checked against the thin-flame model and converge with the grid (see
[Checks](#checks)). What makes real gas explosions damaging is the flame speeding up through
turbulence, instabilities and obstacles, and none of that is resolved. Here it is a constant
factor and two optional terms, neither calibrated against a test. The vented rooms'
pressures come out well below the venting correlations of EN 14994 and NFPA 68, and below the
one open set of measurements found, unless the factor is raised. Nothing here supports judging
the safety of a real room, vent or structure.

## Using it

A scenario's source is a gas cloud when it has a `deflagration`; its charges are then not fired.
Vent panels are a list beside it, and also serve a charge:

```json
"deflagration": {
  "gas": "methane",
  "concentration": 0.095,
  "region": { "min": [2.2, 2.2, 0], "max": [6.8, 6.8, 3] },
  "ignition": [4.5, 4.5, 1.5],
  "acceleration": { "factor": 1, "wrinklingRadius": 1, "subgridCoefficient": 0.2 }
},
"ventPanels": [
  { "box": { "min": [7, 3.5, 0.5], "max": [7.5, 5.5, 2.5] }, "releasePressure": 2000 }
]
```

Both keys are optional, so saves made before them open unchanged, and a scene without them is
simulated exactly as before (`blastbench digest` gives the same hashes). In the app, the
sidebar's **Source** picks a charge or a gas cloud; **Gas cloud** sets the gas, its concentration
(within its flammability limits), the filled region, the ignition point and the flame's
acceleration; **Vent panels** adds panels and their release pressures. The built-in layout
**Gas explosion, vented room** sets one up: a 4.5 × 4.5 × 3 m room of stoichiometric methane lit in
the middle, its 2 × 2 m vent closed by a panel that releases at 2 kPa. Panels are drawn as blocks
until they release. Gauges and deformable structures work as they do for a charge. Deflagrations
last hundreds of milliseconds to seconds, so set **Stop after** accordingly, and the pressure scale
to 3 or 10 kPa.

`blastbench deflagration vessel|vented` runs the checks below; `tube` and `ball` print a flame's
profile along a closed tube and through a free sphere; `layout --out f.json` writes the built-in
layout for `BombCAD run`.

## The mixture

| | Methane | Propane | Source |
|---|---|---|---|
| Stoichiometric, by volume | 9.5% | 4.0% | CH₄ + 2 O₂; C₃H₈ + 5 O₂; air 20.95% O₂ |
| Flammable range | 5–15% | 2.1–9.5% | |
| Heat of combustion (lower) | 50.0 MJ/kg | 46.35 MJ/kg | |
| Laminar burning velocity, stoichiometric | 0.41 m/s | 0.43 m/s | Gülder's fit |
| AICC pressure, stoichiometric | 8.9 bar | 9.4 bar | from 1.013 bar; Cashdollar et al. 2000 |
| Measured p_max, K_G | 7.1 bar g, 55 bar m/s | 7.9 bar g, 100 bar m/s | NFPA 68, Bartknecht |

The laminar burning velocity follows Gülder's correlation, S_L = W φ^η exp(−ξ (φ − 1.075)²), with
W = 0.422 m/s, η = 0.15, ξ = 5.18 for methane and 0.446, 0.12, 4.95 for propane, φ being the
equivalence ratio. It is zero outside the flammable range. It does not change with the unburnt
gas's pressure and temperature. Under adiabatic compression (T ∝ p^0.29), Gülder's exponents
(S_L ∝ T² p^−0.5 for methane, T^1.77 p^−0.2 for propane) would raise methane's by a sixth by
8 bar, but nearly double propane's.

**The heat.** The solver treats burnt and unburnt gas alike as air, an ideal gas with γ = 1.4 or
[hot air](air-blast-model.md#hot-air). Released in full, the heat of combustion (3.2 MJ per cubic
metre of stoichiometric methane–air) would take a closed volume to 13.7 bar, far above the
8.9 bar of the adiabatic isochoric complete combustion (AICC) pressure that equilibrium gives.
Real products have larger heat capacities and partly dissociate. So the heat released is the
share that takes the solver's gas from the ambient state to the AICC pressure at constant
volume: 62% for the ideal gas, 77% with hot air (61% and 76% for propane). That share is fitted
at stoichiometric and applied at every concentration, rich or lean. Cashdollar et al. give the
calculated AICC maxima over concentration as 7.9 bar g for methane and 8.6 bar g for propane, the
latter at 4.5–5%. The stoichiometric 9.4 bar used for propane is slightly below that maximum and
is this model's estimate, not a quoted value. The fit fixes the expansion ratio too, the burnt
gas's volume over the unburnt's at constant pressure. That is 6.6 for the ideal gas and 7.1
with hot air (7.0 and 7.5 for propane), against Bradley and Mitcheson's 7.5 and 8.0 for the real
mixtures. A flame in the ideal gas therefore runs 12% slower, for its expansion, than a real one.
The cloud starts at the air's density and temperature: its own density, 5% lower for
methane–air and 2% higher for propane–air, is not represented.

## The flame

The flame follows Weller's regress-variable form, the one OpenFOAM's XiFoam solves and the one
Bauwens et al. used for the vented tests below. b, the share of the cloud's gas still unburnt,
obeys

  ∂(ρb)/∂t + ∇·(ρub) = −ρ_u S_T |∇b|,

ρ_u being the unburnt gas's density and S_T the burning velocity. Across any profile of b the
source integrates to ρ_u S_T per area of front, so the mixture is consumed at the burning
velocity per area however far the grid has spread the front, and a steady planar front is a
solution whatever its profile. Each level of b moves relative to the gas at (ρ_u/ρ) S_T, and the
mass flux through each is ρ_u S_T.

- The air carries two more densities, as afterburning's fuel and oxygen are carried (and in the
  same buffers: a deflagration turns afterburning off). They are the unburnt mixture and all the gas
  that came from the cloud, burnt or not, so b is their ratio. Products are then not mistaken for
  air diluting the mixture, and the mixture's own fuel fraction, for its burning velocity and
  flammability, is the cloud's diluted only by real air. Air the cloud never reached counts as
  unburnt, so the cloud's edge does not light itself.
- They are carried at limited linear (MUSCL) mass fractions at the faces rather than the upwind
  cell's, for the deflagration only. First-order, the grid's diffusion spread the front over
  six to eight cells. The propagation term takes Godunov's upwind gradient from second-order ENO
  differences. The front is then about four cells thick.
- ρ_u is the ambient mixture's density compressed adiabatically (γ = 1.4) to the cell's pressure.
  This is how a closed vessel's flame burns faster as the pressure rises.
- The ignition point lights the cell holding it as a spherical flame kernel: the cell's burnt gas
  taken as a sphere, expanded by σ, the flame its surface. It burns at ρ_u S_T times that area,
  (36π)^(1/3) (σ(1 − b))^(2/3)/Δ per volume, from a seed of a thousandth. So the burning grows from
  nothing, as a real kernel's does; started at full rate, it sent out a pressure pulse that opened a
  light vent panel. A flame cannot be smaller than a few cells, though. On a coarse grid it burns
  as a ball a cell or two across almost at once, far larger than a real kernel of the same age, and
  a small room's pressure rises early. A 2 m room on 0.25 m cells reaches 1 kPa in 35 ms.
- The burning is worked out for every cell before any cell burns, then applied, releasing its
  heat into the cell's energy.

**The burning velocity.** S_T = f Ξ_r S_L + b₃ u′. Each part is optional:

- f, a constant factor (1 by default): the venting literature's turbulence factor (Bradley and
  Mitcheson's β, Molkov's χ), for turbulence and instabilities not otherwise represented.
- Ξ_r = (r/r₀)^(1/3) beyond r₀ = 1 m from the ignition point, for the flame's self-acceleration
  as it grows, by its own cellular instabilities. Gostintsev et al. (1988) found large flames'
  radii growing as t^(3/2), so their speed as r^(1/3), and Molkov's fractal model uses the same
  exponent. r₀ for methane and propane was not found, and 1 m is a choice.
- b₃ u′, with u′ = C Δ |ω| from the resolved flow's vorticity (C = 0.2) and b₃ = 1, Peters'
  corrugated-flamelet limit S_T − S_L ≈ b₃ u′. This is turbulence the grid cannot resolve,
  estimated from the shear it can: behind obstacles and in jets through openings. Vorticity
  rather than strain, so that a passing pressure wave does not count. It is not a turbulence
  model, and in a quiescent sphere it speeds the flame by about a tenth, from the vorticity the
  flame itself makes on the grid.

**What was tried first.** The front was first a level set G, a signed distance carried by the
gas and advanced at S_T (the G-equation), with the mixture burnt as the front passed. It ran at
exactly σ S_L in a one-dimensional tube, σ the expansion ratio, but at half that in a growing
sphere. A sphere's visible speed is S_L plus the expansion's outflow at the front, and that falls
off as 1/r². Any gap δ between where the gas expands and where the front is taken to be cuts the
speed by about 1/(1 + 2(σ − 1) δ/r): a cell's gap costs 40% at twenty cells' radius. Burning by
mass at the front instead (ρ_u S_T δ(G)), with the front carried at the unburnt gas's velocity
extrapolated to it, was starved or ran away as the grid's diffusion moved mixture across the
band. Weller's form has neither problem.

## Vent panels

A panel is a box whose cells (those a block or the ground does not already fill) are solid until
the largest overpressure in a fluid cell beside any of them reaches its release pressure. Then all
its cells are cleared from the mask, and from the rigid mask a deformable structure's remasking
starts from. The panel has no mass and goes at once, an idealised vent cover. Its cells become
still air at the ambient state, a sliver of gas the room did not have. When it opened is recorded
(`BlastSolver.ventPanelOpenTimes`). A panel with a release pressure of zero or less is an open vent
and is never solid.

## Checks

### A closed sphere

A sphere of stoichiometric methane–air, 0.5 m in radius, voxelised by cell centre, lit at its
centre with a laminar flame. The reference is the thin-flame model for the same sphere, burning
velocity and AICC pressure (Lewis and von Elbe; Dahoe et al. 1996): p = p₀ + (p_max − p₀) x for
burnt mass fraction x, the unburnt gas compressed adiabatically, and dx/dt = 3 r_f² S_u
(p/p₀)^(1/γ)/R³. Its steepest rise gives the deflagration index K_G = (36π)^(1/3) (p_max − p₀)
(p_max/p₀)^(1/γ) S_u. For one ideal gas burning to another with the same γ, as here, the linear
rise is exact. `blastbench deflagration vessel --cells 12,24,48`:

| Cells across the radius | Peak, bar | Half the rise, ms | Nine tenths, ms | K_G, bar m/s | Energy |
|---|---|---|---|---|---|
| 12 | 9.02 | 326 | 412 | 35 | conserved to 10⁻⁵ |
| 24 | 9.02 | 281 | 359 | 41 | |
| 48 | 9.02 | 250 | 308 | 51 | |
| Thin-flame model | 9.02 | 253 | 299 | 76 | |

- **Peak.** The whole mixture burns and the peak is the AICC pressure. That is by construction, as
  the heat was fitted to it, and it shows nothing is lost or gained: the energy the gas gains is
  the heat released to within 10⁻⁵. The measured peaks, 7.1–7.5 bar g in standard vessels
  (8.1–8.5 bar absolute), are lower for the heat lost to the walls, which the model does not
  represent.
- **Times.** The time to half and nine tenths of the rise converge on the thin-flame model's. At
  48 cells they are within 1% and 3%; at 24, 11% and 20% late. A thick front grows slowly while
  it is only a few cells across.
- **K_G** converges slowly, from below: 51 against 76 at 48 cells. The steepest rise comes as the
  flame reaches the wall, when the last unburnt gas is a layer a few millimetres thick, far
  thinner than a cell. A front four cells thick burns it as a smeared tail. Measured K_G (55 in
  Bartknecht's vessels, 66 in a 20-litre sphere, 92 at 120 litres; Cashdollar et al. 2000) lies
  between, so the model's agreement with them at any one resolution means little.
- **Cube-root law.** At 16 cells across the radius, spheres of 0.25, 0.5 and 1 m give the same
  K_G (37 bar m/s), and their times scale with the radius. A laminar flame is similar at every
  size, so this checks only that nothing in the model depends on the cell size absolutely. With
  wrinkling on and the sphere under r₀ = 1 m, the same holds (43 bar m/s, the sub-grid term
  adding a tenth). Larger flames would break the law, as real gases do: Cashdollar's methane K_G
  rises from 66 at 20 litres to 110 at 25.5 m³.
- **Propane** (24 cells): peak 9.52 bar, the model's AICC; half rise at 260 ms against 230; K_G 46
  against 89. **Hot air**: as the ideal gas, the times within 4%.
- **A tube** (DeflagrationTests): a laminar flame lit at the closed end of a narrow tube runs at
  the model's expansion ratio times the burning velocity, 2.7 m/s, to within 10%. A free sphere
  reaches 97% of that speed once its radius is fifteen cells.

### Vented rooms against the correlations

FM Global's 63.7 m³ chamber as Bauwens et al. used it: 4.6 × 4.6 × 3.0 m inside, a square vent in
the middle of a 4.6 × 3 m wall, stoichiometric methane, lit in the middle. The walls and roof are
0.2 m thick, with 2 m of air round the room and 5 m beyond the vent. P_red is the peak overpressure
at the middle of the back wall, after a 1/80 s moving average, as Bauwens et al. filtered theirs
at 80 Hz. `blastbench deflagration vented --vent 2.7,4,5.4,8 --dx 0.1`, open vents:

| Vent, m² | Default flame | Laminar | Factor 3 | Molkov | Bartknecht | NFPA 68 |
|---|---|---|---|---|---|---|
| 2.7 | 1.7 kPa | 0.9 | 10.7 | 77 | 94 | 179 |
| 4.0 | 0.8 | | 4.4 | 35 | 48 | 81 |
| 5.4 | 0.35 | 0.3 | 2.5 | 19 | 29 | 45 |
| 8.0 | 0.26 | | 1.7 | 8 | 15 | 20 |

The default flame is the one above: wrinkling with radius, the sub-grid term and a factor of 1.
"Laminar" has neither; "Factor 3" has both and triples the burning velocity.

The correlations, for the same room, vent and gas:

- **Molkov** (2001): π_red = Br_t^−2.4 for the turbulent Bradley number Br_t = √(E/γ_u) Br /
  ((36π)^(1/3) χ/μ), Br = (A_v/V^(2/3)) c_u/(S_u (E − 1)). The deflagration–outflow interaction
  number χ/μ = 1.75 [(1 + 10 V^(1/3)) (1 + 0.5 Br^0.5)/(1 + π_v)]^0.4 π_i^0.6 is itself the
  correlation's turbulence factor, about 10 here. It is a best fit to 139 tests, and the
  low-strength method EN 14994 adopted is of this kind. Its constants here are from Molkov's paper,
  not the standard, which was not available.
- **Bartknecht** (EN 14994 and NFPA 68 for strong enclosures): A_v = [(0.1265 log K_G − 0.0567)
  P_red^−0.5817 + 0.1754 P_red^−0.5722 (P_stat − 0.1)] V^(2/3), K_G 55 bar m/s, valid for P_red from
  0.1 to 2 bar.
- **NFPA 68** (2002) for low-strength enclosures: A_v = C A_s/√P_red, C = 0.037 bar^½ for methane.
  It is an envelope, meant to be conservative.

- **The model's pressures are far below the correlations'**: the default flame's are a thirtieth
  to a fiftieth of Molkov's best fit, and with the burning velocity tripled, a fifth to a seventh.
  Molkov's χ/μ, the turbulence his fit attributes to such rooms, is about 10. The pressure grows
  as about the 1.7th power of the factor (6.2 times for 3), so a factor near 10 would be needed
  to reach his fit. The flame's acceleration, which the correlations fold in, is what the model
  lacks (see [Limitations](#limitations)).
- **The trend with vent area is near the correlations'**: the pressure falls as A_v^−1.7 for the
  default and tripled flames, against A_v^−2 for NFPA 68 and Molkov.
- **The correlations are conservative for this room.** The test below, in the same chamber,
  measured far less than any of them gives.
- **Time.** The default flame's peak comes at 0.7–1.0 s, when the flame reaches the walls and its
  burnt gas leaves through the vent; tripled, at 0.24–0.35 s.

### Bauwens, Chaffee and Dorofeev (2008)

Six tests in that chamber, near-stoichiometric methane, quiescent (u′ about 0.1 m/s), the vent
covered by a 0.02 mm polypropylene sheet. The model treats the vent as open, as their LES did.
Their peaks are given only as plots of the back wall's pressure (P1), so without digitising them
only the plots' axes bound the measured peaks. In each, the measured overpressure stays inside
its axis:

| Test | Methane | Ignition | Vent, m² | Model, default flame | Plot's axis (figure) | Molkov |
|---|---|---|---|---|---|---|
| 1 | 9.0% | middle | 5.4 | 0.29 kPa | 3 kPa (Fig. 6) | 19 |
| 2 | 10.3% | middle | 5.4 | 0.37 | 3 (Fig. 6) | 19 |
| 3 | 9.8% | back wall | 5.4 | 2.3 | 6 (Fig. 7) | 19 |
| 4 | 9.5% | back wall | 5.4 | 2.2 | 6 (Fig. 7) | 19 |
| 5 | 9.2% | middle | 2.7 | 1.5 | 10 (Fig. 8) | 77 |
| 6 | 9.2% | back wall | 2.7 | 4.5 | 8 (Fig. 9) | 77 |

With the burning velocity tripled, test 1 gives 1.9 kPa.

- **The measured peaks are a tenth or less of the correlations'**: the axes alone put them below
  0.03 bar for tests 1 and 2 against Molkov's 0.19. Bauwens et al. describe the tests as giving
  overpressures below a tenth of ambient.
- **The model's default flame is low**: about a tenth of the axis for the tests lit in the middle,
  a third to a half for those lit at the back wall. The plots' axes are not the peaks, so these
  ratios bound the model's shortfall from below rather than measure it. Digitising the plots
  ([data wanted](data-wanted.md), item 3f) would turn this into a comparison.
- **The model has the measured trends' directions**: lighting at the back wall raises the peak
  (here by six times for the large vent), as Bauwens et al. found it did, and the smaller vent
  raises it. The mechanisms they identified are a Helmholtz oscillation, amplified by the Taylor
  instability of the flame as the burnt gas is accelerated back into the room, and an external
  explosion of the vented mixture. The model resolves the oscillation and the external burning
  only as far as its grid and its flame allow; the Taylor instability's wrinkling it does not
  have at all. A second large peak follows, driven by feedback between the room's acoustics and
  the burning. Their own LES, on a 7.5 cm mesh with sub-grid turbulence and flame wrinkling,
  missed the first peak, mainly, they judged, because the Taylor instability was not resolved.
  It caught the second within about 30%, through sub-grid turbulence the model here does not
  carry. They call these tests, with a weakly reactive mixture and large vents, the hardest of
  their kind for CFD.

### Grid convergence

{{CONVERGENCE}}

## Limitations

1. **The flame's acceleration is not resolved, and what stands for it is not calibrated.** A
   vented room's peak pressure is set by how fast the flame burns when the vent is open. In tests
   that comes from turbulence the outflow makes, cellular and Taylor instabilities (the second
   amplified by Helmholtz oscillation), and the external explosion. Here they are a constant
   factor, a wrinkling with radius whose onset radius is a guess, and a vorticity estimate of
   sub-grid turbulence. The default flame gives pressures far below tests and correlations.
2. **No obstacles' sub-grid turbulence**: obstacles larger than a few cells shape the resolved
   flow and the vorticity term sees its shear, but congestion below the grid's scale, which drives
   the strongest accelerations, is not represented (porosity–distributed-resistance codes such as
   FLACS model it). There is no transition to detonation.
3. **Products treated as air.** The heat is fitted to the AICC pressure at stoichiometric and
   applied at every concentration. The expansion ratio comes out 6.6 (ideal gas) or 7.1 (hot air)
   against 7.5. The cloud's own density is not represented. Rich and lean mixtures' heat follows
   the fuel or oxygen they burn, but their AICC pressures are not checked.
4. **The burning velocity** does not depend on the unburnt gas's pressure and temperature, flame
   stretch (Markstein) or heat loss. A flame is not quenched at walls, and dilution below the
   flammability limit stops it only through the burning velocity.
5. **K_G and the closed vessel's last instants converge slowly**: the final unburnt layer is far
   thinner than a cell.
6. **Vent panels have no mass** and go at once. Panels of several kilograms a square metre hold
   on longer and raise the pressure, and EN 14994 corrects for their inertia.
7. **The domain's open faces copy the cell inside them**, which lets gas flow back in. Burnt gas
   wrapping round a room against an open face drew itself back in and pressurised the whole domain.
   Leave a few metres of air round a vented room.
8. **Refinement, still-air skipping and afterburning are turned off** with a deflagration, the
   first two because the flame is advanced everywhere on the coarse cells, the last because the
   cloud takes its species.

## Future work

- Compare the back wall's pressure histories with Bauwens et al.'s once digitised
  ([data wanted](data-wanted.md), item 3f), and their flame speeds with the flame's arrival.
- A turbulence model for the flame's acceleration: a sub-grid turbulent kinetic energy with
  Bradley's or Zimont's burning velocity, and the instabilities' wrinkling with an onset radius
  from the literature (Bradley, Lawes and Mansour), in place of the constant factor.
- Obstacles' sub-grid turbulence, as porosity–distributed-resistance models carry it.
- The burning velocity's dependence on pressure and temperature (Metghalchi and Keck), and the
  products' own heat capacities instead of a fitted share of the heat.
- Vent panels with inertia, and panels that hinge.
- Hydrogen, whose instabilities and venting are better measured (HySEA).

## Sources

- Bauwens, C. R., Chaffee, J. and Dorofeev, S. (2008). Experimental and numerical study of
  methane–air deflagrations in a vented enclosure. *Fire Safety Science* 9, 1043–1054.
  doi:10.3801/IAFSS.FSS.9-1043.
- Bradley, D. and Mitcheson, A. (1978). The venting of gaseous explosions in spherical vessels.
  *Combustion and Flame* 32, 221–255 (expansion ratios and unburnt γ, as tabulated by Kasmani 2008).
- Cashdollar, K. L., Zlochower, I. A., Green, G. M., Thomas, R. A. and Hertzberg, M. (2000).
  Flammability of methane, propane, and hydrogen gases. *Journal of Loss Prevention in the
  Process Industries* 13, 327–340 (Table 2: calculated and measured maximum pressures and K_G).
- Dahoe, A. E., Zevenbergen, J. F., Lemkowitz, S. M. and Scarlett, B. (1996). Dust explosions in
  spherical vessels: the role of flame thickness in the validity of the cube-root law. *Journal of
  Loss Prevention in the Process Industries* 9, 33–44 (the thin-flame model and K_G).
- EN 14994:2007, *Gas explosion venting protective systems*; NFPA 68, *Standard on explosion
  protection by deflagration venting* (2002 edition for C). Neither standard was available; their
  equations are as Lautkaski (2011) and Kasmani (2008) give them.
- Gostintsev, Yu. A., Istratov, A. G. and Shulenin, Yu. V. (1988). Self-similar propagation of a
  free turbulent flame in mixed gas mixtures. *Combustion, Explosion and Shock Waves* 24, 563–569.
- Gülder, Ö. L. (1984). Correlations of laminar combustion data for alternative S.I. engine fuels.
  SAE 841000 (coefficients as OpenFOAM's Gulders.C has them).
- Kasmani, R. M. (2008). *Vented gas explosions*. PhD thesis, University of Leeds.
- Lautkaski, R. (2011). VTT research report VTT-R-02755-11, on vent sizing for gas explosions
  (Bartknecht's equation and Molkov's correlations as the standards use them).
- Molkov, V. (2001). Unified correlations for vent sizing of enclosures at atmospheric and elevated
  pressures. *IChemE Symposium Series* 148 (Hazards XVI), eqs. 3–5.
- Osher, S. and Fedkiw, R. (2003). *Level Set Methods and Dynamic Implicit Surfaces*. Springer
  (ENO differences and Godunov's upwind Hamiltonian).
- Peters, N. (2000). *Turbulent Combustion*. Cambridge University Press (S_T − S_L ≈ b₃ u′).
- Weller, H. G. (1993). The development of a new flame area combustion model using conditional
  averaging. Imperial College, Thermo-fluids section report TF 9307; Weller, H. G., Tabor, G.,
  Gosman, A. D. and Fureby, C. (1998). Application of a flame-wrinkling LES combustion model to a
  turbulent mixing layer. *Proceedings of the Combustion Institute* 27, 899–907.
