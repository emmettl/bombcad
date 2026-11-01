kind: changed

**A large-panel block's collapse is now quoted with its debris's displacements kept precisely,
and its pile at rest is quiet.** Whole-event runs keep each node's displacement together with the
rounding error its float leaves. Kept as a float, the debris that had fallen 16–26 m moved in steps
of 1.9 µm, and its walls went on failing at rest, 1,700 a second on twelve storeys. Kept
precisely, they fail 23–33 a second, and the pile is still by 6 s. What comes down does not change:
twelve storeys lose 237–309 m² of floor, 11–12 storeys past 15%. The collapse's standing, still
illustrative, now quotes 18,000–51,100 elements failed and 27–76 t of rubble, not 22,600–52,400 and
34–78 t: today's element fails a fifth fewer, and assumed strain 2% fewer. Today's debris reaches
further, 99% of it within 9.1 m, not 7.4 m. Three storeys, whose debris falls less than 8 m, are
not rerun. Every other scene is the same to the bit. For developers, `blastbench wholeevent
--float-displacements` gives the earlier runs' floats. See
[adopted: displacements kept precisely](../../whole-event.md#adopted-displacements-kept-precisely-1-november-2026).
