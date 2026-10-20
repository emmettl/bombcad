# Ground motion where the ground's wave outruns the blast: a proposal

**Status: stages 1 to 3 built (17 October 2026), and the line stopped there; against Prairie
Flat (20 October 2026) the half-space carries the motion ahead of an outrunning blast within a
factor of two, and stage 4 is proposed ([below](#against-prairie-flat-20-october-2026)). The half-space
does not close the gap with Xia et al.'s measurements, elastic or yielding: the vertical motion
is still 15 to 90 times too high; the horizontal within 1.5 times (elastic) or 2.1 to 2.4 times
(yielding) at 21 m, but 10 to 20 times too high at 42 m. Soil that yields does make the
calibrated direct source unnecessary ([stage 3](#stage-3-soil-that-yields)).** A plan for the motion that the one-dimensional
models in [Ground shock](ground-shock.md) leave out. That is the regime of Xia et al.'s gauges,
where both models put the vertical velocity 20 to 80 times too high and miss the horizontal
motion that dominated ([the comparison](ground-shock.md#against-measured-ground-motion)), and of
most of the far field around large surface bursts.

## What is missing

Under a surface burst, the air's front slows as it spreads, and beyond some range it moves over
the ground more slowly than the soil's compression wave (c_P), and later than its shear (c_S)
and Rayleigh waves. From there the ground moves before the air arrives, carried by waves that
started nearer the charge, and the motion is two-dimensional: P, S and Rayleigh waves arriving
at angles, with horizontal motion as large as vertical or larger. The present soil column is a
vertical plane wave under each point and cannot carry any of that. Three things are needed:

1. Waves in the ground that travel sideways: an elastic, layered half-space under the whole
   loaded area, not a column under each point.
2. The load that drives them: the air's pressure over the ground as it sweeps outwards, and,
   near the charge, what the charge drives into the ground directly, which the crater's region
   takes ([cratering](cratering.md)).
3. Vertical and horizontal velocity, acceleration and displacement at the ground points and at
   depth, for the same outputs and app views as now.

## The approach

**Recommended: a two-dimensional axisymmetric elastodynamic solver,** driven by the air's
ground pressures streamed frame by frame, as the soil column is now.

- **The equations:** velocity–stress elastodynamics in (r, z) about the vertical through the
  charge, on a staggered grid (Virieux's scheme in cylindrical form), explicit in time. The
  layers come from the soil profile already in the ground-shock description, with an S-wave
  speed added to each layer (or a Poisson's ratio).
- **Its boundaries:** a free surface loaded by the overpressure p(r, t), and an unsplit
  convolutional perfectly matched layer (Komatitsch and Martin) on the far side and the bottom,
  so the waves leave cleanly.
- **The soil:** elastic with Rayleigh damping first; then the column's bilinear loading and
  unloading as an option, applied to the volumetric part, so the near field softens as it does
  in the column.
- **The load:** the ground slice the column already receives, averaged round rings centred on
  the charge to give p(r, t), and rebuilt between frames with the column's load rules
  (`GroundLoad`, averaged over a few steps). Near the charge, inside the crater's radius, the
  air's pressure on rigid ground would drive the soil far beyond anything elastic. That region
  needs a source equal to what the charge couples into the ground. The crater's stage 1 already
  gives the ground's share of the energy (a third of the charge's energy for a burst on the surface, `CraterEstimate.groundShare`). The proposal is
  to deliver that share as an equivalent pressure on the crater's surface, calibrated once
  against UFC 3-340-01's direct-induced relation and checked against Xia.
- **Its output:** at each ground point, sampled at its range and depth, the vertical and radial
  velocity and displacement, and the arrivals of the P, S and Rayleigh waves. In the
  superseismic region near the surface, where the air's front is faster than every wave, the
  result should reduce to the column's.

**Why not the alternatives first:**

- **Green's functions for a moving load** (Lamb's problem: Pekeris's closed form for a point
  load, Cole and Huth's steady line load moving at any speed, Johnson's full half-space
  functions, Bouchon's discrete wavenumber method for layers). These are exact for linear
  layers, and in the frequency domain they carry frequency-independent damping exactly. But
  they need the whole load history before they start (no streaming), they are linear only, and
  a general three-dimensional load needs a transform over the surface. They are kept as the
  verification references: Pekeris's surface pulse and Cole and Huth's regimes are the solver's
  first checks.
- **The manuals' outrunning methods** (TM 5-855-1; Hendron and Auld, 1967). These are cheap
  estimates in the spirit of the present estimate. Their relations are not in hand: DTIC and
  the manuals' text are listed in [Data wanted](data-wanted.md). Once obtained, they would sit
  beside the solver as the estimate sits beside the column.
- **A three-dimensional solver.** Streets and buildings break axial symmetry. A
  three-dimensional elastodynamic grid under the air's domain is the natural next step, on the
  GPU like the air solver, but it costs as much as the air itself (below). The axisymmetric
  solver comes first, for open ground and for the far field, where the air's load is nearly
  symmetric.

**Shared numerics.** Checked on 17 October 2026: ContinuumKit has a scalar linear wave solver
(`LinearAcoustics`, CPU and Metal, with absorbing masked walls) and solid-mechanics components
(isotropic tetrahedra, contact, orthotropic plane stress). It has no elastodynamic wave solver,
half-space or soil; its roadmap lists heterogeneous and two-dimensional waves as gaps. Edgerton
(read only) has gel and fruit solids and MPM at small scale, with nothing for half-spaces or
seismic waves. Nothing to adopt. ContinuumKit's prepared-grid, forcing and observation
contracts and its Metal execution pattern are the model to follow. An elastic wave solver
checked against Lamb's problem would be a candidate for extraction to ContinuumKit, by its
process, since RoomCAD's structure-borne sound and Edgerton's impact waves could use it.

## How it couples

- **One way,** like the column: the air presses on the ground, and the ground does not press
  back. The air model's ground stays rigid. (Two-way coupling belongs to the crater's stage 2.)
- **A new model choice** in the ground-shock description, `"model": "halfspace"`, beside
  `estimate` and `column`, sharing the soil profile. Older descriptions read as now.
- **The same consumer path:** `GroundShockConsumer` takes the ground slice each frame, here or on
  another Mac, and the axisymmetric grid advances to each frame's time. The points, depths,
  results, USD primvars and the app's chart keep their shapes. The horizontal velocity becomes
  a computed result rather than a geometric estimate.
- **Where the column stays:** in the superseismic region, and as the cheap default, with the
  half-space as the option for the far field and for the outrunning regime.

## The cost

For a 1 t surface burst judged to 50 m out and 25 m down, on 0.1 m cells (about a hundred cells a
wavelength at 200 Hz in 2,000 m/s soil), the grid is 500 × 250 = 125,000 cells, plus the
perfectly matched layer. The step is set by the P-wave speed, about 25 µs, so 0.3 s takes
12,000 steps, or about 1.5 × 10⁹ cell-updates. That is a few seconds on the GPU, or a minute
on the CPU cores, against the 7 to 8 minutes the air took for that burst on 0.25 m cells: a
few per cent to a tenth of the run, and a consumer worth placing on another Mac. For 100 t to 500 m, on 0.5 m cells, it is about 500,000 cells and similar steps: still
minutes. A three-dimensional grid of the air's domain on 0.25 m cells would be tens of millions
of cells, as costly as the air.

## The data to judge it

| Source | What it tests | Standing |
|---|---|---|
| Xia et al. 2022, 1 t at 21 and 42 m, 0.5 m deep (`Fixtures/XiaChen2022`) | The outrunning regime: vertical against horizontal, peak velocities, attenuation from 21 to 42 m | In hand; the soil not measured, the two records disagreeing |
| Prairie Flat (500 short tons, WES TR N-72-2) with the Watching Hill soil data | Gauges 84–1,150 ft out, at 1.5 to 30 ft deep, both sides of the outrunning limit (about 560 ft); the soil's layers | To fetch ([data wanted](data-wanted.md#to-fetch)) |
| Pre-Dice Throw II (100 t TNT and 120 t ANFO; DNA 4363F) | Motion at 305–1,220 m beside four agencies' blind predictions; the site's refraction profile is in USGS OFR 77-143 (in hand) | To fetch |
| Dial Pack, Distant Plain, Mixed Company and Middle Gust (WES reports) | Repeats on the same soils; a wet site against a dry one | To fetch |
| Humble Redwood III (IRIS, network 8H): 91 kg TNT 2 m up, geophones | Far-field surface waves, open | Open; far field only, no near overpressure |
| Large Surface Explosion Coupling Experiment (FDSN 5A): about 1 t of C-4 on the surface, twice | Surface-burst coupling into the ground, seismic far field | Open in name; no public metadata found |
| Wang, Kong and Shang 2023: 300 and 500 kg at 1.5 m height, 3.5–9 m out | Reflected pressure and ground velocity together, peaks tabulated | Open (CC BY); no soil layers |
| Novoselov et al. 2020: small charges beside three-component sensors, site wave speed measured | The linear, outrunning end; arrivals and polarisation | Open (CC BY), data on EIDA |

Checks before any comparison: Pekeris's surface pulse for a suddenly applied point load on a
Poisson solid; Cole and Huth's steady stresses under a load moving at sub-, trans- and
superseismic speeds; Rayleigh-wave dispersion over a layer against Haskell's; energy radiated
through the perfectly matched layer; agreement with the column where the front is superseismic.

## Stage 1: the solver and its checks

`AxisymmetricElasticGrid` and `AxisymmetricElasticStepper` (`Sources/BlastModel/AxisymmetricElastic.swift`):
Virieux's velocity–stress grid in (r, z), its radial derivatives in conservative form so that
the axis carries no singularity, the surface loaded through σ_zz with σ_rz mirrored above it,
and a convolutional perfectly matched layer on the far side and the bottom. It runs on the CPU;
the API follows ContinuumKit's prepared grid, forcing and observation. The checks
(`AxisymmetricElasticTests`):

| Check | Reference | Result |
|---|---|---|
| A disk pressed on the surface, 0.2 m across, switched on over 6 ms | Lamb's problem by the exact transform solution, summed by Bouchon's discrete wavenumber method (itself checked against Boussinesq's static displacement to 3%) | The surface's downward velocity at 2 and 3 m within 8% of the peak throughout; nothing before the P wave |
| A step of pressure sweeping out at 2 and 3 c_P | Cole and Huth's plane solution: v_z = p₀η_P(η_S² + s²)/(μR), v_r = −p₀s(2η_Pη_S − η_S² + s²)/(μR) | Within 5% (v_z) and 8% (v_r) behind the front; still ahead of it |
| The same at 1.4 c_S (transseismic) and 0.7 c_S (subseismic) | Waves outrun the load | Motion ahead of the front: 6% of the peak half a millisecond ahead (transseismic), 30% or more (subseismic) |
| Rayleigh waves over 1 m of soil at 100 m/s on a half-space at 200 m/s | Haskell's secular function (checked against Rayleigh's 0.9194 c_S on one material) | Phase speed within 4% from 30 to 100 Hz, 149 down to 92 m/s (40–50 Hz, two or three wavelengths out, read 8–17% off and are not used) |
| The perfectly matched layer | Energy left inside | Under 2% after the waves leave; with rigid edges over 30% stays |
| A front sweeping at 20 c_P | The elastic soil column, and p/(ρc_P) | The downward velocity a metre down within 3% of both; the outwards motion the plane solution's S-wave share, 2sη_S/(η_S² − s²), within 15% |

## Stage 2: against Xia et al.

`"model": "halfspace"` in the ground-shock description (`HalfSpaceGroundShock`, through
`GroundShockConsumer`). Each frame, the air's ground slice is averaged round rings centred on the
charge, about two samples a cell round each ring. The rings are rebuilt between frames by the
column's rules (`GroundLoad`), and averaged over twelve of the solver's steps. Each layer takes a
shear speed (`shearWaveSpeed`, or a Poisson's ratio of 0.3 if left out). `BombCAD run` puts the
axis under the scene's charge. The run's ground slice then covers the whole disc, out past the
farthest point by a seventh and 5 m. The results are the downward and outward peaks at each
point's depths, its displacement, stress and history.

### The direct source

Inside the crater, the air model's pressure on its rigid ground would drive elastic soil far
beyond anything it could carry. Without the source, fed the air model, the half-space puts the
ground at 21 m moving at 2.5 m/s (on 0.5 m cells) to 7.8 m/s (on 0.25 m cells), forty times
what it gives with it. Kingery–Bulmash's curves stop short of the charge and never showed this.
Inside the apparent crater (Cooper's radius in alluvium, `CraterEstimate`), the load is replaced
by a pressure A sin²(πt/τ). Here τ is twice the P wave's crossing of the disc, and A is set so
that the work a wide disc does, πa²A²(3τ/8)/(ρc_P), is a share ε of the charge's energy.

ε was **calibrated once against UFC 3-340-01's direct-induced relation**, v = 0.14 · 160 ·
(R/W^(1/3))^(−n) ft/s, taking W as the TNT-equivalent mass in pounds. The calibration case is
1 t on dense sand (n = 2.5, c_P 488 m/s, 1,900 kg/m³, Poisson's ratio 0.3), the source alone,
0.5 m down. `blastbench groundmotion --calibrate` gives, at ε = 9.3 × 10⁻⁶:

| R/W^(1/3), ft/lb^(1/3) | Range | Half-space, peak resultant | UFC | Ratio |
|---|---|---|---|---|
| 4 | 15.9 m | 0.053 m/s | 0.213 m/s | 0.25 |
| 6 | 23.8 m | 0.043 m/s | 0.077 m/s | 0.56 |
| 8 | 31.7 m | 0.038 m/s | 0.038 m/s | 1.00 (calibrated) |
| 12 | 47.6 m | 0.031 m/s | 0.014 m/s | 2.26 |
| 16 | 63.5 m | 0.027 m/s | 0.0067 m/s | 4.03 |

The elastic half-space's direct waves fall away as about r^(−1/2), the spreading of Rayleigh
waves at the surface; UFC's as r^(−2.5), as the soil yields and loses energy near the charge. So
one share fits at one range only: four times too low at half of it, four times too high at
twice it. Xia et al. quote 0.116 m/s at 21 m from the same relation with n = 2.55, with W as C-4.
With W as TNT it gives 0.098 m/s.

### The comparison

`blastbench groundmotion` on today's recommended air, the soil as Xia et al. fitted it (457 m/s,
2,050 kg/m³) with a Poisson's ratio of 0.3, 0.5 m down:

| Range | Vertical: half-space (air model 0.25 m; 0.5 m; Kingery–Bulmash) | Measured, integrated | Horizontal: half-space (same) | Measured, integrated |
|---|---|---|---|---|
| 21 m | 0.185; 0.186; 0.186 m/s | 0.009–0.012 | 0.079; 0.072; 0.083 m/s | 0.054–0.058 |
| 42 m | 0.050; 0.050; 0.027 m/s | 0.0008–0.0012 | 0.075; 0.062; 0.068 m/s | 0.0040–0.0042 |

- **The vertical:** 15 to 21 times the measured at 21 m, against the column's 20 to 26. It is
  42 to 63 times at 42 m on the air model (23 to 34 times on Kingery–Bulmash), against the
  column's 50 to 70. The half-space halves the vertical at 42 m on Kingery–Bulmash's load, where
  the air's front is outrun, but the air model's stronger load near the charge takes it back up.
- **The horizontal,** which the column could not give: within 1.4 to 1.5 times at 21 m, but 18
  to 19 times at 42 m. The half-space has the right shape where the blast is outrun: at 42 m the
  horizontal exceeds the vertical, as measured (about four times there, one and a half in the
  model).
- **The soil:** a Poisson's ratio of 0.25 or 0.35 moves the horizontal at 21 m from 0.058 to
  0.119 m/s and leaves the vertical within 10%. Stiffer soil makes 42 m worse, not better. At
  1,000 and 1,800 m/s the vertical there is 0.16 and 0.14 m/s, as the ground's waves from nearer
  the charge, where the air presses at megapascals, reach it with little loss.
- **The cost:** about 6 ms a frame for 1 t to 53 m on 0.16 m cells (52,000 cells), against
  35 to 300 ms of air a frame.

**What it shows.** Waves travelling sideways in an elastic ground give the outrunning regime its
horizontal motion and its shape, but not its size. The measured motion falls by a factor of 10
to 14 from 21 to 42 m, as R^(−3.3) to R^(−3.8). The elastic half-space's falls by 1 to 4. Real ground loses
energy near the charge, where it yields, crushes and cracks; none of that is here. The next
step is stage 3's soil that yields: the column's bilinear volumetric unloading, and the region
round the charge where it yields treated as the crater's own. Until then the half-space stands
as illustrative, its horizontal the only part within reach of the measurement.

## Stage 3: soil that yields

Each layer of the half-space may now yield (`frictionAngle`, `cohesion` and `unloadingWaveSpeed`
on its `SoilLayer`), as the soil round a charge does: it compacts, and it fails in shear.

### The law

- **Compaction: the column's bilinear law.** The soil is elastic at its unloading stiffness, with
  λ_u = λ + ρ(c_u² − c_P²) and the shear modulus as given. While it compacts beyond anything
  before, with its volumetric strain at its most, a share 1 − c_P²/c_u² of each shortening along
  r, θ and z stays as compaction. That applies only where the load compresses the soil that way.
  In uniaxial strain this is the column exactly: it loads at ρc_P², unloads at ρc_u², and is
  left with nothing sideways when unloaded vertically.
- **Shear: a Drucker–Prager cone matched to Mohr–Coulomb in triaxial compression,**
  √J₂ ≤ αI₁ + k, with α = 2 sin φ/(√3(3 − sin φ)) and k = 6c cos φ/(√3(3 − sin φ)). The soil rests
  under its own weight, the vertical stress the weight above and the horizontal Jaky's
  K₀ = 1 − sin φ times it, inside the cone. The cone caps the load's deviator at the margin the
  resting deviator leaves, αI₁ + k − √J₂⁰. By the triangle inequality the total is then inside
  the cone: exactly so where the load presses as gravity does, a little short otherwise. The
  return follows Andrews (2005) for the staggered grid. Each normal-stress point scales its
  deviator, counting the four shear stresses round it by their mean square. Each shear stress is
  scaled by the least of its four neighbours' shares.
- **The surface,** which carries no resting stress, holds its horizontal stresses between
  Rankine's active and passive limits on the load's vertical stress.
- **No tension:** the mean stress, with the resting stresses, is held at nothing or more.

Three simpler forms each failed in a way worth recording:

- **The bilinear law on the mean pressure alone** left compacted soil pulling sideways. Its
  resting stress was cut, and the cone then let the ground fall under its own weight: the
  yielding drew 50 times the source's energy.
- **A return of the total deviator, resting part included,** released gravity's energy into the
  waves wherever the load pulled the soil apart. That happened 18 m under the charge, where the
  edge wave of a pressed disc focuses on the axis in tension.
- **An elastic surface row over yielding sand** slid as a skin, at 9 m/s sideways.

As built, every part of the yielding only takes energy from the waves. The absorbing layer
compacts but does not take the cone.

### Its checks

`AxisymmetricElasticTests` and `HalfSpaceGroundShockTests`. All six stage-1 checks are unchanged
in the elastic limit.

| Check | Reference | Result |
|---|---|---|
| A front at 20 c_u over soil unloading at 2 c_P, under a 200 kPa surcharge so it never pulls | The bilinear soil column | Peak downward velocity within 4% at 1 m and 6% at 3 m on 0.05 m cells, 2% and 5% on 0.025 m |
| Sand at 35° at rest under its own weight | Nothing should yield | Nothing yields or moves |
| A 2 MPa disc on that sand | The cone; the energy | No point more than 1% of the cone's radius outside it; the yielding takes nine tenths of the disc's work, never more; the surface moves less than on elastic soil |
| The direct source alone on yielding sand | The cone; the energy | The cone holds; the yielding takes between half and all of the source's work |

### The direct source

On yielding soil the share is no longer a fit. It is set so that the source puts the crater
model's own share of the charge's energy into the ground: Cooper's 33% for a surface burst
(`CraterEstimate.groundShare`). The share sets the disc's pressure by the work it would do on
elastic soil. On yielding soil, being softer, the disc does about 2.2 times that (2.0 to 2.6
here). So the default for yielding soil, `DirectInducedSource.defaultYieldingShare`, is 15%. That
puts 31 to 35% into the ground for φ 30–40° and cohesion up to 10 kPa. The yielding takes 83 to
84% of it. Against UFC's relation, as in stage 2 (1 t on dense sand, 0.5 m down, unloading at
twice the loading speed), with no fitting:

| R/W^(1/3), ft/lb^(1/3) | Range | UFC | Yielding, φ 30° | 35° | 40° | 35°, c = 10 kPa | Elastic, fitted at 8 |
|---|---|---|---|---|---|---|---|
| 4 | 15.9 m | 0.213 m/s | 0.77 | 1.06 | 1.27 | 0.79 | 0.25 |
| 6 | 23.8 m | 0.077 m/s | 0.33 | 0.34 | 0.42 | 0.37 | 0.56 |
| 8 | 31.7 m | 0.038 m/s | 0.55 | 0.48 | 0.51 | 0.62 | 1.00 |
| 12 | 47.6 m | 0.014 m/s | 1.17 | 1.13 | 1.11 | 1.12 | 2.26 |
| 16 | 63.5 m | 0.0067 m/s | 1.45 | 1.67 | 1.59 | 1.65 | 4.03 |

(Ratios of model to UFC.) The yielding saturates the response. A thousand times the energy, a
share of 10⁻⁴ against 10⁻¹, gives three to four times the velocity at 8 ft/lb^(1/3). Most of
the energy stays near the charge, as the crater model says it does, so no share fits UFC at one
range only as the elastic one did.

**The yielding takes over the source's role.** Fed the air model without any direct source,
the yielding half-space moves the ground at 21 m at 0.186 m/s, as it does with the source. On
elastic soil it was 7.8 m/s (0.25 m cells). The air's own pressures inside the crater no longer
drive the soil beyond anything it could carry. The source is kept so that soil fed
Kingery–Bulmash, whose curves stop short of the charge, still gets its direct waves.

### The comparison

`blastbench groundmotion --friction 30,35,40` on Xia et al.'s fitted soil (457 m/s,
2,050 kg/m³, a Poisson's ratio of 0.3), unloading at twice the loading speed, without cohesion,
0.5 m down. The source was at a nominal share of 0.333 in this run; without it the air-fed
results are the same at 21 m and within 20% at 42 m.

| Range | Vertical, yielding (air model 0.25 m; Kingery–Bulmash) | Measured | Horizontal, yielding (same) | Measured |
|---|---|---|---|---|
| 21 m | 0.186–0.187; 0.206–0.208 m/s | 0.009–0.012 | 0.124; 0.130 m/s | 0.054–0.058 |
| 42 m | 0.058–0.070; 0.014–0.018 m/s | 0.0008–0.0012 | 0.042–0.044; 0.030–0.032 m/s | 0.0040–0.0042 |

- **The vertical** is 16 to 23 times the measured at 21 m, and 48 to 88 times at 42 m on the air
  model (12 to 22 times on Kingery–Bulmash). At 21 m it is the airblast's own p/(ρc). No soil
  law of this kind brings 228 kPa over 2,050 kg/m³ at 457 m/s down to 0.01 m/s: that would need
  an impedance twenty times as high.
- **The horizontal** is 2.1 to 2.4 times the measured at 21 m (1.4 to 1.5 elastic) and 10 to 11
  times at 42 m (18 to 19 elastic).
- **The fall-off** from 21 to 42 m is 2.7 to 3.2 times in each component on the air model, as
  about R^(−1.5). The elastic half-space gave 1 to 4 times; the measurements fall 10 to 14
  times, as R^(−3.3) to R^(−3.8).
- **Kingery–Bulmash at 42 m,** without the air model's strong loads near the charge, gives the
  lowest vertical, 0.007–0.008 m/s without the source. There the cohesionless top half-metre
  yields under the load nearer in and is squeezed up ahead of it, rising for 40 ms after the
  air arrives. That part may be the model's own: the cone is conservative off the vertical.
- **The soil:** with 10 or 50 kPa of cohesion, the vertical at 42 m (Kingery–Bulmash) is 0.023
  to 0.046 m/s and the horizontal 0.02 to 0.05. Without compaction (unloading at the loading
  speed) they are 0.036 to 0.042 and 0.05 to 0.14. Friction angles from 30 to 40° change
  little.
- **The cost:** the unloading speed halves the step. In the 0.25 m run, the six yielding
  half-spaces together added about 24 s to the ground models' time, against 531 s of air for
  892 frames: about 4 ms a frame each, on 0.16 m cells to 53 m.

**The verdict: record and stop.** Neither range comes within a factor of 2 to 3 in the
vertical, nor 42 m in the horizontal, so the standing stays illustrative. What stage 3 does give
the product is soil that yields under the half-space as an option, with the direct source tied
to the crater's energy instead of a fit, and no longer needed where the air model feeds it.
Further work on this line waits for a test that stood where the models claim to hold: Prairie
Flat or Pre-Dice Throw II, with their soil ([data wanted](data-wanted.md#to-fetch)).

## Against Prairie Flat (20 October 2026)

The test the line was stopped for: Prairie Flat's 500 t, with gauges 84 to 1,150 ft out and 1.5
to 30 ft deep, both sides of the outrunning limit, and the site's two layers, 387 m/s over
saturated soil at 1,859 m/s below about 7 m ([the comparison](ground-shock.md#against-prairie-flat)).
The half-space took the two layers, the saturated one with the upper soil's shear speed, on
0.5 m cells to 405 m out and 162 m down.

- **Past the outrunning limit, 560 to 1,150 ft: it holds.** The elastic half-space's peak
  downward and outward velocities are within a factor of three of all 16 records (the judge),
  within two of 15 fed the air alone, a geometric mean of 1.15 (0.91 with the direct source).
  The wave that outruns the blast is the one refracted along the water table, an elastic wave
  in elastic, saturated soil, and the grid carries it. Yielding soil does a little worse (13 to
  15 of 16 within three). Its arrival, the head wave's, agrees with Murrell's records' first
  motion at 1,150 ft (0.22 s).
- **Inside it: no better than the column.** Within a factor of two at 21 of 34 vertical records
  (the air alone), short of two-thirds, too low near the surface and twice too high at 17 ft;
  its first motions come 20–40% early within 140 ft.

So the half-space is right where Xia's test said it was not: there the soil was not measured and
the motion fell as R^(−3.3) to R^(−3.8); here the site's layers are known and the motion that
outruns the blast is carried by the stiff saturated layer. **Stage 4, the half-space in three
dimensions on the GPU, for streets and buildings, is proposed as a new issue**; it should first
pass this comparison in its axisymmetric limit. The standing stays illustrative: one site, its
densities assumed.

**The band.** Since the motion ahead of the blast met its judge, the standing now bands it: with
the half-space chosen, the peak downward and outward velocity at points labelled outrun carries
a band of 0.33 to 3 times the measured, Prairie Flat's factor of three, which all 16 records met
(0.41 to 1.91). It holds 170 to 350 m from 500 t, 0.5 to 3 m down, on two measured layers whose
densities were assumed; the motion where the air arrives first stays unbanded.

## Stages

1. Done: the elastic axisymmetric solver with its absorbing layer, checked against Lamb's
   problem and Cole and Huth.
2. Done: driven by the air's ring-averaged ground pressures through the consumer, with the
   near-charge source calibrated against UFC; Xia again, now with the horizontal (above).
3. Done: soil that yields, compaction and a Mohr–Coulomb cone, with the direct source tied to
   the crater's energy (above); recorded, and the line stopped, as it does not close the gap.
   Next only with Prairie Flat or Pre-Dice Throw II.
4. Proposed (20 October 2026), as Prairie Flat's motion ahead of the blast held within a factor
   of three ([above](#against-prairie-flat-20-october-2026)): a three-dimensional version on the
   GPU for streets and buildings, and a ContinuumKit extraction proposal for the elastic wave
   solver.

## Sources

- H. Lamb, "On the propagation of tremors over the surface of an elastic solid", *Philosophical
  Transactions of the Royal Society A* 203 (1904) 1–42.
- C. L. Pekeris, "The seismic surface pulse", *Proceedings of the National Academy of Sciences*
  41 (1955) 469–480.
- J. Cole and J. Huth, "Stresses produced in a half plane by moving loads", *Journal of Applied
  Mechanics* 25 (1958) 433–436.
- L. R. Johnson, "Green's function for Lamb's problem", *Geophysical Journal of the Royal
  Astronomical Society* 37 (1974) 99–131.
- M. Bouchon, "A simple method to calculate Green's functions for elastic layered media",
  *Bulletin of the Seismological Society of America* 71 (1981) 959–971.
- N. A. Haskell, "The dispersion of surface waves on multilayered media", *Bulletin of the
  Seismological Society of America* 43 (1953) 17–34.
- J. Virieux, "P-SV wave propagation in heterogeneous media: velocity-stress finite-difference
  method", *Geophysics* 51 (1986) 889–901.
- D. Komatitsch and R. Martin, "An unsplit convolutional perfectly matched layer improved at
  grazing incidence for the seismic wave equation", *Geophysics* 72 (2007) SM155–SM167.
- A. J. Hendron and H. E. Auld, "The effect of soil properties on the attenuation of
  airblast-induced ground motions", in *Proceedings of the International Symposium on Wave
  Propagation and Dynamic Properties of Earth Materials*, Albuquerque, 1967 (not in hand).
- *Fundamentals of Protective Design for Conventional Weapons*, TM 5-855-1, US Army, 1986, and
  *Design and Analysis of Hardened Structures to Conventional Weapons Effects*, UFC 3-340-01,
  2002: the outrunning case and the direct-induced relation (neither in hand).
