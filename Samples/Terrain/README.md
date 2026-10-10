# Terrain fixtures

Synthetic elevation grids for the DEM reader's tests (`ElevationGridTests`), not taken from any
survey: a 24 × 18 grid of 5 m cells, a 20 m Gaussian hill on a 1-in-10 slope over 100 m, its
corner at (500000, 4100000) in UTM zone 10N, one cell without data. `synthetic-hill.asc` and
`synthetic-hill.tif` (float32) and `synthetic-hill-int16.tif` (decimetres) were written by
numpy and tifffile; the `-lzw-fp`, `-be-zip-fp` and `-int16-zip-tiled` copies were recompressed
by libtiff's `tiffcp`, which drops the geotags.
