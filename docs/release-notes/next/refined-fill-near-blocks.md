kind: changed

**Refined air among many buildings runs faster.** A newly refined block now checks only the
buildings near it, rather than every building in the scene, when it works out which of its cells
are solid. The results are the same to the bit. On Beirut's 1 km box, a run refined everywhere
takes about 12% less GPU time, and a corridor refined towards one building about 25% less
([performance](../../performance.md#where-a-refined-runs-gpu-time-goes)).
