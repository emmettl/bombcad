kind: fixed

**Rubble no longer blows a run up at the joints between parts.** With failed concrete kept as
rubble particles (an option), a joint whose node had lost its concrete to a particle stayed as
stiff as for the whole node and rang far beyond the step: on the large-panel block a node was
driven to 18 km/s at 0.62 s. A joint now bears in proportion to the mass its nodes have left;
without rubble nothing changes. Found carrying the block past its collapse
(emmettl/bombcad-work#36), which also showed that the energy budget stops closing once the bay
falls, with rubble or without, so collapse stays illustrative. See
[whole-event simulation](../../whole-event.md).
