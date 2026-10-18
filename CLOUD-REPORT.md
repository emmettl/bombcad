# Cloud report: analytic oracles

Branch `cloud/analytic-oracles`, from `origin/main` at `40665a0`. Written on a Linux box with
no Swift toolchain or Metal: nothing in Swift or Metal was built or run here.

## What was done

- `Scripts/analytic/riemann.py`: the exact Riemann solution for an ideal gas (Toro, chapter
  4), with Sod's problem as Toro's test 1.
- `Scripts/analytic/sedov.py`: the Sedov–Taylor point-blast solution for planar, cylindrical
  and spherical geometry, from Kamm's closed-form parametric solution, with the energy constant
  α integrated numerically.
- `Scripts/analytic/godunov.py`: a textbook MUSCL–Hancock and HLLC scheme in one dimension, as
  a yardstick to read BombCAD's errors against.
- `Scripts/analytic/compare.py`: scores a solver profile (CSV) against either solution, beside
  the yardstick on the same grid, and has a `--self-test`.
- `Scripts/test-analytic-oracles.py`: 17 tests, added to `make ci-test`.
- `docs/analytic-oracles.md`, linked from the end of "Verification against theory" in
  `docs/validation.md`.
- `Scripts/check-affected.py` now counts `Scripts/analytic/*.py` as scripts, so a change there
  gets `ci-test` and no Swift build, as `Scripts/*.py` already did (with a test line).

All of it is pure Python with no dependencies; NumPy and SciPy were not needed. It sits apart
from `Scripts/reference/` and its `compare.py`, which another branch owns.

## Test results

    python3 Scripts/test-analytic-oracles.py     Ran 17 tests in 3.0 s, OK
    python3 Scripts/analytic/compare.py --self-test     self-test passed (9 checks)
    python3 Scripts/test-check-affected.py       OK
    python3 Scripts/check-doc-links.py           no errors

The oracles reproduce all five of Toro's exact star states to the digits printed (Tables 4.1
and 4.3), Kamm's spherical and cylindrical α for γ = 1.4 (0.8510 and 0.9840) and the textbook
ξ0 for γ = 1.4 and 5/3 (1.033 and 1.152). The Sedov density profile puts exactly the swept mass
behind the shock (to 10⁻¹²) in all three geometries.

## Where BombCAD's tests and documents stand against the references

No disagreement in BombCAD's own oracle constants. In order of interest:

1. **A comment in `Tests/BlastCoreTests/MappedChargeTests.swift` (the `sphericalBlast` test)
   says the shock at 1.2 m from the 10 kg point blast is "some 20 atmospheres".** The
   Sedov–Taylor solution puts it at 37 atmospheres there: the shock arrives at 0.249 ms moving
   at 1,928 m/s (Mach 5.6), and the strong-shock jump is 3.79 MPa. Taking the ambient 101 kPa
   into account by the Rankine–Hugoniot relation at that shock speed gives 3.7 MPa
   overpressure, 36 atmospheres. The test's check (the radius within 8%) is unaffected and the
   shock is strong either way, which is the comment's point; only the number looks low. Sure of
   the arithmetic; I could not run the 1-D blast to see what it actually reaches.
2. **The Swift Sedov test's front rule costs about 1% of its 4% band.** The rule takes the
   outermost cell with density above 2. In the exact solution that density sits at 0.936 r2,
   and sampled at the test's cell centres (1/80) it reads the radius 1.0% short along the axis
   and 0.7% short along the diagonal. The yardstick scheme in one dimension from the same
   3.5-cell source reads 1.1% long, with a density peak of 3.2 (the test allows 2.5 to 6.5).
3. **The Sod threshold is loose against a textbook scheme.** The Swift test asks for a mean
   density error below 0.004 on 400 cells. MUSCL–HLLC with minmod scores 0.0022 there (0.0038
   on 200 and 0.0070 on 100), and the exact cell averages 0.00014. If BombCAD's score is near
   the yardstick's, the threshold could be tightened to catch smaller regressions; I could not
   run it to see.
4. **The constants agree.** The Sod density function hard-coded in `SolverVerificationTests`
   matches the exact solution within 10⁻⁵ at every one of the 400 cells. The ξ0 = 1.033 used
   in `SolverVerificationTests` and `MappedChargeTests` is 1.0328 exactly (0.02% apart). The
   rows for both problems in `docs/validation.md` match the tests' thresholds.
5. **Not BombCAD's:** the planar α for γ = 1.4 converges to 0.538743 under two independent
   quadratures, 0.035% above Kamm's 0.5385. The cylindrical and spherical values match his.
   The test allows for it, with a comment.

## What the Studio needs to do to compare a run

Neither `blastbench` nor `scenebench` writes a Sod or Sedov profile today; the Swift tests read
the state in memory. `compare.py` reads a CSV with a header row (`x,rho,u,p` for Sod, or
`r,rho,u,p` along a ray for Sedov). The smallest route is a few lines at the end of
`sodShockTube` and `sedovTaylor` writing `solver.primitive(i, j, k)` row by row when an
environment variable names a folder, then:

    python3 Scripts/analytic/compare.py sod sod-hllc.csv --time 0.2
    python3 Scripts/analytic/compare.py sedov sedov-axis.csv --time 0.2571 --energy 1 --ambient-pressure 1e-4

For the Sedov test the energy is the full sphere's (1), the time is the test's
(0.6 / 1.033)^(5/2) = 0.25711 s, and a diagonal ray's `r` is the cell centre's distance
((n + 0.5) √3 / 80). I have not written that Swift, since it could not be built here.

The branch is ready for review.
