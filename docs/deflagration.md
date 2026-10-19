# Gas deflagrations

The second kind of source beside a high-explosive charge: a cloud of methane, propane, hydrogen
or town gas mixed with air, filling a box in a scene, lit at a point. A flame spreads from the ignition point
through the mixture, burning it and releasing its heat, and the gas the burning expands pushes
the air ahead of it and out of any openings. Vent panels close openings until the pressure
beside them reaches a release pressure. This is an accidental event of the kind the
[long-term vision](long-term-vision.md#a-broad-subject) names: a gas leak lit in a room.

**Standing: illustrative.** A laminar flame's propagation, its heat and the closed-vessel pressure
it gives are checked against the thin-flame model (see [Checks](#checks)). What makes real gas
explosions damaging is the flame speeding up through turbulence, instabilities and obstacles. The
flame here is wrinkled by the turbulence the grid cannot resolve, through the correlation and
sub-grid model of FM Global's own LES of these rooms, and by the flow round obstacles the grid
does resolve, and by its own cellular instability from the onset radius measured in that chamber.
- Lit at the back wall of FM Global's chamber, the peak pressure is 0.9–1.8 times the tests'.
- Lit in the middle, it is 0.4–0.6 times theirs: the half of the flame facing the back wall
  stalls, and the acoustically driven peaks are not reproduced.
- Every result is below the venting correlations of EN 14994 and NFPA 68, which are conservative
  for this room (the tests measured a tenth to a quarter of them).

Nothing here supports judging the safety of a real room, vent or structure.

## Where gas explosions stand

As of 17 October 2026. Each band is the model's peak over the measured, unfitted unless said; the
checks are under [Checks](#checks) and the [congestion model](congestion-model.md#merge).

| Gas or case | Compared with | Band | Side | What is missing |
|---|---|---|---|---|
| Methane, a vented room | FM Global's 63.7 m³ chamber, six tests (Bauwens et al. 2008) | 0.9–1.8 lit at the back wall; 0.41–0.58 lit in the middle | either way; unsafe lit in the middle | the stall of the flame's back half; the Helmholtz–Taylor and acoustic peaks |
| Methane, closed | 20 L to 25 m³ vessels, K_G 55–110 | 74 bar m/s on 48 cells (0.7–1.35) | either way | a front thin enough to resolve the last burning layer |
| Propane | a closed sphere only, K_G 89 | 0.66 (59 bar m/s, 24 cells) | unsafe | any vented comparison; its measured instability onset |
| Hydrogen, lean, vented | FM Global's chamber, eight tests (Bauwens et al. 2011) | 1.24–2.96 | safe | the external explosion and Helmholtz peaks |
| Hydrogen, lean, vented | HySEA's containers (Skjold et al. 2017): through the doors; through roof film | 0.72–1.42; 0.19–0.45 | within scatter; unsafe | the roof film's opening pressure, not reported |
| Hydrogen, closed | stoichiometric, K_G 550 (500–990 by vessel) | 0.89–0.99 | either way | rich hydrogen's own instability (no factor richer than φ 1) |
| Town gas | a closed sphere (Bartknecht's 60/40 stand-in); Ronan Point's flat against the inquiry's estimate | 0.77; 12 kPa against 21 | unsafe | any vented test |
| Congestion below the grid | MERGE's rigs, methane and propane | 0.43–1.16 at the finer pitches; 2.8–5.2 at the coarser | either way | the pitch's effect (half the pitch is seven times the peak in MERGE, about the same here) |
| Congestion, flame speed | Baker–Strehlow–Tang's 3D flame Mach numbers | Mach 0.45–1.04 against 0.23–0.5 | fast | as above |
| An open plant cloud | Texas City (the CSB's 2.5–2.8 psi at 37 m) | 0.01 psi with the model alone, so a fitted factor of 6.5 | unsafe unless fitted | the unit's congestion at grade |
| Venting correlations | EN 14994 and NFPA 68 for the same rooms | a seventh to a fiftieth of theirs | below them, as the tests are | none: the correlations are envelopes |

**What holds across them.**
- **Energy:** a cloud's heat goes into the gas to within 10⁻⁵, and a closed vessel peaks at the
  AICC pressure.
- **Vented rooms:** they are within a factor of two to three where the flame runs from a wall to
  the vent, lean hydrogen included once its 1/Le response is on.
- **Congestion:** it is illustrative. The standing advises cells no larger than the arrays'
  pitch, because larger cells grow the peak five to twelve times.

**What is missing across them.**
- the Helmholtz–Taylor and acoustically driven peaks;
- vent panels' inertia;
- transition to detonation;
- the products' and the cloud's own properties: the products are taken as air with fitted heat,
  and the cloud starts at the air's density;
- the burning velocity's dependence on the unburnt gas's pressure and temperature;
- a congestion model with the pitch's effect.

## Using it

A scenario's source is a gas cloud when it has a `deflagration`; its charges are then not fired.
Vent panels are a list beside it, and also serve a charge:

```json
"deflagration": {
  "gas": "methane",
  "concentration": 0.095,
  "region": { "min": [2.2, 2.2, 0], "max": [6.8, 6.8, 3] },
  "ignition": [4.5, 4.5, 1.5],
  "acceleration": { "factor": 1, "turbulence": { "scale": 0.7 } }
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
the middle, its 2 × 2 m vent closed by a panel that releases at 2 kPa. **Vapour cloud explosion at a
process plant** lights a propane cloud in a congested process area beside a blast-resistant module,
a cabin and two envelope buildings, its burning velocity raised by a factor fitted to Texas City
([process plant explosion](process-plant-explosion.md)). Panels are drawn as blocks
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

### Hydrogen and town gas

Added 17 October 2026, so that a domestic explosion of the 1960s, and hydrogen, can be run on their
own gas (`gas: hydrogen` or `townGas`; `blastbench deflagration … --gas hydrogen`).

| | Hydrogen | Town gas | Source |
|---|---|---|---|
| Composition | H₂ | H₂ 51.6, CH₄ 31.6, C₂H₆ 0.7, CO 1.6, CO₂ 1.5, O₂ 0.3, N₂ 12.7% | a British town gas (Cubbage and Marshall 1972, as corrected and tabulated by Lautkaski 2011, Table 25) |
| Stoichiometric, by volume | 29.5% | 18.6% | H₂ + ½ O₂; the components' oxygen, less the gas's own |
| Flammable range | 4–75% | 5.0–31.5% | Zabetakis 1965 (Table 21); Lautkaski (Le Chatelier's rule; Coward and Jones measured 5.35% and 30.9%) |
| Heat of combustion (lower) | 119.96 MJ/kg | 35.45 MJ/kg | per kilogram of the gas, inert gases included |
| Laminar burning velocity | 2.13 m/s stoichiometric, 2.85 m/s at φ 1.68 | 0.64 m/s at 20%, 1.0 m/s at 25% | tabulated, below |
| AICC pressure, stoichiometric | 8.01 bar | 8.44 bar | Cantera 3.1, GRI-Mech 3.0's thermodynamics (methane 8.81, propane 9.34 there) |
| Expansion ratio, stoichiometric | 6.88 | 7.21 | the same (methane 7.52, propane 7.98, as Bradley and Mitcheson's) |
| Measured p_max, K_G | 6.9 bar g, 550 bar m/s | 7.1 bar g, 140 bar m/s | below |

**Their burning velocities are tabulated**, in equivalence ratio, linear between points, since
Gülder's form peaks at φ 1.075 and hydrogen's peaks near φ 1.7:
- *Hydrogen:* S. C. Taylor's expanding spherical flames, extrapolated to zero stretch (PhD thesis,
  Leeds, 1991, appendix; the data of Dowdy et al. 1990), 16 of his 21 mixtures from φ 0.23 to
  5.07. His peak, 2.85 m/s, is at the low end of the OECD/NEA's review of eighteen studies,
  2.67–3.56 m/s (CSNI/R(2000)7, Table A.1.1-2), the higher ones from stretched burner flames; NACA
  recommended 3.10 m/s at φ 1.8 (RM E57D24, 1957), and Cantera with its H₂/O₂ mechanism gives
  3.09. Bauwens et al.'s lean flames in FM Global's chamber read 0.22–0.29 m/s near φ 0.33, where
  Taylor's read 0.19.
- *Town gas:* Lautkaski's burning velocities (2011, Table 38), worked back from Cubbage and
  Simmonds's flame speeds in vented ovens and scaled to a peak of 1.0 m/s at 25% gas. British
  sources put the peak at 0.7–1.2 m/s (the Morton report 0.8, Cubbage and Simmonds 1.2, Rasbash's
  FRN 759 1.2), depending on the gas; GRI-Mech 3.0, untested for gas this rich in hydrogen,
  computes 0.66 m/s at 20%.

**Lean hydrogen turns cellular within centimetres.** Its thermodiffusive instability (Lewis
numbers 0.38–0.49 at 12–20%) sets in at radii of 18–30 mm over φ 0.33–0.57 (Bauwens, Bergthorson
and Dorofeev, ICHS 2015, paper 202, Table 1, in FM Global's chamber), which `criticalRadius` takes,
held below φ 0.33. Richer than φ 0.6 there is no measurement and no instability onset; for town gas
none either. They measured the acceleration beyond onset as (R/R₀)^0.243; the model takes
their law, growing as (R/R₀)^0.243 out to a metre or four onset radii, whichever is further
(`FlammableGas.instabilityGrowth`); methane's wrinkling grows as (R/R₀)^(1/3) to four onset radii.

**The closed-vessel figures** compared against: hydrogen's K_G is the 550 bar m/s of
Bartknecht's time (Blanchard and Schildberg, CET 31, 2013, among others; NFPA 68 and EN 15967 were
not seen), its p_max SAFEKINEX's highest measured ratio, 7.91 (Deliverable 8, 2006, Table 16).
Hydrogen's K_G is not one number: EN 13673's method gives about 850, and SAFEKINEX measured
500–990 bar m/s in vessels from 2.8 to 1,250 dm³, peaking at 35–40%. Town gas's 7.1 bar and
140 bar m/s are Bartknecht's for a stand-in of 60% hydrogen and 40% methane (via Lautkaski,
Table 115).

**Not represented**, beyond what holds for every gas: a hydrogen–air cloud is light, 0.86 kg/m³
stoichiometric against air's 1.20, and the cloud starts at the air's density, the heat fitted to
the AICC pressure; and hydrogen's burning velocity rises steeply with the unburnt gas's
temperature, which the model holds fixed.

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
- The ignition point lights the one cell holding it (chosen on the host: a point on a face was a
  float tie, which lit one cell, all of them or none, as the shader happened to compile) as a
  spherical flame kernel: the cell's burnt gas
  taken as a sphere, expanded by σ, the flame its surface. It burns at ρ_u S_T times that area,
  (36π)^(1/3) (σ(1 − b))^(2/3)/Δ per volume, from a seed of a thousandth. So the burning grows from
  nothing, as a real kernel's does; started at full rate, it sent out a pressure pulse that opened a
  light vent panel. A flame cannot be smaller than a few cells, though. On a coarse grid it burns
  as a ball a cell or two across almost at once, far larger than a real kernel of the same age, and
  a small room's pressure rises early. A 2 m room on 0.25 m cells reaches 1 kPa in 35 ms.
- The burning is worked out for every cell before any cell burns, then applied, releasing its
  heat into the cell's energy.

### The burning velocity

S_T = f Ξ_r Ξ_t S_L. Each factor is optional:

- **Ξ_t, wrinkling by sub-grid turbulence** (on by default). It is Bauwens, Chaffee and
  Dorofeev's (2008, eq. 5) equilibrium wrinkling, the one their LES of FM Global's chamber used:
  Ξ_t = max(1, 1.48 a (u′/S_L)^(1/2) (Δ/δ)^(1/6)). This is Bradley, Lau and Lawes's (1992)
  turbulent burning velocity scaled by a = 0.7, which Bauwens et al. fitted to the initial flame
  speed in that chamber; a = 1 is Bradley's own. Δ, the cell, stands for the turbulence's length
  scale, and δ = ν_u/S_L is the laminar flame's thickness, ν_u = 1.5 × 10⁻⁵ m²/s falling as the
  unburnt gas is compressed.
- **u′ is the air's own sub-grid velocity.** It comes from the eddy viscosity ν_t of the air's
  [sub-grid mixing](air-blast-model.md#sub-grid-mixing), which a deflagration with flame
  turbulence turns on. The conversion is a one-equation model's: k = (ν_t/(C_k Δ))², with C_k =
  0.094 (Yoshizawa; Fureby et al. 1997, the sub-grid model Bauwens et al. used), and u′ = √(2k/3),
  as OpenFOAM's XiFoam takes it. So one sub-grid model carries the mixture, its products and heat
  across the cells and wrinkles the flame. Nothing counts the unresolved turbulence twice.
- **The mixing is Nicoud et al.'s σ-model, not Smagorinsky's.** Smagorinsky's |S| reads the
  laminar potential flow just ahead of a growing flame as turbulence. In a free ball it gave u′ up
  to 0.25 m/s there (u′/S_L ≈ 0.6), sped a quiescent closed sphere up by 15–20%, and Ducros's
  sensor did not remove it (that flow has neither divergence nor curl). The σ-model is zero in
  one-dimensional and axisymmetric flow, so a planar or spherical laminar flame is left nearly
  alone. What is left comes from the grid. A front four cells thick on a Cartesian lattice makes
  some three-dimensional flow at its leading edge (u′ ≈ 0.1 m/s on average there, in a ball on
  5 cm cells), and differences of a curved flow leave a share of Smagorinsky's value that falls
  as (Δ/r)².
- **Obstacles wrinkle the flame through the resolved flow.** Posts, walls and openings larger
  than a cell or two shape the flow, and the shear behind them gives the σ-model its u′. Below
  the grid's scale there is nothing (see [Limitations](#limitations)).
- **f, a constant factor** (1 by default): the venting literature's turbulence factor (Bradley
  and Mitcheson's β, Molkov's χ), for what is not otherwise represented.
- **Ξ_r, wrinkling by the flame's cellular instability** (on by default, `instability:
  .measured`). A spherical flame turns cellular, Darrieus and Landau's hydrodynamic instability,
  at a critical radius r₀, and then speeds up as its cells split.
  - *The onset is measured.* Bauwens, Bergthorson and Dorofeev (2015) measured r₀ on methane
    flames up to 2 m across in FM Global's 64 m³ chamber, the one compared with below: 0.225 m at
    φ = 1.00, from 0.204 m at φ = 0.81 to 0.32 m at 1.2 (their Table 1). r₀ is interpolated in φ.
    Their flames ran at 1.3 σS_L by 1.4 r₀ and about 1.45 by 4 r₀ (their Fig. 5).
  - *The growth is Gostintsev's.* Gostintsev et al. (1988) found large flames' radii growing as
    t^(3/2), so their speed as r^(1/3), the form Bauwens et al. use. Ξ_r = (r/r₀)^(1/3), r the
    distance from the ignition point; between 2 and 4 r₀ it is within about a tenth of their
    measurements, below them nearer r₀.
  - *It holds beyond 4 r₀* (0.9 m), where their measurements end, at 4^(1/3) = 1.59. Left to grow,
    it sent the flame through the vent at three times the tests' speed (see the trace below).
  - *Propane has no measured r₀* here (their propane paper was not found), so its instability is
    off unless an onset is given (`.onset(r₀)`).
  - Once a flame is thirty or more cells in radius its front corrugates on the grid itself (a
    to an eighth more area than a sphere's in the 48-cell closed sphere below), and the two then partly
    count the same wrinkling twice.
- **The external explosion, an option** (`externalFactor`, off by default). Molkov and Makarov
  (2004) needed a factor of 2 on the wrinkling of the flame outside the vent of a 547 m³ enclosure
  (SOLVEX), for the anisotropic turbulence of the vortex the vented cloud rolls into, which
  isotropic sub-grid models miss. Here it multiplies the burning velocity outside the cloud's
  region (their 100 ms ramp left out).

The flame's u′ is the step's own: the eddy viscosity is worked out from the flow at the start of
each step, and the flame burns after the step's sweeps. Earlier, the default flame had a
vorticity term (S_T − S_L = C Δ|ω|, after Peters) and wrinkling from a guessed 1 m. The first is
replaced; the second now starts at the measured radius.

**What was tried first.** The front was first a level set G, a signed distance carried by the
gas and advanced at S_T (the G-equation), with the mixture burnt as the front passed. It ran at
exactly σ S_L in a one-dimensional tube, σ the expansion ratio, but at half that in a growing
sphere. A sphere's visible speed is S_L plus the expansion's outflow at the front, and that falls
off as 1/r². Any gap δ between where the gas expands and where the front is taken to be cuts the
speed by about 1/(1 + 2(σ − 1) δ/r): a cell's gap costs 40% at twenty cells' radius. Burning by
mass at the front instead (ρ_u S_T δ(G)), with the front carried at the unburnt gas's velocity
extrapolated to it, was starved or ran away as the grid's diffusion moved mixture across the
band. Weller's form has neither problem.

## On terrain

Over sloping terrain the deflagration's air takes cut cells, as every scene's does (see
[terrain](terrain.md#cut-cells)): the cloud is laid down in the air each cut cell holds, and its
mixture is carried through each face's open part. On a 30° slope the staircase lets a flame grow
14–15% faster than on a flat floor; cut cells hold it within 1–5%.

## Vent panels

A panel is a box whose cells (those a block or the ground does not already fill) are solid until
the largest overpressure in a fluid cell beside any of them reaches its release pressure. Then all
its cells are cleared from the mask, and from the rigid mask a deformable structure's remasking
starts from. With a deformable structure in the scene the panel's cells are put in that rigid
mask as well when they are placed, after the structure: until 17 October 2026 they were not, and
the structure's first remask opened every panel at once. The panel has no mass and goes at once, an idealised vent cover. Its cells become
still air at the ambient state, a sliver of gas the room did not have. When it opened is recorded
(`BlastSolver.ventPanelOpenTimes`). A panel with a release pressure of zero or less is an open vent
and is never solid.

## Checks

### A closed sphere

A sphere of stoichiometric methane–air, 0.5 m in radius, voxelised by cell centre, lit at its
centre. The reference is the thin-flame model for the same sphere, burning velocity and AICC
pressure (Lewis and von Elbe; Dahoe et al. 1996): p = p₀ + (p_max − p₀) x for burnt mass fraction
x, the unburnt gas compressed adiabatically, and dx/dt = 3 r_f² S_u (p/p₀)^(1/γ)/R³. Its steepest
rise gives the deflagration index K_G = (36π)^(1/3) (p_max − p₀) (p_max/p₀)^(1/γ) S_u. For one
ideal gas burning to another with the same γ, as here, the linear rise is exact. `blastbench
deflagration vessel --cells 12,24,48,96`, a laminar flame and (`--accelerated`) the default one:

| Cells across the radius | Peak, bar | Half the rise, ms | Nine tenths, ms | K_G, bar m/s | Energy |
|---|---|---|---|---|---|
| 12 | 9.02 | 326 / 276 | 412 / 335 | 35 / 55 | conserved to 10⁻⁵ |
| 24 | 9.02 | 281 / 248 | 359 / 297 | 41 / 63 | |
| 48 | 9.02 | 250 / 217 | 308 / 259 | 51 / 74 | |
| 96 | 9.02 | 219 / | 271 / | 60 / | |
| Thin-flame model | 9.02 | 253 | 299 | 76 | |

- **Peak.** The whole mixture burns and the peak is the AICC pressure. That is by construction, as
  the heat was fitted to it, and it shows nothing is lost or gained: the energy the gas gains is
  the heat released to within 10⁻⁵. The measured peaks, 7.1–7.5 bar g in standard vessels
  (8.1–8.5 bar absolute), are lower for the heat lost to the walls, which the model does not
  represent.
- **Times, laminar: two errors that cross.** The laminar rise times pass through the thin-flame
  model's at 48 cells (within 1% and 3%) and go on past it: 13% and 9% early on 96. `--area`
  traces the front's area, the integral of |∇b|, against the thin-flame model's 4π r_f²:
  - *Early, the flame is slow.* A front four cells thick burns over too small an area while the
    flame is a few cells across: 0.49 of the sphere's at two and a half cells' radius, 0.78 at
    eight and 0.92 at fourteen (see
    [Grid convergence](#grid-convergence)). On 48 cells the first 1% of the rise comes at 90 ms
    against 74.
  - *In mid-burn, on fine cells, the front corrugates.* Once it is thirty or more cells in radius
    its area runs 9–13% above a sphere's on 48 cells (4% on 24), and the burn is that much fast.
    The flow the front makes is hydrodynamically unstable on the grid, as a real flame's is.
- **Times, default.** The default flame adds the σ-model's sub-grid wrinkling and the cellular
  instability from r₀ = 0.225 m, which a 0.5 m sphere passes at half its radius. It runs 12–15%
  ahead of the laminar one, and on 48 cells 14% and 13% ahead of the thin-flame model.
  - *Turbulence alone* ran 4–8% ahead of the laminar flame. In a quiescent sphere the σ-model's u′
    should be nothing; the grid's own flow at the front's leading edge gives it about 0.1 m/s
    there. With Smagorinsky's model instead (`--mixing-model smagorinsky`) turbulence alone ran
    14% ahead at 24 cells.
  - So the thin-flame comparison is the laminar flame's, and the default flame is expected to beat
    it, as real flames of this size do once cellular.
- **K_G cannot converge on this front.** Laminar, it rises by about 9 bar m/s a doubling: 35, 41,
  51, 60 on 12 to 96 cells, against 76. The thin-flame model's steepest rise comes at the very end,
  x → 1, at 9 bar, where the unburnt gas is compressed 4.8-fold. When the front is k cells from the
  wall, about 3 k × 4.8/N of the mass is still unburnt: on 48 cells, two cells out, 60% of it. The
  last tenth of the mass burns in a layer under 1% of the radius thick. A front four cells thick
  meets the wall long before then: its area falls to 0.96 of a sphere's at x = 0.6, 0.61 at 0.81
  and 0.25 at 0.94 (48 cells). So K_G reaches the thin-flame model's only once the front fits
  inside that layer, many hundreds of cells across the radius; at about 9 a doubling, two or three
  more doublings than run here.
  - The default flame's K_G, 74 on 48 cells, is near 76 only because its instability makes up for
    the thick front.
  - Measured K_G (55 in Bartknecht's vessels, 66 in a 20-litre sphere, 92 at 120 litres;
    Cashdollar et al. 2000) lies between, with heat loss to the walls lowering it, so agreement
    with them at any one resolution means little.
- **Cube-root law.** At 16 cells across the radius, laminar spheres of 0.25, 0.5 and 1 m give the
  same K_G (37 bar m/s), and their times scale with the radius. With sub-grid turbulence alone,
  44, 49 and 56: on the same number of cells a larger sphere has larger cells, and Bradley's
  (Δ/δ)^(1/6) wrinkles it a little more. The instability's fixed r₀ breaks the law too, as real
  flames do: Cashdollar's methane K_G rises from 66 at 20 litres to 110 at 25.5 m³.
- **Propane** (24 cells): peak 9.52 bar, the model's AICC; half rise at 260 ms laminar and 246
  with sub-grid turbulence against 230; K_G 46 and 59 against 89. No measured r₀, so no
  instability. **Hot air**: as the ideal gas, the times within 4%.
- **A tube** (DeflagrationTests): a flame lit at the closed end of a narrow tube runs at the
  model's expansion ratio times the burning velocity, 2.7 m/s, to within 10%, laminar or with
  sub-grid turbulence: the flow is one-dimensional and the σ-model sees no turbulence in it.

### Where a vented room's pressure was lost

The trace was run with copying open faces, which drained the domain; far-field faces raise the
peaks by 10–30% (see below). Before the cellular instability was added, FM Global's chamber
reached a seventh of test 1's measured peak and the correlations' were thirty to fifty times the
model's. Traced, item by item:

- **Early pressure goes as the flame's speed to about the sixth power.** Before the burnt gas
  reaches the vent, the overpressure is set by the volume the flame makes, which goes as S r² with
  r growing as S t. At 0.3–0.45 s test 1's back wall read 0.45–1.3 kPa, the model's 0.03–0.07 kPa,
  and Bauwens et al.'s LES 0.2–0.7.
  - *The tests' young flame was fast.* Their thermocouples put the flame at 1 m by about 0.26 s,
    and their burnt gas reached the vent by 0.45 s. The model's flame reached the vent at 0.73 s.
  - *Lit in the middle, the back of the model's flame stalled* between 0.5 and 1 m from the
    ignition point. The vent drew the unburnt gas behind it through the flame at 1–2.5 m/s, faster
    than it burnt, while the tests' flame ran at 3 m/s.
- **The vent's cover is not it.** The tests' polypropylene sheet went at 0.2–0.3 s. A 0.3 kPa panel
  standing for it went at 0.20 s, as the sheet did, and test 1 gave 0.33 kPa against 0.30 open.
- **The flame's speed and wrinkling near the vent are about right once it is grown.** Lit at the
  back wall, the flame ran at the tests' speeds from 3 m on. At the vent and outside, the σ-model's
  u′ is 0.1–0.25 m/s and Bradley's correlation wrinkles 70–95% of the front, so turbulence made at
  the vent is not missing.
- **The young flame is short on two counts.**
  - *Numerically*, a thick front burns over too small an area until it is about seventeen cells in
    radius (see [Grid convergence](#grid-convergence)). Correcting it raised the peaks by only
    10–20%.
  - *Physically*, the cellular instability was missing. Bauwens et al. (2015) measured its onset
    in this chamber at 0.225 m, and their flames ran 30–45% faster than laminar from 0.3 to 0.9 m.
    The tests' 0.1 m/s of initial turbulence adds about a tenth (Bauwens et al. 2008: 1.2 times
    laminar at 0.3 m, both together).
- **The expansion ratio** (6.6 for the ideal gas against 7.5) matters less: hot air (7.1) raised
  test 1 from 0.30 to 0.39 kPa and test 4 from 2.88 to 3.21.
- **The external explosion.** Molkov and Makarov's factor of 2 outside the vent raises test 1 from
  0.89 to 2.18 kPa (2.17 measured) and test 6 from 12.9 to 14.5 (7.94). It helps where the room is
  lit in the middle and overshoots further where it is lit at the back wall, so it is an option,
  not the default.
- **Helmholtz and acoustic peaks.** The tests' first peak (Helmholtz oscillation with the Taylor
  instability, and the external explosion) and the acoustically driven second are resolved only as
  far as the grid and the flame allow; the model's peaks are single and broad. Test 5's measured
  maximum is the acoustic peak at 1.22 s, and the model gets 0.37 of it.

So the instability was the largest missing piece. Unbounded beyond its measured range, Gostintsev's
r^(1/3) overshot badly where the flame runs far (test 6: 28.9 kPa against 7.9; test 4: 10.3
against 4.8). Held at 4 r₀, where the measurements end, it is the default.

### Vented rooms against the correlations

FM Global's 63.7 m³ chamber as Bauwens et al. used it: 4.6 × 4.6 × 3.0 m inside, a square vent in
the middle of a 4.6 × 3 m wall, stoichiometric methane, lit in the middle. The walls and roof are
0.2 m thick, with 2 m of air round the room and 5 m beyond the vent. P_red is the peak overpressure
at the middle of the back wall, after a 1/80 s moving average, as Bauwens et al. filtered theirs
at 80 Hz. `blastbench deflagration vented --vent 2.7,4,5.4,8 --dx 0.1`, open vents. The domain's
open faces have ambient air beyond them; until 16 October 2026 they copied the cells inside, which
drained the domain below ambient and lowered the peaks by 10–30% (the copying faces' columns
below, `--copy-faces`):

| Vent, m² | Default | Default, copying faces | Sub-grid turbulence alone, copying | Laminar, copying | Molkov | Bartknecht | NFPA 68 |
|---|---|---|---|---|---|---|---|
| 2.7 | 3.48 kPa | 3.05 | 1.36 | 0.9 | 77 | 94 | 179 |
| 4.0 | 1.94 | 1.51 | 0.55 | | 35 | 48 | 81 |
| 5.4 | 1.53 | 1.12 | 0.41 | 0.3 | 19 | 29 | 45 |
| 8.0 | 1.27 | 0.91 | 0.29 | | 8 | 15 | 20 |

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

- **The model's pressures are below the correlations'**: a seventh to a twenty-second of Molkov's
  best fit, and a sixteenth to a fiftieth of NFPA 68's.
- **The trend with vent area is flatter than the correlations'**: the pressure falls as A_v^−0.9
  against A_v^−2 for NFPA 68 and Molkov. The large vent's peak, the burnt gas leaving, falls least.
- **The correlations are conservative for this room.** The tests below, in the same chamber,
  measured a tenth to a quarter of Molkov's fit, and a twentieth to an eighth of NFPA 68's. Lit in
  the middle the model is below the tests too (1.5 kPa against 2.2–2.7 for the large vent, 3.5
  against 7.2 for the small), so there it is on the unsafe side of both.

**Obstacles.** With square posts 0.2 m wide from floor to ceiling on a 1 m grid in the room (`--posts
0.2`, 24 posts, 4.5% of the floor), test 1's mixture gave 0.55 kPa with sub-grid turbulence alone
against 0.30 without the posts. The laminar flame gave 0.20 against 0.23: it is only blocked. The
flame's speed at 2 m from the ignition point rose from 10 to 23 m/s. So the flow round obstacles the
grid resolves wrinkles the flame, through the σ-model's u′ in the shear behind them. No test with
these posts exists to say how far.

### Bauwens, Chaffee and Dorofeev (2008)

Six tests in that chamber, near-stoichiometric methane, nearly quiescent (u′ about 0.1 m/s), the
vent covered by a 0.02 mm polypropylene sheet. The model treats the vent as open, as their LES did.
The peaks are plotted only (the back wall's pressure, P1, filtered at 80 Hz, and the flame's speed
along the vent's axis), and were digitised here from the PDF's vector paths
(`/Volumes/StudioData/bombcad/data/Bauwens2008/digitised/`, calibrated on 5–11 labelled ticks an
axis, to 0.01 kPa). `blastbench deflagration vented --vent 5.4 --percent 9.0 --speeds` and so on,
0.1 m cells, far-field faces (the copying faces' runs alongside):

| Test | Methane | Ignition | Vent, m² | Measured, kPa | Their LES | Model | Model, copying faces | Sub-grid turbulence alone, copying | Molkov |
|---|---|---|---|---|---|---|---|---|---|
| 1 | 9.0% | middle | 5.4 | 2.17 (0.47 s) | 1.82 | 1.17 | 0.89 | 0.30 | 19 |
| 2 | 10.3% | middle | 5.4 | 2.71 (1.08 s) | 1.82 | 1.57 | 1.19 | 0.40 | 19 |
| 3 | 9.8% | back wall | 5.4 | 5.35 (0.57 s) | 1.39 | 4.75 | 4.30 | 2.93 | 19 |
| 4 | 9.5% | back wall | 5.4 | 4.79 (0.52 s) | 1.39 | 4.63 | 4.20 | 2.88 | 19 |
| 5 | 9.2% | middle | 2.7 | 7.23 (1.22 s) | 8.49 | 2.98 | 2.69 | 1.30 | 77 |
| 6 | 9.2% | back wall | 2.7 | 7.94 (0.58 s) | 4.90 | 14.2 | 12.9 | 4.49 | 77 |

Their LES ran one mixture, 9.5%, for each figure, so tests 1 and 2 share a value, and so do 3 and 4.

**The flame's speed** (from its arrival every half metre along the vent's axis, 1.4 m above the
floor, as their thermocouples were; m/s, against distance from the ignition point):

| | at 1 m | 2 m | 3 m | largest |
|---|---|---|---|---|
| Test 1, measured / model | 6.8 / 6.0 | 18.7 / 14.9 | 19.7 / 22.0 | 20 / 23 |
| Test 4, measured / model | 6.4 / 4.9 | 11.9 / 11.9 | 20.2 / 28.0 | 45 / 96 |
| Test 6, measured / model | 5.7 / 4.5 | 11.2 / 10.7 | 20.0 / 25.8 | 125 / 212 |
| Test 1, towards the back wall | −2.6 to −3.6 / −2.3 to −3.9 beyond 1 m | | | |

Test 6's largest leaves out two arrivals within a step of their neighbours' (over 1,000 m/s). The
speeds are those of the far-field runs; the copying faces' were within 2% inside the room.

- **Overall the model is within a factor of 2.5 of every test**, against a factor of 7 before:
  the model-to-measured ratio's geometric mean over the six is 0.76 (0.65 with copying faces, 0.30
  with sub-grid turbulence alone and copying faces).
- **Lit at the back wall it is closest on the large vent**: 89–97% of the measured peaks, nearer
  than their LES (1.4 kPa). On the small vent (test 6) it is 1.8 times the measured peak. Its flame
  speeds match the measured ones to 2 m, run a third fast at 3 m, and are too fast leaving through
  the vent (96 m/s against 45 in test 4).
- **Lit in the middle it is low**, 0.41–0.58 of the measured peaks, where their LES came within
  a third. Its flame speeds inside the room are within a fifth of the measured ones, but the back of
  the flame still stalls between 0.5 and 1 m from the ignition point (see the trace above), before
  running at the tests' speed beyond. Their measured maxima for tests 2 and 5 are the acoustically
  driven second peaks, which the model does not reproduce.
- **The measured mechanisms are partly there.** Bauwens et al. trace the first large peak to a
  Helmholtz oscillation, amplified by the Taylor instability of the flame as the burnt gas is
  accelerated back into the room, and to the external explosion. The second comes from feedback
  between the room's acoustics and the burning. The model resolves the oscillation and the external
  burning only as far as its grid and flame allow; the Taylor instability's wrinkling below the grid
  it does not have, as their LES did not.

### Hydrogen and town gas

**In a closed sphere** (as [above](#a-closed-sphere), 0.5 m, lit at the centre; `blastbench
deflagration vessel --gas hydrogen --percent 29.5 --cells 12,24,48`, and `--accelerated` for the
default flame). K_G in bar m/s, laminar / default flame:

| Mixture | 12 cells | 24 | 48 | Thin-flame model | Measured |
|---|---|---|---|---|---|
| Hydrogen 29.5% (stoichiometric) | 155 / 177 | 189 / 204 | 233 / 240 | 322 | 550 (500–990 by vessel) |
| the same, default flame with 1/Le (below) | | 491 | 545 | | |
| Hydrogen 15% | | 11 / 18 | 13 / 22 | 19 | |
| the same, default flame with 1/Le | | 68 | 77 | | |
| Town gas 25% | 69 / 81 | 86 / 97 | 101 / 108 | 146 | 140 |

- The peaks are the AICC pressures, 8.11, 4.62 and 7.96 bar, by construction, the energy
  conserved to 10⁻⁵, as for methane.
- **Stoichiometric hydrogen reads 0.4 of the measured K_G.** The thin-flame model on Taylor's
  burning velocity gives 322, 0.59 of the 550: measured hydrogen flames in vessels accelerate by
  their own instability, which no measured onset represents here richer than φ 0.6. Town gas reads
  0.77 of its (stand-in's) 140, as methane reads 0.64–1.35 of its 55.
- **Lean hydrogen's onset takes the default flame 60–65% faster** (13 to 22 on 48 cells), at its
  measured critical radius of 23 mm.

**Vented, in FM Global's chamber.** Bauwens, Chao and Dorofeev measured lean hydrogen deflagrations
in the same 63.7 m³ chamber as their methane (ICHS 2011, paper 237, Table 1; the journal version
is IJHE 37, 2012): a square vent of 5.4 or 2.7 m² closed by a 0.02 mm sheet (taken here as open),
quiescent mixtures, lit at the centre or 0.25 m from the back wall. `blastbench deflagration
vented --gas hydrogen --percent 18 --vent 2.7 --ignition back`, 0.1 m cells. Peak overpressure,
kPa, the measured being the larger of their external and internal (Helmholtz) peaks:

| Ignition, vent, H₂ | Measured | Model, with 1/Le | Ratio | Without 1/Le | Ratio | Methane's growth law, ratio |
|---|---|---|---|---|---|---|
| Centre, 5.4 m², 12.1% | 0.9 | 1.94 | 2.16 | 0.22 | 0.24 | 0.13 |
| Centre, 5.4 m², 14.9% | 2.0 | 5.91 | 2.96 | 0.66 | 0.33 | 0.15 |
| Centre, 5.4 m², 18.0% | 7.1 | 17.9 | 2.52 | 2.63 | 0.37 | 0.15 |
| Centre, 5.4 m², 19.7% | 11.1 | 27.4 | 2.47 | 4.32 | 0.39 | 0.17 |
| Centre, 2.7 m², 18.0% | 23.4 | 35.0 | 1.49 | 5.19 | 0.22 | 0.10 |
| Back wall, 2.7 m², 15.1% | 12.7 | 17.9 | 1.41 | 3.58 | 0.28 | 0.12 |
| Back wall, 2.7 m², 17.8% | 31.4 | 44.3 | 1.41 | 10.96 | 0.35 | 0.16 |
| Back wall, 5.4 m², 17.9% | 15.0 | 18.6 | 1.24 | 2.91 | 0.19 | 0.08 |

**Without its thermodiffusive response, lean hydrogen vented at 0.19–0.39 of the measured peaks:
the unsafe side, below methane's 0.4–0.6 lit in the middle of the same chamber.** With methane's
growth law, capped at four onset radii (7–12 cm for lean hydrogen), it read 0.08–0.17; the measured
lean hydrogen law, (R/R₀)^0.243 to a metre (Bauwens et al. 2015, see
[above](#hydrogen-and-town-gas)), doubled it.

**With 1/Le** (17 October 2026; `FlameAcceleration.thermodiffusive`, on by default):
- **The factor:** the burning velocity times 1/Le, Le the deficient reactant's Lewis number
  (`FlammableGas.lewisNumber`, from Cantera's mixture-averaged transport: 0.36 at 12%, 0.39 at
  18%), 2.6–2.8 here.
- **The source:** Bauwens et al. (2011) took 0.9/Le, about 2 at 18% with their Le of 0.46, fitted
  to these tests. Here nothing is fitted: the coefficient is one. Fitted to these tests it would be
  0.75 (0.70–1.62 of the peaks), but that was not kept: it read the containers below lower still.
- **The result:** the peaks are 1.24–2.96 of the measured, on the safe side. Those lit at the back
  or behind the smaller vent come within 1.2–1.5; those lit in the middle with the larger vent are
  2.2–3.0.
- **The closed sphere, unfitted:** stoichiometric hydrogen's K_G comes to 491–545 bar m/s, against
  the measured 550 (500–990 by vessel). Its thermodiffusive acceleration is what the thin-flame
  model's 322 had lacked.

What is still left out:
- The external explosion and the Helmholtz oscillations that set several of the measured peaks.
- The lean flame's buoyancy: a 12% flame rises as it grows.
- Richer than stoichiometric the deficient reactant is oxygen, whose Lewis number is above one, so
  the factor falls from 2.3 to one across φ 1. Rich hydrogen's own instability is not represented.

**Vented, in HySEA's containers** (unfitted). Skjold et al. vented homogeneous, quiescent hydrogen
in 20 ft ISO containers, 5.87 × 2.35 × 2.40 m inside (ICHS 2017, paper 223, Tables 1–2; the
HySEA project, open on Zenodo). The empty containers ("frame only") are compared, in two
configurations:
- **Doors:** the whole end open, lit at the back wall's centre 1.2 m up (`blastbench deflagration
  vented --gas hydrogen --percent 15 --container doors --vent 5.64`).
- **Roof:** 4, 6 or 8 m² of eight 1 m² roof openings sealed with perforated film, lit at the floor's
  centre (`--container roof --vent 4,6,8`). The openings are in four pairs across the roof, about
  1.0, 2.1, 3.3 and 4.5 m from the back wall, read from the paper's Figure 7: 4 m² is the middle two
  pairs, 6 m² adds the pair by the doors, and 8 m² all four.

Peak overpressure inside, kPa, 0.1 m cells:

| Test | Measured | Model, with 1/Le | Ratio | Without | Ratio |
|---|---|---|---|---|---|
| Doors, 15% (tests 1–6) | 3.9–7.7 (mean 5.2) | 5.54 | 0.72–1.42 (1.07 of the mean) | 0.70 | 0.13 |
| Roof, 4 m², 21% (test 25) | 14.6 | 6.55 | 0.45 | 1.54 | 0.11 |
| Roof, 6 m², 21% (test 21) | 12.0 | 4.76 | 0.40 | 0.88 | 0.07 |
| Roof, 8 m², 21% (test 16) | 19.0 | 3.53 | 0.19 | 0.58 | 0.03 |

(Without 1/Le, the runs used evenly spaced openings; with them, the paper's 7.72, 4.80 and 3.74 kPa.)

- **The doors:** within the six repeats' own scatter.
- **The roof:** still on the unsafe side, 0.19–0.45 (0.20–0.53 with the openings assumed evenly
  spaced). The measured peaks do not fall as the vent grows (8 m² gave the highest), which no
  venting correlation has.
- **Four candidate causes, each added in turn** (kPa at 4 / 6 / 8 m²; 6.55 / 4.76 / 3.53 with the
  paper's layout alone):
  - the steel frame of 200 × 75 mm channels on the floor round the ignition point (`--frame`,
    Figure 3): 0–4% more;
  - gravity, for the burnt gas's buoyancy (`--gravity`): 10–20% less, the flame rising to the
    openings sooner;
  - 6 m of air above the roof for the external explosion (`--clearance 6`, against 2): 5–8% less;
  - all three: 6.21 / 4.33 / 2.80 kPa, 0.43 / 0.36 / 0.15 of the measured.

  The doors with all three read 6.01 kPa, still within their scatter. None of the four closes the
  gap, so none is kept beyond the paper's layout.
- **The likeliest cause left is the film itself.** It was 0.2 mm polyethylene, 0.185 kg/m²,
  perforated along its edges, and its opening pressure is not given. Peaks that do not fall with
  the vent's area are what a cover's opening sets. The commercial panels, at 0.1 bar, gave 19–25
  kPa in the same tests. The model takes the film as open.

**Where lean hydrogen stands.** The fitted coefficient was set aside, so nothing is fitted:
- FM's chamber reads 1.2–3.0 of the measured peaks.
- The containers' doors read within their scatter.
- The closed sphere's K_G reads 0.89–0.99.
- The containers' roof vents read 0.2–0.45.

So the containers' roof and FM's centre-lit tests fall outside 0.5–2, and the comparison stops
here.

Other open vented hydrogen tests, for later: INERIS's 1 and 10.5 m³ vessels (Daubech et al.,
ICHS 2011), tabulated; HySEA's containers with obstacles, vent panels and stratified mixtures
(the same papers, and Skjold et al., CET 77, 2019).

### Grid convergence

- **A laminar flame converges only once it is many cells across.** A front four cells thick, in a
  growing ball, holds more of its burnt mass in its outer, larger half, so its middle, where
  |∇b| weighs, lags the radius of the ball that mass makes by about a cell. It burns over too
  small an area, (1 − 0.9 Δ/r)²; the ball grows at 55% of σ S_L at three cells' radius, 73% at
  six, 83% at ten, and close to σ S_L by about seventeen (`blastbench deflagration ball --closed`,
  2.5, 5 and 10 cm cells alike). On 0.1 m cells that is the first 1.7 m of a room. Scaling the
  burning by (1 + 0.75 Δ/r)², r the distance from the ignition point, made a ball grow within 3% of
  σ S_L from six or seven cells. But it put the closed sphere 5, 7 and 12% ahead of the thin-flame
  model on 12, 24 and 48 cells, and raised the vented peaks by only 10–20%, so it was not kept.
  Scaling by the front's own curvature fed back on the grid's corrugations, convex parts burning
  faster and growing.
- **The flame's speed in a vented room converges; its peak pressure roughly does.** Test 1 on
  0.2, 0.1 and 0.05 m cells, the default flame, copying faces (as run before 16 October 2026):

  | Cells | P_red | Speed at 1.25 / 1.75 / 2.25 / 2.75 m |
  |---|---|---|
  | 0.2 m | 1.91 kPa | 6.7 / 18.2 / 22.2 / 47.8 m/s |
  | 0.1 m | 0.89 | 8.1 / 12.8 / 17.0 / 20.6 |
  | 0.05 m | 0.75 | 9.0 / 15.5 / 24.2 / 28.8 |
  | Measured | 2.17 | 9.1 / 17.7 / 19.3 / 19.9 |

  On 0.05 m cells the speeds match the measured ones to 1.75 m and run a quarter to a half fast
  beyond, and the peak is within a sixth of the 0.1 m cells'. The 0.2 m cells' are too coarse for a
  front four cells thick in a 4.6 m room. At these amplitudes the peak is whichever of several
  transients is largest, so a single run's peak is uncertain by about ±20% on 0.1 m cells or finer.
  Bauwens et al. found their LES within 8% on 6, 7.5 and 10 cm cells.

## Limitations

1. **The flame's acceleration is only partly modelled.** A vented room's peak pressure is set by
   how fast the flame burns when the vent is open. In tests that comes from the turbulence the
   outflow makes, cellular and Taylor instabilities (the second amplified by Helmholtz
   oscillation), and the external explosion. The model wrinkles the flame by its sub-grid
   turbulence, after Bauwens et al.'s LES, whose one constant they fitted in this chamber, and by
   its cellular instability from an onset measured there too.
   - The instability is held beyond four onset radii for methane, and beyond about a metre for
     hydrogen, where the measurements end; larger flames may accelerate further.
   - The Taylor instability and the external vortex's extra wrinkling are not modelled; the
     latter is an option (Molkov and Makarov's factor of 2).
   - Lit in the middle of FM Global's chamber the peaks are 0.4–0.6 of the tests', and the
     flame stalls towards the back wall; lit at a back wall, 0.9–1.8 of them.
2. **A young flame is slow**: until it is about seventeen cells in radius, a front four cells thick
   burns over too small an area (55–83% of it from three to ten cells). On 0.1 m cells that is most
   of a room. The tests' initial turbulence (u′ ≈ 0.1 m/s) is not carried.
3. **In a quiescent vessel the default flame beats the thin-flame model**, by 13–14% on 48 cells:
   the instability is meant to; a few percent of it is the grid's own flow at the front, which the
   σ-model reads as turbulence. On fine cells the front also corrugates on the grid, and then the
   instability partly counts the same wrinkling twice.
4. **Obstacles:** those larger than a cell or two shape the resolved flow, and the σ-model's u′ in
   their wakes wrinkles the flame. Congestion below the grid's scale has its own illustrative model
   ([Congestion below the grid](congestion-model.md)), within 0.4–1.2 of MERGE's finer pitches but
   three to five times high at its coarser. There is no transition to detonation.
5. **Products treated as air.** The heat is fitted to the AICC pressure at stoichiometric and
   applied at every concentration. The expansion ratio comes out 6.6 (ideal gas) or 7.1 (hot air)
   against 7.5. The cloud's own density is not represented. Rich and lean mixtures' heat follows
   the fuel or oxygen they burn, but their AICC pressures are not checked.
6. **The burning velocity** does not depend on the unburnt gas's pressure and temperature or heat
   loss, and on flame stretch only through lean hydrogen's 1/Le and congestion's SCOPE wrinkling. A flame is not quenched at walls, and dilution below the
   flammability limit stops it only through the burning velocity.
7. **K_G cannot converge on this front**: the last tenth of a closed vessel's mixture burns in a
   layer under 1% of its radius thick, and a front four cells thick needs hundreds of cells
   across the radius to resolve it (35 to 60 bar m/s on 12 to 96 cells, against 76).
8. **Vent panels have no mass** and go at once. Panels of several kilograms a square metre hold
   on longer and raise the pressure, and EN 14994 corrects for their inertia.
9. **Open faces:** a vented room's checks run with far-field faces, ambient air beyond them. With
   the faces copying the cell inside them (an option), burnt gas wrapping round a room against an
   open face drew itself back in and pressurised the whole domain, so leave a few metres of air
   round a vented room.
10. **Refinement, still-air skipping and afterburning are turned off** with a deflagration, the
   first two because the flame is advanced everywhere on the coarse cells, the last because the
   cloud takes its species.

## Future work

- Congestion below the grid with the pitch's effect, sharing the obstacles between what the grid
  resolves and what it models ([what was tried](congestion-model.md#merge)), so that an open vapour
  cloud explosion is predicted rather than fitted.
- Find why a flame lit in the middle of a vented room stalls towards the back wall, where the tests
  and their LES ran at 3 m/s.
- A young flame that burns at its speed from the start: a sub-grid ignition kernel, carried until
  the resolved front is many cells across, in place of the area lost to the front's thickness.
- A thinner front, or one tracked across the cell, for K_G and the last unburnt layer.
- The tests' initial turbulence, as resolved eddies laid down with the cloud.
- The instability beyond four onset radii, and propane's onset (Bauwens et al. 2015, Proceedings
  of the Combustion Institute 35); the Taylor instability's wrinkling under acceleration; the
  external vortex's (Molkov and Makarov), as a model rather than a factor.
- Obstacles' sub-grid turbulence, as porosity–distributed-resistance models carry it.
- The burning velocity's dependence on pressure and temperature (Metghalchi and Keck), and the
  products' own heat capacities instead of a fitted share of the heat.
- Vent panels with inertia, and panels that hinge.
- HySEA's containers with obstacles, vent panels and stratified mixtures, and the roof film's
  opening; INERIS's 1 and 10.5 m³ vessels; rich hydrogen's instability.

## Sources

- Bauwens, C. R., Bergthorson, J. M. and Dorofeev, S. B. (2015). Critical Peclet numbers for the
  onset of Darrieus–Landau instability in atmospheric-pressure methane–air flames. *25th ICDERS*,
  Leeds, paper 231 (Table 1, the critical radii; Fig. 5, the flame speeds beyond them).
- Bauwens, C. R., Chaffee, J. and Dorofeev, S. (2008). Experimental and numerical study of
  methane–air deflagrations in a vented enclosure. *Fire Safety Science* 9, 1043–1054.
  doi:10.3801/IAFSS.FSS.9-1043 (eq. 5, the equilibrium wrinkling and a = 0.7; Figs. 3 and 6–9,
  digitised).
- Bradley, D., Lau, A. K. C. and Lawes, M. (1992). Flame stretch rate as a determinant of turbulent
  burning velocity. *Philosophical Transactions of the Royal Society A* 338, 359–387.
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
- Fureby, C., Tabor, G., Weller, H. G. and Gosman, A. D. (1997). A comparative study of subgrid
  scale models in homogeneous isotropic turbulence. *Physics of Fluids* 9, 1416–1429 (the
  one-equation model, ν_t = C_k Δ √k, C_k = 0.094 after Yoshizawa).
- Gostintsev, Yu. A., Istratov, A. G. and Shulenin, Yu. V. (1988). Self-similar propagation of a
  free turbulent flame in mixed gas mixtures. *Combustion, Explosion and Shock Waves* 24, 563–569.
- Gülder, Ö. L. (1984). Correlations of laminar combustion data for alternative S.I. engine fuels.
  SAE 841000 (coefficients as OpenFOAM's Gulders.C has them).
- Kasmani, R. M. (2008). *Vented gas explosions*. PhD thesis, University of Leeds.
- Bauwens, C. R., Bergthorson, J. M. and Dorofeev, S. B. (2015). Experimental investigation of
  spherical-flame acceleration in lean hydrogen–air mixtures. *ICHS 2015*, paper 202 (Table 1: the
  critical radii and burning velocities; the growth exponent 0.243). Journal version: *IJHE* 42
  (2017) 7691–7697.
- Bauwens, C. R., Chao, J. and Dorofeev, S. B. (2011). Effect of hydrogen concentration on vented
  explosion overpressures from lean hydrogen–air deflagrations. *ICHS 2011*, paper 237 (Table 1).
- Blanchard, R. and Schildberg, H.-P. (2013). *Chemical Engineering Transactions* 31, 667–672
  (K_G of hydrogen, methane and propane, by method).
- Coward, H. F. and Jones, G. W. (1952). *Limits of flammability of gases and vapors*. US Bureau of
  Mines Bulletin 503 (town and coal gases' compositions and limits, pp. 120–121).
- Drell, I. L. and Belles, F. E. (1957). *Survey of hydrogen combustion properties*. NACA RM
  E57D24 (the recommended burning velocities, adiabatic flame temperatures).
- Lautkaski, R. (2011). *Duct venting of gas explosions*. VTT-R-02755-11 (Table 25: town gas
  compositions; Table 38: its burning velocities from Cubbage and Simmonds; Table 115: K_G).
- OECD/NEA (2000). *Flame acceleration and deflagration-to-detonation transition in nuclear
  safety*. NEA/CSNI/R(2000)7 (Table A.1.1-2: hydrogen burning velocities from 18 studies).
- Rasbash, D. J. (1969). *The relief of gas and vapour explosions in domestic structures*. Fire
  Research Note 759 (Table 1: burning velocities, town gas 1.2 m/s).
- SAFEKINEX (2006). Deliverable 8, BAM (Tables 2, 16, 17 and Fig. 27: hydrogen's limits, maximum
  pressures and K_G by vessel).
- Taylor, S. C. (1991). *Burning velocity and the influence of flame stretch*. PhD thesis,
  University of Leeds (appendix: hydrogen–air expanding flames).
- Zabetakis, M. G. (1965). *Flammability characteristics of combustible gases and vapors*. US
  Bureau of Mines Bulletin 627 (Table 21).
- Lautkaski, R. (2011). VTT research report VTT-R-02755-11, on vent sizing for gas explosions
  (Bartknecht's equation and Molkov's correlations as the standards use them).
- Molkov, V. (2001). Unified correlations for vent sizing of enclosures at atmospheric and elevated
  pressures. *IChemE Symposium Series* 148 (Hazards XVI), eqs. 3–5.
- Molkov, V. V. and Makarov, D. V. (2004). Rethinking the physics of a large-scale vented explosion
  and its mitigation. *IChemE Symposium Series* 150 (the external vortex's wrinkling factor of 2).
- Nicoud, F., Baya Toda, H., Cabrit, O., Bose, S. and Lee, J. (2011). Using singular values to build
  a subgrid-scale model for large eddy simulations. *Physics of Fluids* 23, 085106 (the σ-model,
  C = 1.35).
- Osher, S. and Fedkiw, R. (2003). *Level Set Methods and Dynamic Implicit Surfaces*. Springer
  (ENO differences and Godunov's upwind Hamiltonian).
- Weller, H. G. (1993). The development of a new flame area combustion model using conditional
  averaging. Imperial College, Thermo-fluids section report TF 9307; Weller, H. G., Tabor, G.,
  Gosman, A. D. and Fureby, C. (1998). Application of a flame-wrinkling LES combustion model to a
  turbulent mixing layer. *Proceedings of the Combustion Institute* 27, 899–907.
