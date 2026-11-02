kind: changed

**Replays play at an even pace, on the Mac and on the iPad viewer.** Play used to step a frame
each 1/24 s, whatever the simulated time between frames. A run's frames are uneven in time (a
street run's gaps swing from 0.02 to 0.89 ms), so the wave's speed jumped by up to 40 times from
one frame to the next. Now a clock of simulated time moves on with each refresh of the display,
and the frame shown is the last recorded at or before it. A run plays in about as long as before.
On the street run, the simulated time shown per quarter second now varies by 1.12 times
(90th over 10th percentile, measured on an iPad Pro), against 1.5 to 1.6 before. The Mac shows the same frame for any time
as before, and its crater tail still plays in real time. On the iPad the view draws 60 frames a
second while playing. While a run is still arriving, it plays up to the frames already in
([the viewer's notes](../../spatial-viewer.md#on-the-ipad-pro-measured-2-november-2026)).
