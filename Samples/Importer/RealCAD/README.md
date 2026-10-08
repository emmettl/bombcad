# Real CAD export fixtures

Unmodified CAD exports from the community [FreeCAD parts library](https://github.com/FreeCAD/FreeCAD-library),
pinned to revision `f5ca01cdcaa2f69b9295a6382719c2d90628780c`.
These are authored library parts exported by FreeCAD/Open Cascade, rather than
BombCAD’s hand-written test meshes. All six CAD files are byte-for-byte upstream
copies; only their local filenames differ. The CAD files total about 523 KiB and
stay in the repository, outside the app’s bundled resources.

Each part has an STL export to exercise today’s importer and a STEP counterpart
for future CAD translation tests. **BombCAD currently accepts OBJ/STL only. STEP
files are reference fixtures, not supported imports.** Corresponding STEP/STL
files have not yet been compared through a STEP translator.

## Current importer behaviour

Use **Millimetres**, **Z up**, and a zero corner for the STL files. STL carries no
unit metadata; millimetres follows the corresponding STEP files’ explicit unit
declaration. Source bounds may include negative coordinates; BombCAD normalises
the lower bound to the chosen corner. Start with Open ground and compare grids.

| Fixture | Source size (mm) / triangles | What it exercises | Expected result today |
| --- | --- | --- | --- |
| [concrete-block.stl](concrete-block.stl) / [STEP](concrete-block.step) | 390 × 140 × 190 / 372 | A closed hollow block with two through-openings and rounded interior corners. | Accepted as one part. Medium and Fine each produce two cells at the zero corner, with resolution warnings; their sampled volumes differ by a factor of eight despite equal cell counts. Fine also flags potentially missing surfaces. |
| [casement-window.stl](casement-window.stl) / [STEP](casement-window.step) | 100 × 120 × 5.25 / 108 | A multi-solid window export with intersecting or ambiguously touching surfaces. | Rejected before sampling. The defect inspector locates affected triangles. This is an assembly-handling limitation to investigate, not a repaired or deliberately damaged fixture. |
| [pvc-tee.stl](pvc-tee.stl) / [STEP](pvc-tee.step) | 82 × 37.975 × 67 / 4,004 | Curved thin tube walls, intersecting bores, negative coordinates and a denser exporter-generated mesh. | Geometry validation succeeds as one part, but Medium and Fine produce no occupied cells at physical scale. Inspect the empty preview and missing-surface warnings; applying it is blocked. |

The window dimensions above are those actually encoded by the upstream export;
do not assume it is a full-size building window from its title. Changing units or
scale changes the represented physical dimensions. Any enlarged demonstration
should be labelled as such rather than presented as an accurately sized model.

The automated tests additionally sample the block and tee at **5 mm** through the
core API. That finer spacing is a regression-test setting, **not an available app
grid**. The block’s openings and the tee’s bore remain empty; the tee still has
thin-feature and missing-surface warnings. These checks establish importer
behaviour, not simulation accuracy or convergence.

## Provenance and attribution

[manifest.json](manifest.json) records the exact upstream paths, revision, raw and
source links, SHA-256 checksums, file sizes, dimensions, triangle counts, author
history and current expectations. No files were repaired, retessellated or scaled.

| Part | Attribution and source evidence |
| --- | --- |
| Concrete block 14x39x19 | **Yorik van Havre**, with **WladIMirG** credited in the recorded file history. The original addition is commit `5490996448262af069cd11c962d2b64122b0b457`. |
| Simple 2-panes window | **Yorik van Havre**, with **WladIMirG** credited in the recorded file history. The native `.fcstd` document identifies Yorik van Havre as its last modifier and declares CC-BY 3.0. |
| PVC Tee 32mm | **Javier Castellanos (Mirddyn)**, identified by the native `.FCStd` document’s CreatedBy and LastModifiedBy properties. **BERSERK** is credited for the recorded upstream file organisation. |

The library publishes its assets under [CC-BY-3.0](https://creativecommons.org/licenses/by/3.0/);
the upstream notice and full terms are preserved in
[LICENSE-FreeCAD-assets.txt](LICENSE-FreeCAD-assets.txt). The PVC tee’s native
author metadata additionally declares [CC-BY-4.0](https://creativecommons.org/licenses/by/4.0/);
that specific notice is retained here and in the manifest. These third-party
assets retain their upstream terms rather than adopting BombCAD’s code licence.
Attribution does not imply endorsement by the model authors or FreeCAD.

## Updating fixtures

Fetch only the pinned URLs in the manifest and verify every checksum. An upstream
update should deliberately update the revision, attribution and checksums, then
re-run `swift test --filter 'RealCADFixtureTests|ImporterSampleTests'`. Review
changed import outcomes rather than silently relaxing geometry validation. Keep
new models small and record their own redistribution licence and author credit.
