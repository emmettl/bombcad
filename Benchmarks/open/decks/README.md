# Runnable controls: ideal-gas-balloon-v1

These two decks pin numerical inputs for the existing
[KB free-field](../cases/kb-surface-burst-free-field.json) and
[UFC room](../cases/ufc-closed-room-gas-pressure.json) cases. They do **not** replace the
references, prescribe how real TNT behaves, or change BombCAD's defaults. They are a shared
constant-volume ideal-gas balloon control, intended to expose differences between codes with
identical inputs. No second code has run this protocol yet. In particular, turning afterburning
off removes energy important to the UFC comparison; a low score is an approximation result,
not a reason to silently change the deck.

## Run, extract, score

From the repository root, build once, then use the shared GPU scheduler on a Mac:

```bash
swift build -c release --product blastbench
~/.local/bin/gpu-slot --mem 3 python3 -I Scripts/open-benchmark/run_decks.py run \
  --binary .build/release/blastbench --out $BOMBCAD_DATA/open-benchmark/my-run \
  --code-version MY-BUILD-VERSION --code-commit MY-SOURCE-COMMIT
python3 -I Scripts/open-benchmark/run_decks.py extract \
  --histories $BOMBCAD_DATA/open-benchmark/my-run \
  --out $BOMBCAD_DATA/open-benchmark/my-results.json \
  --diagnostics $BOMBCAD_DATA/open-benchmark/my-diagnostics.json
python3 -I Scripts/open-benchmark/score.py \
  $BOMBCAD_DATA/open-benchmark/my-results.json --strict
```

`--case ID` and `--run ID` select a smaller run. The wrapper refuses an existing output folder.
The adapter can also be called directly:
`blastbench open-benchmark --deck FILE --run ID --out NEW-HISTORY.csv`.
It constructs a grid directly, fills ambient gas, installs the sparse state, and restarts at
zero; it never calls the application charge depositor. It refuses unsupported physics and
checks the deposited excess energy and mass, allowing 0.01% for Float conversion. Its log
records initial budgets and final/initial total energy. All six runs produce 29 predictions.

Another code can read these same JSON decks and write the CSV histories below. Place them in a
new folder, with filenames `CASE--RUN.csv`, then create its receipt and use the same extractor:

```bash
python3 -I Scripts/open-benchmark/run_decks.py import --histories /path/to/histories \
  --code-name OTHER-CODE --code-version VERSION --code-commit COMMIT
python3 -I Scripts/open-benchmark/run_decks.py extract --histories /path/to/histories \
  --out /path/to/results.json --diagnostics /path/to/diagnostics.json
```

Import also accepts the case/run selectors. It checks every requested history; it cannot verify
that another code implemented the declared physics. Record that code's mesh, reconstruction,
Riemann solver and any deviations alongside its entry. A code that cannot implement an input
must report the deviation, not present it as this fixed control.

## Physics and exact initial state

All units are SI, origin at the grid's minimum corner, cell `(i,j,k)` occupying
`[i dx,(i+1) dx] x [j dx,(j+1) dx] x [k dx,(k+1) dx]`, x fastest in flattened storage.
The Euler equations have one ideal gas, gamma 1.4, `p = (gamma-1) (E - |momentum|^2/(2 rho))`.
There is no JWL material, species reaction, afterburning, mapped start, radiation, gravity,
viscosity, heat conduction, structure or wall heat loss. Initially all momenta are zero.
Every unlisted cell has density 1.225 kg/m3 and internal energy 101325/0.4 J/m3.
Every `initial_cells` record replaces those two values; its energy is a **density**, not a
specific energy or total joules. There is no finite-time energy release after t = 0.

The sparse records, not a code's own source implementation, define the discrete start.
Their reproducible construction in `Scripts/open-benchmark/protocol.py` is:

1. Spherical balloon density 1600 kg/m3 and energy 4.184 MJ/kg of represented charge.
2. In each intersecting cell, count the 8 x 8 x 8 equally spaced midpoint samples strictly
   inside the sphere. Normalise these hit counts over all source cells to weights `w` summing
   to one. A zero hit count is omitted; no analytic cell intersection is assumed.
3. Add `represented_mass * (1 - 1.225/1600) * w / dx^3` to ambient density and
   `represented_mass * 4184000 * w / dx^3` to ambient internal-energy density. This retains
   the mass of products replacing air and the prescribed **excess** energy, even on coarse grids.
   Keep ambient energy beneath the added energy. All motion starts from rest.

For the surface burst, a 100 kg hemisphere equals half a 200 kg sphere. Solve its positive
coordinate octant, with 25 kg of represented charge and 104.6 MJ excess energy. The sphere
radius is computed from the **full 200 kg**, not 25 kg. The cube is 64 m a side, 128 cells per
axis at 0.5 m. Faces x-min, y-min and z-min reflect (reverse normal momentum in ghost cells);
the three outer faces copy the adjacent interior conserved state into ghost cells. This is
zero-gradient outflow, not an exact non-reflecting condition. Ground-gauge coordinates are
unchanged from the original case. Stop at 0.100 s. Boundary and spatial convergence remain to
be checked before treating the chosen mesh as accurate; the deliberately coarse source is
resolved by its conservative cell values, not by a detonation calculation.

