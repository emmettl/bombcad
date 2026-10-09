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

**On a footing** stands the connection on a rigid footing instead of the ground (see [footings](structural-model.md#footings)); the connection's own properties then describe the joint between the body and the footing's top. **Footing and soil** edits the footing's overhang beyond the base along x and y, its thickness and density, and the soil under it: its shear modulus (MPa), Poisson's ratio and density, friction, an optional bearing capacity (kPa), whether it has its mass and radiation damping, and an optional layer depth (m) over rock or over other ground with its own shear modulus, Poisson's ratio and density. The defaults are a medium dense sand. Each support region with a footing gets its own, spanning the region's bearing points; the ground's connection makes one under all the base it ties. The footing is not drawn. Projects with a footing save their scene as encoding version 5, which older versions of the app refuse rather than open with the base standing on the ground. A footing without thickness, a Poisson's ratio of 0.5 or more, or a layer of no depth is refused like any other invalid connection.

For linked imports the generated base support follows the base connection, including an elevated imported base. It no longer silently clamps a finite connection. These source-managed choices survive resampling without detaching the geometry.

**Add base support** places a strip at the bottom of the selected part or region. The general **Add Support** button uses the body bounds when nothing structural is selected. Select a support to edit its corner, size and **Support connection**, or remove it. Each support has its own law; region edits and independent support laws detach imported geometry when it can no longer regenerate safely. Changing ground restraint after detachment leaves these supports alone.

Finite support connections are **horizontal bearings**. They act over tributary area on exposed lower faces of solid elements, or footprint points on the lower edges of vertical shell walls and vertical beam columns inside the region. Use a thin horizontal strip around the intended bearing. The law carries compression, limited tension and Mohr–Coulomb shear, with opening/sliding damage and bearing/friction after separation, as the existing ground connection does. Shell and beam footprint points account for rotation and rocking.

Finite supports do not attach arbitrary interior solid nodes, vertical wall faces or horizontal shell slabs; use an ideal clamp for those locations. They select initial attachment points on stationary horizontal bearing planes. The planes remain unbounded horizontally after sliding or separation; these regions are not footing geometry or connections between two moving components. A connection can stand on soil (a Winkler bed that settles, turns and yields past its bearing capacity; see [base connections](structural-model.md#base-connections)), or on a rigid footing of finite plan over soil with mass, radiation damping and an optional layer ([footings](structural-model.md#footings)); embedment and soil against a footing's sides remain outside this model. The editor reports the active bearing area once inputs finish loading, and warns if no eligible points remain. Clamped or tied slave nodes contribute no independent bearing force; inspect the strip, overlaps and discretised geometry.

Ideal clamps override finite connections wherever they overlap. Among overlapping finite regions the last region wins; a finite region overrides the ground connection at its bearing points. Ground restraint and support regions are independent. All properties, geometry and per-region assignments persist in projects and saved run inputs and participate in Undo/Redo.

`StructureModel.supportAnchorages` is aligned with `supports`. Missing/null entries mean ideal clamps; removing a support removes its law at the same index. Empty arrays are omitted from JSON to preserve historical input fingerprints. Project scene payloads with finite support-region laws use encoding version 2, so older apps reject them instead of silently treating the connections as clamps; version 1 scenes remain readable. Invalid law values and references are rejected on editing, project loading and solver construction. Solver provenance advances to `blast-solver-2` for these connections; existing saved results remain readable.

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
