# Tracing the glass model against GEER's Beirut survey

Scripts for docs/glass-probability.md, "Why it over-breaks against GEER". Standard library only.

1. Export each matched façade's pane responses from the saved Beirut runs (CPU, about a minute):
   `scenebench glass-calibrate <Beirut inputs> --dx 4 --height 320 --radius 2500 --mass 500000
   --runs 200000:…/loads-200000,500000:…/loads-500000,1100000:…/loads-1100000 --geer Facade_damage.shp
   --skip-runs --draws 10 --trace trace.csv` (writes trace.csv and trace.csv.matches.csv).
2. `python3 geer.py`: GEER's classes, break and blow-out rates, and facing, by distance.
3. `python3 gtrace.py 1`: the model's bands from the trace (run 1 is 0.5 kt).
4. `python3 vsload.py 1`, `facing.py 1`, `fragility.py`: GEER's classes against each side's own
   load, by facing, and the fitted fragilities.

The paths at the top of geer.py and gtrace.py point at StudioData; the survey's files are GEER's
(DesignSafe PRJ-3030, ODC-By), not in the repository.
