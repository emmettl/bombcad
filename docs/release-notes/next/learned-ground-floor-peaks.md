kind: added

**The quick estimate can take its ground-floor peaks from the learned field model.** The new
option is **Learned field model for ground-floor peaks**, under the envelope damage, and it is off
by default. With it on, a network trained on BombCAD's own 4 m district runs gives the peak at
each ground-floor façade strip, for the strip's damage, its glass and the walls' chances; the
impulse, the roofs and the upper storeys stay on the surrogate. The network runs on the GPU and
adds about 0.2 s to a drag frame on Beirut's 14,000 buildings. Its standing is illustrative. On
Beirut's 50 runs, a city it never saw, the estimate's glass by side is exactly right on 0.942 of
sides against the surrogate's 0.916, and concrete walls' Brier skill is 0.68 against 0.60 at the
app's load factor. It needs its weights, a 16 MB file not yet shipped with the app; without them
the estimate is the surrogate's alone, and says so
([in the app's quick estimate](../../learned-models.md#in-the-apps-quick-estimate-21-october-2026)).
