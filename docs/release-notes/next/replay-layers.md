kind: changed

**Replay shows vent panels, envelope damage, the thermal paint and the cloud as they came, and
recording no longer holds the run up.** A run's recording now keeps, with each frame where they
change, which vent panels have opened and which envelope panes have broken, each envelope
building's damage colour (glass broken from the frame its first pane breaks), the thermal
receivers' paint as far as reckoned then, and the cloud from the frame it was handed over in, so a
replayed vented street turns each building to glass broken at the frame its first pane broke,
rather than showing the run's end throughout.
0.6.0's recordings still play, those layers as the run left them. The blast's field for each frame
is now cut out on the GPU by the batch that passes the frame's time, while it is there anyway, so a
frame of 21 million cells takes about half a millisecond of the main thread instead of 9 ms, and
the run is the same to the bit with recording on or off ([using the app](../../using-the-app.md#replaying-a-run)).
