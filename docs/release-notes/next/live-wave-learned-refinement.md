kind: added

**Refine the live blast wave with a learned model.** **Learned Refinement**, in the live wave's bar,
corrects the wave cell by cell with a network trained on BombCAD's own district runs. It is off by
default. On Beirut's runs, which it never saw:

- close in behind buildings, its peaks go from ×1.7 high to about right;
- in sight, 94% of cells come within ×1.25 of the runs' peaks, against 91%;
- arrivals come out closer;
- the pulse carries the runs' impulse.

Behind buildings over the whole plan it is no better, and beyond 1 km it reads a little low. It
adds about 20 ms to a drag step on Beirut, so it runs while you drag. Its weights, 15.7 MB, are
downloaded the first time it is turned on, only once you agree. It is illustrative
([the learned refinement](../../live-wave.md#the-learned-refinement-2-november-2026)).

Headless, `blastmodel live-wave-features` writes its training pairs, and `scenebench
live-wave-judge --learned` judges it. `scenebench field-export --arrival` has now been run over all
200 runs of the learned field's list.
