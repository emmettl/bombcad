kind: fixed

**Thermal output over terrain no longer stalls a district run.** Each sight line from a receiver
to the fireball looked up the terrain's highest point by scanning every one of its nodes, so on a
district's heightfield the thermal march spent nearly all its time there and a run with thermal
receivers made no progress for over an hour. The highest point is now found once. Results are
unchanged, bit for bit.
