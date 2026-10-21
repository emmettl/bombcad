# First runnable control record, 21 October 2026

BombCAD release adapter at source commit `32a3583a`, protocol `ideal-gas-balloon-v1`.
The [protocol](../../decks/README.md) fixes inputs and read rules before comparison.
The [scorer entry](../../results/bombcad-ideal-gas-balloon-v1.json) contains all 29 predictions.
The historical entry is unchanged.

- `receipt.json`: exact source/build identity and SHA-256 hashes of deck copies, six raw
  histories, executable and its snapshotted resource files.
- `diagnostics.json`: free-field phase boundaries and room half-window drift.
- `budgets.json`: the adapter's initial excess mass/energy checks and final total-energy changes,
  transcribed from its six retained logs. These budget figures are diagnostics, not references.

Raw histories, logs and the 25 MB runtime snapshot are retained on StudioData at
`$BOMBCAD_DATA/open-benchmark/control-32a3583a/`; they are not bundled in this
repository. The receipt identifies their bytes, but cannot make them available on another host.
Reproduce them with the run command in the protocol, using a fresh output directory and the
source/build revision recorded here. Another GPU/compiler may differ in its last bits: retain
its own receipt and compare numerical results rather than claiming the same executable hash.

| Case | Strict coverage | Pass | Score |
|---|---:|---:|---:|
| KB surface burst, incident | 24/24 | 12/24 | 0.50 |
| UFC closed room | 5/5 | 3/5 | 0.60 |

All eight incident impulses pass the existing scoring bands; all eight peaks are low, and four
arrivals pass. Room means in charge-density order are 418.117, 836.456, 1673.182, 3346.599 and
6693.300 kPa. The first two fail the UFC comparison. Without afterburning, even the analytic
ideal-gas equilibrium bounds (418.4 and 836.8 kPa) cannot reach those two scoring bands.
The three heavier charges pass. No source parameters or windows were adjusted to improve this.

The greatest room half-window drift is 0.016%; the largest relative change of total gas energy
across the six runs is below 8e-8. These are useful consistency checks of this implementation,
not a grid-convergence study or proof of physical fidelity. Peaks, arrival and source-size errors
have not been separated from the ideal-gas/no-afterburning approximation. The deliberately
coarse start is not a resolved detonation.

The first attempt at `69d33d15` completed the simulations but was rejected for writing the wrong
CSV column spelling. Its files remain separately on StudioData. This record comes from a fresh
run of the corrected writer and passed the complete import/extraction/scoring path.

**Next stage:** implement the same deck and history contract in a second solver, then compare
histories and extracted quantities. pyro2 has since run it, 1-D spherical
([its record](../pyro2-ideal-gas-balloon-v1/README.md)); no external invitations were sent. A spatial and sampling convergence study should accompany stronger accuracy claims.
