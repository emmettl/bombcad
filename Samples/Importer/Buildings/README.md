# Building IFC fixtures

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
**Import Model…** with the IFC file. The first screen lists its source elements.
Use building, storey, type and text filters, then **Include matching** or
**Exclude matching**. Filters only change the list; checkboxes determine inclusion.
Choose **Preview chosen elements** to convert the chosen GUIDs. The build bundles the pinned native converter;
no Python installation or runtime download is needed by app users.

With all supported elements chosen, expect **seven physical elements**: four walls and three floor/roof slabs. The
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
GlobalIds, names, storeys, source coordinate origin, exact inclusion choices, full decomposition inventory and warnings remain available.
**Choose IFC elements…** revisits the retained source. Placement and grid choices
stay staged; each new subset is rebased to its own bounds, so review placement again.
The **IFC completeness** section and exported report distinguish deliberate
exclusions, unsupported types, selected elements without converted geometry,
converted elements with no sampled cells, and cells covered by other elements.
Containers without geometry remain reviewable omissions. Inventory follows the
decomposition tree; uncontained products may be absent.
Resampling the retained meshes does not require the original file or converter.

## Broader building cases

The additional unchanged models have pinned source links, checksums, authors and
licence notices in [manifest.json](manifest.json). They remain repository-only.

- [duplex-apartment.ifc](duplex-apartment.ifc): **BSI (2020) "Duplex Apartment
  Test Files," buildingSMART International**, from the
  [community dataset](https://github.com/buildingsmart-community/Community-Sample-Test-Files/tree/7ddf57a201f88a0c213d5322b02ed15e94a60a40/IFC%202.3.0.1%20%28IFC%202x3%29/Duplex%20Apartment).
  The original [attribution notice](NOTICE-Duplex.md) and
  [licence notice](LICENSE-community.txt) retain CC-BY-4.0 terms. This is a real
  two-storey architectural export with doors, windows and furnishings. Its
  decomposition has **289 source entries, 144 supported entries**, and four
  storey scopes: Level 1, Level 2, T/FDN and Roof. For a reliable starting subset,
  **Clear all**, choose Level 1, then include IfcWallStandardCase and IfcSlab
  using the Type filter. Expect **31 elements / 732 triangles** and dimensions
  about **8.8 × 26.57 × 6.14 m**. Some Level 1 elements span more than one floor;
  storey selection follows source containment, not a geometric height cut.
  Door `1hOSvn6df7F8_7GcBWlRGQ` and window `1hOSvn6df7F8_7GcBWlR72`
  produce open/non-manifold converter meshes and remain blocked. Their names
  and GUIDs identify the failure; explicitly exclude a failed element and retry,
  or re-export closed solids. Choosing every supported entry does not guarantee
  a complete valid import.
- [building-structural.ifc](building-structural.ifc): buildingSMART International
  Ltd., the structural version of the house. It has **12 supported entries**,
  including the roof container, and **11 converted solids / 456 triangles**:
  six beams, four walls and one footing. Beam shoes and the chimney are
  unsupported and stay visible as exclusions.
- [column-straight-rectangle.ifc](column-straight-rectangle.ifc): buildingSMART
  International Ltd.; **Tim Chipman / Constructivity** as recorded in the
  header. One tessellated column, 12 triangles. The original imperial units
  convert to **0.2032 × 0.2032 × 3.048 m**.
- [wall-with-opening-and-window.ifc](wall-with-opening-and-window.ifc):
  buildingSMART International Ltd.; **Peter Bonsma / RDF Ltd.** in the source
  owner history. This is a **negative unit-detection fixture**. The source
  declares millimetres, but the pinned converter cannot resolve its project /
  context and reports that unit information is unavailable. BombCAD blocks it
  before preview instead of accepting a 3,000 m wall. Repair/re-export the IFC
  project and unit definitions before importing it.

The latter three files use [LICENSE-buildingSMART.txt](LICENSE-buildingSMART.txt)
(CC-BY-4.0). No fixture is silently repaired or rescaled. The grid sampler reports
complete element losses separately from partial surface and gap diagnostics;
those feature checks remain approximate and require finer-grid comparisons.

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
