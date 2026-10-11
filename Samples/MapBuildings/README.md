# Map building fixtures

`synthetic-neighbourhood.geojson` is made up, not taken from OpenStreetMap or any other map: eleven
houses and flats on a 64 m square at (0°, 51.5°), with an open square, a block round a courtyard,
an L-shaped hall and a sliver with no area. Their tags exercise each height fallback: `height` in
metres and feet, `building:levels` with and without `roof:levels`, and none. Use it with
`blastbench terrain --study buildings` or Run ▸ Map buildings in the app (corner 0, 51.5).

Real OpenStreetMap data is © OpenStreetMap contributors under the Open Database Licence; BombCAD
does not bundle any.
