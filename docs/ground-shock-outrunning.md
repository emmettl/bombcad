# Ground motion where the ground's wave outruns the blast: a proposal

**Status: stage 1 built and checked (17 October 2026); stage 2 under way.** A plan for the motion that the one-dimensional
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
  gives the ground's share of the energy (0.1 of the charge on earth or rock). The proposal is
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

For a 1 t surface burst judged to 50 m out and 25 m down, on 0.1 m cells (about ten cells a
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
| Prairie Flat (500 t, WES TR N-72-2) with the Watching Hill soil data | Gauges 84–1,150 ft out, at 1.5 to 30 ft deep, both sides of the outrunning limit (about 560 ft); the soil's layers | To fetch ([data wanted](data-wanted.md#to-fetch)) |
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

`AxisymmetricElasticGrid` and `AxisymmetricElasticStepper` (`Sources/BlastCore/AxisymmetricElastic.swift`):
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

## Stages

1. The elastic axisymmetric solver with its absorbing layer, checked against Lamb's problem
   and Cole and Huth.
2. Driven by the air's ring-averaged ground pressures through the consumer, with the near-charge
   source from the crater's energy share; Xia again, now with the horizontal.
3. Layers and damping, then the bilinear soil; Prairie Flat and Pre-Dice Throw II if obtained.
4. If it holds: a three-dimensional version on the GPU for streets and buildings, and a
   ContinuumKit extraction proposal for the elastic wave solver.

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
