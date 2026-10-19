kind: added

**Freestanding objects can share the air with a deformable structure** (stage 1, for the
experimental object drivers on the coarse grid). An object's cells stay solid and moving with it
while a structure beside it bends, and the structure's cells stay its own while the objects move.
In a closed test, a box beside a plate struck by 1 kg changes the gas by what the plate alone does
(16 g of 54 kg). Stage 2 adds contact: thrown into a wall in the air, a box strikes the wall's
nodes at the structure's own step, and the wall's reaction is within 3% of the same throw without
air. **Compute Motion now takes a deformable structure** in the scene. The crop takes in the
structure, the air is uniform (0.1 m), and the section gives the impulse the objects struck it with.
The structure is drawn as placed. `rigidboxdemo --car-wall` blows a saloon into a concrete wall
([freestanding objects](../../freestanding-objects.md#limitations-and-future-work)).
