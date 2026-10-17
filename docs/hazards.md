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
inhabited building distance (K40), and for a cased charge DoD's default hazardous fragment
distance for items not tested, Table AP2.T2's "open" column (`107.87 + 24.14 ln Q` m under 45.4 kg,
not less than 71.9 m; `-251.87 + 118.56 ln Q` m to 204.1 kg; 381 m above). BombCAD's own
[hazardous fragment distance](fragments.md#hazard) is shown beside them as an **estimate**: it
reads short of DoD's test-derived distances by a sixth to a half
([fragments.md](fragments.md#against-dods-distances)), so it governs only where it is the larger.
The summary says which governs. A bare charge in the open takes K40 (DoD 4145.26-M
§C5.8.1.7.1.8).

These are distances for a bare charge in the open: they do not see the scene's buildings,
channelling or shielding, which the run's own fields below do.

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
  100 kg, 294 m, governs: **the minimum safe distance is 294 m**. BombCAD's own estimate, 172 m in
  flight, is shown beside it.

## Limitations

- The injury curves come from animal tests (sheep, pigs, goats, dogs and others) under single,
  ideal, free-field pulses, scaled to a 70 kg adult; the run's pulses, reflected and channelled,
  are taken as triangular. Bass's curve holds under 30 ms; longer pulses are judged by the
  eardrums and Bowen's threshold alone.
- No tertiary injury (a person thrown against something: UFC 3-340-02 names 2.3 psi as where
  people in the open may be thrown off balance) and no quaternary injury; fragments and debris
  are [their own hazards](fragments.md#hazard).
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

## Sources

- DoD 4145.26-M, *DoD Contractor's Safety Manual for Ammunition and Explosives*, 2008: §C5.6.2,
  §C5.18.6.3, the K-factor distances in both units.
- UFC 3-340-02, *Structures to Resist the Effects of Accidental Explosions*, 2008, §1-11: eardrum
  rupture, lung thresholds, the effective pressure by orientation, 2.3 psi.
- J. A. Teland, *Review of blast injury prediction models*, FFI-rapport 2012/00539, Norwegian
  Defence Research Establishment: Bowen's and Bass's curves, and their distances (Table 12.1).
- I. G. Bowen, E. R. Fletcher and D. R. Richmond, *Estimate of man's tolerance to the direct
  effects of air blast*, DASA-2113, 1968 (as Teland gives it).
- C. R. Bass, K. A. Rafaels and R. S. Salzar, Pulmonary injury risk assessment for short-duration
  blasts, *Journal of Trauma* 65 (2008) 604–615 (as Teland gives it).
