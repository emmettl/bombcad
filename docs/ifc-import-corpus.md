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

Setting `BOMBCAD_IFC_CORPUS_A GPU run standing the 21 real buildings under gravity for 0.3 s
(`BOMBCAD_IFC_CORPUS_GRAVITY=1`, through `gpu-slot`) was queued behind other work on the Studio
when this was written; its results go here. The three repository fixtures stand (see [structures
from IFC](structural-editing.md#structures-from-ifc)).=1` also stands each structure under gravity. That uses the
GPU, so run it through `gpu-slot`.

## Results

| | First run | After the fixes |
|---|---|---|
| Files imported both ways or one way | 112 of 382 | 168 of 385 |
| Real buildings (buildingSMART, community) imported | 28 of 47, three with one element of hundreds | 31 of 47 |
| Elements converted | — | 8,630 (811 meshes excluded as invalid) |
| Smallest shell element, Esplanades / Clinic | 0.1 mm / 2 mm | 52 mm / 62 mm |

Every real building now imports except the Schependomlaan design model, which is over the 20 MB
input limit. The buildingSMART files that stop are its HVAC, plumbing, rail and landscaping
scenes, which hold no supported elements and say so. Of the IfcOpenShell issue files, most of
those that stop hold only rebar, proxies or distribution elements, or a single element whose
mesh is broken: the bug the file was filed for.

The full table, per file, is `corpus3-table.md` in `/Volumes/StudioData/bombcad/import-structural/`.

### Under gravity

A GPU run standing the 21 real buildings under gravity for 0.3 s
(`BOMBCAD_IFC_CORPUS_GRAVITY=1`, through `gpu-slot`) was queued behind other work on the Studio
when this was written; its results go here. The three repository fixtures stand (see [structures
from IFC](structural-editing.md#structures-from-ifc)).

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
7. **Slivers.** Parallel plates a few millimetres apart left slivers of elements, as small as
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
- **Envelope sampling.** An envelope stops where two elements' triangles intersect ambiguously
  (Esplanades), where a building samples into more than the 2,048 regions it holds, or where
  thin elements sample into no cells at 0.25 m (the precast planks). Each says so.
- **Not imported:** rebar is being read for structures in separate work. Unsupported classes
  stay out: proxies on their own, coverings, MEP and infrastructure elements (IfcCourse,
  IfcTrackElement…).
- **Inclined members.** Most rigid members are rigid because they are not square to the axes:
  2,170 of them, mostly sloped roof members, ramps and braces.
