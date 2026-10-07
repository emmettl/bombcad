# Editing imported structures

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

**Fix nodes on the ground** controls the ground-plane restraint. For a linked import it also
updates the generated restraint at the model's base. After detachment it leaves custom
supports intact.

**Add base support** places a strip at the bottom of the selected part or region. The general
**Add Support** button uses the body bounds when nothing structural is selected. Select a
support to edit its corner and size or remove it. Nodes inside any support are held still;
these controls do not infer connections between disconnected components.

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
swift test --filter 'StructureEditingTests|StructuralEditorWorkflowTests|ImportedPartTests|ImportedProjectTests'
```

These cover refinement of a vanished part, stable ownership, region deletion, material limits,
reinforcement and support preservation, opening placement, undo/redo and project round trips.
Native checks cover part material changes, support and opening creation, undo of their editor
rows, framing and saving. Row bindings tolerate removal during SwiftUI updates so undo does
not access an array index that has disappeared.
