kind: added

**A quick estimate of a district's envelope damage in seconds, without running the air.**
Simulation ▸ Quick Estimate of Envelope Damage (and `BombCAD run --surrogate`) predicts each wall,
roof and façade strip's load from its distance, facing and the buildings in its way
(Kingery–Bulmash corrected by terms fitted to BombCAD's runs of two made-up districts), then
judges it with the run's own damage model. Over Beirut's 724,000 components it takes about half a
minute, against 25–28 minutes for each full run on the CI mini (27–41 minutes when timed again for
the hybrid comparison). Judged against Beirut's full runs, which it was not fitted to, each
building side's glass state agrees with the run's for 75–84% of sides and the share broken by
distance comes within about 0.1 to 2 km; walls and roofs are not to be relied on. It is shown as
an estimate with that standing, never as a run ([first look](../../surrogate-first-look.md)).
