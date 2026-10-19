kind: added

**Infer the charge from what was seen after an explosion:** `scenebench infer-charge` takes the
shock's arrival times at observers (Rigby et al.'s table, or any CSV of places and time windows)
and gives the TNT yield and the place, and if asked a height and a clock offset, each with its
credible interval, in about a second ([charge inference](../../charge-inference.md)). It rests on
Kingery–Bulmash's arrivals with the air's temperature, optionally corrected observer by observer
by a BombCAD run of the scene, and a sampler whose intervals hold synthetic charges as often as
they claim. *Approximation:* on Beirut it finds 0.50–0.54 kt (90%: 0.36–0.85) and Warehouse 12 to
within 32 m from Rigby's 31 observers, and 0.66 kt from Stennett et al.'s six, their own estimates
by the same curves (0.50 and 0.64 kt). Broken glass can be added from GEER's façade survey, but it
biases the yield low (the glass model breaks far more than the survey saw), so it is
*illustrative* and off by default.
