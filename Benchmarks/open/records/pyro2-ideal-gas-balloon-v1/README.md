# pyro2 on ideal-gas-balloon-v1, 21 October 2026

The first code other than BombCAD run to the [decks' contract](../../decks/README.md):
[pyro2](https://github.com/python-hydro/pyro2) 4.5.1 (PyPI `pyro-hydro`, BSD-3-Clause), unchanged,
driven by [`run_deck.py`](../../other-codes/pyro2/run_deck.py). Its histories were imported and
extracted by `Scripts/open-benchmark/run_decks.py` (which checked their provenance, stop times,
sampling, coverage and the room's initial energy) and scored by `score.py`. The
[scorer entry](../../results/pyro2-4.5.1-ideal-gas-balloon-v1.json) holds all 29 predictions.

**What it keeps from the decks:** one ideal gas of γ 1.4; air of 1.225 kg/m³ at 101.325 kPa, at
rest; the balloon as the decks' excess mass and excess energy added to the ambient state inside its
sphere (radius from the full charge at 1,600 kg/m³), released at t = 0; the free field's 0.100 s
and the room's 0.120 s stops; signed overpressure at every gauge from 0 to the stop, at least every
50 µs (every solver step is written, the longest 15 µs); and the extractor's read rules unchanged.

**The deviation, stated:** pyro2 has no 3-D grid, so both cases are 1-D spherical, on a
one-cell-wide wedge of its spherical-polar grid with reflecting faces (as in
[`blast1d.py`](../../other-codes/pyro2/blast1d.py)), not the decks' 3-D Cartesian meshes:
- the free field is the whole 200 kg sphere (eight times the deck's octant) on 20 mm cells from a
  reflecting core at 0.11 m to an outflow boundary at 36 m, each gauge at its distance from the
  centre, its pressure linear between cell centres;
- the room is a closed rigid sphere of the cube's 216 m³ on 20 mm cells, its observable the
  volume-weighted mean pressure over every cell.

Numerics are pyro2's (second-order unsplit CTU, CGF Riemann solver, CFL 0.8), not the decks'
BombCAD settings. Numba's JIT was off (the venv holds no SciPy, which its `np.dot` needs), which
changes the speed, not the answer: the free field took two hours of wall time on a loaded Studio,
each room 31–47 minutes.

- `receipt.json`: the decks' and the six histories' SHA-256 hashes, as `run_decks.py import` wrote it.
- `diagnostics.json`: the free field's phase boundaries and the rooms' half-window drift.
- `runs.json`: each run's grid, steps, longest step and wall time, and the 40 mm resolution check.

The histories (about 13 MB), the deck copies and the run scripts are kept on StudioData at
`$BOMBCAD_DATA/open-benchmark/pyro2-decks/` (`entry-20mm/` is the imported folder); they are
not in the repository.

| Case | Strict coverage | Pass | Score |
|---|---:|---:|---:|
| KB surface burst, incident | 24/24 | 23/24 | 0.96 |
| UFC closed room | 5/5 | 3/5 | 0.60 |

**On 40 mm cells** (the resolution check), the peaks are 2–7% lower (Z = 1: 1,486 kPa against
1,601 kPa), the impulses within 1% but at Z = 1 (+3.5%), and the arrivals earlier by 6% at
Z = 0.75 down to under 0.5% from Z = 3 out; its hollow core is 0.23 m against 0.11 m, so its
balloon starts denser. The rooms move by under 0.2%. The 0.25 kg/m³ room is not on 40 mm: its charge is smaller than the five cells the
grid's hollow core needs.
