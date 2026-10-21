# Profiled steel sheeting

Trapezoidal and sinusoidal steel sheets, the cladding and roofs of portal-frame sheds and
warehouses, in both of BombCAD's building models:

- **as shells**, in a deformable structure: any plate-like solid can be made a profiled sheet in
  the structure editor (`StructureModel.solidSheets`, `ProfiledSheet`);
- **in the one-way damage of envelopes**: an envelope's walls or roof can be "Profiled steel
  sheeting" (`EnvelopeConstruction.Kind.profiledSteelSheeting`), judged by UFC 3-340-02's method
  for cold-formed panels and its fixings by EN 1993-1-3.

The [portal-frame warehouse sample](#the-portal-frame-warehouse-sample) uses both. The
[standing](standing.md) of both is an **approximation**:
- **Langdon's corrugated panels**, held by her connections as springs, their flanges buckling
  locally: the shells' permanent sets are within half to twice of those measured on 10 of 13
  tests, both ways, and none runs away. Three, where buckling comes on earlier than plate theory
  says, are not.
- **ADBLAST's building cladding**, screwed to its supports and shot in air: the first deflection
  is 0.90–1.35 of that measured on all ten tests. What is left after misses by 27 mm on average
  since buckled flanges keep their folds ([below](#what-is-left-scoped); 66 mm before).
- **The envelope construction on the same ten tests**: under the same load it gives within 1.0–1.35
  of the shells' deflection. Under the air's load, on the strip of ribs across the span that it is
  judged on, it gives 0.65–1.09 of measured; on a whole component's mean, 0.49–1.36
  ([comparison](#against-adblasts-cladding-as-an-envelope)).
- Cladding torn off deforming purlins is not compared.

The code is in `Sources/BlastModel/ProfiledSheet.swift` (profiles, section properties, the shell
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

A thin flange in compression buckles. The ribs carry this on their fibres (`LocalBuckling`, a beam
material's option, set by `ProfiledSheet.localBuckling`). None of it is fitted to the tests
below.
- **Which flange.** A flange buckles if its elastic buckling stress as a plate held along both
  edges, σ_cr = 4π²E/(12(1−ν²))·(t/b)², is below the yield. Langdon's 95 mm flange buckles at
  320 MPa, below its 356; her 45 mm flange, at 1.4 GPa, does not. TR84's 100 mm crest buckles at
  163 MPa (1.5 mm) and 41 MPa (0.75 mm), its 50 mm trough not at 1.5 mm. Where the maker gives
  an effective modulus (thin cladding), buckling is in it already and nothing is added. A sheet's
  crests are on the side of its midsurface its assignment says (`SheetAssignment.crestSide`), the
  troughs on the other.
- **What it keeps, by how it buckles** (`PostBuckling.automatic`). The bound of Johnson's parabola
  between elastic and inelastic buckling, σ_cr = f_y / 2, decides:
  - **Elastically** (σ_cr under half the yield, λ = √(f_y/σ_cr) over √2): the flange keeps its
    effective width's strength, Winter's ρ f_y with ρ = (λ − 0.22)/λ² (EN 1993-1-5 §4.4). TR84's
    crests: 0.54 f_y at 1.5 mm, 0.28 at 0.75 mm.
  - **Inelastically**, as it yields: it collapses, its stress falling to nothing over as much
    strain again as it took to buckle. Langdon's flange (λ 1.05). What the section keeps is then
    its webs' and its other flange's.
- **When.** From the flange's strain at that stress carried to the rib's extreme fibre by the
  curvature (its distance from the centroid against half the profile's depth).

Either rule can be chosen (`--effective-width`, `--collapse` in the benches). Each alone fails one
of the two test series below. Effective width everywhere takes Langdon's negative direction back
to 4 of 13 within the band; collapse everywhere leaves ADBLAST's thicker sheets 70–100 mm down
where they ended level.

### Connections as springs

A sheet, or any shell, can be held along an edge by springs to fixed ground
(`StructureModel.springSupports`, `SpringSupport`), each per metre of edge:
- pulling along the span; across it, either way differently (a sheet bearing on its support one
  way, its screws pulling through the other); and turning about the edge, differently either way;
- if asked, the edge comes away altogether once the across spring has given way to nothing
  (`releases`): a sheet off its screws;
- each elastic, then yielding and hardening or softening linearly, never below nothing, and
  unloading elastically (`SpringLaw`);
- the nodes held still along the edge, as a weld holds them;
- the turning spring at the beams' ends only (a sheet's ribs, which carry its bending), the others
  at every node.

Verified: a 1 m plate on a turning spring of 20 kN m/rad per metre, loaded at 1 kPa as a
cantilever, turns at its foot by its moment over the stiffness, 0.025 rad, within 5%
(`ProfiledSheetTests`). Springs are compiled into the shell kernel only for a body that has them.

### Screws that let go

A sheet assigned a fastening (`SheetAssignment.fastening`, `Fastening`) is screwed to the beams it
lies on, rather than sharing their nodes:
- its skin and ribs get nodes of their own, a layer for each sheet;
- wherever a sheet's node lies on the node of a beam across its ribs (a purlin or rail; not a
  rafter or column along them), a link joins the two (`ShellMesh.links`), standing for the screws
  over its share of the beam's length;
- along the normal, the sheet bears on the beam stiffly, and pulling off, the screws hold until
  their tension passes the screws' strength. Then the link lets go for good;
- in shear, the screws bear in the sheet, holding up to their bearing strength.

The pull-off direction is away from the beam's side of the sheet, or, where the beam lies in the
sheet's plane (as purlins snapped to it do), towards its crests: its troughs bear on the beams.

The screws' strengths are EN 1993-1-3 Table 8.2's for self-drilling screws, without partial
factors (`Fastening.screws`):
- tension: the lesser of pulling out of the support, 0.45 d t_sup f_u,sup, and the sheet pulling
  over the washer, d_w t f_u;
- shear: the sheet's bearing, 3.2 √(t/d) f_u d t, at most 2.1 f_u d t;
- stiffness: ADBLAST's 0.66 MN/m a screw; one screw in every trough unless said.

Verified: an STW35 sheet over two purlins 1.8 m apart, one screw a metre (2.1 kN each), sucked
up slowly, stays on at 1.5 kPa (9.4 mm, against the elastic 7.9) and comes off at 4 kPa, its
screws' q L/2 being 2.3 kPa (`ProfiledSheetTests`). The links are a pass of their own before the
nodes move, compiled into the node kernel only for a body that has them.

### Cold-formed purlins and rails

Purlins and side rails are beams of steel scaled to the section (`SteelSection.equivalent`), at
the maker's moment capacity. For a cold-formed Zed or C that capacity already allows for local
and distortional buckling (EN 1993-1-3), so no fibre softening is added. Verified: Hadley's
UltraZED 200/1.6, simply supported over 6 m, holds at 0.9 of 8 M_c/L² and runs away at 1.1
(`ProfiledSheetTests`). Two approximations follow:
- its rectangle starts to yield at two-thirds of its capacity, where a thin-walled section stays
  elastic nearly to it, so it bends twice as far as it should at 0.9;
- what follows the peak is not modelled. A lipped flange's distortional buckling, and an unbraced
  flange in uplift, are lower than the capacity the maker gives for a flange held by sheeting.

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
buckling where a plate's imperfections bring it on early. Its standing stayed illustrative until
building cladding's own fixings (screws) and its own tests were compared
([ADBLAST](#against-adblasts-cladding-tests)).

The one-way model (below) on the same panels: its elastic peaks are 0.63–1.14 of those measured
below 1 bar. At 1.04–1.05 bar its single span has already yielded (r_u 0.96 bar) where the
panels, partly fixed at their ends, had not, and it over-reads 2.7 times: the safe side
(`ProfiledSheetTests`, "Langdon's panels in the one-way model").

## Against ADBLAST's cladding tests

ADBLAST, a European research project (Hoffmeister et al., RFCS final report EUR 27487, 2015), shot
building cladding with plastic explosive at the Royal Military Academy in Brussels
(`Fixtures/ADBLAST2015`):
- **The panels:** three TR84/273 trapezoidal sheets, 0.75 or 1.5 mm, 2.46 m between two square
  tubes, screwed to them with self-drilling screws;
- **The charges:** 0.5–1.5 kg of C4, 3.5 m above the middle;
- **What was measured** at the middle: the reflected pressure and impulse; the first peak
  deflection; the deflection left.

The model (`AdblastCladdingTest`, `blastbench adblast`):
- the sheets are a `ProfiledSheet` of TR84 (84 mm at 273 mm, its flats fitted to Pruszyński's
  T-84 data sheet), crests up, at ADBLAST's coupon yields at 2.3 /s (439 and 420 MPa);
- each tube is a spring support releasing as above: the screws in bearing along the span, the
  sheet bearing on the tube, and the screws pulling through it (5.1 and 10.5 kN a screw by EN
  1993-1-3; ADBLAST estimates 6.1);
- **in air:** the charge as TNT by its heat of detonation (1.13 for C4, UFC 3-340-02 Table 2-1),
  the panel 1 m above rigid ground on two rigid supports (the rig's height is not given), air of
  5 cm;
- or, without air, the measured reflected pulse at the middle applied over the whole panel.

| Test | Charge, sheet | Measured first / final (mm) | In air, first / final (mm) | Measured pulse over the whole panel, first (mm) |
|---|---|---|---|---|
| 3 | 0.5 kg, 1.5 mm | −22 / 0 | −23.5 / −1.5 | −29 |
| 4 | 1.0 kg, 1.5 mm | −34 / 0 | −46 / +23 | −60 |
| 6 | 1.0 kg, 1.5 mm | −41 / not given | −46 / +23 | −77 |
| 1, 2 | 1.5 kg, 1.5 mm | −52, −71 / +30, +19 | −68 / −122 | −86, −88 |
| 7 | 0.5 kg, 0.75 mm | −50 / +4 | −45 / −14 | −72 |
| 8, 10 | 1.0 kg, 0.75 mm | −76, −71 / +14, +23 | −83 / −47, screws pulled | −401, −245 |
| 11, 12 | 1.5 kg, 0.75 mm | −110, −101 / −13, +6 | −115 / −63 | −365, −272 |

The air's centre reflected impulse is 0.78–1.42 of the gauge's, its peak about half (5 cm air
rounds it off). Tests 1 and 2 are filtered at 15 Hz (ADBLAST's note), so their peaks are low.

What this shows:
- **In air, the first peak is 0.95–1.35 of measured**: 1.5 mm 0.95–1.35, 0.75 mm 0.90–1.16.
  Repeated shots with the same charge scatter by up to 1.4 in measured deflection, as much as the
  model's spread about them.
- **The measured centre pulse over the whole panel over-reads by 1.3–5 times.** The ends and
  corners are 4 m from the charge, not 3.5, and the blast wraps under the panel. The load's spread
  is the difference: the coupling to the air is what the comparison needs.
- **What is left after was not right; nearer since the fold.** The 1.5 mm sheets ended level or
  lifted (ADBLAST: they lifted in every test, as the buckles formed in the first loading changed
  their shape). The 0.75 mm sheets ended within 23 mm of level. Before the buckled flanges kept
  their folds, the model left the 1.5 mm sheets 1.5–122 mm down, and the 0.75 mm 14–63 mm down
  (the table above, run then). With the fold, the default since 19 October 2026
  ([below](#what-is-left-scoped)):
  - the 1.5 mm sheets end 2 mm down to 5 mm up;
  - the 0.75 mm sheets end 14–40 mm down.

  The buckle's own shape is still not modelled.
- **The screws**: ADBLAST does not report screws pulling through in these tests. The model pulls
  them through at one tube at 1.0 kg on 0.75 mm. That is the safe side for debris, or a fault of
  the screws' strength without its rate, or both.

ADBLAST also shot four sheets on a U 60 purlin with the screws (its Table 17), where the 0.75 mm
sheets pulled through and the purlin took the impulse. Those are not compared: the table gives
no test's charge, and the purlin's span is not drawn. The project's deliverables (D4, D5, D6)
would give both ([data survey 3i](data-survey.md#3i-profiled-cladding-on-its-fixings)).

### Substructure desk stage, 21 October 2026

The [stage-one fixture audit](../Fixtures/ADBLAST2015/substructure/README.md) keeps Table 17's
12 rows, its missing values and the two impulses that disagree with Table 16. The TR35 profile
now uses Figure A5's dimensions. The charge-selection helper takes only measured and predicted
impulses; the declared rule is the nearest absolute impulse, ties to the smaller mass, before
judging any mechanical outcome.

**Recorded stop:** the draft plan's sources do not establish the blast rig's U-60 span or bounds.
Figure 21 is undimensioned; Annex A-40 describes different U-240 purlins. The two 1.27 m spans
are from the static tests and remain candidates for the blast rig. The fixture distinguishes
these from reported inputs. No air shots or deforming-purlin harness have run, and the standing
and defaults remain unchanged.

## In the one-way damage of envelopes

An envelope's walls, and separately its roof, can be profiled steel sheeting. In the editor, the
envelope's **Construction** gives:
- the roof's kind;
- each sheet's profile;
- the spacing of the rails and purlins it spans (1.8 m unless said);
- whether it is continuous over them;
- its screws per metre at each rail;
- the rails' steel thickness.

A sheeted component spans one way between its rails or purlins, whatever its own size, under the
load on the middle third of it across the span (its strip, [equivalent uniform
loads](building-envelopes.md#envelope-components-and-their-pressure-histories)): its ribs span on
their own, so the most loaded ones, away from the edges the blast clears round, are what count. The method
is UFC 3-340-02 §5-34, cold-formed steel panels (`EnvelopePanel.profiledSheetOneWay`):

- the dynamic design stress is the nominal yield × 1.21 (average strength) × 1.1 (dynamic increase,
  whatever the rate), eq. 5-26;
- the ultimate resistance is r_u = 7.2 M⁺/L² for a single span, or 3.6 (M⁻ + 2M⁺)/L² for the first
  span of a continuous sheet (eqs. 5-29, 5-30). M⁺ and M⁻ are the effective section moduli at the
  ultimate times the design stress (§5-34.2; `SheetProfile.designModulus`). The sheet hangs crests
  out, so pushed in, the span's middle compresses its crests and a continuous sheet's supports its
  troughs. Each modulus is:
  - the maker's, where given, the same both ways;
  - otherwise, by the compressed flat's class (EN 1993-1-1 Table 5.2):
    - class 1 or 2 (b/t up to 38ε): the plastic modulus;
    - otherwise: the elastic modulus with that flat at Winter's effective width, ρ = (λ − 0.22)/λ²
      for λ = √(f_y/σ_cr) past 0.673, σ_cr the flat's buckling stress as a plate held on both edges
      (EN 1993-1-5 §4.4). A class 3 flat stays whole.

  Langdon's narrow flange is class 1. ADBLAST's TR84 crests, at b/t 67 and 133, are class 4, held at
  61% and 34% of their width;
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

With 3 screws a metre into 2 mm rails, that is 2.1 kN a screw, 6.2 kN/m. Pushed in, the sheet bears
on its rails; only coming back out, or sucked, does it pull on its screws. The reaction pulling it
off is UFC Table 3-9's dynamic reaction of a uniformly loaded span, 0.39 R + 0.11 F:
- R is the resistance at the sheet's furthest outward deflection;
- F is the largest suction, per metre width.

When that passes what the screws hold, the sheet is blown off its fixings (`EnvelopePanel
.sheetPullOff`): failed, at the time of its rebound.

Verified against the formulas by hand (`ProfiledSheetTests`, "Sheeting in the one-way model").

### Against ADBLAST's cladding as an envelope

The same ten ADBLAST tests ([above](#against-adblasts-cladding-tests)), with the sheets as an
envelope's construction (`AdblastCladdingTest.envelope`, `blastbench adblast --envelope`):
- **The construction:** TR84 on a single span of 2.46 m, at S320's nominal yield. Its design
  stress, 426 MPa, lies within the coupons' 420–439 MPa at 2.3 /s.
- **The screws:** one per trough, holding until the sheet pulls over its washer, as the shells'.
- **The panel in air:** the same panel, as a rigid envelope in the same place, with the same
  charge and air as the shells' run.
- **The load:** recorded as an envelope's damage takes it ([equivalent uniform
  loads](building-envelopes.md#envelope-components-and-their-pressure-histories)). *Strip* is the
  middle third across the span, the ribs where the deflection was measured, weighted along the span
  by a hinge at the middle; it is what a sheeted roof or wall is judged on. *Plate* weights every
  face by that shape both ways, as a solid slab is judged. *Whole* is the plain mean.
- **Measured pulse:** the measured centre pulse over the whole span, as for the shells.

The air's load depends only on the charge, so one run serves every test of it.

| Test | Charge, sheet | Measured first (mm) | Shells in air | One-way, strip | Plate | Whole | Shells, measured pulse (mm) | One-way, measured pulse (mm) |
|---|---|---|---|---|---|---|---|---|
| 3 | 0.5 kg, 1.5 mm | 22 | 1.07 | 1.05 | 1.18 | 1.36 | 29 | 29 |
| 4, 6 | 1.0 kg, 1.5 mm | 34, 41 | 1.35, 1.12 | 0.91, 0.76 | 0.85, 0.71 | 0.74, 0.61 | 60, 77 | 63, 83 |
| 1, 2 | 1.5 kg, 1.5 mm | 52, 71 | 1.31, 0.96 | 0.88, 0.65 | 0.81, 0.59 | 0.67, 0.49 | 86, 88 | 97, 100 |
| 7 | 0.5 kg, 0.75 mm | 50 | 0.90 | 0.74 | 0.68 | 0.58 | 72 | 76 |
| 8, 10 | 1.0 kg, 0.75 mm | 76, 71 | 1.09, 1.17 | 0.96, 1.03 | 0.88, 0.94 | 0.74, 0.79 | 401, 245 | 529, 284 |
| 11, 12 | 1.5 kg, 0.75 mm | 110, 101 | 1.05, 1.14 | 1.00, 1.09 | 0.92, 1.00 | 0.75, 0.82 | 365, 272 | 484, 314 |

The in-air columns are ratios to the measured deflection.

What this shows:
- **Given the same load, the one-way model is the shells' to within 1.0–1.35**, on the safe side.
  Its stiffness is the beam's. Its strength is a little below the shells', which have membrane
  action from the screws in bearing along the span.
- **On the strip it reads 0.65–1.09 of measured, the shells 0.90–1.35.** Repeated shots scatter by
  up to 1.4 (tests 1 and 2: 52 and 71 mm), as much as either model's spread about them. The lowest
  three, 0.65–0.76, are the second of a repeated pair or the lightest shot on thin sheet: the
  unsafe side by up to a third.
- **The whole component's mean reads 0.49–1.36, low on nine.** The side ribs carry a quarter less
  positive impulse than the middle ones, because the blast clears round the panel's long edges.
  Weighting the plate by its shape gains half of that back; the strip gains the rest.
- **The clearing's suction is as strong as the sheet.** The air's load has −20 to −40 kPa of
  suction after the positive phase, about the sheets' resistance (19.6 kPa at 1.5 mm, 8.2 kPa at
  0.75 mm). The suction swings the sheet back up by 22–56 mm. The 1.5 mm sheets did lift: they
  were left 19–30 mm up at 1.5 kg. This is also why the 0.5 kg shot on 1.5 mm reads higher on the
  whole panel than the 1.0 kg one: the sheet swings back down after the suction.
- **The resistance was set by UFC's method, not fitted:** the effective section at the ultimate for
  a slender flat, not the plastic modulus as before. That lowers r_u to 0.69 of the plastic
  modulus's at 1.5 mm and to 0.57 at 0.75 mm. A stronger backbone from the shells, with their
  membrane action, would read lower still, so no resistance or stiffness taken from the shells
  narrows the gap. The gap was in how a component's load was summed.
- **The grading is the safe side.** All ten are heavy or hazardous, and 11 and 12 failed, mostly
  by their rebound's support rotation. ADBLAST found the sheets buckled and set, but none came off:
  the 1.5 mm sheets lifted, and the 0.75 mm ones were left within 23 mm of level.
- **The screws hold on all ten,** as in the tests. The shells pull them through at one tube on two
  (8, 10).

The standing is now an **approximation**: on the strip, within about the shells' band, reading
low by up to a third on three of ten.

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
- 32 mm sheets on the walls and 45 mm sheets on the roof, crests out, screwed to the rails and
  purlins with one self-drilling screw in every trough, pulling out of the Zeds' 1.6 mm at
  1.7 kN (EN 1993-1-3).

A sheeted neighbouring unit stands behind it as an envelope, and 100 kg of TNT stands 30 m from
the front gable. Meshed at 0.5 m it has 8,688 shells, 9,920 beams and 2,142 screw links, with a
16 µs step. At 90 ms, 430 of the links have let go and the front gable's middle has moved 177 mm
(234 with its sheets held for good) (`PortalWarehouseTests`).

## What is left, scoped

Two of the comparisons' misses, scoped on 19 October 2026 and not built.

**What is left after the blast: buckled shapes snapping through.** ADBLAST's 1.5 mm sheets ended
level or lifted, the buckles of the first loading having changed their shape; the model leaves
them 1.5–122 mm down or 23 mm up ([above](#against-adblasts-cladding-tests)). The ribs' local
buckling is a softening of their fibres, so the shell's geometry never takes the buckle's shape
and cannot snap back through it on the rebound or the negative phase. Two ways in. One is to let
the mesh carry the buckle: elements about a quarter of a flange (25 mm on TR84's 100 mm crest)
and a seeded imperfection of b/200 (EN 1993-1-5, Annex C). That is several times the elements, a
smaller step, and the rib fibres' softening switched off where the mesh resolves the buckle.
The other keeps the fibres but gives the buckled fibre a memory: a reversed stiffness and
strength once it has buckled, and a permanent shortening that pulls the section the other way.
That is cheaper but needs fitting. The data in hand judge either: ADBLAST's first and final
deflections on ten shots, signs included. Its deliverables D4–D6 would add histories
([data survey 3i](data-survey.md#3i-profiled-cladding-on-its-fixings)). For flat plates, Aune et
al. (IJIE 90, 2016, open on NTNU Open) measured reversed snap buckling by 3-D image correlation,
which would check the shells' snap-through on its own; no open test of profiled sheeting
snapping through was found.

**Built: the buckled flange's fold** (19 October 2026; the default since, `ProfiledSheet.foldMemory`,
`--no-fold` in `blastbench langdon` and `adblast` for the old behaviour). Of the two ways in above, the resolved mesh
cannot be built here: the shell mesher lays plates only along the axes, and the profiles' webs
slope (Langdon's at 45°). The memory needs no fitting once it is taken from plastic mechanism
theory rather than fitted:

- **The fold.** What a buckled flange shortens past its buckling is kept as a fold, a half-sine
  over the flange's width b, its amplitude w = (2b/π)√ε for a shortening ε.
- **Straightening it.** Tension pulls the fold straight at the strength of its plastic hinges.
  With hinges at its middle and ends, T w = 2 M_p with M_p = σ_y t² / 4, a stress of σ_y t / 2w,
  until the shortening is taken back. Without the option a buckled fibre is pulled back at its
  yield.
- **On the rib.** Carried to the rib's fibre as the onset is (strain by d / h, stress by h / d),
  the one parameter is πt/4b (h/d)^(3/2): 0.015 for TR84 at 1.5 mm.

The fold changes only fibres on a flange that buckles, and nothing until one has; off, the runs
are bit-identical.

| Test | Measured final (mm) | Without (mm) | With the fold (mm) |
|---|---|---|---|
| 1, 2 (1.5 kg, 1.5 mm) | +30, +19 | −121 | −2 |
| 3 (0.5 kg, 1.5 mm) | 0 | −1.5 | −0.2 |
| 4, 6 (1.0 kg, 1.5 mm) | 0, not given | −1.7 | +5.2 |
| 7 (0.5 kg, 0.75 mm) | +4 | −14 | −14 |
| 8, 10 (1.0 kg, 0.75 mm) | +14, +23 | −64 | −27 |
| 11, 12 (1.5 kg, 0.75 mm) | −13, +6 | −62 | −40 |

The table is ADBLAST in the air (`profiled-sheeting/fold/` on StudioData).

- **ADBLAST's final sets move the right way.** The mean miss falls from 66 to 27 mm. Every test
  is nearer, but for test 4, which ends 5 mm up where it ended level. The 1.5 mm sheets end
  level or lifted, as ADBLAST saw. The first peaks are unchanged (within 1 mm).
- **Langdon's tests hardly move.** Only the negative direction changes, where the wide flange
  buckles: its permanent sets fall 1–5%, a little further under, nine of twelve still within half
  to twice. The design direction is unchanged: its compressed flange does not buckle.

Made the default on 19 October 2026, the user agreeing.

**Buckling earlier than plate theory says.** Three of Langdon's tests miss
([above](#against-langdons-corrugated-panels)). In c1212 and c1803 the compressed flange is the
narrow one, 45 mm, whose plate buckling stress is 1.4 GPa (λ_p 0.50), and yet the panels dished
at their centres. In c1801-4 the moment stays just under the wide flange's σ_cr. An effective-width
knock-down (EN 1993-1-5's ρ) does nothing below λ_p 0.673, so the narrow flange's miss is not the
flange alone. It is the corrugation flattening under curvature (Brazier's ovalisation), with the
web–flange junctions turning, which a beam fibre cannot represent. Again two ways in: the
resolved mesh with its imperfection, as above, which would show the dishing directly; or a
section-flattening term on the ribs that lowers their moment with curvature, fitted to Langdon's
three tests and checked on the other thirty. Open data: Langdon's thesis (in hand, 33 tests, with
her quasi-static tests on partially restrained panels that failed by local buckling at the
corrugations' centres; Langdon and Schleyer, Exp. Mech. 2006), and a 2025 static study of twelve
full-scale trapezoidal sheets in which eleven yielded before their design capacity and half were
16–105% softer than Eurocode's elastic stiffness. That study is static, but it would show whether
the knock-down belongs to the section or to the test.

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
- V. Aune, E. Fagerholt, K. O. Hauge, M. Langseth, T. Børvik, "Experimental study on the response
  of thin aluminium and steel plates subjected to airblast loading", *Int. J. Impact Eng.* 90
  (2016) 106–121, [NTNU Open](https://ntnuopen.ntnu.no/ntnu-xmlui/handle/11250/2457721).
- G. S. Langdon, G. K. Schleyer, the quasi-static tests of partially restrained corrugated panels,
  *Experimental Mechanics* (2006), [doi:10.1007/s11340-006-9026-4](https://link.springer.com/article/10.1007/s11340-006-9026-4).
- "Experimental-theoretical investigation of the strength and deformability of full-scale
  second-generation profiled sheeting samples" (2025),
  [PMC12471979](https://www.ncbi.nlm.nih.gov/pmc/articles/PMC12471979/).
