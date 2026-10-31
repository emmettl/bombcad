kind: changed

**A map building tagged wood is timber.** File ▸ New District, a map's buildings added to a scene,
and the headless district benches now read OpenStreetMap's `building:material=wood`,
`timber_framing`, `timber`, `wood_frame` and `log` as a timber construction: walls and roof of
cross-laminated timber 0.105 m thick (three lamellae), the one timber the envelope damage model
has, its thickness assumed. Such a building's walls and roof are judged as timber, and in the fire
after the blast it burns from outside and its roof is not fire-rated. Before, a wood tag said
nothing and the building took the default concrete. Beirut's map carries no material tag at all,
so its estimates do not move; districts with wooden buildings do. The earlier rule stays by name,
to reproduce earlier estimates: New District ▸ "Wood tags not read (earlier estimates)", headless
`--wood-tags ignore`. See
[Building envelopes](../../building-envelopes.md#buildings-from-map-data) and
[Fire spread](../../fire-spread.md#the-app-stage-3-31-october-2026).
