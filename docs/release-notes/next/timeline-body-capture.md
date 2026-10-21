kind: changed

**Recording structure-heavy runs spends less time on the main thread.** Timeline recording copies only the structure motion and damage needed for replay, extracted on the GPU alongside the air field. Short office-tower comparisons took 0.83 ms per frame against 25.44 ms in debug, and 1.19 ms against 2.42 ms in release, for the original body-copy path ([measurement](../../using-the-app.md#replaying-a-run)).
