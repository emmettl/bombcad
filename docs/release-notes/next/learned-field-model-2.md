kind: changed

**Learned field model 2:** the quick estimate's learned field option now gives the peak at every
storey's façades, not just the ground floor's. Field model 1's network still does the ground floor,
and a second network, trained on BombCAD's own runs at more heights, does the storeys above. The
chances draw each network's own scatter. Roofs and the impulse stay on the surrogate. It was
judged against Beirut's runs refined to 2 m, a city it never saw:

- glass blown out by building side scores Brier skill 0.44 against field model 1's 0.35, and 0.43
  against 0.32 above the ground floor;
- concrete walls damaged moderately or worse score 0.656 against field model 1's 0.654, and both
  pass the tenths test, on the façade terms refitted the same day (see the surrogate's note; on the
  terms before, field model 2's walls missed it by one tenth);
- roofs are unchanged.

It is illustrative. The two files, 31.4 MB together, download from the `field-model-2` release only
when you click Download. An install that has field model 1 keeps working as before, and is offered
the second file (15.7 MB) under "A newer model is available". **Check on this Mac**, or
`BombCAD field-model check` without a window, runs the networks on a built-in 5 km district. It
reports the GPU, the times, the peak memory and whether the model fits. A plan too large for the
GPU is refused with a message and left to the surrogate, never run. See
[learned models](../../learned-models.md#field-model-2-in-the-app-23-october-2026).
