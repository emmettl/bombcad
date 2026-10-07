# Whole-building IFC fixture

A small architectural house from the [buildingSMART Certification datasets](https://github.com/buildingSMART/Certification-datasets),
pinned at `80d976a9b193a26a8e928c3e79bff67af1de68a8`.
[manifest.json](manifest.json) records the upstream path, source link, checksums,
file sizes, attribution, licence and exact mesh-export settings. These files are
repository-only and are not bundled with the app.

- [building-architecture.ifc](building-architecture.ifc) is the **unchanged** IFC4
  file. Attribution: **buildingSMART International Ltd.**, Simple-Scene
  Building-Architecture. Its header records Sketchup-IFC-manager 5.6.0 /
  SketchUp 2026 as the exporter.
- [building-architecture.obj](building-architecture.obj) and its
  [material file](building-architecture.mtl) are derived references exported by
  the pinned IfcConvert 0.8.5 helper. The OBJ uses IFC GlobalIds as group names.
  Material colours are visual metadata, not physical material properties.
- [LICENSE-buildingSMART.txt](LICENSE-buildingSMART.txt) preserves the upstream
  [CC-BY-4.0](https://creativecommons.org/licenses/by/4.0/) notice, which also
  applies to these derived reference exports. The fixture retains these terms
  rather than adopting BombCAD’s code licence. Attribution implies no endorsement.

## Try the building

Build the app with `Scripts/build-app.sh debug`, choose **Open ground**, then use
**Import Model…** with the IFC file. The build bundles the pinned native converter;
no Python installation or runtime download is needed by app users.

Expect **seven physical elements**: four walls and three floor/roof slabs. The
parent roof container has no separate geometry; its two child slabs are present.
Spaces, furnishings, site markers/proxies and other unsupported types are
excluded explicitly. Source units and placements are converted to **metres,
Z up**, with a source footprint about **6.2 × 6.6 × 5.95 m**. The Parts browser
retains readable names, types, storey labels when supplied, and exact GlobalIds.

At a zero corner, Medium produces **2,181 occupied cells and 38 regions**. Review
thin-feature, gap and missing-surface warnings, then Compare grids. The entrance
recess in the floor and the interior room air remain empty; supports and materials
are not inferred. IFC imports currently create rigid obstacles only. Ordinary
placement warnings depend on the surrounding scene and charge position.

Save as `.bombcad` and reopen: original IFC bytes, converted element sources,
GlobalIds, names, storeys, source coordinate origin and warnings remain available.
Resampling the retained meshes does not require the original file or converter.

## Why the matching OBJ is a reference

The upstream converter emits segmented boundary junctions in the floor mesh,
and separate building elements can touch or overlap. The strict whole-mesh
OBJ/STL importer can reject this raw combined OBJ. The IFC pipeline instead
splits existing edge junctions into conforming triangles, validates each element
as a closed solid, and unions their sampled occupied cells. It never creates
missing faces or fills source openings. Coordinates are canonicalised at
0.1 micrometre after rebasing from the original world coordinates.

The converter also reports unsupported material metadata for this model; these
are surfaced as an import note. Structural properties are not mapped in this
rigid-geometry milestone. Per-element diagnostics can miss gaps between elements,
so inspect Source against Simulation and compare grids before applying.

## Reproduce the reference mesh

Run `python3 Scripts/prepare-ifc-converter.py` from the repository root, then:

```sh
.build/ifc-converter/IfcConvert \
  Samples/Importer/Buildings/building-architecture.ifc \
  Samples/Importer/Buildings/building-architecture.obj \
  -y --use-element-guids --weld-vertices --include entities \
  IfcWall IfcSlab IfcRoof IfcColumn IfcBeam IfcMember IfcPlate IfcFooting \
  IfcStair IfcStairFlight IfcRailing IfcDoor IfcWindow
```

Review checksum changes and run
`swift test --filter 'IFCImportTests|ImportedBuildingTests'` before updating a
fixture or the converter. Integration tests require the prepared helper; the
independent-element core tests run without it. `make test` prepares it first.
