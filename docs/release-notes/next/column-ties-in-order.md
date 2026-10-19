kind: fixed

**A building with slabs on columns is built the same by every launch.** The order in which slab
nodes were tied to column heads (and, for a node near two heads, which head it went to) and the
numbering of the punching rings followed an order that changes from one launch to the next. The
structure handed to the GPU therefore differed between launches, and a run could differ in its
last bits, which grow once something fails. The heads are now taken in order: the twelve-storey
and office towers' structures are the same, byte for byte, in every launch.
