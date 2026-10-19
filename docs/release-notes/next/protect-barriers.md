kind: added

**Barriers and stand-off lines in protective design.**
- **Stand-offs.** `scenebench protect` takes a stand-off as one of the scene's stand-off lines,
  which stops each charge it guards against a metre outside it. Protective Design in the app
  offers the scene's lines, each with your cost.
- **Barriers.** It also takes barrier walls, built on the ground as `Scenario.addBarrier` builds
  them, which the façade load surrogate's lines over the ground cross. The surrogate was fitted on
  buildings only and takes little off for a wall (about 2% of the peak behind one 10 m high), so
  a barrier rarely earns its cost until the refit with barrier runs.

See [protective design](../../protective-design.md#in-bombcad-scenebench-protect).
