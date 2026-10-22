kind: fixed

**Charges on sloping ground now get the mapped start.** A charge sitting on terrain was always
started as a rough sphere of hot gas, instead of the accurate one-dimensional solution mapped onto
the grid that flat ground gets. Its loads then depended on how fine the cells were: on Beirut's
district the blast's impulse read 14–17% low on finely refined air. The ground under the charge is
now treated as the mirror it is, along its own slope. A charge on a gentle slope reads as on flat
ground, and Beirut's impulse rises about 9% on 4 m cells, the same at every refinement within 2%.
This was the known limitation noted for 0.7.0. Runs of charges on terrain made before it read a
lower impulse; flat ground is unchanged.
