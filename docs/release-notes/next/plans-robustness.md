kind: fixed

**Floor plans as offices draw them.** The plan importer now places doors drawn with their leaf and
swing (it dropped them before), closes walls whose faces stop together or a few millimetres short,
finds a turned plan's angle exactly (a tenth of a degree off left walls read as centrelines),
passes over furniture blocks on wall layers and short wall ends at an angle, and refuses a DXF cut
off part way rather than reading half of it. A corpus of 25 small DXF and SVG plans, each trying
one such thing with its expected answer, checks it (Fixtures/FloorPlans, `scenebench plan-check`);
hatching alone is not read, a recorded limitation.
