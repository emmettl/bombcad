kind: added

**Save a run part way and carry it on later, the same to the bit** (headless, stage 1: the air,
its refinement and its clocks). `blastbench snapshot --checkpoint-at T --checkpoint-out DIR` saves
the solver's state at the first 64-step boundary from T, `--resume DIR` carries a run on from it,
and `--from DIR` draws it as it was saved ([checkpoints](../../checkpoints.md)). On the CI mini, 24
runs (refined once and twice, on cut terrain, with gravity, on the recommended air, up to 50
million cells) carried on from a checkpoint ended exactly as the same runs straight through. 50
million cells take 78 MB stored early in a run, saved in 4 s and taken back in 0.6 s. Runs with
structures, envelopes or deflagrations are refused for now; the app's "Continue from here" comes
with stage 3.
