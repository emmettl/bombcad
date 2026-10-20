kind: added

**BombCAD's validation as an open benchmark another blast code can run and be scored on.** Ten
cases in a solver-neutral JSON format (`Benchmarks/open/cases`), each with its scene, charge and
stated TNT equivalence, gauges, and the measured or reference values with their uncertainty and
full citations: Kingery–Bulmash in the open and on a wall, ANFO before pipe columns, a blast wall's
shielding, two close-in reflected loads, a closed room's gas pressure, slabs bent by hung charges,
laminated panes in a shock tube and ground motion under 1 t. A standard-library scorer
(`Scripts/open-benchmark/score.py`) gives each gauge's ratio, each case's score within its stated
factor and a summary. BombCAD's own entry, quoted from the record without new runs, scores 0.65 on
average (83 of 123 values within their bands), the shortfalls those the record already names. No
other code has run the cases yet; what is missing is listed ([open benchmark](../../open-benchmark.md)).
