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
and are 3–7% below the 1-D peaks on the finest meshes run.

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
- **Peaks** converge slowly, at an observed order below one: a shock smeared over two or three
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

ROOM

## Scores

SCORES

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

OPEN

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
