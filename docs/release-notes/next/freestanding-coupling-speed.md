kind: changed

**Freestanding objects' motion runs are about twice as fast in crowded scenes, and repeat to the
bit.** Moving objects through refined air now remaps only the cells that open or close, side by
side on the CPU's cores, so the coupling, which cost more than the air in the car park, room and
pen, takes a quarter to a third of its time: the car park's 0.5 s run took 771 s against 1,417 s
on the CI Mac mini ([freestanding objects](../../freestanding-objects.md#populated-scenes)). The
gas, outlines and walls are the same to the bit. Two faults went with it: a box in the corner of
an L of others was opened by their remap and closed by its own (in the furnished room the pieces
now move up to 5 mm differently), and the air's loads were summed in an order the GPU decided, so
the same run could part after 0.05 s; both are fixed.
