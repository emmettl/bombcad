# Mapped start smoke

A 1 kg charge on rigid ground with a small concrete block 9 m off, for `make app-smoke`: on coarse
cells the charge is mapped 6 m out from its one-dimensional solution, so the grid's clock starts
at about 9 ms, after four 2 ms frames. The app runs it from inside its bundle with a structure and
frames, and must reach 16 ms within ten minutes (0.5.0's build waited forever at the hand-over).
