# Profiled steel sheeting

Trapezoidal and sinusoidal steel sheets, the cladding and roofs of portal-frame sheds and
warehouses, in both of BombCAD's building models:

- **as shells**, in a deformable structure: any plate-like solid can be made a profiled sheet in
  the structure editor (`StructureModel.solidSheets`, `ProfiledSheet`);
- **in the one-way damage of envelopes**: an envelope's walls or roof can be "Profiled steel
  sheeting" (`EnvelopeConstruction.Kind.profiledSteelSheeting`), judged by UFC 3-340-02's method
  for cold-formed panels and its fixings by EN 1993-1-3.

The [portal-frame warehouse sample](#the-portal-frame-warehouse-sample) uses both. The
[standing](standing.md) of each is **illustrative**. Compared with Langdon's corrugated panels,
the shells get the elastic response about right. They do not get the plastic response: local
buckling is not modelled, and the connections give way where the panels held. No blast test of
building cladding or its fixings has been compared.

The code is in `Sources/BlastCore/ProfiledSheet.swift` (profiles, section properties, the shell
model), `ProfiledSheetResponse.swift` (the one-way model), `LangdonPanelTest.swift` and
`blastbench langdon` (the comparison), and `PortalWarehousePreset.swift`.

## The profiles

A profile is its centreline over one pitch: for a trapezoid, the thickness, pitch, overall depth
and the flats of crest and trough; for a sinusoid, the thickness, pitch and depth. Its area, second
moment and plastic modulus per pitch follow as a thin-walled section, each wall a line of the
thickness (`SheetProfile.section`). Where the maker gives an effective section modulus, which
allows for local buckling of the walls (EN 1993-1-3), bending strength uses it; otherwise the
plastic modulus.

| Profile | Thickness | Depth | Pitch | Crest / trough | Yield | Source |
|---|---|---|---|---|---|---|
| Trapezoidal roof sheet, 45 mm (STR45) | 0.63 mm (0.7 nominal) | 43 mm | 180 mm | 47 / 77 mm | 350 MPa | Swedsteel-Metecno's Eurocode tables |
| Trapezoidal wall sheet, 32 mm (STW35) | 0.63 mm (0.7 nominal) | 32 mm | 159 mm | 70 / 40 mm | 350 MPa | the same |
| Sinusoidal sheet, 76/18 | 0.63 mm | 18 mm | 76 mm | | 280 MPa | ArcelorMittal's Frequence 13.76.18 |
| Langdon's quarter-scale blast wall | 2 mm | 42.5 mm | 220 mm | 45 / 95 mm | 296 MPa | Langdon (2003), Tables 7-1, 3-2 |

Checked against the published properties (`ProfiledSheetTests`, "Section properties match"):
- the gross area and second moment of STW35 and STR45, within 3% of Swedsteel's (their 3 mm corner
  radii are left out here);
- Langdon's second moment and neutral axis, within 2%, and her equal-area axis, 12.36 mm against
  12.37. Her plastic moment is 3% below this one.

## As shells: a skin and its ribs

A profiled sheet's stiffness lies in its depth. A flat plate of its thickness could not carry
pressure between its ribs, and the profile's slopes cannot be meshed by plates along the axes.
So `ProfiledSheet` builds a sheet in two parts:

- **the skin**: a plate as thick as the profile is deep, standing for 5% of the sheet, which closes
  the surface to the air and holds the ribs together across the sheet;
- **the ribs**: beams on the skin's midsurface along the span, one on every line of the mesh across
  the sheet from edge to edge. Each stands for an equal share of the sheet's ribs, so that the ribs
  are lumped at the mesh's spacing and no skin element has a node between them.

Both are of the solid's own steel, scaled as `SteelSection.equivalent` scales a rolled section.
Together they bend along the span as stiffly and as strongly as the profile, and weigh as much. The
ribs' square section, as wide as the profile is deep, keeps the mesher from taking them for plates.
Hardening is scaled with the stiffness, so a hinge hardens as the profile's would. The profile's
yield is used, not the steel's.

