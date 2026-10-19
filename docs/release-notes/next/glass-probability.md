kind: added

**Each building side's chance of broken, blown-out and thrown glass, in about a minute.** Quick
Estimate (and `BombCAD run --surrogate`) now draws the first look a hundred times over the yield,
each building's glass strength and the estimate's own scatter, and colours each side by its chance
of glass broken, blown out or thrown past 3 m (GSA's condition 3b); "Yield known to within" sets
the yield's spread, or `--surrogate-yields` takes an inferred charge's samples. Against Beirut's
full runs at 0.2, 0.5 and 1.1 kt the chances are calibrated (each tenth of chance within 0.1 of the
share of runs, for all three); against GEER's survey they are not, sharing the glass model's
over-breaking, so they read as a run's spread, not the event's.
Walls and roofs are given no chances ([glass by chance](../../glass-probability.md)).
