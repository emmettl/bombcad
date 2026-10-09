# Native interface review

Manual checks supplement the opt-in static captures described in the
[roadmap](roadmap.md#usability-in-parallel). They establish what was seen in a native window;
they do not validate numerical results or replace automated tests.

## Review environment

Reviewed on 9 October 2026 in the native macOS app, in the system's existing dark appearance.
The optimized release build contained the changes from commit
`7b169ff3ea5e431440accda468b75720097019ee` (layout JSON diagnostics). A copy of the app used a
separate bundle identifier and temporary fixtures, preserving the installed app and its
preferences. No simulation was run during these checks.

## Documents and Help

- A layout JSON file with no objects, a zero-mass charge and a 4 × 4 × 4 m domain opened as
  a separate document named Native UI QA.
- Saving through the native panel produced a `.bombcad` package. Closing and reopening it
  retained the layout, settings and view at time zero.
- Removing the required `reflectiveFaces` field from a copy produced an alert naming the
  missing field. Automated diagnostics tests cover the other decoding errors.
- Help topic selection and sidebar labels were readable in the native dark window. The
  earlier contrast problem in an offscreen Help capture did not reproduce there.

## Completed OBJ preview

Use the unchanged [named-parts.obj](../Samples/Importer/named-parts.obj) fixture with the
empty 4 m project above. Its three closed shells are Concrete block, Steel column and Thin
panel; the source extent is 4.1 × 1 × 1 m.

1. Open **Import Model…** and choose the OBJ. With the default corner at (1, 1, 0) m, the
   model does not fit. The sheet displays a placement error and disables Import.
2. Choose **Expand domain to fit**. The draft domain becomes 6.1 × 4 × 4 m, and the sheet
   states that expansion is staged until Import. The completed preview replaces the error
   state, with readable source and sampled geometry in the viewport.
3. Toggle **Simulation** off to inspect the source, then enable it and toggle **Source**
   off. The display changes with the controls. Diagnostic overlays remain independently
   visible while Warnings is enabled.
4. Enter `Thin` in **Find a part** and choose **Select matching**. The list shows Thin panel
   selected, the viewport highlights it, and its diagnostic text remains readable. Scroll
   the left controls to expose the lower part settings and reusable-profile disclosure.
5. Choose **Cancel**. The original document returns, still at time zero with the original
   16 × 16 × 16 grid and zero charge. The saved package retains its 4 m domain and empty
   object list; no imported geometry or staged expansion was applied.

These checks passed without a code change. Geometry warnings were visible and Import remained
disabled until warning review; the check ended by cancelling, without accepting the import.

## Keyboard and coordinate labels

A follow-up native review used the same temporary project and dark appearance. In the import
file picker, typing the OBJ's initial letter selected it and Return opened the sheet. Tab
moved from Corner X to Y, Z and Find a part. Typing `Thin panel` entered the space normally;
Escape cancelled the sheet and returned to the unchanged document at time zero.

The document and editor remained readable after **Window → Move & Resize → Top Left** placed
the window in a quarter of the screen. The lower editor controls were reachable by scrolling.
This did not establish the absolute minimum window size. A temporary gauge label accepted a
space, and document undo restored the label and then removed the gauge.

That review exposed unnamed gauge coordinate fields in the native accessibility tree. The
editor now supplies axis and unit names while keeping the visible grid labels. A separate
optimized release build of this change was checked in a native window: its three gauge
fields expose `Position X (m)`, `Position Y (m)` and `Position Z (m)`. Its six block fields
expose `Corner X/Y/Z (m)` and `Size X/Y/Z (m)`, with each axis named separately. The visible
grids retain their compact layout. The temporary gauge and block were undone and the original
empty project saved again; the package retained its original domain and zero charge.

These checks use the existing macOS keyboard-navigation setting. They do not establish access
to every control by keyboard or test VoiceOver's spoken navigation.

## Constrained offscreen captures

The opt-in helper also captures `editor-minimum.png` at a fixed 1000 × 640 points, matching
`ProjectEditor`'s declared minimum content size, and `layout-editing-short.png` at 310 × 580
points. These four light/dark images use an empty zero-charge project and have been visually
reviewed. The main sidebar, status, chart labels, legend and chart actions fit the minimum
content viewport. The short editing form shows its upper controls and clips the lower content
at the scroll viewport, rather than enlarging the capture to include it.

Reproduce them with:

```sh
BOMBCAD_INTERFACE_REVIEW=/tmp/bombcad-ui-review swift test --filter InterfaceSnapshotTests.constrainedPanels
```

The helper checks the fixed host bounds and unchanged project inputs. The older captures still
expand to the view's fitting size. These new captures exclude the native window chrome and
toolbar; Metal content is not drawn in the hidden host. They do not verify native window
resizing, scrolling, keyboard focus or interactive render behaviour. Passing the helper means
the artifacts were captured and the checked invariants held; it does not automatically certify
their visual layout.

## Remaining checks

- Broader tab order, keyboard-only workflows and focus restoration after sheets close.
- Scrolling and text clipping at minimum window sizes and other display scales.
- Native light appearance and completed STL/IFC previews.
- Imported-project save/reopen, multiple document windows and their independent state.
- Interactive saved-run comparison and render-export panels.
- Animated run rendering; the checks above cover static layout and import views only.
