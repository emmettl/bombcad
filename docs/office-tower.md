# Twelve-storey office, steel and glass

A sample layout of modern construction, beside the older [twelve-storey
tower](shell-model.md) of flat slabs on concrete columns. It is a speculative office: a
concrete core, a steel frame with composite floors, and a glazed curtain wall. Across the street
stand two smaller buildings as envelopes, and a van's worth of explosive is parked at the kerb.

@@IMAGE@@

## The building

| Part | As modelled | Typical practice, and the source |
|---|---|---|
| Storeys | 12 of 3.8 m floor to floor, 45.6 m high | 3.6–4.0 m for speculative offices, 4.0–4.2 m for prestige ones [1] |
| Plan | 22.5 m square, a 7.5 m grid, three bays each way | Façade columns typically at 5.4–7.5 m; planning grids in multiples of 1.5 m [1] |
| Stability | A reinforced concrete core in the middle bay, 7.5 m square, of 300 mm walls with 565 mm² of bars a metre in each face, each way; a doorway into it on every floor | "Concrete cores are the most practical system for buildings of up to 40 storeys" [1] |
| Columns | Twelve 305 × 305 × 118 UC on the perimeter | 305 UC for 5–12 floors carried, 356 UC for 10–40 [1]; properties from the SCI's tables [4] |
| Primary beams | 457 × 191 × 67 UB on the column lines, both ways | Composite primaries at a span-to-depth ratio of 16–18 [2]: 16.5 here |
| Secondary beams | 356 × 171 × 45 UB at 2.5 m between the primaries | Composite secondaries at 22–25 [2]: 21 here, a little deep |
| Floors | 130 mm of concrete on a 60 mm steel deck, spanning 2.5 m; the deck as 1,200 mm² of bars a metre along its span, 30 mm up, and an A193 mesh near the top | A 130 mm slab on a 60 mm deck at 3 m spans is a common reference [3]; SCI P359 covers slabs 100–200 mm thick [5] |
| Curtain wall | Unitised: aluminium mullions at 1.5 m, 65 × 150 mm, a storey high and fixed to the slab edges, 0.25 m outside the column lines | Unitised systems of 125–150 mm depth, units up to 2.7 × 3.6 m (Schüco USC 65 F) [6] |
| Glazing | 10 mm toughened glass, vision lites 1.25 m wide from 0.25 m above each floor to 2.95 m; an opaque spandrel above, to the next floor | Toughened glass's characteristic bending strength is 120 MPa (EN 12150-1), against 45 MPa annealed [7]; outer panes of 6 mm toughened glass are usual in insulating units [8] |

### How it is meshed

Everything is shells and beams of 0.25 m. Some parts are simplified to fit that mesh, and each
simplification is listed here.
- **Steel members.** A beam element's section is a rectangle. Each rolled section is a rectangle
  0.6 of its depth wide, of steel scaled to the section's major-axis bending stiffness, plastic
  bending strength and mass (`SteelSection`, as the [IFC import](structural-editing.md) does for
  flanged sections). Its axial stiffness is then about twice the section's.
- **Composite floors.** The beams lie on their slab's midsurface and share its nodes: full shear
  connection between them, but without the composite section's lever arm. The floors are a
  little less stiff than real composite ones.
- **Connections.** Every joint of the frame is rigid, because the shell model has no pinned
  joints. A real frame of this kind has simple (pinned) beam-to-column connections and leans on
  its core.
- **Curtain wall.** It is one plate, 150 mm thick (a mullion's depth), round each storey of each
  face. Its frame material (`ScenarioPreset.curtainWallFrame`) is scaled so that a strip one
  element wide bends as stiffly and as strongly as a mullion, and weighs as much. The vision
  lites are openings in it, each glazed with a pane: an opening cuts the frame but keeps the pane
  it holds, which joins the frame round its edge ([shells](shell-model.md), item 6). The
  spandrels are the frame plate itself.
- **The glass** is one pane of 10 mm toughened glass, standing for an insulating unit. It fails
  as annealed glass does, at its own strength.
- **The neighbours across the street** are envelopes: rigid and exposure-only. Their 6 mm
  annealed panes are judged by [envelope damage](building-envelopes.md).

## Under gravity

@@GRAVITY@@

## The blast

@@BLAST@@

## Sources

1. SteelConstruction.info, [Concept design](https://steelconstruction.info/topics/design/concept-design/) (SCI and BCSA): floor-to-floor heights, column spacing, planning grids, stability systems and column sizes by floors carried.
2. SteelConstruction.info, [Framing schematics](https://steelconstruction.info/resources-for-students/framing-schematics/): span-to-depth ratios of composite beams.
3. Structville, [Design of composite slab with profiled metal deck](https://structville.com/2020/07/design-of-profiled-metal-deck-composite-slabs.html): a worked example of a 130 mm slab on a 60 mm deck at 3.0 m spans.
4. SCI P363, *Steel building design: design data* (the "Blue Book"): the properties of the 305 UC, 457 UB and 356 UB.
5. SCI P359, [*Composite design of steel framed buildings*](https://www.SteelConstruction.info/images/c/c7/SCI_P359.pdf): composite slabs of 100–200 mm on decks of 45–100 mm.
6. Schüco [USC 65 F unitised façade](https://www.bimobject.com/en/schueco/product/schueco_usc_65): basic depths of 125 and 150 mm, units up to 2.7 × 3.6 m.
7. EN 12150-1, thermally toughened soda lime silicate safety glass: characteristic bending strength 120 MPa.
8. Priedemann façade lab, [Wicona and Glas Trösch unitised element](https://priedemann.net/en/services/facade-lab/exhibition/wicona-glas-troesch.html): a 6 mm toughened outer pane.
