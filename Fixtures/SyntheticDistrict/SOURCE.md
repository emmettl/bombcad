# A synthetic district

Made up for BombCAD's tests of File ▸ New District (`DistrictLayoutTests`, `NewDistrictTests`):
not a real place and not map data. `python3 make_district.py .` writes the three files.

- `district.osm`: 49 footprints, 24 × 16 m, on a grid 100 m apart about a point near 0° N, 0° E,
  tagged with heights, levels or neither, a few of brick; a warehouse; an office block with a
  courtyard (a multipolygon); and a building part, which is left out.
- `ground.asc`: an ESRI ASCII grid of elevations, 0.0003° cells: a slope to the north-east, a hill,
  and sea (below 1 m) along the south-west edge.
- `heights.asc`: building heights, 0.001° cells, 6 to 21 m rising to the north, for the untagged.
