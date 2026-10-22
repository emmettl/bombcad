# The open benchmark in Clawpack

The two runnable decks of the [open benchmark](../../../../docs/open-benchmark.md)
(`ideal-gas-balloon-v1`, [decks](../../decks/README.md)) run in
[Clawpack](https://www.clawpack.org) 5.14.0 (BSD-3-Clause; PyPI `clawpack`), through PyClaw's
classic wave-propagation solver, the library used unchanged. The scripts here set the runs up,
record the decks' observables in the decks' CSV contract, import them with the protocol's own
tool (`Scripts/open-benchmark/run_decks.py import`) and write the entry
`Benchmarks/open/results/clawpack-5.14.0.json`.

- **`kb-surface-burst-free-field`** as a **2-D axisymmetric surface burst over rigid ground**:
  the deck's physics, observation points, sampling and read rules on an r-z mesh. **This is a
  deviation from the deck**, whose mesh and discrete start are 3-D Cartesian; see below.
- **`ufc-closed-room-gas-pressure`** as a **3-D Cartesian run of the whole closed cube** on the
  deck's own mesh, from the deck's own `initial_cells`: an import of the deck's contract, except
  for the numerics the deck names for BombCAD's adapter (HLLC, limiter θ 1.5).

| File | What |
|---|---|
| `blast_axi.py` | The free field on an r-z mesh: the source, the geometric source terms, the deck's floors, the gauges; writes `outputs/<label>.json` and, for a full run, the deck-format CSV |
| `room3d.py` | The room in 3-D, the whole cube or (`--octant`) its symmetric eighth; writes `outputs/<label>.json` and, for the whole cube, the deck-format CSV |
| `mesh_study.py` | The mesh study tables below, from `outputs/` (standard library only); writes `outputs/mesh-study.json` |
| `make_results.py` | Extracts `histories/` with `run_decks.extract` and writes the entry (standard library only) |
| `histories/free-field/`, `histories/room/` | The imported histories, the deck copies and the receipts with their SHA-256 hashes |
| `outputs/` | Every run's summary: parameters, energy budget, steps, wall time, and its gauges read by the deck's rule from the 50 µs samples and from every step |

## The free field: what a 2-D run can and cannot test

**The ground cannot change this case.** The charge is a hemisphere centred on the rigid ground,
so the ground is a plane of symmetry: the wave it reflects is the mirror image of the incident
one, and the exact solution is the free-air sphere's, which a 1-D spherical run computes. That is
why the deck can use a symmetric octant and pyro2 a 1-D sphere. What a 2-D run tests is whether a
code that has the ground as a boundary, on a grid that is not aligned with the wave, gets there:
the ground's numerical reflection, the axis, the gauges read in the first row of cells, and a
source that is a staircase rather than a sphere. A ground reflection that differs from the
mirror needs a charge above the ground (a height of burst), which no case has yet.

**The answer:** it does not change the score. On 62.5 mm cells the 2-D run scores 23 of 24,
as pyro2's 1-D run does, and fails the same value (the impulse at Z = 1.5, 0.74 of the fit, the
balloon's missing afterburning). Its impulses and arrivals converge, at about second order, to
pyro2's 1-D values (the Richardson estimates within 1% and 0.05 ms); its peaks converge slowly,
and are 1–7% below the 1-D peaks on the finest meshes run.

## The set-up

**Install.** Clawpack builds Fortran kernels: gfortran 13.3 (Ubuntu's package), then in a virtual
environment NumPy, meson, meson-python and ninja, then
`pip install clawpack==5.14.0 --no-build-isolation` with the environment's `bin` on `PATH`
(sdist sha256 `b9f3208fe9e1d834122ae86e2af536a3010435d0d65e6629f360416ea9cffe89`). Python 3.13,
NumPy 2.5.

**Free field** (`blast_axi.py`).

- *Mesh.* x the radius from the charge's vertical axis, y the height; square cells from 0.5 m to
  31.25 mm, 48 m in r and z (16 m for the near-field runs). The axis and the ground are PyClaw
  walls; the two outer faces extrapolate (zero gradient, the deck's outflow).
- *Equations.* Euler, one ideal gas, γ 1.4, written in r-z with the geometric source terms
  −(1/r)(ρu, ρu², ρuv, u(E + p)), added after each step by the two-stage Runge-Kutta step of
  PyClaw's own axisymmetric example (`examples/euler_2d/shock_bubble_interaction.py`).
- *Numerics.* ClassicClaw, unsplit, with transverse correction waves; Roe's solver with its
  entropy fix (`riemann.euler_4wave_2D`); the MC limiter; CFL 0.45 (the deck's), a step rejected
  above 0.5; the deck's density and pressure floors (10⁻⁶ kg/m³, 10⁻³ Pa), what they add counted.
  The 16 mm run starts with six first-order steps (the deck names six startup steps for
  BombCAD's adapter); see *what went wrong*.
- *Source.* The deck's rule on r-z cells: 8 × 8 midpoint samples per cell strictly inside the
  200 kg sphere's radius (0.3102 m), each weighted by its radius (the volume it stands for),
  normalised over the cells; the hemisphere's 100 kg excess mass, 100 × (1 − 1.225/1600) kg,
  and its 418.4 MJ added to ambient air at rest (1.225 kg/m³, 101,325 Pa). The initial budget
  matches the declared mass and energy to 10⁻¹².
- *Gauges.* The deck's observable: pressure (not conserved state) interpolated between cell
  centres, the fractional coordinate position/dx − 0.5, each neighbour clamped to the domain;
  a ground gauge therefore reads the first row of cells, dx/2 above the ground. Recorded at
  the deck's 50 µs targets (each landed on exactly) and at every step.

**Room** (`room3d.py`). The whole 6 m cube, walls on all six faces, 24 cells a side, the deck's
`initial_cells` as given; on finer meshes the same construction (`protocol.source_cells`) on that
mesh. ClassicClaw 3-D, unsplit with transverse increment and correction waves (22), Roe's solver
with entropy fix (`riemann.euler_3D`), the **minmod** limiter, CFL 0.45, the deck's floors. The
observable is the deck's: the volume mean of pressure over every cell, every 50 µs to 120 ms.
`--octant` solves the eighth [3, 6]³ with walls on the planes through the charge's centre, by
symmetry the same volume mean; it is used only for the finer meshes, after checking it on the
deck's mesh.

## The free field's mesh study

Read by the deck's rule from the 50 µs samples. The full-domain meshes run all eight gauges to
100 ms; the near-field runs (16 m domain, 20 ms) the four nearest. *p* is the observed order from
the three finest meshes of a gauge, and the Richardson estimate is given where 0.5 ≤ p ≤ 4.
pyro2's column is its 1-D spherical run of the same balloon on 10 mm cells, its 50 µs history read
by the same rule: the answer the 2-D run should approach if the ground adds nothing.

MESH-STUDY

- **The near-field domain changes nothing**: on 62.5 mm cells the 16 m, 20 ms runs read the same
  values as the 48 m, 100 ms run to the digits shown. **Nor does the far boundary**: on 36 m
  domains the 0.5 and 0.25 m runs read every value as the 48 m runs do, to five digits, so the
  extrapolated outer faces return nothing within a gauge's first positive phase.
- **Impulses and arrivals** have converged by 62.5 mm, to within 1–2% of pyro2's 1-D run, and
  their Richardson estimates lie within 1% and 0.05 ms of it.
- **Peaks** converge slowly, at an observed order of one or less: a shock smeared over two or three
  cells, read at a cell centre and every 50 µs. On 31.25 mm cells the peak at Z = 0.75 is 7%
  below pyro2's on 10 mm, at Z = 1–2 1–4%; the far gauges' peaks, run only to 62.5 mm, are 4–6%
  below, and their changes between meshes are too small and irregular to give an order.
- **Energy.** PyClaw's geometric source terms are not conservative: they use the flux at the
  cell's centre where a conservative scheme uses its faces. With the charge in a few cells at
  the axis, the domain gains energy, almost all of it in the first millisecond: 41% of the
  charge's on 0.5 m cells, 22% on 0.25 m, 5.2% on 0.125 m, 2.1% on 62.5 mm, 0.9% on 31.25 mm (by
  20 ms). That is why the coarse meshes' impulses are high and their arrivals early. The floors
  add 0.01–0.15%.

**Against the 1-D run and BombCAD's control.** BombCAD's control on the deck's 0.5 m 3-D mesh
read peaks 0.39–0.65 of pyro2's and arrivals 0.79–0.98
([open benchmark](../../../../docs/open-benchmark.md#a-second-code-pyro2-20-october-2026)).
Clawpack's 0.5 m axisymmetric run reads peaks 0.47–0.85 and arrivals 0.68–0.93 of pyro2's: low
peaks on half-metre cells are the mesh, in either code, and the 2-D run's early arrivals there
are its energy gain.

## The room

On the deck's mesh, from the deck's cells, Clawpack's room means are 418.4, 836.9, 1,673.5,
3,347.1 and 6,694.2 kPa: each within 0.03% of the energy bound (γ − 1) Q / V, as an ideal gas
that has stopped moving must be, and within 0.07% of BombCAD's control on the same deck
(418.1, 836.5, 1,673.2, 3,346.6, 6,693.3 kPa). The kinetic energy left at 100 ms is under 0.04%
of the gas's; the relative half-window drift is at most 1.2 × 10⁻⁴.

ROOMTABLE

- **The mesh does not matter**: from 24 to 96 cells a side the means move by at most 0.07% (the
  lightest charge, whose reverberations hold a little more kinetic energy on the finer mesh).
- **The octant is the cube**: on 24 and on 48 cells a side the octant reads the whole cube's mean
  to 10⁻⁹ (0.25 and 4 kg/m³ on 24, 1 kg/m³ on 48).
- The score is the balloon's, not the mesh's: the two lightest charges fail because an ideal gas
  without afterburning cannot reach the UFC curve, as BombCAD's control and pyro2 found.

## Scores

`Benchmarks/open/results/clawpack-5.14.0.json`, scored with `Scripts/open-benchmark/score.py --strict`:

| Case | Code | Score | Passed | Coverage | Geometric mean ratio | Typical factor |
|---|---|---|---|---|---|---|
| `kb-surface-burst-free-field` | Clawpack 5.14.0, 2-D axisymmetric, 62.5 mm | 0.96 | 23/24 | 24/24 | 0.92 | 1.12 |
| | pyro2 4.5.1, 1-D spherical, 10 mm | 0.96 | 23/24 | 24/24 | 0.95 | 1.14 |
| | BombCAD's control, the deck (3-D, 0.5 m) | 0.50 | 12/24 | 24/24 | 0.77 | 1.40 |
| `ufc-closed-room-gas-pressure` | Clawpack 5.14.0, the deck (3-D, 0.25 m) | 0.60 | 3/5 | 5/5 | 0.74 | 1.55 |
| | pyro2 4.5.1, a sphere of the room's volume | 0.60 | 3/5 | 5/5 | 0.74 | 1.55 |
| | BombCAD's control, the deck | 0.60 | 3/5 | 5/5 | 0.74 | 1.55 |

The one free-field failure is pyro2's: the impulse at Z = 1.5, 0.74 of the fit. Against
Kingery–Bulmash the 62.5 mm run's peaks are 0.94–1.04, its impulses 0.74–0.96 and its arrivals
0.92–0.98.

**The free-field score on each mesh** (the same scorer, on each run's gauges):

| Cells | 0.5 m (the deck's) | 0.25 m | 0.125 m | 62.5 mm |
|---|---|---|---|---|
| Score | 0.54 (13/24) | 0.79 (19/24) | 0.96 (23/24) | 0.96 (23/24) |
| Fails | 10 near peaks and arrivals, Z = 4's arrival | Z = 0.75's peak, four near arrivals | Z = 1.5's impulse | Z = 1.5's impulse |

So on the deck's own cell size a second code scores about what BombCAD's control does, and the
score stops moving at 0.125 m.

## What went wrong, and what was changed

Each of these was found by a run failing, and each fix is in the scripts; none was chosen by
its effect on a score.

- **Clawpack's 2-D HLLE solver** (`rpn2_euler_hlle.f90`) gives NaN within 0.6 ms of the release.
  Its one-sided sound speeds are computed as √((γ−1)H − u²/2) where (γ−1)(H − |u|²/2) is meant,
  and its right state's enthalpy uses the left state's pressure. Roe's solver was used instead.
- **PyClaw's default dimensional splitting** failed within 3–5 ms (negative pressure behind the
  shock); the unsplit scheme with transverse waves did not.
- **Roe's solver is not positive.** In the near-vacuum that the balloon's over-expansion leaves
  at its centre it gives negative pressure. The deck's floors keep the next step's Riemann
  problems physical, and the drivers count what they add.
- **`dt_initial` is applied only by PyClaw's Controller**, which the drivers do not use, so the
  first runs tried a first step of 50 µs; and **a step whose CFL number is NaN is accepted**,
  since PyClaw rejects only CFL > cfl_max. The drivers now set the first step (10⁻⁷ s) and reject
  a non-finite CFL number; every run reported here was made after that fix.
- **The 16 mm mesh** drove a cell at the balloon's edge to negative density in the first full
  step, and the floored cell's speed ran the time step to 10⁻³⁵ s. Six first-order startup steps
  (`--startup-steps 6`) get past it. STARTUP
- **The room with MC** ran its time step down to nanoseconds by 1.8 ms: a cell floored to 10⁻⁶
  kg/m³ that keeps its energy has a pressure of a gigapascal. With minmod the heaviest charge
  needs no floor at all and the lightest's floors add 0.03% of its energy. The room's observable,
  a volume mean of a conserved energy, hardly depends on the limiter.

## What the deck contract left open

Found by running the decks in a code they were not written for. Several are about the free
field's 2-D translation, which the deck does not provide for; the rest would meet any code.

1. **A mesh other than the deck's.** The deck fixes a 3-D Cartesian octant on 0.5 m cells and its
   discrete start; it has no rule for another mesh or dimension. Here the deck's sampling rule was
   carried to r-z cells with each sample weighted by its radius, which keeps the declared mass and
   energy exactly. `run_decks extract` labels any imported history `ideal-gas-balloon-v1` whatever
   mesh it came from, and the receipt has no field for the mesh or a deviation: `make_results.py`
   rewrites the configuration by hand. A structured `deviations` block in the receipt would carry it.
2. **Resolution.** The deck fixes 0.5 m for BombCAD's adapter but does not say what resolution an
   entry should use, or ask for a mesh study. The score here runs 0.54, 0.79, 0.96, 0.96 from 0.5 m
   to 62.5 mm, and the peaks have not converged at 16 mm.
3. **Conservation.** The deck checks the initial mass and energy but sets no bound on their drift.
   A standard non-conservative axisymmetric scheme gained 41% of the charge's energy on the deck's
   cell size, and the extractor cannot see it. A deck could ask for the final excess energy over
   the initial, and refuse beyond a stated tolerance.
4. **Floors and startup steps** are named (10⁻⁶ kg/m³, 10⁻³ Pa, six steps) but not defined: what a
   floored cell's momentum and energy become, and what a startup step is. Both decided whether the
   runs survived (the room with MC did not; the 16 mm mesh needed the startup steps), and six
   first-order steps move the 31 mm mesh's near peaks and impulses by up to 3.4%.
5. **The numerics** it names (HLLC, limiter θ 1.5) are BombCAD's. Clawpack has no HLLC, and its
   2-D HLLE is in error; a second code will differ here, as the decks' README expects.
6. **A ground-flush gauge reads the first row of cells**, dx/2 above the ground, by the clamp
   rule. Gauges at the same distances 45° above the ground read raw peaks 1–3% higher on 31 mm
   cells. A precursor of a few pascals ahead of the shock there trips the extractor's refusal of
   an earlier positive pulse, since the deadband is 0.1 Pa.
7. **Sampling.** The 50 µs samples still move resolved peaks: on 31 mm cells the peak at Z = 1 is
   1,500 kPa from the samples and 1,549 kPa from every step (3%); on 62.5 mm at Z = 0.75, 2.5%.
8. **The far boundary**, an open item for pyro2's run, is settled for this code: on a 36 m domain
   every value is the 48 m domain's to five digits. The deck could ask for that check.
9. **The ground cannot be tested by this case.** With the charge centred on the ground the
   reflection is the mirror image of the incident wave. A case with a height of burst (Kingery and
   Bulmash's air-burst curves, or a reflected-pressure case) would test it.
10. **The room** is settled by the deck: the mean, the window and the energy bound left nothing to
    choose, and two codes on the same deck agree within 0.07%.

## Rerunning

From this folder, with the virtual environment above as `$PY` (each run on one core):

```bash
$PY blast_axi.py --dx 0.0625 --label free-field-dx0.0625 --history-dir NEW-FOLDER   # the entry, 42 min
for dx in 0.5 0.25 0.125; do $PY blast_axi.py --dx $dx --label free-field-dx$dx; done
for dx in 0.0625 0.03125; do
  $PY blast_axi.py --dx $dx --extent 16 --tmax 0.02 --gauges Z0.75 Z1 Z1.5 Z2 --label near-dx$dx
done
$PY blast_axi.py --dx 0.015625 --extent 16 --tmax 0.02 --gauges Z0.75 Z1 Z1.5 Z2 \
  --startup-steps 6 --label near-dx0.015625
for dx in 0.5 0.25; do $PY blast_axi.py --dx $dx --extent 36 --label boundary-36m-dx$dx; done
for run in 0.25kg-m3 0.5kg-m3 1kg-m3 2kg-m3 4kg-m3; do
  $PY room3d.py --run $run --cells 24 --label room-n24-$run --history-dir NEW-ROOM-FOLDER
  $PY room3d.py --run $run --cells 48 --octant --label room-n48-octant-$run
done
python3 -I mesh_study.py
```

Then import each new history folder and write the entry:

```bash
python3 -I ../../../../Scripts/open-benchmark/run_decks.py import --histories NEW-FOLDER \
  --case kb-surface-burst-free-field --code-name "Clawpack (PyClaw)" --code-version 5.14.0
python3 -I ../../../../Scripts/open-benchmark/run_decks.py import --histories NEW-ROOM-FOLDER \
  --case ufc-closed-room-gas-pressure --code-name "Clawpack (PyClaw)" --code-version 5.14.0
python3 -I make_results.py     # reads histories/free-field and histories/room
python3 -I ../../../../Scripts/open-benchmark/score.py ../../results/clawpack-5.14.0.json \
  --case kb-surface-burst-free-field --case ufc-closed-room-gas-pressure --strict
```

The runs are deterministic on one machine; another compiler or NumPy may move the last digits.