The approximations are:

- the ribs' axial stiffness and strength are about twice the profile's (a rectangle as deep as the
  profile with its bending stiffness), as for rolled sections;
- the profile bends alike both ways, though a trapezoid's flanges differ;
- across the span, the sheet is held together only by the skin, as a corrugated sheet is nearly
  free to open there; its in-plane shear stiffness (stressed-skin action) is the skin's;
- local buckling of the walls is not modelled, beyond the maker's effective modulus;
- the sheet shares its rails' and purlins' nodes: its screws are rigid, and never pull out.

Verified: simply supported and loaded slowly, Langdon's panel bends as a beam of its section,
0.6934 mm against 5qL⁴/384EI's 0.6936 mm. Its ribs share the skin's nodes, and it weighs what the
profile does, within 1% (`ProfiledSheetTests`).

In the structure editor, a selected piece's **Profiled sheet** picker makes it a sheet of one of the
library's profiles, meshed as shells (of structural steel, if it was not already a steel). **Ribs
along** chooses the direction the ribs run, which the sheet spans: up a wall, between horizontal
rails, by default, and along a roof's longer side. The expansion into skin and ribs happens when the
shell solver meshes the body (`StructureModel.expandingSheets`). The ribs are appended after the
body's own solids, and the piece keeps its index.

## Against Langdon's corrugated panels

G. S. Langdon's thesis (Liverpool, 2003) tested quarter-scale offshore blast walls in a pulse
pressure rig. The panels were 2 mm of 316L stainless steel, corrugated in a deep-trough
trapezoidal profile, 880 mm wide and 915 mm high, welded top and bottom to a 3 mm "flexible" angle
on a rigid angle. The flexible length was 60, 120 or 180 mm, and the sides were free. The rig
applied a uniform triangular pulse, up to 2.9 bar and 50–200 ms long, in the design ("positive")
direction or against it. The peak deflection at mid-span was measured where the transducer stayed
on, and the permanent deflection after every test: 33 tests in all (`Fixtures/Langdon2003`).

The model (`LangdonPanelTest`):
- the panel is a `ProfiledSheet` of her profile;
- each flexible angle is a 3 mm plate the flexible length long, held at its far edge;
- the pulse is applied to the loaded face with no air, as the rig applied it;
- the steel is 316L at its proof stress at 0.42 /s (356 MPa, her Table 3-4), hardening at its true
  tangent modulus to its true strain at rupture (Table 3-3);
- elements of 57 mm, 16 along the span.

Her own beam model (Chapter 6), with connection springs fitted to her separate connection tests,
is given alongside. `blastbench langdon` runs the tests; the outputs are on StudioData
(`bombcad/profiled-sheeting/langdon-runs/final16`).

| Tests | Measured | BombCAD (16 elements) | Langdon's beam model |
|---|---|---|---|
| Elastic peak deflection, 16 tests at 0.43–1.05 bar | 2.5–13 mm | 0.54–1.28 of measured (13 of 16 below) | 0.51–1.24 (of 14) |
| Positive, 60 mm angle: 1.21, 1.92 bar | 4–5, 69 mm permanent | 2.9, 185 mm | 3.3, 89 mm |
| Positive, 120 mm: 1.48, 2.00 bar | 100, 133 mm | 33 mm; runs away | 60, 142 mm |
| Positive, 180 mm: 1.37, 1.81, 2.39 bar | 131, 153, 155 mm | 12.5, 243 mm; runs away | 42, 107, 180 mm |
| Negative, 1.0–1.34 bar (7 tests) | 144–602 mm permanent | 0.3–6 mm | 0–48 mm |

What this shows:

- **Elastic: like a beam of the section.** BombCAD's peaks are her beam model's, within 1.4
  mm. Both under-read the panels: by up to half at the 120 mm connection (7.0 mm against
  13 at 0.99 bar), close to it elsewhere. She attributes this to the section's distortion, which
  neither model has. Her connections did not move while the panels were elastic.
