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

## Remaining checks

- Tab order, keyboard-only workflows and focus restoration after sheets close.
- Scrolling and text clipping at minimum window sizes and other display scales.
- Native light appearance and completed STL/IFC previews.
- Imported-project save/reopen, multiple document windows and their independent state.
- Interactive saved-run comparison and render-export panels.
- Animated run rendering; the checks above cover static layout and import views only.
