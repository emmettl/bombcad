kind: fixed

**A corrupt GeoTIFF or IFC is refused with a message instead of ending BombCAD.** A BigTIFF
value past 2⁶³ in a strip's offset or count, no samples per pixel, or sizes whose product overflows ended
the app; a width of 2³² − 1 ran it out of memory, and thousands of samples a pixel held it for
minutes. A strip or tile cut short, which read its missing rows as elevations of 0, and an
infinite sample, cell size or tie point, which placed the terrain at infinity, are refused too.
An IFC whose geometry lies impossibly far off (past ten million kilometres) is refused, naming
the line, where it ended the app too. Valid files read as before. Found by fuzzing the GeoTIFF
reader and the IFC importer on a Mac
([Linux](../../linux.md#fuzzing-on-a-mac-and-threadsanitizer-on-the-slow-suites-28-october-2026));
each case is a test in ElevationFileRobustnessTests or IFCGeometryRobustnessTests.
