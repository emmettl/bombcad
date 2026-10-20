kind: fixed

**Saved façade loads keep close-in peaks above 65.5 kPa.** `district-compare --save-loads` no longer clips façade pressures above 65.5 kPa. The strips were stored as 16-bit floats in pascals, so every close-in peak read as 65,504 Pa in `district-glass`, `surrogate-extract` and `surrogate-judge`. They are now stored over a power-of-two scale recorded in `strips.json`, at the same relative precision. Folders saved earlier still read as before, clipped peaks and all.