For the room, solve the full 6 m cube, 24 cells per axis at 0.25 m, all six faces reflecting
and adiabatic. Source centre `(3,3,3)`, full-sphere mass 54, 108, 216, 432 or 864 kg; there is
no symmetry mass reduction. Stop at 0.120 s. As an independent energy-budget bound, the
equilibrated ideal-gas excess pressure would be `(gamma-1) Q / 216`, i.e. 418.4, 836.8,
1673.6, 3347.2 and 6694.4 kPa. Kinetic energy still present lowers the spatial mean pressure.
These are analytic controls, **not** UFC reference values or replacement simulated predictions.

The BombCAD adapter pins HLLC, limiter theta 1.5, CFL 0.45, six startup steps, density floor
1e-6 kg/m3, pressure floor 1e-3 Pa and no refinement. Directional splitting, limiter details
and floating-point arithmetic can still differ between implementations: identical decks do not
promise identical answers. The JSON also hashes the unmodified empirical case it accompanies.

## Histories and read rules

CSV header, in this order:

```text
case,run,gauge,time_s,overpressure_Pa
```

Write **signed overpressure above 101325 Pa**, not absolute pressure, peaks or clipped positives.
Times start at deposition/detonation zero; no mapped-start offset is allowed. Write all gauges
at common times, including zero and the stop, spaced by at most 50 microseconds. The adapter
lands batches at those targets and writes actual solver times. A 20 ns tolerance handles its
clock rounding; the extractor checks start, stop, monotonicity, gaps, finite numbers, IDs and
coverage. A missing sample, duplicate time, wrong unit/header or truncated record is refused.

- **Free field:** sample pressure by trilinear interpolation between cell centres. The fractional
  cell coordinate is `position/dx - 0.5`; clamp each neighbour index to the domain at symmetry
  boundaries. Interpolate pressure, not conserved state. Report the largest sampled pressure,
  without smoothing or interpolation of the peak. Replace absolute overpressures <= 0.1 Pa by
  zero (a fixed numerical deadband). Arrival is the first rising half-peak crossing before the
  peak, linearly interpolated in time. Start the impulse at the last non-positive sample before
  that crossing (interpolate its zero if negative), and end at the first non-positive sample
  after the peak, again interpolating the zero. Integrate the piecewise-linear positive phase
  by trapezoids. Pa s equals kPa ms numerically. A zero between the half-peak crossing and the
  largest peak is refused as a later-pulse ambiguity, as is an earlier positive pulse before
  the selected phase (even if below half peak); a phase not ended by the stop is refused.
  Diagnostics record the chosen phase boundaries. This fixes an observation rule; it does not
  make noisy or under-resolved waveforms physically accurate.
- **Room:** at every sample, compute the volume mean of pressure over **all gas cells**, not the
  pressure at the centre or the EOS evaluated on a mean density/energy with kinetic energy
  omitted. The initial room mean must match the declared source-energy bound within 0.01%;
  this also catches a point pressure or absolute-pressure series mislabeled as a volume mean. Time-average that series from exactly 0.100 to 0.120 s, using interpolated endpoints
  and trapezoids. Convert Pa to kPa. Diagnostics give the difference of the second and first
  half-window means divided by the whole mean. This is a fixed finite-window proxy for the
  quasi-static gas pressure, **not** proof that reverberations have decayed. Report drift even
  if it is poor; do not choose a more favourable window after looking at the UFC score.

## Versioning, evidence and limits

The wrapper snapshots the executable and its adjacent SwiftPM resource bundles in the output
folder, then keeps a deck copy, each raw history and its adapter log, and a receipt with SHA-256
hashes of decks, histories, the executable and all snapshot files. A concurrent build cannot change
the runtime used between shots. Extraction checks deck equality against this
protocol, case hashes and history hashes, and refuses missing/extra/duplicate runs and unsafe
receipt paths. Results use the existing scorer format, carry the protocol ID and hashes in
notes, and are separate from `bombcad-0.6.0-dev.json`. The source commit and build version are
caller-supplied provenance: supply the actual build, including a dirty-tree marker if applicable.

Deck files are generated, not edited by hand:

```bash
python3 -I Scripts/open-benchmark/protocol.py
python3 -I Scripts/open-benchmark/test_decks.py
```

Any change to source physics, mesh, boundary treatment, sampling or extraction requires a new
protocol ID and regenerated decks; never retune this version to improve its score. The tests
verify exact regeneration, symmetry energy accounting, analytic pulse/window integrals and
malformed/incomplete/tampered histories. The existing ten references and historical entry are
unchanged. This stage does not add a second solver, structural decks, convergence studies,
scored full waveforms, an external submission service, or a claim of independent validation.
