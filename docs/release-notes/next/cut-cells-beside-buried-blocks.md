kind: fixed

**Air over terrain no longer gains gas where buildings stand in a slope.** A cut cell between a
building's face and the rising ground took a ghost beyond the building built before the ground's
mirror was set, so gas passed through the building's face as the blast went by: a street over a
hill in a closed box gained 0.34 kg and 0.28 MJ in 60 steps, refined or not. The ghost is now built
in order and the box keeps its gas to round-off ([terrain](../../terrain.md)). Scenes whose
buildings stand on flat ground, or on terrain without cut cells, are unchanged.
