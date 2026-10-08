# Multi-object scaling

Coarse coupling between multiple structures and the air can use local pages of four
by four by four air cells. A world-tile map translates positions into compact
occupancy, wall-velocity, debris-area and momentum/energy-exchange arrays. Every
body contributes to the same address for a given world cell, preserving composition
and applying its debris reaction once.

This is an allocation change within BlastCore. The air grid and refinement pool
remain separate allocations; inter-body contact remains unsupported.

## Allocation and motion

`SolverConfiguration.bodyCouplingLayout` accepts `automatic`, `dense` and `tiled`.
Automatic uses the smaller allocation; a single body retains its dense path. The
choice is read when structures are compiled. These are backend controls, not new
authored scene properties.

The default tile capacity is twice a conservative initial padded footprint, limited
to the number of tiles in the domain. `bodyCouplingTileCapacity` can specify a positive
capacity for programmatic runs. Zero selects the default. Memory reporting includes
the map, pool and reverse tile table.

GPU allocation uses current and swept node envelopes, including loose nodes and
section/debris radii, with four metres of horizontal and three metres of vertical
padding. Allocation runs before air stepping and when publishing a changed boundary.
Pages remain for the lifetime of the compiled body set so vacated cells can reopen
and restart can remove displaced outlines. It is a bounded pool with conservative
body envelopes, rather than a precise per-particle spatial index.

Exhaustion or motion outside allocated coverage during a fluid interval sets an
explicit storage-failure flag. Further batches stop, the editor reports the failure,
and completed-run capture is disabled. This is distinct from the existing inter-body
contact screen. Frozen-air mechanics do not allocate further boundary pages.

New multi-body runs use `blast-solver-4`. Previous `blast-solver-3` records remain
readable with their original provenance; single-body runs retain `blast-solver-2`.
Project encoding stays at version 4 and multi-body result encoding at version 2.

## Benchmark

```sh
swift build -c release --product scenebench
.build/release/scenebench scaling.json --source-revision=$(git rev-parse HEAD)
python3 Scripts/check-scene-benchmark.py scaling.json
```

The complete matrix contains 2, 4, 8 and 16 clamped bodies at 12 m and 28 m spacing,
coarse air and refinement ratio 2, and all three layouts. Bodies include solid, shell
and mixed representations and 0.25 m/0.5 m meshes. Each fixture uses the same object
identities and inputs across layouts. Each case warms up twice, then records the
median of five GPU measurements, each containing eight boundary updates. An
eight-step simulation batch is measured separately. Coarse pressure is compared
against the first layout (dense by default); the checker requires relative error
below `1e-5`. Refinement counts and swept fractions are retained.

`--quick` selects one spacing and coarse air. `--layouts=dense,tiled,automatic` selects
layouts explicitly. Reports retain the device, OS, source revision and timing method.
Raw reports belong under `Benchmarks/MultiObjectScaling`.

Boundary timing and whole-batch timing answer different questions. Air sweeps,
mechanical substeps and fine-level work can dominate. Compact storage does not
guarantee a faster run for every refinement setting. Forced tiled storage can also
be larger in compact arrangements. Automatic selection is based on allocated bytes.

## Verification

Dense/tiled checks compare full coarse primitive states, gauge histories, body node
buffers, aggregate mass/energy and object summaries. Cases cover solid, shell and
mixed bodies, refined air, wide spacing, sleeping air tiles, reorder, page-crossing
movement and restart. Loose debris crosses tile boundaries with identical dense/tiled
reactions; its momentum gain is checked against the air's loss relative to a passive
reference. An exhausted pool stops without claiming body contact, and the application
cannot keep it as a completed run. Historical multi-body provenance survives save/reopen.

These checks verify allocation and exchange. They do not reproduce a measured
multi-building experiment or validate the invented buildings below.

## Neighborhood example

`NeighborhoodExample.make()` creates sixteen independent reinforced-concrete shell
buildings with roof slabs, ground restraint and door openings, surrounded by open
streets. Its domain is 144 by 144 by 12 metres and the conventional charge is 2 kg
TNT equivalent. The structural details are illustrative and uncalibrated.

```sh
.build/release/scenebench --example Samples/Neighborhood/layout.json
.build/release/scenebench --preview docs/neighborhood.png
```

Open the supplied layout in BombCAD. Begin with coarse air and a short run when
inspecting resources; finer or longer studies need their own resolution checks.