- **Positive, plastic: wrong by up to three times either way.**
  - At the 60 mm connection the model is too soft (185 mm against 69).
  - At 120 and 180 mm it is too stiff at 1.4–1.5 bar (12.5 and 33 mm against 131 and 100).
  - At 2 bar and over (c1215, c1805, c1807) the panel runs away: the flexible angles fold over as
    the panel pulls them in, their elements turn inside out and are removed, and the panel comes
    free. The real panels held, with 133–155 mm of set.
  - The modelled angle is a flat plate across the pull, which can resist it only by bending. The
    real connection carries it through the angle's corner and the welded end cap, which her
    connection tests measured and her springs were fitted to.
  - On elements half the size (28.6 mm, `langdon-runs/final32`), the elastic peaks are 0.50–1.09
    of measured and the runaway remains. The plastic sets fall by 6–30% (c622 157 mm, c1212 23,
    c1803 9, c1804 229): they are not converged.
- **Negative: local buckling.** Loaded against its design direction, the wide flange buckles in
  compression (a class 4 section that way) and the section collapses, with 144–602 mm of set. Ribs
  as beams cannot buckle, so the model reads 0.3–6 mm, a hundredth of the measurement: the unsafe
  side. Her beam model misses it too, by ten times or more.

So the shell model is a fair elastic model of a profiled sheet and no more. Its plastic response
depends on connections it does not model and on local buckling it cannot represent. Its standing
is illustrative.

Making it better, in order:
1. The connection as a spring and strength fitted to Langdon's connection tests (her Chapter 4):
   an anchorage at the panel's ends, not a plate.
2. A softening hinge for the ribs, from the section's class: a class 4 rib's moment falling after
   its peak.
3. Fasteners that pull out, for building cladding: a link with the strength `screwTension` gives
   (below) between a sheet and its rails, which needs releasable ties in the shell solver.

The one-way model (below) on the same panels: its elastic peaks are 0.63–1.14 of those measured
below 1 bar. At 1.04–1.05 bar its single span has already yielded (r_u 0.96 bar) where the
panels, partly fixed at their ends, had not, and it over-reads 2.7 times: the safe side
(`ProfiledSheetTests`, "Langdon's panels in the one-way model").

## In the one-way damage of envelopes

An envelope's walls, and separately its roof, can be profiled steel sheeting. In the editor, the
envelope's **Construction** gives:
- the roof's kind;
- each sheet's profile;
- the spacing of the rails and purlins it spans (1.8 m unless said);
- whether it is continuous over them;
- its screws per metre at each rail;
- the rails' steel thickness.

A sheeted component spans one way between its rails or purlins, whatever its own size. The method
is UFC 3-340-02 §5-34, cold-formed steel panels (`EnvelopePanel.profiledSheetOneWay`):

- the dynamic design stress is the nominal yield × 1.21 (average strength) × 1.1 (dynamic increase,
  whatever the rate), eq. 5-26;
- the ultimate resistance is r_u = 7.2 M/L² for a single span, or 3.6 (M⁻ + 2M⁺)/L² for the first
  span of a continuous sheet (eqs. 5-29, 5-30). M is the effective modulus times the design stress,
  the same both ways;
- the equivalent elastic deflection is X_E = β r_u L⁴ / (E I), with β 0.0130 or 0.0062 (eq. 5-31),
  on the gross I;
- the load–mass factor is 0.74 (§5-34.4). The response is elastic–perfectly plastic, and its range
  runs from the single span to the continuous one, as concrete's runs from simply supported to
  fixed edges.

It is graded by PDC-TR 06-08's limits for one-way corrugated metal deck with limited tensile
membrane capacity, limited by its connectors (Table 4-6):

| Damage | Limit |
|---|---|
| None | ductility up to 1 |
| Moderate | ductility up to 1.8 and support rotation up to 1.3° |
| Heavy | ductility up to 3 and 2° |
| Hazardous | ductility up to 6 and 4° |
| Failed | beyond either |

