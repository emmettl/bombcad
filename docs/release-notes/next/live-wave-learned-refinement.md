kind: added

**The live blast wave is refined by a learned model.** **Learned Refinement**, on by default in the
live wave's bar, corrects the wave cell by cell within about 1 km of the charge. It uses a network
trained on BombCAD's own district runs, and eases to the plain wave by 1.2 km. On Beirut's runs,
which it was never trained on:

- close in behind buildings, its peaks go from ×1.7 high to about right;
- 96% of cells in sight and 70% behind buildings come within ×1.25 of the runs' peaks, against 91%
  and 68%;
- arrivals come out closer;
- the pulse carries the runs' impulse.

It adds about 20 ms to a drag step on Beirut, so it runs while you drag. Until its weights (15.7 MB,
the `live-wave-model-1` release) are on your Mac, the wave is the plain one. **Download
Refinement…** in the bar fetches them, only once you agree. Turn the checkbox off to go back to the
plain wave. It is illustrative ([the learned refinement](../../live-wave.md#adopted-as-the-default-2-november-2026)).

Headless, `blastmodel live-wave-features` writes its training pairs, and `scenebench
live-wave-judge --learned [--blend near,far]` judges it. `scenebench field-export --arrival` has now
been run over all 200 runs of the learned field's list.
