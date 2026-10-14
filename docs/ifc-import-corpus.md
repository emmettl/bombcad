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
timeout becomes a row of its own. The run takes about ten minutes on the Studio and uses the CPU
only. Each file is handled as the app would handle it:
- **Choice:** at most 1,024 elements, the lowest storeys first. Past the 100,000-triangle limit,
  the first storey alone.
- **Invalid meshes:** excluded and the rest converted again, as the import review does.
- **Envelope:** sampled at 0.25 m (0.5 or 1 m for larger sites).
- **Structure:** converted with the default options and meshed, with the smallest element
  recorded.

The 19 real buildings that convert were stood under gravity for 0.3 s, damped (`BOMBCAD_IFC_CORPUS_GRAVITY=1`,
through `gpu-slot`, on the code before the last two fixes below). The table compares that with
the share the import now reports as loose: members tied to nothing that stands on a support.
"Weight carried" is the supports' reaction over the weight. A peak of 54.9 mm is a body falling
freely against the damping for the whole 0.3 s.

| Building | Shells / beams | Loose (by volume) | Weight carried | Peak (mm) |
|---|---|---|---|---|
| buildingSMART house | 648 / 0 | 0% | 100% | 0.0 |
| buildingSMART structural house | 1,044 / 0 | 0% | 100% | 0.5 |
| Schependomlaan precast floor | 4,095 / 0 | 0% | 100% | 0.0 |
| Schependomlaan walls, ground floor | 6,579 / 11 | 0% | 100% | 80.1 |
| Schependomlaan walls, first floor | 6,362 / 10 | 0% | 100% | 66.7 |
| Schependomlaan walls, second floor | 4,469 / 9 | 0% | 100% | 65.4 |
| Schependomlaan hollow-core floor | 11,185 / 227 | 1% | 100% | 79.3 |
| Amersfoort sports hall (first storey) | 21,465 / 746 | 6% | 99% | 78.4 |
| Duplex (architectural) | 19,814 / 220 | 26% | 64% | 75.6 |
| Clinic, architectural | 27,888 / 0 | 2% | 59% | 69.6 |
| Esplanades | 183,736 / 11 | 57% | 42% | 80.8 |
| buildingSMART road | 16,896 / 0 | 81% | 22% | 54.9 |
| Schependomlaan steelwork | 222 / 541 | 84% | 9% | 59.1 |
| buildingSMART bridge | 1,550 / 0 | 95% | 5% | 54.9 |
| Clinic, structural (first storey) | 27,646 / 363 | 3% | 2% | 55.7 |
| Schependomlaan structural model | 86,599 / 675 | 0% | 1% | 71.4 |
| Schependomlaan balconies, stairs, precast elements | 8–394 / 18–48 | 99–100% | 0–88% | 54.9 |

So the small houses, the precast floor and the sand-lime walls stand, but most real buildings
do not, as imported. Where weight is lost, the loose share accounts for much of it in
Esplanades, the Duplex, the steelwork, the road and the bridge. It does not in the Clinic's
architectural model (2% loose, 41% of the weight lost) or in the two structural models below. Subcontractor models without their
building have nothing to stand on (the balconies, stairs and precast elements). The import
report now lists the loose members, and the standing names them. Even where nearly all the
weight is carried, some members sag 65–80 mm: loose pieces, and members bearing on others
through a single line of nodes.

Two structural models lose nearly all their weight while connected: the Clinic's and
Schependomlaan's. This has not been traced. Their supports may hold too little of the base, or
the base connections may fail under the weight. A structure from a real building should be
stood under gravity, and its loose members dealt with, before it is loaded.

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

The task's list also named mapped items, extruded-solid variants, boolean openings and
georeferencing. The corpus showed none of these breaking the importer:
- **Mapped items, extrusions and boolean openings:** the pinned IfcOpenShell converter handles
  them. 33 of the files that import use IfcMappedItem and 72 use boolean results. Where the
  converter fails, as in the "missing subtraction" issue files, the mesh it returns is open, and
  the import review names the element.
- **Georeferencing:** the sports hall's EPSG:28992 map conversion converts in the project's
  local frame and is rebased like any other.

## What is left

- **Open or non-manifold meshes.** These are the largest loss: 802 element meshes across the
  corpus, 303 of Esplanades' 1,024 chosen elements, 183 of the Clinic's and 44 of the Duplex's.
  The ones looked at have edges shared by four faces: the element's representation items
  (layers, sub-solids) touch each other, and a few have open edges. The converter's output does
  not keep the items apart, even unwelded, so separating them would need a decomposition of the
  welded mesh, which is not done. The review names each element, and they can be excluded.
- **The 20 MB input and 100,000-triangle limits.** These keep out the Schependomlaan design
  model whole. Clinic Structural and the Amersfoort sports hall come in a storey at a time. The
  limits are shared with the file loader and the project format, so raising them is a change to
  those as well.
- **Standing under gravity.** Most real buildings do not stand as imported (see the table
  above). Loose members are now reported, but tying them (larger gaps closed, members bearing
  on others over an area, upper storeys on columns that miss their slabs by more than the
  tolerance) is not done. The weight lost by the Clinic's models and Schependomlaan's
  structural model is not explained.
- **Envelope sampling.** An envelope stops where two elements' triangles intersect ambiguously
  (Esplanades), where a building samples into more than the 2,048 regions it holds, or where
  thin elements sample into no cells at 0.25 m (the precast planks). Each says so.
- **Not imported:** rebar is being read for structures in separate work. Unsupported classes
  stay out: proxies on their own, coverings, MEP and infrastructure elements (IfcCourse,
  IfcTrackElement…).
- **Inclined members.** Most rigid members are rigid because they are not square to the axes:
  2,170 of them, mostly sloped roof members, ramps and braces.
