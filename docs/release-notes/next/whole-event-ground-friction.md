kind: limitation

**A large-panel block's collapse is now quoted on a ground with friction and in live air, where
its debris comes to rest.** Whole-event runs take Coulomb friction 0.6 on the ground by default
(the structure solver's own default stays frictionless), and keep the air awake, as the
twelve-storey runs already did (the solver's own sleeping air is unchanged elsewhere). The
collapse's standing, still illustrative, quotes its range between today's element and assumed
strain on those defaults. Twelve storeys lose 237–309 m² of floor, 11–12 storeys past 15%, with
22,600–52,400 elements failed and 34–78 t of rubble. Three storeys lose none to 19% of their
floor, with 861–8,059 elements failed (read at rest, at 5 s). The debris comes to rest, 99% of it within 1.3–7.4 m of the
plan (5.8–7.4 m on twelve storeys, 1.3–3.0 m on three). The frictionless runs had ended at up to
16.9 m and still creeping. On the frictionless ground, three storeys lost 15% of their floor with
today's element, where with friction their broken ground-floor wall holds at the foot and the block
stands. In sleeping air the frozen field pushed the falling bay, and assumed strain took 74–81% of
three storeys' floor down where in live air it takes 19%. For developers, `blastbench wholeevent
--ground-friction 0` gives the frictionless ground of the earlier runs and `--sleeping-air` their
sleeping air. See [adopted: ground friction 0.6](../../whole-event.md#adopted-ground-friction-06-30-october-2026)
and [adopted: awake air](../../whole-event.md#adopted-awake-air-31-october-2026).
