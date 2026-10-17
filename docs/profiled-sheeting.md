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
held by her connections as springs and with their flanges buckling locally, the shells' permanent
sets are within half to twice of those measured on 10 of 13 tests, both ways, and none runs away;
three, where buckling comes on earlier than plate theory says, are not. No blast test of building
cladding or its fixings has been compared.

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
- the profile is as stiff and strong both ways until a flange buckles;
- across the span, the sheet is held together only by the skin, as a corrugated sheet is nearly
  free to open there; its in-plane shear stiffness (stressed-skin action) is the skin's;
- local buckling is a softening of the ribs' fibres on the flange that buckles (below), not the
  section's distortion;
- the sheet shares its rails' and purlins' nodes: its screws are rigid, and never pull out.

Verified: simply supported and loaded slowly, Langdon's panel bends as a beam of its section,
0.6934 mm against 5qL⁴/384EI's 0.6936 mm. Its ribs share the skin's nodes, and it weighs what the
profile does, within 1% (`ProfiledSheetTests`).

### Local buckling of the ribs

A thin flange in compression buckles, and the section's moment falls after its peak: the
softening hinge of a class 4 section. The ribs carry it on their fibres (`LocalBuckling`, a beam
material's option, set by `ProfiledSheet.localBuckling`).
- **Which flange.** A flange buckles if its elastic buckling stress as a plate held along both
  edges, 4π²E/(12(1−ν²))·(t/b)², is below the yield, or wherever the maker's effective modulus
  allows for buckling (thin cladding: both flanges). Langdon's 95 mm flange buckles at 320 MPa,
  below its 356; her 45 mm flange, at 1.4 GPa, does not. A sheet's crests are on the side of its
  midsurface its assignment says (`SheetAssignment.crestSide`), the troughs on the other.
- **When.** From the flange's buckling strain carried to the rib's extreme fibre by the
  curvature (its distance from the centroid against half the profile's depth); with the maker's
  modulus, from the rib's first yield, the effective section's peak.
- **How far.** The fibres on that side of the rib, past that strain in compression, carry a stress
  falling from the yield to nothing over as much strain again. What the section keeps is its webs'
  and its other flange's. Unloading, and tension, are as before.

None of these is fitted to the tests below.

### Connections as springs

A sheet, or any shell, can be held along an edge by springs to fixed ground
(`StructureModel.springSupports`, `SpringSupport`), each per metre of edge:
- pulling along the span, across it, and turning about the edge, differently either way;
- each elastic, then yielding and hardening or softening linearly, never below nothing, and
  unloading elastically (`SpringLaw`);
- the nodes held still along the edge, as a weld holds them;
- the turning spring at the beams' ends only (a sheet's ribs, which carry its bending), the others
  at every node.

Verified: a 1 m plate on a turning spring of 20 kN m/rad per metre, loaded at 1 kPa as a
cantilever, turns at its foot by its moment over the stiffness, 0.025 rad, within 5%
(`ProfiledSheetTests`). Springs are compiled into the shell kernel only for a body that has them.

## In the structure editor

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
- the panel is a `ProfiledSheet` of her profile, its wide flange in tension in the design
  direction, buckling locally as above;
- each end is held by her connection as springs (her Table 7-3): pulling in along the span
  (K_xe, R_mx, K_xp), across it (K_y), and turning as the flexible angle opens (her "+") or closes
  ("−"), each fitted to her tests on 150 mm pieces of the connections (Chapter 4), so per metre
  1/0.15 of hers. Her correction for the angle's 45 mm lever, 45 sin φ (eq. 7-2), is added to the
  deflection, as she added it;
- the pulse is applied to the loaded face with no air, as the rig applied it;
- the steel is 316L at its proof stress at 0.42 /s (356 MPa, her Table 3-4), hardening at its true
  tangent modulus to its true strain at rupture (Table 3-3);
- elements of 57 mm, 16 along the span.

Her own beam model (Chapter 6), with the same springs, is given alongside. `blastbench langdon`
runs the tests (`--connection plates` for the angles as 3 mm plates, held at their far edges, as
first built; `--no-buckling`); the outputs are on StudioData
(`bombcad/profiled-sheeting/langdon-runs/`, `sb16` and `sb32` for these, `final16` for the first
build).

| Tests | Measured | BombCAD | Langdon's beam model |
|---|---|---|---|
| Elastic peak deflection, 16 tests at 0.43–1.05 bar | 2.5–13 mm | 0.62–1.56 of measured | 0.51–1.24 (of 14) |
| Positive, 60 mm: 1.21, 1.92 bar (permanent) | 4–5, 69 mm | 3.6, 119 mm | 3.3, 89 mm |
| Positive, 120 mm: 1.48, 2.00 bar | 100, 133 mm | 21, 169 mm | 60, 142 mm |
| Positive, 180 mm: 1.37, 1.81, 2.39, 2.93 bar | 131, 153, 155, not given | 11, 127, 184, 199 mm | 42, 107, 180 mm |
| Negative, 60 mm: 1.18, 1.33, 1.34 bar | 283, 315, 310 mm | 213, 250, 248 mm | 3.9 mm (1.18 bar) |
| Negative, 120 mm: 1.26, 1.30 bar | 476, 469–483 mm | 324, 330 mm | 48 mm (1.26 bar) |
| Negative, 180 mm: 1.00, 1.22 bar | 144, 602 mm | 0.2, 332 mm | 0, 48 mm |

Of the 13 permanent sets measured over 10 mm, 10 are within half to twice: all the negative ones
but one (0.55–0.80 of measured) and four of the six positive (0.83–1.73). Nothing runs away: at
2.93 bar the panel holds at 199 mm. On elements half the size (28.6 mm) every result is within a
few percent of these: the springs and the buckling are converged where the plates were not.

What each change did, on the same tests (`langdon-runs/s16`, `pb16`):
- **The springs alone** end the runaway (the 2.0 and 2.39 bar tests 1.27 and 1.18 of measured),
  but leave the negative direction a hundredth of what was measured: 4 of 13 within the band.
- **Buckling alone**, with the plates, lifts the negative sets to 0.33–0.45 of measured, but the
  plates still fold and run away above 2 bar: 1 of 13.
- **Both**: 10 of 13.

What is still wrong:
- **The design direction at 1.4–1.5 bar** (c1212, c1803): 21 and 11 mm against 100 and 131. The
  real panels yielded and buckled at their centres there ("dishing" of the flange, Langdon §5.4);
  by plate theory the narrow flange that is compressed this way does not buckle, so here the model
  stays nearly elastic. Her beam model, 60 and 42 mm, is closer.
- **The negative 180 mm test at 1.0 bar** (c1801-4): 0.2 mm against 144. The panel's moment stays
  just below the flange's buckling by plate theory, which a real plate's imperfections lower;
  12 mm more at 1.22 bar, the model collapses (332 mm against 602).
- **The elastic peaks** spread a little more than before, 0.62–1.56: the springs' lever correction
  raises them, and four of the smallest (2.5–4.5 mm measured) are now over.

So with its connections known the shell model is a fair model of a corrugated panel both ways,
within half to twice of the permanent set on most of the tests. It still misses the onset of
buckling where a plate's imperfections bring it on early. Its standing stays illustrative, as
building cladding's own fixings (screws) and its own tests are not compared.

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

## Shared with ContinuumKit?

Before building them, ContinuumKit was checked for a softening hinge or a connection spring: it
has neither (its beams and `TimberFailure` are material points, not hinges or springs). Two parts
of this are general and could move there by its process (a provenance document, independent
tests, a synthetic consumer):
- `SpringLaw`'s one-dimensional elastic, hardening-or-softening spring with elastic unloading
  (`springForce` in `Shell.metal`), with its turning pair either way;
- `LocalBuckling`'s softening of a fibre in compression past an onset strain, the class 4 hinge of
  a fibre beam.
Both are candidates, not yet proposed.

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
