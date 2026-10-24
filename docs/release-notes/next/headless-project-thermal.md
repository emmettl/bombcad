kind: fixed

**`BombCAD run`, `BombCAD watch` without `--as-app` and sweeps no longer fail to keep the run of a
project that has its own thermal radiation or cloud.** Such a run started the project's radiation
and cloud as the app does, then tried to keep the run before they had caught up ("The thermal
radiation is still being reckoned"). It now leaves them, as it already left the project's
fragments and ground points: the headless way to ask for them is `--thermal` and `--cloud`, and
`--as-app` runs the project as the app does, its radiation and cloud included.
