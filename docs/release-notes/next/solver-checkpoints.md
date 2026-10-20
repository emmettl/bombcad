kind: added

**Save a run part way and carry it on later, the same to the bit** (headless: the air, its
refinement and its clocks, structures, envelopes' recorders and venting, exposure planes and
deflagrations). `blastbench snapshot --checkpoint-at T --checkpoint-out DIR` saves
the solver's state at the first 64-step boundary from T, `--resume DIR` carries a run on from it,
and `--from DIR` draws it as it was saved ([checkpoints](../../checkpoints.md)). On the CI mini, 24
runs (refined once and twice, on cut terrain, with gravity, on the recommended air, up to 50
million cells) carried on from a checkpoint ended exactly as the same runs straight through. 50
million cells take 78 MB stored early in a run, saved in 4 s and taken back in 0.6 s. Struck walls in
solids and shells, glazed buildings with their recorders and vented panes, and a gas-filled room
carry on to the bit too. In the app, a recorded run saves its state every eighth of the way, within
Settings ▸ Replay's "Space for saved states" (512 MB a run), and wherever you choose with
Simulation ▸ Save State Here (⌥⌘S); replaying, the slider marks them and Continue from… carries the
run on from the one at or before the time shown, the same to the bit as the run straight through
([continuing a run](../../using-the-app.md#continuing-a-run-from-a-saved-state)). Runs with
fragments, ground points or thermal receivers, or with a delayed charge already fired, are refused
with the reason; a saved state is read only by a build whose saved parts keep the same versions.
