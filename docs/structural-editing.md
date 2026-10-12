# Editing imported structures

Local fixed blocks and the deformable object have persistent scene identities. Structural
solids, openings and supports have component IDs scoped to their owning object. Selection
and editor bindings resolve those identities on each access, so a deleted row cannot edit
the next region that moves into its old array position. Fixed-block context menus offer
**Duplicate Block**; the copy gets a new identity, and undo restores the exact prior objects.
Names stay with blocks after deletion or reorder rather than being renumbered by position.
See the [ownership foundation](multiple-object-scene.md#implemented-ownership-foundation).

**Add Independent Structure** creates a separate deformable body, initially a wall placed
beyond the current structures along x. **Editing structure** selects the object whose
members, materials, element formulation, openings and supports are being edited. Deformable
imports also create separate owners. Removing an attached imported body uses its source
controls; local and detached bodies can be removed through **Remove Selected Structure**.
Each object retains its own preferred solid element size when switching formulations.

All bodies share the air domain. Their initial envelopes must be separated; inter-object
contact and connections between moving bodies are not supported. A conservative envelope
or resolved-cell overlap stops the run. See [shared air mechanics](multiple-object-scene.md#implemented-shared-air-mechanics).

Deformable imports can be edited by their named source parts in **Edit layout → Deformable
structure**. Selecting a part highlights the bounds of its surviving sampled regions.
**Frame selected part** brings it into view. The selected part's regions appear below its
controls; **Show all sampled regions** reveals the rest of the body.

## Materials and refinement

The part material picker and advanced properties apply to the whole selected part. Use
**Use structure’s default material** to remove the override. While linked, these choices are
stored against source part IDs and regenerate on a new grid. Even a part with no occupied
cells can retain its material choice and recover it if a finer grid resolves the part.

The body can contain at most eight distinct active materials, including its default. A change
that exceeds the limit fails without changing the body, its source assignments or attachment.
After detachment, part material edits affect surviving owned regions; the retained source
record remains an inspection reference. Mixed region materials are reported before a choice
replaces them across the whole part.

## Local edits and detachment

Changing sampled geometry, a region's material, reinforcement, element formulation, openings
or custom support regions can make the structure independent of its source. The editor
detaches it automatically when the resulting body cannot safely regenerate. The edit and
detachment form one undo step. No-op edits keep the link. Changing the default material or
the source-managed base restraint can keep the link when the body is otherwise unedited.

Reinforcement choices apply to all sampled regions of the selected part. Mats and columns
follow those regions' shapes, not the original mesh surfaces; inspect the sampled regions
before using them. Existing explicit reinforcement layers are preserved when other edits
rebuild the generated reinforcement. Detached geometry, openings, supports, reinforcement
and material choices survive save/reopen and changes to the air grid.

**Cut opening** places an opening at the selected part or region, extending through its
smallest bounding dimension. Select the opening to adjust its corner and size. With nothing
structural selected, **Add Opening** targets the first structural region. Openings subtract
from the whole body, so an opening can affect another region if its bounds overlap it.

## Restraints

**Restrain the base on the ground** controls the ground-plane restraint. For a linked import it also updates the generated restraint at the model’s base. After detachment it leaves custom support regions intact.

**Base connection**, shown while base restraint is enabled, chooses Clamped, Starter bars, Construction joint, Resting on the ground, On soil or On a footing over soil. **Connection properties** edits tensile strength, plateau and final opening, shear cohesion, cohesion-loss slip, friction, an optional bearing capacity (past which the ground yields and the base settles for good) and optional normal/shear stiffness. Values use MPa, mm and GPa/m. Automatic stiffness uses the structure’s default material and element size. An edited law is shown as **Custom connection**, rather than relabelled as a preset. The presets describe assumptions, not a measured connection for a particular structure.

**On a footing** stands the connection on a rigid footing instead of the ground (see [footings](structural-model.md#footings)); the connection's own properties then describe the joint between the body and the footing's top. **Footing and soil** edits the footing's overhang beyond the base along x and y, its thickness and density, and the soil under it: its shear modulus (MPa), Poisson's ratio and density, friction, an optional bearing capacity (kPa), whether it has its mass and radiation damping, and an optional layer depth (m) over rock or over other ground with its own shear modulus, Poisson's ratio and density. The defaults are a medium dense sand. **Set into the soil** puts the footing's base a given depth below the surface, with the soil's friction angle (35° by default): its sides then bear against the soil up to the passive pressure and grip it by friction, its base bears the overburden's share as well, and it is as stiff as Gazetas's embedded footing; an embedded footing saves the scene as encoding version 7. Each support region with a footing gets its own, spanning the region's bearing points; the ground's connection makes one under all the base it ties. The footing is not drawn. Projects with a footing save their scene as encoding version 5, which older versions of the app refuse rather than open with the base standing on the ground. A footing without thickness, a Poisson's ratio of 0.5 or more, or a layer of no depth is refused like any other invalid connection.

For linked imports the generated base support follows the base connection, including an elevated imported base. It no longer silently clamps a finite connection. These source-managed choices survive resampling without detaching the geometry.

**Add base support** places a strip at the bottom of the selected part or region. The general **Add Support** button uses the body bounds when nothing structural is selected. Select a support to edit its corner, size and **Support connection**, or remove it. Each support has its own law; region edits and independent support laws detach imported geometry when it can no longer regenerate safely. Changing ground restraint after detachment leaves these supports alone.

Finite support connections are **horizontal bearings** unless **Joint faces**, shown for a support's connection, turns them over the body or against one of its faces across x or y, or sets them **At an angle**: the support's angle from straight below the body (90° beside it, 180° over it) and its bearing in plan from +x (see [joints facing other ways](structural-model.md#base-connections)). A joint at an angle ties the staircase of faces that stands for it, each over its area projected on the joint, and saves the scene as encoding version 7. **Ties two parts across a gap** makes the support's joint tie the body to another of its parts, both moving, instead of to fixed ground (a beam seated on a corbel, a panel against its frame; see [joints between parts](structural-model.md#base-connections)); leave a gap of at least one element between the parts and span it with the region. It is for solid elements, cannot stand on a footing, and also saves as version 7. They act over tributary area on exposed faces of solid elements facing that way, or on points of shell and beam faces facing that way inside the region: through the thickness at free edges of walls and slabs, at the corners of a wall's or slab's face (a slab's soffit on a bearing), over a beam's free end or across its sides (a beam seated on a corbel). A turned joint saves the scene as encoding version 5, as a footing does. Use a thin horizontal strip around the intended bearing. The law carries compression, limited tension and Mohr–Coulomb shear, with opening/sliding damage and bearing/friction after separation, as the existing ground connection does. Shell and beam footprint points account for rotation and rocking.

Finite supports do not attach interior solid nodes or interior edges of shells; use an ideal clamp for those locations. They select initial attachment points on stationary bearing planes. The planes remain unbounded horizontally after sliding or separation; these regions are not footing geometry or connections between two moving components. A connection can stand on soil (a Winkler bed that settles, turns and yields past its bearing capacity; see [base connections](structural-model.md#base-connections)), or on a rigid footing of finite plan over soil with mass, radiation damping and an optional layer ([footings](structural-model.md#footings)), set into the soil if asked. The editor reports the active bearing area once inputs finish loading, and warns if no eligible points remain. Clamped or tied slave nodes contribute no independent bearing force; inspect the strip, overlaps and discretised geometry.

Ideal clamps override finite connections wherever they overlap. Among overlapping finite regions the last region wins; a finite region overrides the ground connection at its bearing points. Ground restraint and support regions are independent. All properties, geometry and per-region assignments persist in projects and saved run inputs and participate in Undo/Redo.

`StructureModel.supportAnchorages` is aligned with `supports`. Missing/null entries mean ideal clamps; removing a support removes its law at the same index. Empty arrays are omitted from JSON to preserve historical input fingerprints. Project scene payloads with finite support-region laws use encoding version 2, so older apps reject them instead of silently treating the connections as clamps; version 1 scenes remain readable. Invalid law values and references are rejected on editing, project loading and solver construction. Solver provenance advances to `blast-solver-2` for these connections; existing saved results remain readable.

## Structures from IFC

An IFC building imported with **Deformable shells and beams** becomes a structure of shells
and beams (`IFCStructure`), not one of sampled solid regions. The import sheet's **Structure
from IFC** section reports what the conversion did before anything is applied, and the same
report stays under **Edit layout → Structure from IFC**.

- **Elements.** Walls, slabs and roofs square to the axes become shells: as thick as their
  structural layer where the IFC gives a material layer set (the block of a brick-on-block
  wall), else as their geometry. Columns, beams and members become beams of their section's
  depth and width; a flanged section (under half its bounds filled) is a rectangle 0.6 of its
  depth wide whose material is scaled to the bending stiffness, strength and mass of a
  wide-flange shape of its area and depth. Footings become footings under the members on
  them, set into the soil by their depth. Holes through a shell, openings, doors and unglazed
  windows become openings; a window whose materials or name say glass becomes a 6 mm pane of
  annealed glass on its wall's midsurface. Inclined, curved and irregular elements, finishes
  (stud partitions, flooring, tiles) and slabs on grade that walls pass through stay rigid
  obstacles, each with its reason.
- **Materials.** Read from the IFC's material names where they name one the solver has
  (concrete, with its grade if given, block, masonry, steel, glass). Elsewhere the stated
  default, flagged in the report, the standing and the parts list; choose a part's material
  under Parts to replace it.
- **Reinforcement.** Read from the IFC where it gives it, member by member
  (`IFCReinforcement`). Reinforcing bars, meshes and tendons are converted alone and each is
  measured from its shape (a swept tube's diameter is 4V/S, its length S/πd, whatever its
  path), its size taken from the IFC (its own or its type's, read in the project's unit,
  millimetres or centimetres, whichever fits the shape) where it gives one. A bar goes to the
  element the IFC nests it in, else to the concrete element holding its middle or most of it.
  In a shell, its bars become a mat in each face, their steel per metre each way at their
  weighted depth (links through the thickness are left out). Along a beam, they become at
  most eight bars, merged at its corners and the middles of its sides, and the rest are ties.
  An element with only `Pset_ConcreteElementGeneral` takes its area or mass ratio at its
  cover, or at 30 mm, stated; covers no bar could have are left out. Elsewhere concrete
  shells take the offered 0.3% in each face both ways, or none, and beams none; each member
  says which, flagged where it is not the IFC's. Prestress in tendons is ignored.
- **Connections.** Members that meet are tied rigidly (their shells share nodes) after gaps
  up to the chosen tolerance (100 mm by default) are closed, measured to a wall's whole
  thickness where only its structural layer is meshed. Every tie is listed; untick one in the
  import sheet to leave that pair untied, the second member drawn back 10 mm.
- **Supports.** Members on a footing stand on their own footing over the default sand, tied
  by the chosen base connection (starter bars by default; a construction joint or resting on
  the ground). Without footings the base is tied to the ground by it. Members standing on a
  slab on grade, and walls and columns of the lowest storey with nothing under them in the IFC
  (their foundation left out), are tied to the ground at their foot the same way; slabs on the
  ground rest on it. Each is listed. Change them under **Restraints** once imported; that
  detaches the structure from its source.

**Checks.** The small house, the structural house and the duplex's first storey import,
mesh and stand under gravity: the duplex (6,201 shells and 120 beams) sags 1.2 mm at its
longest steel beam after 1 s, its supports carrying its weight to 0.1% (the houses in
`IFCStructureImportTests` and boxes in `IFCStructureTests`; the duplex in a one-off run). Under 10 kg of TNT 6 m from the small house,
its walls as imported (sand-lime masonry from the IFC, 200 mm) peak within 0.3% of the same
walls built by hand in the editor, and under 50 kg, where the struck wall breaks, within 0.7%
with 63 against 64 elements removed; the hand-built walls were typed to the centimetre (their
tops 4 mm higher) with the materials the report gives. Over 0.1 s on 0.25 m cells the house as
shells takes 6.9 s against 3.0 s as rigid obstacles, 2.3 times as long
(`IFCStructureStudyTests`, with `BOMBCAD_IFC_STUDY` set to a folder for its report).

Changing the options, the element subset or a part's material in the import sheet converts
the building again; saved projects keep the options and report (scene encoding version 9).
The shell model's bands apply only where the structure is like what was compared: reinforced
concrete walls and slabs, read from the IFC, all tied and on a modelled base. Otherwise the
standing names what differs (assumed materials, beams from IFC sections, other materials,
concrete unreinforced or on the default's steel rather than the IFC's, untied pairs, walls
tied where the IFC has no foundation) and gives no band.

**How often IFC files carry reinforcement.** Over the 385 IFC files of the import corpus
(buildingSMART's samples and community files, and IfcOpenShell's issue files;
`Scripts/ifc-reinforcement-survey.py`), 62 have concrete. Of them, 3 give anything about
reinforcement that could be read, and 23 name their concrete reinforced ("gewapend", "RC")
with nothing to say how. Reinforcing bars appear in 49 files, nearly all IfcOpenShell's
one-bar bug reports and buildingSMART's two specification examples. The only real building
with bars, a Tekla export of precast balconies, has six, all in a thermal-break connector
(not concrete), and the specification's bar cage sweeps its disks along arcs the converter
does not make. Of 148 reinforcing elements the converter makes 113, and 4 land in a concrete
element. The one file with reinforcement properties gives a 50 m cover, which is left out.
In practice, then, reinforcement comes from the default unless a structural model is
exported with its bars (`IFCReinforcementCorpusTests`, with `BOMBCAD_IFC_CORPUS` set, reads
a corpus and reports per file).

## Persisted ownership

`StructureModel.solidSourceParts` is an optional-length array aligned with `solids`. Each
non-null entry contains the imported instance's `modelID` and its source-scoped integer
`partID`. New local regions have null ownership. Import installation and resampling rebuild
the array from preview ownership; removal deletes the corresponding entry with the region.
This keeps named-part editing available after detachment and region deletion. Removing the
retained source clears its ownership references without deleting the independent structure.
The project reader rejects references to missing models or source parts.

## Verification

```sh
swift test --filter 'AnchorageTests|FootingTests|SupportConnectionTests|StructureEditingTests|StructuralEditorWorkflowTests|ImportedPartTests|ImportedProjectTests'
```

These cover refinement of a vanished part, stable ownership, region deletion, material limits,
reinforcement and support preservation, opening placement, undo/redo and project round trips.
Native checks cover part material changes, support and opening creation, undo of their editor
rows, framing and saving. Row bindings tolerate removal during SwiftUI updates so undo does
not access an array index that has disappeared.

Connection checks cover raised solid, shell and beam reactions, independent laws, lift-off, clamp precedence, removal ownership, invalid values, linked-import refinement, transactional edits and project/undo round trips, and for footings the scene's encoding version, save/reopen, undo/redo and refusal of invalid footings and soils (`StructureEditingTests`). The earlier ground-connection statics and tipping checks remain unchanged.
