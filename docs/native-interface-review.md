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

## Review log

What the on-screen review has covered so far (moved from the
[roadmap](roadmap.md#usability-in-parallel) on 11 October 2026).

On the last point: the app's logic is covered by tests that drive its model without a window,
and its rendering is checked through offscreen snapshots. An initial static panel review now
covers the Run sidebar, saved-run comparison, Export for Rendering sheet, linked-part layout
editor, import loading state, Settings and Help content in light and dark appearances. The
Help sidebar's selected labels and dark contrast have also been checked in a native window;
the earlier offscreen rendering problem was a capture artifact. An isolated release app has
passed a zero-charge layout JSON import, native package save, close and reopen at time zero.
A completed OBJ import preview has also been reviewed in a native window, including display
toggles, part search, scrolling and cancellation of a staged domain expansion. See the
[native interface review](native-interface-review.md) for the procedure and its limits.
Keyboard focus, scrolling at minimum window sizes and the other panels still need broader
interactive review.

Review the app on screen and fix what is found. Started: isolated offscreen captures exposed
a misleading layout selector, which displayed the last preset choice after opening another
project. The menu now shows the actual scene name and offers built-in layouts as replacement
actions. The review also covers linked-part editing, import loading, Settings and Help content
in both appearances. During loading, the import sheet no longer reports that its preview is
unavailable while also saying it is updating. Native dark-appearance checks now confirm Help
topic selection and readable sidebar labels without a styling change. A temporary zero-charge
layout imported as a separate document, saved through the native panel and reopened with its
inputs intact at time zero. Import errors now identify missing JSON fields, wrong value types
and null values by path; malformed JSON has a separate syntax message.
Reproduce these static captures with
`BOMBCAD_INTERFACE_REVIEW=/tmp/bombcad-ui-review swift test --filter InterfaceSnapshotTests`.
The opt-in helper creates hidden windows in the test process, writes PNGs under `light` and
`dark`, and checks that capture leaves saved inputs unchanged. Settings captures use and remove
a temporary defaults suite. The import capture records the initial loading state rather than
waiting for asynchronous preview completion. The helper expands the requested size
to the view's fitting size, so these captures do not verify scrolling at the minimum window
size. A separate [native import review](native-interface-review.md#completed-obj-preview)
covers a completed small OBJ preview, its display controls, part search and cancellation;
this is not a check of every importer or window size. The helper also writes fixed viewport
captures of the main content at its 1000 × 640 point minimum and a short editing form;
these show clipping without fitting-size expansion, and have been reviewed in both
appearances. They exclude native chrome and toolbar, and do not check scrolling or focus.
See the [capture procedure and limits](native-interface-review.md#constrained-offscreen-captures).
Animated run rendering and broader
native interaction remain separate checks; the helper is skipped during ordinary test runs.

On 18 October 2026 a fresh build of main was reviewed on the real screen, by the accessibility tree
and the keyboard ([below](#on-the-real-screen-labels-and-keyboard)).

## Panels at the sidebar's width

On 12 October 2026 the offscreen helper captured the panels not reviewed before, in light and dark
appearances, each at the sidebar's 310-point width: whole (6,000 or 3,200 points tall, written also in
overlapping parts of 900 points to read) and at a short 580 points to see clipping. A blast wall on a
hill, with a block, a crate, a car, fragments, thermal radiation, the cloud and a soil column of ground
points, shows every Run section with its settings; a vented methane room shows the gas and vent
sections. The Edit tab was captured with a gauge and with a block open, and the sweep and import
repair sheets on their own. Reproduce with
`BOMBCAD_INTERFACE_REVIEW=/tmp/bombcad-ui-review swift test --filter InterfaceSnapshotTests.remainingPanels`.

Found and fixed:

- **Cell size** showed the field's own title again, wrapped in two lines, inside the row; the field's
  title is now hidden (it remains its accessible name).
- **Advisor**: the target was cut to "Pea…" and the per-cent field's title wrapped a letter at a time.
  The target is a row of its own and the field's title is hidden.
- **Fragments, tracers and ground points** showed an empty picker for a count not among its choices,
  as a saved project can hold; the held value is now offered too (tested).
- **Freestanding objects**: the three add buttons were all cut to "Add…"; they stack when they do
  not fit side by side.
- **Main material** cut "Reinforced concrete" short; the picker is labelled "Material", as in the
  Run tab.
- The resolution warning read "1 regions have…".

Passed without change: the terrain, map buildings, vent panels, gas cloud, thermal, cloud, ground
shock, structure and standing sections, Playback, Display and Solver; the gauge and block editors;
the sweep sheet; and the short captures, which clip at the scroll viewport with the rest reachable.
The repair sheet gives nearly the same advice twice, in its banner and below it; left as it is.
Switches that are on show grey, not blue, because the hidden window is never active.

Keyboard focus and tab order cannot be checked offscreen: in the test process the app is not
active, so SwiftUI's focus system takes no Tab keystrokes and its accessibility tree stays empty, and
making the window key would mean activating it on screen. They are listed below for a person.

## Envelope damage: colours, legend and section

On 16 October 2026 the envelope damage display was checked offscreen, without a screen.

**The view.** `blastbench snapshot --street-envelopes --envelope-damage --mass 50|500 --time 0.08`
renders the street study's four buildings as envelopes, judged one way after the run, through the
app's renderer. At 50 kg the two buildings facing the charge are moderate and the far two none; at
500 kg the facing two are failed (hazardous with fixed edges) and the far two moderate. The view
has one appearance; the app's light and dark settings do not change it.

**The section.** `swift test --filter InterfaceSnapshotTests.envelopeDamage`, with
`BOMBCAD_INTERFACE_REVIEW` set, captures the sidebar's Envelope building damage section at its
310-point width, in light and dark. Synthetic loads give four buildings: none, glass broken alone,
moderate, and heavy with the 2° flag.

**The palette.** Each pair of the six colours was set apart in CIELAB under Machado et al.'s
(2009) simulations of protanopia, deuteranopia and tritanopia, at full severity. The closest pair
under each:

| Palette | Normal | Protanopia | Deuteranopia | Tritanopia |
| --- | ---: | ---: | ---: | ---: |
| First | 36.7 | 21.5 | 13.8 | 16.2 |
| Now | 37.5 | 32.4 | 21.4 | 24.5 |

- In the first palette, yellow and orange were 13.8 apart under deuteranopia, and none and glass
  broken 16.2 apart under tritanopia.
- The closest pair now is yellow and orange under deuteranopia, at 21.4. The colours also darken
  as the damage grows.

Found and fixed:

- **The air's paint hid the damage.** Buildings were painted with peak overpressure over their
  damage colour, so failed buildings read orange. A judged building is now drawn in its own
  colour, lit, without the paint. A "Show damage in the view" switch, on by default, gives the
  paint back.
- **No legend.** The section now shows the six colours with their meanings, three to a row.
- **Failed hardly showed on dark backgrounds.** It was nearly black (L* 12) against the dark
  sidebar and the view's ground. It is lighter now (L* 26), with no pair any closer, and the
  swatches and dots have an outline.
- **The none dot vanished on the light background.** It now has the same outline.
- **"0 of 1 panes broken"** now reads "pane".

Passed: every line fits at 310 points in both appearances, the flag's sentence included.

Not checked: how the colours look on a real display, and VoiceOver. The legend has one combined
accessibility label naming the six levels.

## On the real screen: labels and keyboard

18 October 2026, a fresh build of main (about `af18afdc`), driven with the user's approval through
System Events: the accessibility tree read element by element, and focus followed with Tab, Escape
and the menus. Full Keyboard Access was off (a system setting, not changed for the review), so Tab
reached text fields and lists only.

Found, and what was done (in 0.6.0):

1. **Domain ▸ Extent**: the X, Y and Z fields were all named "Extent". Now "Extent X (m)", "Extent
   Y (m)" and "Extent Z (m)".
2. **Every trash button** was named "Remove". Each now names what it removes: "Remove Block 1",
   "Remove gauge Near façade", and likewise exposure-only buildings and freestanding objects
   (their Duplicate buttons too).
3. **Advisor**: the target's field was named "Percent". It now reads as its picker does, "Peaks
   within (%)", and "A run under (min)" for time.
4. **Export for Rendering** opened with focus on the sheet itself, and Tab did not reach "A frame
   every", a stepper, which is no key view without Full Keyboard Access. The interval is now a
   field beside its stepper, focused when the sheet opens; the parameter sweep (its name prefix),
   the run comparison (its arrival threshold) and the import (its corner's X) open in a field too.
   Escape already closed each and returned focus.
5. **Tab order** ran through the sidebar's fields, then stopped on nothing before cycling back: the
   3D view, which takes first responder on a click but no keys. ContinuumKit's `OrbitControlView`
   now leaves the Tab loop (`canBecomeKeyView` false; a click still ends a field's editing),
   released in ContinuumKit 0.1.0-alpha.28, which BombCAD pins.
6. **No keyboard path** to Import Model, Parameter sweep, Compare runs, Keep Run or Export CSV,
   which were toolbar or chart-panel buttons only. They are menu items now: File ▸ Import Model…
   (⇧⌘I) and Export Results as CSV…; Simulation ▸ Keep Run… (⌘K), Compare Runs… (⇧⌘K) and
   Parameter Sweep….
7. **The window at its minimum**, 1000 × 692 with the toolbar, scrolled to the end in both tabs:
   nothing cut. A gauge's coordinates wrap onto two lines; left.
8. With a box opened, its fields read "Corner X (m)" with no name. Each now reads with its own,
   "Block 1, corner X (m)"; a gauge's "Near façade, position X (m)".

`AccessibilityLabelTests` holds 1–6 in the sources (offscreen, a hosted form's rows build no
accessibility elements to read, so the labels themselves are read at each screen review), and
ContinuumKit's `SceneRenderTests` the orbit view's place in the Tab loop. The new labels, the
sheets' first focus and the menus have not yet been seen on the real screen.

## Since 0.6.0 (23 October 2026)

What reached users after 0.6.0 was captured offscreen and looked at by eye: before this, sessions
had only app tests. `InterfaceReviewSince060Tests.swift` adds four captures to the suite, in light
and dark at the sidebar's 310 points, whole, at the short height (580 points) and in 900-point
parts: `BOMBCAD_INTERFACE_REVIEW=<dir> swift test --filter
'InterfaceSnapshotTests/(estimateAndPeople|learnedField|remoteRun|archingAndTerraces)'`, under
`gpu-slot`. The view itself is drawn once through the renderer (`view/`), with the hazard rings,
stand-off lines and refined outlines as the viewport sets them.

- **The quick estimate and the drag:** six glazed buildings round 50 kg with a fence 10 m off; the
  close calls refining (bar, Cancel, 2 min budget) and refined (the "refined" mark, the green
  outline), every building opened, the selected building, the walls' colouring, then the charge
  dragged across the fence (the preview's two orange lines, the amber line, the rings moved, Pin
  This Instead disabled) and the whole Run sidebar with the Hazards section.
- **The learned field option:** off, the first-use dialog (drawn as the alert SwiftUI presents for
  it), declined, downloading, a checksum that fails, a file not found, cancelled, a corrupt file at
  the estimate, and on with a stand-in's weights.
- **People in the scene:** the warning and pickers, shares by band, no baseline, pinned at night and
  changed to the evening, Clear Baseline, Show counts open, coloured by people hurt.
- **A run on a Mac nearby:** Run on in the sidebar, the overlay connecting, running, paused (Rerun
  with Edits off, then on after an edit), lost (Keep Watching, Fetch Result Later), waiting,
  finished, failed and stopped, and the kept run "On Studio" in Compare Runs.
- **Masonry and the terraced sample:** Arching between returns in the construction editor, and the
  solid-brick terraced sample's Run and Edit tabs.

Found and fixed:

- **Colour by** cut the walls' and openings' choices short ("Chance walls dam…"). The picker sits on
  its own row and its choices have shorter names; what the long names added ("moderate or worse",
  "fitted to Beirut's survey", "GSA's condition 3b") is shown under the legend.
- **The walls' and roofs' colourings had no legend.** They show the chance's ramp, with a line of
  their own.
- **The glass chances' line said "Walls and roofs are not given chances"**, beside the walls' and
  roofs' chances. It now says where those are and that they are not to be relied on.
- **A building's rows** were named "Facade 3.0" twice, once for the wall and once for its glass;
  they read "Façade 3" and "Façade 3 glass".
- **A rotation that rounds to nought** read "-0.00°"; it reads "0.00°".
- **A building's construction and chances lines** were centred when short and indented when long;
  they are set at the leading edge, as are Show counts' lines.
- **The close calls' line** said "their damage" for one building, and "1 further close calls were".
- **The Glass picker** cut "As designed (weathered, E1300)" short; it reads "As designed (E1300)",
  the weathering in its help.
- **A failed download** read "not found on this server.. The learned field option stays off."; the
  system's reason now ends without its own full stop and starts in lower case after the colon.
- **The lost connection's Stop It** is **Stop**, as in the running overlay, with the same help.
- **"On Studio came back from Studio"** quotes the run's name: "“On Studio” came back from Studio
  and is kept", and likewise while it runs on.
- **Show counts** read "72 people placed (evening (5 pm))"; it reads "72 people placed, evening
  (5 pm)".

Passed without change: the drag preview's marking, the hazard rings and the stand-off line (amber
once crossed), the refinement's budget and progress, the refined mark and outline, the learned
field option's dialog and its other messages, the people's pickers, bands and baseline buttons,
Run on, the overlay's other states, the kept run's name, and the arching switch.

Left, with the reason:

- The learned field switch's title wraps at the hyphen, "ground-" over "floor peaks": readable, and
  a shorter title would lose what the option is.
- A corrupt weights file reads "could not be read: version 1953459744, not 1": the number is the
  file's bytes. The message is `LearnedField`'s, which the field model's work (emmettl/bombcad-work#69)
  is changing; left to it.
- A building's line gives two pane counts, "11 of 12 panes broken" (the panes the estimate judges)
  and "glass 97% of 74 panes broken" (the construction's mix). Both are right; which to show is a
  decision for the user, not a layout fix. Its mix also nests brackets, "(apartments (assumed))".
- Layout's menu cuts a long sample's name in the middle ("Terraced house…1919 solid brick"); its
  help holds the whole name. A menu button keeps to one line.
- While the charge is dragged, the burst's start stays drawn where the charge was until it is let
  go, since the scene is loaded again only then; the charge's marker and the rings follow it.
- In the overlay, Pause becoming Resume widens the button and moves Stop.

## Remaining checks

For a person at a real screen:

- The panels above on the real screen: Colour by on its own row, the drag preview while dragging,
  the learned field model's real download dialog (its icon, the app's, is a folder offscreen), and
  the Mac nearby overlay over the viewport while a run streams.
- Keyboard focus and VoiceOver on the new controls: Pin as Baseline, Clear Baseline, Show counts,
  Colour Buildings by People Hurt, Refine close calls and Up to, the learned field switch and Cancel
  Download, Run on, and the overlay's Pause, Rerun with Edits, Keep Watching, Fetch Result Later and
  Stop, and Arching between returns.

- The fixes above, on the screen: the labels as the accessibility tree reads them, each sheet
  opening in its field, Tab no longer stopping on the 3D view, and the new menu items.
- With Full Keyboard Access on (System Settings ▸ Keyboard): Tab through every control, buttons,
  pickers, steppers and switches included, in reading order.
- VoiceOver's speech itself, beyond the labels the tree carries.
- The materials' colours (0.6.0) in the viewport, with the damage colouring and rubble over them,
  in both appearances and under System Settings ▸ Accessibility ▸ Display ▸ Color Filters; checked
  so far only offscreen and by simulated colour deficiency (`MaterialAppearanceTests`).
- Other display scales, and the window at its minimum there.
- The native light appearance.
- Completed STL and IFC previews (the IFC panels need the converter, not installed in the test
  process).
- Imported-project save and reopen, and several document windows with their own state.
- The interactive saved-run comparison and render-export panels.
- Animated run rendering; the checks above cover static layout and import views only.
