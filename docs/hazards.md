# Blast hazards: safety distances and injury

Beside the [hazardous fragment distance](fragments.md#hazard), every run gives the blast's own
hazards: the US explosives safety standards' K-factor distances for its charge, the minimum safe
distance and whether overpressure or fragments govern it, and how far the blast injures a person
standing in the scene, from the run's own peaks.

**Standing: approximation.** The injury curves are published, recognised methods, and their free
field is checked against their own published distances; they come from animal tests under ideal
pulses, and nothing here is compared with injuries. The K-factor distances are policy, not
predictions. Not for medical triage or casualty estimates.

## Where to see them

- **In the app**, the sidebar's Hazards section lists the K-factor distances, the minimum safe
  distance with what governs it, and, after a run, how far each injury level reaches at standing
  height. Under Display, **Safety distances and injury** draws the K24 and K40 distances (and the
  minimum safe distance where fragments govern it) as blue rings, and after a run the injury's
  contours on the ground: amber where eardrums begin to rupture, dark red where half would die.
- **Headless**, `BombCAD run` prints them as `Hazards:` lines.
- **`blastbench hazards [--mass 100] [--fragments spec.json]`** gives the K-factor distances, the
  minimum safe distance and the free field's injury radii for a charge on the ground, in the open
  and against a wall.

## Safety distances

DoD 4145.26-M (2008), the DoD contractors' manual (open on epa.gov), gives each distance as
`D = K W^(1/3)`, both as K in ft/lb^(1/3) with W the net explosive weight in lb and in
m/kg^(1/3) with W in kg (K × 0.3967), for TNT-equivalent weight (`KFactorDistance`):

| K | m/kg^(1/3) | Overpressure the standard names | Use | DoD 4145.26-M |
|---|---|---|---|---|
| K18 | 7.14 | 3.5 psi (24 kPa) | Unbarricaded intraline distance | §C5.6.2.4 |
| K24 | 9.52 | 2.3 psi (15.8 kPa) | Public traffic route distance | §C5.6.2.5 |
| K40 | 15.87 | 1.2 psi (8.3 kPa) | Inhabited building distance (K40 to K50) | §C5.6.2.7 |
| K328 | 130.1 | — | Non-essential personnel at intentional detonations, not less than 381 m | §C5.18.6.3 |

The **minimum safe distance** is never shorter than the published distance that applies: the
inhabited building distance (K40); for a charge inside a building (within an envelope's or a
structure's bounds), DESR 6055.09's distance for debris from a structure (Edition 1 Change 2, Table
V3.E3.T2's "Structure" column: 61 m to 14.1 kg, `-251.87 + 118.56 ln Q` m to 204.1 kg, 381 m
above); and for a cased charge DoD's default hazardous fragment distance for items not tested, Table AP2.T2's "open" column (`107.87 + 24.14 ln Q` m under 45.4 kg,
not less than 71.9 m; `-251.87 + 118.56 ln Q` m to 204.1 kg; 381 m above). BombCAD's own
[hazardous fragment distance](fragments.md#hazard) is shown beside them as an **estimate**: it
reads 0.58–1.02 of DoD's test-derived distances, up to two-fifths short
([fragments.md](fragments.md#against-dods-distances)), so it governs only where it is the larger.
BombCAD's own [envelope debris distance](#debris-from-failed-envelope-components) is likewise an
estimate beside them, governing only where larger. The summary says which governs. A bare charge in the open takes K40 (DoD 4145.26-M
§C5.8.1.7.1.8).

These are distances for a bare charge in the open: they do not see the scene's buildings,
channelling or shielding, which the run's own fields below do.

## Debris from failed envelope components

When envelope damage judges a wall, roof or pane failed, it throws its debris (`EnvelopeDebris`,
since 18 October 2026), and the run's hazards judge where it lands as they judge fragments:
hazardous where more than one piece of 79 J or more lands per 55.7 m² (DDESB TP-21 §4.2), in the
fragments' rings and sectors.

- **Launch speed:** the one-way model's own speed at failure, UFC 3-340-02 §4-58.2.1 (Equation
  4-187: the load's impulse less the resistance's, over the effective mass), at the point of
  largest deflection. A piece elsewhere on the component takes that times its place on the
  mechanism's shape, as UFC says: "from a maximum at the point of maximum deflection to zero at
  the supports" ([equivalent loads](building-envelopes.md#envelope-components-and-their-pressure-histories)).
- **When it fails:**
  - masonry, when it has lost its resistance (fallen);
  - glass, when it breaks;
  - concrete, as it passes 10° of support rotation;
  - CLT, as it passes ductility 2;
  - sheeting, when its screws pull off, at the furthest of its rebound.
- **After failure:** concrete, masonry and timber fly at that speed ("the maximum velocity of the
  fragment after failure vf is equal to the maximum velocity of the element at incipient failure
  vi"): broken up, the gas leaves round them. Glass and sheets, thin and whole, go on being pushed
  by the load still on them until it turns, as the [glazing hazard](building-envelopes.md) takes
  a pane.
- **Direction:** each section turns about the held edge nearest it, so each piece leaves square
  to its section as turned at failure (10° for concrete), towards that edge. The upper half of a
  wall leaves a little upwards, the lower half a little downwards, and a toppling wall's bricks
  downwards.
- **Pieces** (assumptions):
  - masonry: its bricks, 215 × 65 mm through a leaf;
  - concrete: rubble cubes of half its thickness;
  - annealed glass: 50 mm shards; laminated glass: the pane whole;
  - sheeting: a metre of sheet between rails;
  - CLT: 0.3 m strips.

  Each component's face is sampled 16 × 16 ways, each sample standing for its share of the pieces.
- **Flight:** with the fragments' drag (a tumbling body of its mean presented area) through still
  air. Pieces stop on the scene's blocks and on the buildings' solids that did not fail, and land on
  the ground or terrain.

In the app the debris's rings join the fragments' under Display, and the Hazards section gives its
line and the minimum safe distance with it. Headless, it is a `Hazards:` line, with
`--envelope-damage`. `blastbench envelope-debris` runs the Kasun cubicle below;
`blastbench envelope-walls` runs Keys's walls.

**Against measurement:**
- **Keys's brick walls** (Keys, 2016; 41 kg TNT at 10.6–15 m, 2 m single-leaf walls falling as
  cantilevers, `Fixtures/Keys2016`): their debris's mass-weighted mean reach is 0.31–0.59 m from
  the wall's face, against 0.23–0.64 m measured; the median 0.25 m, as measured; 90% within
  0.75–1.25 m against 1.25–2.25 m; the furthest 1.0–1.5 m against 3–6 m (on the mapped start since
  19 October 2026; on the balloon, 0.25–0.53, 0.25–0.75 and 0.5–1.5 m). Bricks that bounce and
  roll are not modelled, so the far tail is short. None lands with 79 J (a brick falling 2 m
  carries about 55 J), so none is hazardous.
- **The Kasun cubicle** (Norwegian and Swedish tests: 2 × 2 × 2 m inside, 0.15 m reinforced
  concrete, 80 kg inside):
  - launch: the walls and roof fail at 2.6–2.8 ms, their pieces leaving at up to 118–131 m/s,
    against the Klotz Group's debris launch velocity, 525 √(γ L / M) = 124 m/s (Weerheijm and
    Conway, IESS 2018);
  - venting: the failed walls and roof open in the air from 2.6 ms, and the gas leaves. The
    overpressure inside, 12.9 MPa at 2 ms, is 61 kPa at 5 ms, 25 kPa at 20 ms and 1 kPa at
    30 ms. Shut, it stays at 12–18 MPa.
  - reach: hazardous debris to 129 m, its furthest hazardous piece at 258 m, against the tests'
    1 per 56 m² at 290–315 m (Kummer, IESS 2018, Fig. 11; the Klotz Group's tool 260 m). That is
    under half, the unsafe side. Here the pieces are 1 kg cubes leaving within 10° of square to
    their sections; the tests' spread of sizes and angles is not modelled. DESR's structure
    distance for 80 kg, 268 m, governs the minimum safe distance.
  - on the mapped start, since 18 October 2026 (`--balloon-start` for the balloon these were run
    on): the walls fail 0.2 ms sooner and leave at under 1% less speed. The reach is 129 m, and
    the furthest hazardous piece 256 m. Kasun III's speeds below are the same on either start, within
    1 m/s.
- **Kasun III's launch speeds** (the same cubicle, its bars 12 mm at 100 mm in both faces; Weerheijm,
  Stolz, Riedel and Mediavilla, TU Delft repository, Table 2, from high-speed film). PETN is taken
  as 1.27 TNT, and the bench builds the cubicle with these bars (1.5% of the section). At failure,
  at the largest deflection:

  | Charge | Measured, mean (least) | The model | The Klotz Group's formula |
  |---|---|---|---|
  | 6.9 kg PETN | 52 m/s (29) | 44–49 m/s | 41 m/s |
  | 110 kg PETN | 224 m/s (173) | 171–192 m/s | 164 m/s |

  The light charge reads 0.84–0.95 of the measured mean, the heavy one 0.76–0.86, near its
  least. At 14 kg/m³ the shock adds to the gas pressure that the one-way model is driven by.

**Why Kasun's reach is short** (18 October 2026). `blastbench envelope-debris --levers` throws the same
failed walls with one thing changed at a time, at 80 kg:

| Changed | Hazardous to | Furthest hazardous piece |
|---|---|---|
| Nothing (1 kg cubes, 10° off square) | 129 m | 258 m |
| Cubes of 0.3 kg / 8.1 kg / 32 kg | 189 / 73 / 41 m | 208 / 349 / 400 m |
| Drag halved / doubled | 142 / 129 m | 349 / 176 m |
| Launched square / 20° / 45° off it | 60 / 172 / 189 m | 57 / 334 / 348 m |

No one lever reaches the tests' 290–315 m. Small pieces give the density but not the range;
large ones the range but not the density. The tests had both, a spread of sizes and of angles,
which the model has not. The open record does not give the spread:
- Kasun's piece masses, their pickup by distance, and any bounce and roll are in the FOI and
  Forsvarsbygg reports (FOI-R--2202--SE for 80 kg), which are to be ordered;
- the Kasun III database is in a DDESB seminar paper that could not be reached;
- DDESB TP-21 treats bounce and roll only in words.

MSIAC's plot of Kasun's inhabited building distances (van der Voort et al., IESS 2018) reads about
330–380 m near 80 kg, longer still. The model is left as it is, its reach recorded as under half,
and DESR's structure distance stands under it. The reports wanted are in
[Data wanted](data-wanted.md#to-request).

## Injury

The blast wave's own injury to a person (`BlastInjury`), for an ideal (Friedlander) pulse of
incident overpressure p and positive duration T, T scaled to a 70 kg adult at sea level:

| Level | Criterion | Source |
|---|---|---|
| Eardrum rupture threshold | 5 psi (34.5 kPa) | UFC 3-340-02 §1-11 |
| 50% eardrum rupture | 15 psi (103 kPa) | UFC 3-340-02 §1-11 |
| Lung injury threshold | A fifth of Bowen's 50% lethality, `423 (1 + 6.76 T^-1.064)` kPa (reflected) | Bowen et al. (1968), as Teland (2012) gives it |
| 50% lethality (lung) | `89.5 (1 + 6.7 T^-0.83)` kPa incident, T under 30 ms | Bass et al. (2008), as Teland gives it |

**Where the person stands.** In the open, the eardrums and Bowen's threshold take the incident
pressure plus the dynamic pressure, `5p² / (2p + 14 p0)`; **against a wall facing the charge** the
person sees the **reflected** pressure, `(8p² + 14 p p0) / (p + 7 p0)` (UFC: "the highest of
either the incident pressure, the incident pressure plus the dynamic pressures, or the reflected
pressure"). Bass found no difference between the two for lethality and takes the incident
pressure for both. Both stances are given.

**From the run's own fields.** Every run records, on a plane of probes at 1.5 m (a standing
person's chest and head) at the air's cell spacing, each point's peak overpressure and positive
impulse (`BlastSolver.configureExposurePlane`), which does not change the air. When the run ends,
each probe's level is worked out for both stances (`InjuryField`), the positive phase taken as
triangular (duration twice the impulse over the peak). So the levels follow the scene: channelled
down a street, shielded behind a building, reflected beside walls. Probes whose cells touch a
solid are not read, so a person flat against a wall is the "against a wall" stance's estimate,
not a probe.

## Checks

- **The curves against their own published distances.** Teland (FFI-rapport 2012/00539, Table
  12.1) gives the distances at which TNT in free air reaches 50% lethality by Bass's curve and by
  Bowen's against a wall, from 0.5 to 1,500 kg, from ConWep's blast parameters. From the
  Kingery–Bulmash curves (a free-air burst as a surface burst of 1/1.8 its mass), BombCAD's are
  within 6% (Bass: 0.98 against 1.01 m at 0.5 kg, 12.0 against 12.4 m at 200 kg, 26.7 against
  26.6 m at 1,500 kg) and within 5% (Bowen) (`BlastInjuryTests`).
- **The K-factor distances**: Kingery–Bulmash's surface burst at K18, K24 and K40 gives incident
  overpressures within a fifth of the 24, 15.8 and 8.3 kPa the standard names.
- **The run's own fields against the free field**: 10 kg on open ground, 0.25 m cells, probes at
  1.5 m (`InjuryFieldTests`): the eardrum threshold reaches 11.5 m against the free field's 13.1 m,
  50% eardrum rupture 6.6 against 7.6 m, the lung's threshold 4.3 against 6.2 m and 50% lethality
  2.2 against 4.5 m. Past a few metres within 15%; closer in, the cells' peaks read low (as
  [validation.md](validation.md#kingerybulmash-the-design-practice-standard) records), the unsafe
  side: refine the air near the charge for close-in injury.

## A worked example

100 kg of TNT on the ground (`blastbench hazards --mass 100`):

- K18 33 m, K24 44 m, **K40 74 m**, K328 604 m (the standard's minimum there, 381 m).
- In the open, from the free field: the eardrum rupture threshold to 28 m, 50% eardrum rupture to
  16.5 m, the lung injury threshold to 15.6 m, **50% lethality to 11.5 m**. Against a wall facing
  it: 44, 23, 22 and 11.5 m.
- Bare, the **minimum safe distance is 74 m, overpressure (K40) governing**. In a 150 kg steel
  cylinder (12 mm wall, 250 mm bore, 1 m up; `--fragments`), DoD's default fragment distance for
  100 kg, 294 m, governs: **the minimum safe distance is 294 m**. BombCAD's own estimate, 208 m in
  flight, is shown beside it.

## Limitations

- The injury curves come from animal tests (sheep, pigs, goats, dogs and others) under single,
  ideal, free-field pulses, scaled to a 70 kg adult; the run's pulses, reflected and channelled,
  are taken as triangular. Bass's curve holds under 30 ms; longer pulses are judged by the
  eardrums and Bowen's threshold alone.
- No tertiary injury (a person thrown against something: UFC 3-340-02 names 2.3 psi as where
  people in the open may be thrown off balance) and no quaternary injury; fragments and debris
  are [their own hazards](fragments.md#hazard).
- **Envelope debris:**
  - its pieces' sizes are assumed;
  - launch angles come only from the sections' turn at failure;
  - pieces neither bounce, roll nor break on landing;
  - against the Kasun tests its hazardous reach is under half.
- One standing height (1.5 m); probes beside a solid are not read, and close in the cells' peaks
  read low.
- K-factor distances: the primary charge only, as a bare charge in the open; additional charges
  are not added.
- Not for medical triage or casualty estimates.

## Future work

- Bass's long-duration curves (Rafaels et al., 2010) and his threshold curves, from the papers
  themselves (not read here).
- Whole-body translation (tertiary injury), if open data supports a criterion.
- Probes at a prone height, and a person against each wall read from the wall's own surface
  pressures.
- Envelope debris: a mass distribution by loading density (DDESB TP-14 Revision 5, not open in
  full); launch angles spread as tests show; bounce and roll.

## Sources

- DoD 4145.26-M, *DoD Contractor's Safety Manual for Ammunition and Explosives*, 2008: §C5.6.2,
  §C5.18.6.3, the K-factor distances in both units.
- UFC 3-340-02, *Structures to Resist the Effects of Accidental Explosions*, 2008, §1-11: eardrum
  rupture, lung thresholds, the effective pressure by orientation, 2.3 psi.
- J. A. Teland, *Review of blast injury prediction models*, FFI-rapport 2012/00539, Norwegian
  Defence Research Establishment: Bowen's and Bass's curves, and their distances (Table 12.1).
- I. G. Bowen, E. R. Fletcher and D. R. Richmond, *Estimate of man's tolerance to the direct
  effects of air blast*, DASA-2113, 1968 (as Teland gives it).
- DESR 6055.09, *DoD Explosives Safety Regulation*, Edition 1 Change 2 (2025), Table V3.E3.T2:
  the hazardous fragment distances, "Open" and "Structure".
- DDESB Technical Paper 21, Revision 2 (Swisdak, Tatom and Conway, 2017), §4.2: the hazardous
  debris density, 1 per 55.7 m² at 79 J.
- UFC 3-340-02 (2008) §4-57 and §4-58.2.1: post-failure fragments and their velocity (Equation 4-187).
- J. Weerheijm and R. Conway, *The Klotz Group contribution to explosives safety*, NDIA IESS 2018:
  the debris launch velocity; S. Kummer, *A fast running model for lethality due to wall debris
  throw from above ground magazines*, NDIA IESS 2018, Fig. 11: the Kasun tests' debris density.
- R. A. Keys, *Experimental & computational structural analysis of masonry panels subject to long
  duration blast loading*, PhD thesis, University of Southampton, 2016, and R. Keys and S. K.
  Clubley, *Engineering Structures* 130 (2017) 229–241: the brick walls' debris
  (`Fixtures/Keys2016`).
- C. R. Bass, K. A. Rafaels and R. S. Salzar, Pulmonary injury risk assessment for short-duration
  blasts, *Journal of Trauma* 65 (2008) 604–615 (as Teland gives it).
