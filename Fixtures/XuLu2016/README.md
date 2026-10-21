# The contest slab's record, as Xu and Lu plotted it

`contest-slab-figure-6.json` holds the two measured curves of Figure 6 of J. Xu and Y. Lu,
"Numerical modelling for reinforced concrete response to blast load: understanding the demands
on material models", ACI SP-306 (2016): the experiment's central deflection (mm, every 0.5 ms)
and the blast force they applied to their quarter-slab model (kN, every 0.25 ms). The user's copy
is on `$BOMBCAD_DATA/data/XuLu2016/`; only these derived numbers are kept.

**Read on the right-hand axes.** The figure's two axes do not agree (its left axis tops at 140 mm
where its right reads 4.5 in, 114 mm; 120 kN against 30 kip, 133 kN). Read on the left, the
measured deflection would peak at 132 mm; on the inch axis it peaks at 108.0 mm at 30.0 ms, as
Schwer's plot (108 mm) and the stated 4.29 in. Read on the kip axis, the applied force over a
quarter of the slab's 64 × 33.75 in face peaks at 48 psi at 7 ms (stated: 50 psi) and carries
6.77 MPa ms by 60 ms, rising to about 7 with the tail (stated 1,020 psi ms, 7.03); on the kN axis
it would carry 13% less. So both measured curves are plotted against the imperial axes, and are
recorded so.

**How.** The page rendered at 300 dpi; the green curves' pixels, per column, at their median
height; axes from the gridlines and frame. **Checks.** The force over the quarter area matches
the hand-read reflected pressure record "Set-1a" in `SlabBenchmark.load` within about 1 psi from
1 to 30 ms: the same record, plotted independently, so the benchmark's load is confirmed rather
than replaced.
