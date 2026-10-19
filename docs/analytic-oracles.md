# Analytic oracles: Sod's shock tube and the Sedov–Taylor blast

Two problems with exact solutions check the air solver: Sod's shock tube and the Sedov–Taylor
point blast. The Swift tests in `Tests/BlastCoreTests/SolverVerificationTests.swift` carry the
answers to both as a handful of constants. This page describes independent Python versions of
the full solutions in `Scripts/analytic/`, written from the published sources, and a script
that scores a profile from BombCAD's solver against them. They are pure Python with no
dependencies, so they run anywhere, including in `make ci-test`.

## The exact solutions

**Sod's shock tube** (`Scripts/analytic/riemann.py`). The exact solution of the Riemann
problem for an ideal gas, following Toro, chapter 4: the star-region pressure by Newton
iteration on the pressure function, then the solution sampled at any x/t. It covers any two
states and any ratio of specific heats, not only Sod's. Sod's problem is Toro's test 1: density
1 and pressure 1 on the left, 0.125 and 0.1 on the right, γ = 1.4, both at rest. Its star state
is p\* = 0.30313, u\* = 0.92745, ρ\*L = 0.42632 and ρ\*R = 0.26557, and the shock runs at
1.75216. The tests check all five of Toro's star states to the digits he prints, the
Rankine–Hugoniot conditions across the computed shock, the rarefaction's isentropy and the
mirror symmetry of the solution. The density function hard-coded in the Swift test agrees
with it within 10⁻⁵ at every cell of the 400-cell tube.

**The Sedov–Taylor blast** (`Scripts/analytic/sedov.py`). The self-similar flow behind a
strong shock driven by energy E released at a point (spherical), along a line (cylindrical)
or on a plane, in gas of uniform density ρ0 whose own pressure is neglected. The shock radius
is r2 = (E / (α ρ0))^(1/(j+2)) t^(2/(j+2)), with j = 3, 2 and 1 for the three geometries. The
profiles are Kamm's closed-form parametric solution in Sedov's variable V; the energy constant
α is integrated numerically. For γ = 1.4, α is 0.85107 spherical (so ξ0 = α^(−1/5) = 1.0328,
the 1.033 the Swift tests use) and 0.98407 cylindrical, both Kamm's to the digits he prints.
The planar α comes out at 0.538743, 0.035% above Kamm's 0.5385; two independent quadratures
agree on it to 10⁻¹¹, and the swept mass behind the shock equals ρ0 times the swept volume to
10⁻¹² in all three geometries, which checks the density profile independently of α. The
difference is far below anything BombCAD's tests resolve. For γ = 5/3, ξ0 is 1.1517.

## A yardstick scheme

`Scripts/analytic/godunov.py` is a textbook second-order finite-volume scheme:
MUSCL–Hancock, minmod-limited primitive slopes and the HLLC Riemann solver (Toro, chapters 10
and 14), in planar, cylindrical or spherical geometry. It is not an oracle. It shows what an
ordinary second-order scheme scores on the same grid, so BombCAD's error can be read against a
known-good scheme's and not only against zero.

On Sod's problem at t = 0.2 its mean density error falls with the grid as a second-order
scheme with a captured shock and contact should, roughly as the first power of the cell size:

| Cells | Mean density error, MUSCL–HLLC | Exact cell averages |
|-------|--------------------------------|---------------------|
| 100   | 0.0070                         |                     |
| 200   | 0.0038                         |                     |
| 400   | 0.0022                         | 0.00014             |

The Swift test asks for a mean error below 0.004 on 400 cells, nearly twice the yardstick's
0.0022. The last column is the error of the exact solution averaged over each cell, against
the exact solution at the cell centre: the floor no scheme can go below on that grid.

## What the Swift Sedov test's rule reads

