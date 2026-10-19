kind: fixed

**Broken panes open the refined air where they are.** On refined air with venting (the default), a
mismatch between the solver's and the GPU's layout of the panes' lookup left the two highest pane
cells never opened on the fine grid, and opened the fine cells of the corner cell at the origin,
ground or not, whenever the first pane broke. The layouts now agree, and a test holds them to it.
Runs without refinement or without venting are unchanged.
