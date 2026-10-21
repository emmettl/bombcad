kind: added

**Finer weak-wave controls:** `blastbench acoustic-phase --fine` selects 512/1024/2048 cells, and `--cfl 0.45|0.225` explicitly compares two Courant settings. Results retain initial conserved state for independent pressure-projection and transport checks. The original default matrix and solver defaults are unchanged.