The Swift test takes the shock radius as the outermost cell along a ray whose density exceeds
2 (with ρ0 = 1), at the time the radius should be 0.6, on cells of 1/80. In the exact solution
for γ = 1.4 the density falls to 2 at 0.936 r2, about three cells behind the shock at that
size, but it climbs so steeply that the exact solution sampled at the test's cell centres reads
the radius 1.0% short along the axis and 0.7% short along the diagonal. The test's 4% band
therefore leaves about 3% for the solver. The yardstick scheme, run in one dimension from a hot
core of 3.5 cells as the test's source is, reads 1.1% long at 80 cells and its density peak
reaches 3.2 against the exact 6, inside the test's 2.5 to 6.5.

## Comparing a BombCAD run

`Scripts/analytic/compare.py` reads a profile written as CSV: a header row naming the columns,
then one row per cell, with `#` lines ignored. The position column is `x` along the tube for
Sod and `r` along a ray from the centre for Sedov; `rho` is required, and `u` and `p` are used
when present. Cells must be evenly spaced.

    python3 Scripts/analytic/compare.py sod profile.csv --time 0.2
    python3 Scripts/analytic/compare.py sedov ray.csv --time 0.2571 --energy 1
    python3 Scripts/analytic/compare.py --self-test

For Sod it prints the mean errors in density, velocity and pressure, and how many cells the
shock and contact sit from their exact positions. For Sedov it prints the mean density error
inside 1.2 r2, the front by the Swift test's rule in cells and as a fraction of r2, the density
peak against the strong-shock jump, and, for a profile running from the centre with velocity
and pressure, the energy it holds as a fraction of E (summed assuming the flow is spherically,
cylindrically or planarly symmetric). Each score is printed beside the yardstick scheme's on
the same grid, unless `--no-yardstick` is given. `--left` and `--right` take other Riemann
states as `rho,u,p`; `--gamma`, `--rho0`, `--j` and `--ambient-pressure` set the rest. The
energy is the whole blast's, not an octant's. `--self-test` runs on the exact solutions alone:
exact cell averages must score near zero, a shock moved five cells must be caught, and the
yardstick must score as above.

Neither `blastbench` nor `scenebench` writes these profiles today. The tests read them
through `BlastSolver.withState` and `primitive(i, j, k)`; a profile is those values written one
row per cell, for example from the end of `sodShockTube` or along the axis and the diagonal at
the end of `sedovTaylor`.

## Limitations

- Both solutions are for an ideal gas with a constant ratio of specific heats. BombCAD's
  thermally perfect and dissociating air, and its detonation products, are not covered.
- The Sedov–Taylor solution neglects the ambient pressure: it holds while the shock is strong,
  for overpressures many times atmospheric. It is the point blast's limit, not a charge's
  blast at distance, which is the Kingery–Bulmash references' job.
- `sedov.py` covers uniform ambient density and 1 < γ < 2, the standard case of Kamm's
  report. The Riemann solver raises if the two states would form a vacuum.
- The comparison assumes an evenly spaced profile and, for the Sedov energy, symmetry about
  the centre. A three-dimensional run is compared ray by ray.

## Sources

- G. A. Sod, "A survey of several finite difference methods for systems of nonlinear
  hyperbolic conservation laws", *Journal of Computational Physics* 27, 1978.
- E. F. Toro, *Riemann Solvers and Numerical Methods for Fluid Dynamics*, 3rd ed., Springer,
  2009. The exact Riemann solver (chapter 4) and its five tests (Tables 4.1 and 4.3); MUSCL–Hancock
  and HLLC for the yardstick.
- L. I. Sedov, *Similarity and Dimensional Methods in Mechanics*, Academic Press, 1959.
- G. I. Taylor, "The formation of a blast wave by a very intense explosion. I. Theoretical
  discussion", *Proceedings of the Royal Society A* 201, 1950.
- J. R. Kamm, *Evaluation of the Sedov–von Neumann–Taylor blast wave solution*, Los Alamos
  report LA-UR-00-6055, 2000; and J. R. Kamm and F. X. Timmes, *On efficient generation of
  numerically robust Sedov solutions*, LA-UR-07-2849, 2007. The parametric solution and the
  energy constants.
