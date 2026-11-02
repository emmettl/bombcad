kind: changed

**The fire keeps up while you move things:** with the fire after the blast shown, its wind
sliders now redraw the fire's 40-draw preview in about 8 ms on Beirut's 14,169 buildings on a Mac
Studio, against 45 ms, and dragging the charge holds about 25 ms a frame with the fire following.
The district's buildings and their neighbours are kept between frames, and only each building's
glass and walls are refreshed from the live estimate. The fire is the same as before, to the bit
([fire after the blast](../../fire-spread.md#a-fast-path-for-the-preview-2-november-2026)).
