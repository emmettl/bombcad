# IFC import over a corpus of open files

BombCAD's IFC importer was run, headless, over 385 openly available IFC files in IFC 2x3, IFC4
and IFC 4.3. Each file was imported both ways: as rigid obstacles made into an exposure-only
envelope, and as a structure of shells and beams ([structures from
IFC](structural-editing.md#structures-from-ifc)). This page covers what broke and what was
fixed, what still cannot import and why, and how to run the corpus again.

## The corpus

The files live on the Studio at `/Volumes/StudioData/bombcad/data/ifc-corpus/`, not in the
repository. Its `SOURCE.md` gives each set's source, revision and licence.

| Set | Files | Licence | What it is |
|---|---|---|---|
| [buildingSMART Sample-Test-Files](https://github.com/buildingSMART/Sample-Test-Files) | 35 | CC BY 4.0 | Simple-Scene buildings and infrastructure in IFC 2x3, 4 and 4.3; ISO reference-view samples |
| [buildingSMART Community-Sample-Test-Files](https://github.com/buildingsmart-community/Community-Sample-Test-Files), a subset | 88 | CC BY 4.0 | The Medical-Dental Clinic (architectural, structural), the Duplex, Esplanades (Estonia), a georeferenced IFC4 sports hall, the Schependomlaan design model and its subcontractors' structural models, and the IFC4 geometry samples |
| [IfcOpenShell/files](https://github.com/IfcOpenShell/files) | 262 | none stated, so local use only | Files attached to IfcOpenShell's bug reports: crashes, missing boolean subtractions, mapped items, reinforcement |

No corpus file was added to the repository. The tests that cover each fix write their own small
IFC files (`IFCRobustnessTests`).

## Running it

```sh
swift build --build-tests
python3 Scripts/ifc-corpus.py run /Volumes/StudioData/bombcad/data/ifc-corpus OUT --jobs 4
python3 Scripts/ifc-corpus.py summary OUT --markdown OUT/table.md
```

Each file runs in a process of its own through the `IFCCorpusTests` test, so a crash or a
timeout becomes a row of its own. The run takes about half an hour on the Studio and uses the
CPU only. Each file is handled as the app would handle it:
- **Choice:** at most 1,024 elements, the lowest storeys first by their elevations in the IFC.
  Past the triangle limit, the lowest storey alone.
- **Invalid meshes:** excluded and the rest converted again, as the import review does.
- **Envelope:** sampled at 0.25 m (0.5 or 1 m for larger sites).
- **Structure:** converted with the default options and meshed, with the smallest element and
  the loose members recorded.

Setting `BOMBCAD_IFC_CORPUS_GRAVITY=1` also stands each structure under gravity for 0.3 s,
damped. That uses the GPU, so run it through `gpu-slot`.

## Results

| | First run | Round 1 | Round 2 |
|---|---|---|---|
| Files imported | 112 of 382 | 168 of 385 | 188 of 385 |
| Real buildings imported (buildingSMART, community) | 28 of 47, three with one element of hundreds | 31 of 47 | 32 of 47 |
| Elements converted | 6,056 | 8,630 | 15,035 |
| Element meshes excluded as invalid, real buildings | 584 | 653 | 71, besides Clinic Structural's 650 |
| Elements repaired (real buildings) | — | — | 737, into 3,613 closed solids |
| Smallest shell element, Esplanades / Clinic | 0.1 mm / 2 mm | 52 mm / 62 mm | 52 mm / 62 mm |

Round 1 made the importer read what real files hold (parts, uncontained elements, units) and say
plainly what it cannot. Round 2 was about real buildings standing once imported: repairing
broken element meshes, tying members that touch, holding what stands on the ground or on rigid
elements, and taking files up to 100 MB. Every real building now imports, the Schependomlaan
design model (49 MB) included. The buildingSMART files that stop are its HVAC, plumbing, rail
and landscaping scenes and the IFC 4.3 road, which hold no supported elements and say so, and
its electrical scene, whose one element's mesh is open. Clinic Structural's 650
excluded meshes are elements that round 1 never chose: with the higher triangle limit it now
converts more than one storey, and its bar joists and coped steel beams come from the converter
open (see "What is left").

The full table, per file, is `corpus5-table.md` in `/Volumes/StudioData/bombcad/import-structural/`.

### Under gravity

@@GRAVITY_AFTER@@

## What broke, and what was done

1. **Elements built of parts.** Schependomlaan's sand-lime walls aggregate one
   IfcBuildingElementPart per block. Its precast floor slabs aggregate their planks and lattice
   girders as proxies. The walls and slabs themselves have no geometry, so 37 of the 38 walls,
   and all the slabs, came in with nothing. Now a part of a supported element (a part, proxy,
   assembly or covering aggregated into it) is imported:
   - **Envelope:** each part is an element of its own.
   - **Structure:** the parts form one member, square where the parts holding nine tenths of
     its volume are, so round girder bars do not tip a slab.
   - **Report:** the parent is no longer reported missing.
2. **Products in no spatial structure.** 60 files hold walls or slabs that no
   IfcRelContainedInSpatialStructure places in a storey. The converter's metadata leaves those
   out, so the import found nothing. They are now found in the IFC's STEP text (`IFCStep`),
   imported without a storey, and listed in a note.
3. **Units the converter cannot find.** A file whose project is joined by an
   IfcProjectLibrary, among others, left the converter unable to find the units, so the import
   was blocked. Now the length unit of the file's one project, SI with its prefix or a
   conversion-based unit such as feet, is applied to the geometry and the material thicknesses,
   and a note says so. A file without exactly one project and one length unit is still blocked.
4. **One bad GlobalId.** An invalid or repeated GlobalId aborted the whole file. Now it leaves
   out that element and says so.
5. **Plain messages.** These now say what happened instead of dropping elements silently:
   - A file with nothing supported says what it holds ("it holds 73 IfcBuildingElementProxy, 2
     IfcElementAssembly…").
   - A file the converter cannot read gives the converter's own error ("Expected a single
     IfcProject"), and so does a conversion that fails or produces no geometry.
   - The triangle limit says to choose fewer elements, a storey at a time.
   - The import notes list the classes left out as unsupported, with counts.
6. **Too many materials for the solver.** Steel frames with many flanged sections give each
   section a material of its own, 37 for the Schependomlaan steelwork against the solver's 8. The
   nearest of a kind are now merged, using volume-weighted means. The report gives the largest
   change this makes to an element's stiffness.
7. **Loose members.** A member tied to nothing that stands on a support falls under gravity. The
   import now finds these from the mesh itself: nodes shared or tied, held where clamped or
   where a connection has points on them, as the solver holds them. It lists them in the report
   (with their share of the structure) and in the standing. This also showed that unticking a
   tie did nothing. The mesh joins an end that lies within half an element of a midsurface, so
   a member drawn back 10 mm stayed tied. It is now drawn back far enough not to be.
8. **Slivers.** Parallel plates a few millimetres apart left slivers of elements, as small as
   0.1 mm, in every plate that crossed both, and time steps to match. Plates within a fifth of
   an element of each other now share a midsurface (see the [shell
   model](shell-model.md#limitations)), and the structure moves the smaller one onto the larger's
   midsurface, carrying what stands on it.
9. **Broken element meshes.** The largest loss in round 1: 802 element meshes were excluded,
   303 of Esplanades' 1,024 chosen elements among them. Their representation items (layers,
   sub-solids, a frame and its sash) touch, and the converter welds them into one mesh whose
   shared faces leave edges used four times (`IFCMeshRepair`). Such a mesh is now remade:
   - Coincident faces of opposite sense cancel, so two pieces pressed together over the same
     triangles become one solid.
   - The rest are paired across each edge, where more than two meet with the next one round the
     edge on its inner side. Each closed set is a solid, imported as a piece of its element, as
     parts are.
   - A mesh whose tiny edges fell together in the scene's single precision (a steel section's
     fillets, 50 m from the building's corner) is welded at that precision instead.

   737 elements of the real buildings were remade into 3,613 closed solids. 1,414 pieces were left
   out as open, and the import lists them.
10. **Members that touch but are not joined.** Layers stacked face to face (a road's courses, a
    topping on a slab), beams meeting a column off its centreline, and plates against a beam's
    side share no node of the mesh, so they stood apart. Structures from IFC now tie them
    (`StructureModel.tiesTouching`): each node of the lighter member near where they touch to the
    nearest node of the other, rigidly. Nodes already tied, holding others, or held by a support
    are left alone. Only pairs not already joined, directly or through others, are tied. Each tie
    is listed with the connections as inferred, a guess, and the standing names it. Unticking one
    leaves the pair apart.
11. **Foundations the IFC leaves out.** A lift pit's floor 0.4 m below the foundation slabs set
    Schependomlaan's lowest level, so the whole structural model hung from it (1% of its weight
    carried). The Duplex's slabs on grade lie on fill between its foundation walls, 1.1 m above
    their footings, and are of the storey above the walls'. Slabs within 1.5 m of the lowest
    level, with less than half their plan on anything, now rest on the ground at their soffit,
    where they are of the lowest storey or lie within walls standing on the ground. Beams lying on the ground
    (base plates, ground beams) are tied at their underside, since the ground's connection holds
    only nodes at ground level, and theirs are above it. Members standing on an element kept
    rigid (an arch, an inclined roof) are held by it, as it does not move. Each support reaches
    half an element above and below the foot, since the mesh may move a member's end or
    centreline that far onto a line it keeps. Each is listed as assumed.
12. **Size.** IFC files up to 100 MB (up from 20) and buildings up to 400,000 triangles (up from
    100,000) now import. Past 20 MB a note says that converting, sampling and saving are slower,
    and that the project keeps the whole file. Meshes from OBJ and STL keep their limits.
13. **Duplicates.** Layers exported twice (the road's courses) overlap coplanar, and the mesh
    gives the second no elements. It is no longer reported as falling.

The task's list also named mapped items, extruded-solid variants, boolean openings and
georeferencing. The corpus showed none of these breaking the importer:
- **Mapped items, extrusions and boolean openings:** the pinned IfcOpenShell converter handles
  them. 33 of the files that import use IfcMappedItem and 72 use boolean results. Where the
  converter fails, as in the "missing subtraction" issue files, the mesh it returns is open, and
  the import review names the element.
- **Georeferencing:** the sports hall's EPSG:28992 map conversion converts in the project's
  local frame and is rebased like any other.

## What is left

- **Meshes open as the converter returns them.** These are 1,414 pieces of repaired elements,
  and whole elements: Clinic Structural's 461 rod-web bar joists and 188 coped wide-flange beams,
  and the IfcOpenShell issue files filed for exactly this. Their boundaries are open where the
  converter's subtraction or sweep failed. Filling holes that are not flat is not done; the
  review names each element.
- **Subcontractor models alone.** Balconies, stairs and precast pieces without their building
  have nothing to stand on, and are reported loose.
- **Envelope sampling.** An envelope stops where two elements' triangles intersect ambiguously,
  where a building samples into more than its 2,048 regions or 256 openings (the Schependomlaan
  design model has 1,066 windows and doors), or where thin elements sample into no cells at
  0.25 m. Each says so.
- **Not imported:** rebar is read for structures in separate work. Unsupported classes stay
  out: proxies on their own, coverings, MEP and infrastructure elements (IfcCourse,
  IfcTrackElement…).
- **Inclined members.** Most rigid members are rigid because they are not square to the axes:
  about 2,700 of them, mostly sloped roof members, ramps and braces.
