kind: changed

**Compute Motion warns when a car's gap to the ground lies between cell faces.** Beside a
deformable structure the motion run moves cars on uniform 0.1 m cells, which take a saloon's
0.15 m underbody gap as 0.1 m. That gap can decide whether the car overturns or rocks back. The
standing and the Freestanding objects section now say so for each such car, as they do on a slope
or for a tilted car: whether it overturns may differ on finer cells. Beside a structure the
section offers uniform cells that resolve the gap, with their cost (about 3.2 times the time on
0.075 m cells), or says that the scene is too large for them
([freestanding objects](../../freestanding-objects.md#which-outcomes-the-whole-cell-outline-flips-20-october-2026)).
