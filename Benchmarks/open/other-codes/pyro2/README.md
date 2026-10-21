# The open benchmark in pyro2

Two of the [open benchmark's](../../../../docs/open-benchmark.md) cases run in a code that is
not BombCAD: [pyro2](https://github.com/python-hydro/pyro2) (Zingale and others; BSD-3-Clause),
an open finite-volume hydrodynamics code in Python, installed from PyPI as `pyro-hydro` 4.5.1
and used unchanged. The scripts here set the runs up through pyro2's Python driver, record the
gauges and write the entry `Benchmarks/open/results/pyro2-4.5.1.json`. What the runs found about
the case format, and how they compare with BombCAD's run of the same balloon, is in
[the open benchmark](../../../../docs/open-benchmark.md#a-second-code-pyro2-20-october-2026).

**These runs predate the [decks](../../decks/README.md)** (`ideal-gas-balloon-v1`, 21 October)
and were set up from the cases' prose. The physics is the decks': one ideal gas of γ 1.4, a
constant-volume balloon of 1,600 kg/m³ holding 4.184 MJ/kg, released at t = 0, no afterburning.
They deviate from the decks in the mesh (1-D spherical at 10 mm, not 3-D at 0.5 m), in air of
1.2250 kg/m³ (15 °C) with no ambient energy beneath the charge's, in a free-field run that stops
at 75 ms rather than 100 ms, and in the room (a sphere of its volume, read at 80 ms rather than
averaged over 100–120 ms). So they are not an import of the decks' contract.

**The decks' run** (21 October) is `run_deck.py`: the same grid code, started and read as the decks
say, every step written as a history in the decks' CSV, imported by `run_decks.py`. Its record is
[`records/pyro2-ideal-gas-balloon-v1`](../../records/pyro2-ideal-gas-balloon-v1/README.md). To rerun
(Python 3.12 with `pyro-hydro==4.5.1`; with SciPy in the environment Numba's JIT works, and
without it set `NUMBA_DISABLE_JIT=1`, slower):

```bash
python -I Benchmarks/open/other-codes/pyro2/run_deck.py --case kb-surface-burst-free-field \
  --run 100kg --dr 0.02 --r-out 36 --out HISTORIES
for run in 0.25kg-m3 0.5kg-m3 1kg-m3 2kg-m3 4kg-m3; do
  python -I Benchmarks/open/other-codes/pyro2/run_deck.py --case ufc-closed-room-gas-pressure \
    --run $run --dr 0.02 --out HISTORIES
done
python3 -I Scripts/open-benchmark/run_decks.py import --histories HISTORIES --code-name pyro2 --code-version 4.5.1
python3 -I Scripts/open-benchmark/run_decks.py extract --histories HISTORIES --out RESULTS.json
```

| File | What |
|---|---|
| `blast1d.py` | The spherical blast: the grid, the charge, the probes, and the peak, impulse and arrival of a record |
| `run_free_field.py` | `kb-surface-burst-free-field`: writes `outputs/free-field-dr<cell>mm.json` and a thinned history `-history.csv` |
| `run_closed_room.py` | `ufc-closed-room-gas-pressure`, as a closed sphere of the room's volume: writes `outputs/closed-room-dr20mm-<run>.json` |
| `make_results.py` | Writes the entry from the outputs (standard library only) |
| `run_deck.py` | One run of an `ideal-gas-balloon-v1` deck, written as the decks' CSV history |
| `outputs/` | The runs' summaries, as committed |

## Why pyro2

- It installs from PyPI on Linux with no compiler (Python, NumPy, Numba). Clawpack and PyClaw
  build Fortran kernels, and the machine these runs were made on has no Fortran compiler;
  OpenFOAM was not tried, since its packages come from outside the package registries this
  machine's network reaches.
- Its compressible solver has a spherical-polar grid (r, θ with azimuthal symmetry) and ships a
  spherical Sedov problem, so a spherical blast is a supported set-up rather than a source term
  added by hand.
- It is documented (python-hydro.github.io/pyro2) and small enough to read, so what each
  parameter does can be checked.

Against it: it is a teaching code, slow (about 25 µs per cell and step on this machine, ghost
cells included), with one ideal gas
for the whole domain and no 3-D grid.

## The set-up

**Geometry.** A wedge of the spherical-polar grid, one cell wide in θ, about the equator, with
reflecting θ faces: the flow stays radial, so the run is 1-D spherical. pyro2's grid cannot
reach r = 0 (its four ghost cells must stay at r ≥ 0), so it starts at a small r_in inside the
charge with a reflecting wall. The wedge's width is set so that its innermost ghost cell is as
wide in θ as in r, because pyro2 takes the time step's limit over ghost cells as well.

**Charge.** A constant-volume balloon released at t = 0: the charge's own mass at 1,600 kg/m³,
holding 4.184 MJ/kg as internal energy, in the same ideal gas (γ = 1.4) as the air. The charge's
surface lies on a cell face, and its mass and energy are spread over the shell r_in < r < r_c so
that neither is lost to the hole. No JWL products, no detonation front, no afterburning.

**Air.** 101.325 kPa (the case's) at 15 °C (the case gives none), 1.2250 kg/m³, γ = 1.4.

**`kb-surface-burst-free-field`.** The 100 kg hemisphere on rigid ground is half of a 200 kg
sphere in free air, so the run is a 200 kg sphere (radius 0.3102 m, 836.8 MJ; 2.69 GPa in the balloon at first), each gauge at its
distance from the charge's centre. Radial cells of 10 mm out to 36 m, open (outflow) beyond; the
run ends at 75 ms, after the farthest gauge's positive phase.

**`ufc-closed-room-gas-pressure`.** pyro2 has no 3-D grid, so not the case's cube: a closed,
rigid, adiabatic sphere of the room's volume (216 m³, radius 3.722 m), the charge at its centre,
cells of about 20 mm. The quasi-static pressure is the volume-mean pressure above ambient, read
at 80 ms (when BombCAD's entry read its room).

**Reading the gauges** (`blast1d.positive_phase`). The pressure at a gauge is interpolated
linearly between the two nearest cell centres, every time step. The peak is the record's largest
overpressure; the positive phase is the stretch around the peak where the overpressure is above
zero, its ends interpolated; the impulse is its trapezoidal integral; the arrival is the first
time the overpressure reaches half its peak (1% and 10% are recorded too).

## Rerunning

Python 3.10 or later. In a fresh virtual environment:

```bash
python3 -m venv venv
venv/bin/pip install pyro-hydro==4.5.1 scipy    # Numba needs SciPy for pyro2's small matrix products
cd Benchmarks/open/other-codes/pyro2
../../../../venv/bin/python run_free_field.py --dr 0.01                      # the entry's run
for run in 0.25kg-m3 0.5kg-m3 1kg-m3 2kg-m3 4kg-m3; do
  ../../../../venv/bin/python run_closed_room.py --run $run --dr 0.02 --label closed-room-dr20mm-$run &
done; wait
python3 -I make_results.py
python3 -I ../../../../Scripts/open-benchmark/score.py ../../results/pyro2-4.5.1.json \
  --case kb-surface-burst-free-field --case ufc-closed-room-gas-pressure
```

pyro2 writes its parameters to `inputs.auto` in the working directory. The resolution study is
`run_free_field.py --dr 0.04`, `--dr 0.02`, and for the four nearest gauges
`--dr 0.005 --r-out 14 --tmax 0.016 --gauges Z0.75 Z1 Z1.5 Z2 --label free-field-near-dr5mm`.

## The runs

On a shared four-core Linux machine, each run on one core alongside other work:

| Run | Cells | Steps | Wall time |
|---|---|---|---|
| Free field, 40 mm, to 36 m | 895 | 2,821 | 5 min |
| Free field, 20 mm, to 36 m | 1,795 | 7,795 | 33 min |
| Free field, 10 mm, to 36 m (the entry) | 3,595 | 19,036 | 81 min |
| Free field, 5 mm, to 14 m, four gauges | 2,790 | 9,396 | 50 min |
| Closed room, 20 mm, each of the five charges | 180 or 181 | 21,366 to 29,282 | 40 to 45 min |

The time step is set by the hot gas left near the centre, not by the shock, which is why the
room's few cells take as many steps as the free field's many.

**Free field, against resolution.** Peak (kPa), impulse (kPa·ms) and arrival at half the
peak (ms):

| Gauge | Reference | 40 mm | 20 mm | 10 mm | 5 mm |
|---|---|---|---|---|---|
| Z0.75, 3.48 m | 2,411 / 890 / 1.3 | 2,743 / 825 / 1.19 | 2,832 / 830 / 1.27 | 2,865 / 832 / 1.28 | 2,919 / 834 / 1.29 |
| Z1, 4.64 m | 1,354 / 1,097 / 2.2 | 1,486 / 898 / 1.93 | 1,601 / 867 / 2.02 | 1,666 / 859 / 2.04 | 1,700 / 860 / 2.04 |
| Z1.5, 6.96 m | 551 / 824 / 4.6 | 554 / 616 / 4.13 | 589 / 612 / 4.22 | 613 / 611 / 4.24 | 622 / 611 / 4.24 |
| Z2, 9.28 m | 284 / 625 / 7.9 | 271 / 494 / 7.32 | 286 / 493 / 7.40 | 294 / 492 / 7.41 | 297 / 492 / 7.42 |
| Z3, 13.9 m | 116 / 430 / 16.5 | 110 / 370 / 15.92 | 114 / 370 / 15.97 | 116 / 370 / 15.98 | – |
| Z4, 18.6 m | 65 / 336 / 26.9 | 62.9 / 291 / 26.27 | 64.4 / 291 / 26.31 | 65.2 / 291 / 26.32 | – |
| Z5, 23.2 m | 43 / 275 / 38.3 | 42.8 / 238 / 37.58 | 43.3 / 238 / 37.62 | 44.3 / 238 / 37.62 | – |
| Z6, 27.9 m | 32 / 233 / 50.2 | 31.7 / 201 / 49.46 | 32.2 / 201 / 49.49 | 32.5 / 200 / 49.49 | – |

The impulses and arrivals have converged by 20 mm; the peaks still rise with refinement close
in (2% at Z = 1 from 10 to 5 mm). The 40 mm run's hollow core is larger (r_in = 0.23 m, against
0.05 m on the finer grids), since r_in must be at least five cells, so its balloon is
denser and starts at 4.5 GPa rather than 2.7.

**Closed room.** Volume-mean overpressure (kPa), and the kinetic energy's share of the gas's
energy at the time:

| Run | Energy balance | 10 ms | 30 ms | 80 ms (the entry) | 100 ms |
|---|---|---|---|---|---|
| 0.25 kg/m³ | 418 | 393 (5.1%) | 416 (0.6%) | 417 (0.5%) | 416 (0.7%) |
| 0.5 kg/m³ | 837 | 829 (0.9%) | 831 (0.8%) | 836 (0.3%) | 836 (0.2%) |
| 1 kg/m³ | 1,674 | 1,617 (3.3%) | 1,661 (0.8%) | 1,675 (0.0%) | 1,676 (0.0%) |
| 2 kg/m³ | 3,347 | 3,337 (0.4%) | 3,349 (0.1%) | 3,337 (0.4%) | 3,340 (0.3%) |
| 4 kg/m³ | 6,694 | 6,667 (0.5%) | 6,664 (0.5%) | 6,696 (0.1%) | 6,699 (0.0%) |

The energy balance is ((γ − 1) E − p₀ V_charge) / V. The total energy drifted by 0.08 to 0.19%
over the 100 ms runs.

**Fix after the runs.** The first version of `positive_phase` took round-off ahead of the shock
(about 10⁻¹⁴ Pa above ambient) as positive, and so started two gauges' positive phases at t = 0:
Z0.75 on 20 mm and Z2 on 5 mm. That changed their durations, not their impulses (the round-off
integrates to nothing), peaks or arrivals. The function now counts anything below 10⁻⁹ of the
peak as zero, and those two durations in `outputs/` were corrected by hand, each with a note
saying so. The 10 mm entry was not affected.
