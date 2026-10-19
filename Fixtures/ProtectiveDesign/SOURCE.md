# The protective-design prototype's problems, as data

Written by `python3 Scripts/protective/export.py Fixtures/ProtectiveDesign/prototype.json` from the
prototype's made-up sites (`Scripts/protective/scenarios.py`: courtyard, street, weak-shielding).
It holds no real place or price: the buildings, loads, shielding and costs are the prototype's
assumptions (docs/protective-design.md). For each site it gives the sides' options and costs, the
site-wide changes, every side's chance of passing its target for every option and choice of
site-wide changes, and the plans the prototype's searches found. `ProtectionSearchTests` checks
that the Swift search finds the same plans from the same chances.