Its fixings are checked against EN 1993-1-3 Table 8.2's resistances of a self-drilling screw
(`EnvelopePanel.screwTension`), without partial factors:
- 5.5 mm screws, pulling out of the rail at 0.45 d t_sup f_u,sup;
- or the sheet pulling over a 16 mm washer at d_w t f_u, whichever is less.

With 3 screws a metre into 2 mm rails, that is 2.1 kN a screw, 6.2 kN/m. When UFC Table 3-9's
dynamic reaction, 0.39 R + 0.11 F at its largest, passes what the screws hold, the sheet is blown
off its fixings: failed, at the time of its peak deflection.

Verified against the formulas by hand (`ProfiledSheetTests`, "Sheeting in the one-way model").
Not compared with any blast test of building cladding: none of its fixings has been found
([data survey](data-survey.md#3b-a-footing-or-connection-under-fast-loading)).

## The portal-frame warehouse sample

"Portal-frame warehouse, profiled steel cladding" (`ScenarioPreset.portalWarehouse`). Its
proportions are steelconstruction.info's for single-span portal frames:

- 25–35 m spans are the most efficient: this one spans 30 m;
- frames at 6–8 m: here at 6 m, four bays, 24 m long;
- 8 m to the eaves;
- a roof pitch of 5–10° (6° common): this roof is flat at the eaves, as the shells' plates lie along
  the axes, where a real one would rise 1.6 m to the ridge;
- purlins at up to 1.8 m;
- columns with about 1.5 times the rafters' plastic modulus.

The members:
- columns of 533 × 210 × 92 UB and rafters of 457 × 191 × 67 UB (1.6 times), sized here, not taken
  from a design; joined rigidly without haunches, the column bases clamped;
- gable posts at 6 m;
- purlins and side rails 1.8 m apart, of a 200 mm Zed of 1.6 mm (Hadley UltraZED 200/1.6: 4.49 kg/m,
  I 341.85 cm⁴, moment capacity 14.98 kN m), continuous;
- 32 mm sheets on the walls and 45 mm sheets on the roof, sharing the rails' and purlins' nodes.

A sheeted neighbouring unit stands behind it as an envelope, and 100 kg of TNT stands 30 m from
the front gable. Meshed at 0.5 m it has 8,688 shells and 9,920 beams, with a 16 µs step
(`PortalWarehouseTests`).

## What was checked first

Before any of this, ContinuumKit and Edgerton were checked, so as not to duplicate their research
([sharing numerics](continuumkit-adoption.md)). ContinuumKit has no shell, beam, steel plasticity
or fastener law. Edgerton has steel plate plasticity at coupon and impact scale (CPU solid
elements, without rate effects, not extracted) and no connections. Profiled sheeting therefore
reuses BombCAD's own shells, beams and steel, and adds no new material law.

## Sources

- G. S. Langdon, *Failure of Corrugated Panels and Supports under Blast Loading: Experimental,
  Analytical and Numerical Studies*, PhD thesis, University of Liverpool, 2003,
  [doi:10.17638/03167700](https://doi.org/10.17638/03167700).
- Swedsteel-Metecno, *Static designing tables for Swedsteel trapezoidal sheets according to Eurocode
  standards*, REV.1, July 2016.
- ArcelorMittal, Frequence 13.76.18 sinusoidal profile (76 mm pitch, 18 mm deep, 0.63–1.25 mm).
- UFC 3-340-02, *Structures to Resist the Effects of Accidental Explosions*, 2008, §5-34 and
  Table 3-9.
- PDC-TR 06-08 Rev. 1, *Single Degree of Freedom Structural Response Limits for Antiterrorism
  Design*, 2008, Table 4-6.
- EN 1993-1-3, *Design of steel structures: cold-formed members and sheeting*, Table 8.2.
- steelconstruction.info, [Portal frames](https://steelconstruction.info/Portal_frames).
- Hadley Group, UltraZED2 sectional properties and dimensions, 2025.
- SCI P363, *Steel building design: design data* (the "Blue Book"): 533 × 210 × 92 UB.
