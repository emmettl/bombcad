# Importer samples

Small, hand-authored geometry for trying BombCAD’s importer and material editor.
These hand-authored files live in the repository only; they are not bundled with the app. They
use no textures or external material files. The separate [RealCAD collection](RealCAD/README.md)
contains attributed third-party STL/STEP export pairs with pinned provenance and licence notices.

Start with **Open ground**, choose **Import Model…** (or drop one file onto the
viewport), and confirm the settings below. All files use **metres / Z up** except
`millimetres-y-up.obj`. A domain of at least **8 × 8 × 8 m** fits every valid sample
at the default zero corner. Use **Deformable** to try material assignment; select
an empty layout first so there is no existing deformable structure.

| File | What to try / expected result |
| --- | --- |
| [unit-cube.obj](unit-cube.obj) | Start here: a closed 1 × 1 × 1 m cube. Medium (0.25 m) gives 64 occupied cells. Try placement, a material preset, Apply, and reopening its source. |
| [named-parts.obj](named-parts.obj) | Two 1 m blocks named **Concrete block** and **Steel column**, plus a **Thin panel** measuring 0.1 × 1 × 1 m. Select both blocks for bulk material editing; isolate parts, copy/paste materials, and save a profile. The panel disappears at Medium and returns at Fine (0.125 m), with thickness warnings. All three parts import even when isolated in the preview. |
| [disconnected-blocks.stl](disconnected-blocks.stl) | The same two 1 m blocks, as ASCII STL. They become **Component 1** and **Component 2** because STL carries no part names. Try assigning different materials. |
| [narrow-gap.obj](narrow-gap.obj) | Two 1 m blocks separated by 0.05 m. Medium closes the gap in sampled geometry and reports gap warnings. Compare grids: even Fine is too coarse to resolve this gap reliably. Separate source parts retain their material assignments. |
| [hollow-block.obj](hollow-block.obj) | A 3 m cube with a centred 1 m enclosed cavity. Medium gives 1,664 occupied cells, leaving the cavity empty. Toggle Source/Simulation to inspect it. **Cavity boundary** is a shell, not a separate filled material volume. |
| [millimetres-y-up.obj](millimetres-y-up.obj) | Choose **Millimetres** and **Y up**: a 1 × 2 × 3 m column after conversion. Check the metre dimensions and reference grid before applying. Keeping metres produces an oversized model. |

**Compare grids** shows changes without applying them. Review the Source,
Simulation and Warnings layers together: a returned thin part or stable volume
does not establish that its geometry is adequately resolved. The 0.1 m panel and
0.05 m gap are intentionally smaller than two Fine cells. Material names in OBJ
label geometry only; assign physical presets in BombCAD.

## Repair workflow

These broken files should open the defect inspector and remain blocked from the
simulation. Export a repair report, then use **Choose repaired file** with the
matching valid file below.

| Deliberately invalid file | Defect | Repaired counterpart |
| --- | --- | --- |
| [Repair/open-box.obj](Repair/open-box.obj) | A 1 m box missing its top face; four open edges. | [Repair/closed-box.obj](Repair/closed-box.obj), with the top face restored. |
| [Repair/overlapping-blocks.obj](Repair/overlapping-blocks.obj) | Two 1 m boxes overlap by 0.5 m. Separate overlapping solids cannot be imported. | [Repair/merged-block.obj](Repair/merged-block.obj), their Boolean union represented by one closed 1.5 × 1 × 1 m box. |

The repaired counterparts illustrate the result of a CAD repair. BombCAD does
not close holes or Boolean-union overlapping solids automatically. Disconnected
valid samples may also produce placement/support advisories; review those before
running a deformable simulation.
