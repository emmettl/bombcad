kind: added

**Two candidate options for the far field, off by default.** "Façade terms refitted on clear-top
runs" (Envelope Damage; headless `--surrogate-terms clear-top`) gives Quick Estimate and the far
field the surrogate refitted on its fit runs remade with their tops clear of the far façades. The
peak, impulse and rise-share terms are refitted, and so is the chances' load scatter. "Carry the
run's match flat" (Far field) drops the trend with distance from the far field's match to the run.
Against Beirut's clear-top runs, Quick Estimate's far loads at 0.5 kt go from 0.72–0.92 of the
run's to 0.82–1.03. The glass chances' blown out passes the protective-design test (Brier 0.027
against 0.038). With both options on, the far field's error in the share of sides blown out halves
at every yield. Some glass broken still reads low at 0.2 kt beyond 1.75 km, and concrete walls'
chances miss their tenths test by 0.01 in one tenth. Whether to adopt them is the user's decision
([the surrogate](../../surrogate-first-look.md#refitted-on-clear-top-runs-25-october-2026)).
Developers: `surrogate-judge`, `hybrid-judge` and `glass-calibrate` take `--terms clear-top`, and
`glass-calibrate` takes `--load-scatter`.
