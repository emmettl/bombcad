kind: limitation

**A large-panel block's collapse carried to 10 s: the collapse holds, the walls at rest do not.**
The collapse's standing, still illustrative, now notes the twelve-storey block with today's element
run to 10 s. The collapse is over by 3.5 s: 243 m² of floor down and 99% of the debris within
7.5 m hold to 10 s. But the block at rest goes on failing walls at 1,300–1,800 elements a second,
and its pile spreads slowly, so whole-event results are now read once the block is at rest, at 5 s,
and no later failure count or rubble mass is quoted (read again there, three storeys lose 861–8,059
elements, where 864–8,081 were quoted at 7 s). That failing is the solver's, not the concrete's:
the debris fallen 16–26 m keeps its displacements as floats, which there move in steps of 1.9 µm, a
fifth of the panels' cracking strain across an element, and the rounding sets the pile humming.
Kept precisely, in a prototype not adopted, the pile settles, failing at a fortieth of the rate,
and the block comes down the same, with a fifth fewer failures and rubble at 5 s; whether to adopt
it is the user's decision. For developers, `blastbench
wholeevent --outcome <run folder>` names the row to quote, and `--dump-split` writes the census
split node by node. See [the 10 s run](../../whole-event.md#the-10-s-run-31-october-2026) and
[read at rest](../../whole-event.md#read-at-rest-and-the-walls-that-fail-at-rest-31-october-2026).
