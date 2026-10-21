kind: added

Field exports can capture the signed pressure consumed by the first-phase recorder, including
its seeded initialization and selected receivers at additional heights. Use `--trace-pressure`
with `--trace-columns` and `--first-phase`; the separate, versioned trace supports exact
recorder replay and has an explicit sample budget. Check ordinary/observed output parity
before using an instrumented trace to diagnose production labels.
