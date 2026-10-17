# Cratering

What the ground under a scene is made of, the crater each charge digs in it, and the share of
the charge's energy the air keeps. This is stage 1 of two (see the
[roadmap](roadmap.md#effects-beside-the-blast)): an empirical crater, and the energy a charge
on soft ground gives to the ground instead of the air. Stage 2, a crater that forms coupled to the
blast, is not built.

**Standing: approximation for the crater's diameter, illustrative for its depth and lip.** The
diameter comes from P. W. Cooper's cube-root scaling with Kinney and Graham's scatter. Five of
six measured craters fall within that scatter, three of them the 500-ton TNT shots at Suffield
([below](#against-measured-craters)). The depth is a rule of thumb in dry ground. Below a shallow
water table the walls slump to Glasstone and Dolan's 10–15°. That brings the three wet sites'
depths within 0.84–1.41 of the estimate, against 0.19–0.31 by the dry rule
([below](#below-a-water-table)). The air's share on soft ground is an approximation, the same for
every soil.

**The crater does not act on the blast.** A crater forms over a time of order √(D/g): about
0.4 s for 100 kg, seconds for a kiloton. By then the blast has gone, and most runs have ended.
So the air keeps the ground as it was before the blast, and the crater is worked out from the
scene, reported and drawn when the run ends. The one effect of the ground that does reach the
air is the energy it takes ([below](#the-air-on-soft-ground)).

## Choosing the ground

In the app, the Run tab's Terrain section has a **Made of** picker:

- **Rigid ground**, the default: the reflecting ground the air model has always had. No crater,
  no energy lost, and debris stops dead.
- **Soil under debris only**: the soft ground under structures' debris (`groundStiffness`, a
  Winkler bed), as before 17 October 2026, and nothing else.
- **Earth or rock**, the rows of Cooper's table of cratering efficiencies (below). Each digs a
  crater and leaves the air less of a charge near it. It also puts the debris on soil, with a
  subgrade modulus to match, which the stiffness slider can still change.

Under earth or rock, **Water table near the surface** and its depth set where the water table is
(see [below](#below-a-water-table)). Choosing saturated soil turns it on, with the water at the
surface; the other types leave it off, deep enough not to matter. A caption under the picker
gives the crater the charge would dig.

The ground type and the water table are saved with the project's run settings (`ground` and
`waterTable` in `settings.json`, left out for rigid ground and a deep water table). Both are part
of the run's fingerprint: the ground because it changes the air, the water table as a run input
beside it.

Headless, `--ground` takes a type as well as `rigid`, `soil` or a modulus, and `--water-table`
takes a depth in metres or `deep`:

```bash
swift run -c release BombCAD run street.bombcad --ground glacialSoil --water-table 1.5 --usd street.usda
```

The summary then ends with a line per crater. For 500 t of TNT on glacial soil, for example:
"Crater in glacial soil: 67.7 m across (45.1–90.3), 16.9 m deep, lip 4.23 m high out to 84.6 m".

| Type (`--ground`) | Cooper's site | E_CR | Debris modulus |
|---|---|---|---|
| Rock (`rock`) | Basalt and granite (Mice, Mine Shaft) | 0.20 | 150 MN/m³ |
| Soil over sandstone (`soilOverSandstone`) | Mixed Company, western Colorado | 0.25 | 150 MN/m³ |
| Dry lake bed (`playa`) | Nevada Test Site, New Mexico | 0.45 | 100 MN/m³ |
| Dry alluvium (`alluvium`) | Nevada Test Site, Cooper's reference | 0.50 | 50 MN/m³ |
| Clay over shale (`clay`) | Middle Gust, south-eastern Colorado | 0.55 | 50 MN/m³ |
| Glacial soil (`glacialSoil`) | Suffield, Alberta | 0.75 | 100 MN/m³ |
| Clay over claystone (`clayShale`) | Diamond Ore, Montana | 0.95 | 100 MN/m³ |
| Saturated soil (`saturated`) | Coral sand (Eniwetok), saturated clay (Middle Gust) | 2.00 | 15 MN/m³ |

Cooper's table has eleven rows. Two near-duplicates are folded in, and his footnote says they
are "not all of equal confidence". The debris moduli are rough, within the range the soft-ground
setting already gave. Reclaimed fill below a high water table, like Beirut's port, belongs with
saturated soil.

## The crater

**Size.** The apparent crater's radius at the original ground's level is Cooper's equation 29.7:

R = K (2 E_CR W e^(−1.457 HOB))^(1/3)

- R is in feet, W is the TNT-equivalent mass in pounds, and E_CR is the cratering efficiency from
  the table above.
- K is 0.97 ft/lb^(1/3), Cooper's constant for TNT (his equation 29.3).
- HOB is the height of burst in charge radii; see [below](#height-of-burst).
- For TNT in the Nevada alluvium this is 0.77 W^(1/3) m across. That is close to Kinney and
  Graham's 0.8 W^(1/3) m, fitted to about 200 accidental explosions.

**One K for every explosive.** Cooper scales K with the explosive's detonation pressure, which
gives ANFO and ammonium nitrate about 0.61. BombCAD instead uses TNT's K for every charge's
TNT-equivalent mass. The two large ammonium-nitrate craters below fall within the scatter that
way (0.89 and 1.24 of the estimate), and outside it with ANFO's K (1.42 and 1.97). That choice
was made on these two events, so for them the check is not independent. BlastCore keeps both
(`CraterExplosive`), and `blastbench snapshot --explosive anfo` uses ANFO's.

**Scatter.** Kinney and Graham give a standard deviation of about a third of the diameter.
Every crater is reported with that one-sigma range. Cooper notes "quite a bit of significant
scatter", put down to mixed explosives and soils.

**Depth and lip.** Shape, from Cooper and Glasstone and Dolan:

- The apparent depth is half the radius (Cooper, p. 430; Kinney and Graham give a quarter of the
  diameter).
- The bowl is a paraboloid from that depth up to the original ground at the apparent radius.
- The lip rises to a crest a quarter of the depth high at 1.25 radii (Glasstone and Dolan,
  §6.71).
- Beyond the crest, the ejecta thin as the 3.86th power of the distance (§6.75), eased to nothing
  at 2.5 radii, the middle of their "two to three times" (§6.74).
- The lip then holds about two thirds of the bowl's volume. Glasstone and Dolan put the ejecta at
  55% of the apparent crater's mass, before counting the upturned rim.

### Below a water table

A water table near the surface keeps a crater shallow. In saturated soil with a high water table,
the walls slump and the crater becomes "shallower and broader", towards slopes of about 10 to 15
degrees (Glasstone and Dolan, §6.11). Water rushing in carries material that would have formed
the lip into the bottom. They also note "hydraulic fill" making a wet crater's final depth
shallower (§6.09), and a water table flattening and widening the crater (§6.78). GEER put
Beirut's shallow crater down to its water table 1.5 m below the quay.

BombCAD takes the slope as 12.5°, the middle of the range. A bowl whose rim slopes at θ is
R tan θ / 2 deep, so the apparent depth below a water table d_w metres down is:

D = min(D_dry, max(d_w, R tan θ / 2))

- The walls below the water slump to θ.
- The crater still reaches the water table, because the dry ground above it holds its shape.
- It is never deeper than in dry ground, so a water table below the dry crater changes nothing.
- 10° and 15° give the depth's range, reported with it. The lip, a quarter of the depth, comes
  down with it.
- The radius is left as it is. Glasstone and Dolan say wet craters are broader but give no figure,
  and saturated soil's cratering efficiency already digs wider.

**Why a slope and not a depth.** No open source gives a crater's depth as a function of the water
table's: not Cooper, nor Kinney and Graham, nor UFC 3-340-02. TM 5-855-1 and the crater databases
(AFWL-TR-71-144, Gould's DNA 6187F) were not to hand ([data wanted](data-wanted.md)). Glasstone
and Dolan's slope is the one open, quantitative statement. The measured wet craters' own depth
over radius sits inside it: 0.124 at Prairie Flat and 0.131 at Dial Pack, against 0.088–0.134 for
10–15°. Beirut's 0.077 is below it, where fill also flowed into the basin.

**True and apparent craters.** The true crater is the hole the charge digs. Fallback and slough
from its walls then fill part of it back, and what is left is the apparent crater (Cooper,
figure 29.1; Glasstone and Dolan, §6.70). Measurements and scaling laws, these included, are of
the apparent crater. No open source gives the true crater a ratio to it: the one figure found,
about 1.7 times the depth at a single dry site, is second-hand. So the true crater is not
estimated. In saturated, cohesive soil the two are said to be nearly the same.

### Height of burst

Cooper measures the height of burst from the ground to the charge's centre (his example 29.2).
BombCAD measures it to the charge's underside, so that a sphere resting on the ground counts as a
surface burst. The reason is the evidence. The two 500-ton TNT spheres fired resting on the
ground at Suffield dug craters within the scatter of the surface-burst law (1.26 and 1.04 of
it). Measured to their centres, a radius up, the law gives them half the measured diameters.
Cooper's constant was presumably fitted to bursts like these. A charge centred on the surface,
or below it, also counts as a surface burst. Above 3.2 charge radii, where under 1% of the
energy couples into the ground, there is no crater: it is an air burst. Cooper's examples are
still checked to his own measure (`CraterTests.cooperExamples`).

## The air on soft ground

On rigid ground a charge resting on the surface acts on the air as one of twice its mass in free
air (Glasstone and Dolan, §3.34). Real ground takes part of the energy into the crater and the
ground shock:

- **The share.** Kinney and Graham give a surface burst's apparent-to-actual yield ratio as 1.5 to
  2 (their example 8-7). Kingery and Bulmash, whose curves are for real ground, are reported to
  take 10% as absorbed: 1.8 (Aouad and others, 2021, citing ARBRL-TR-02555; not checked in the
  report itself).
- **Rigid ground:** a charge keeps all of its mass for the air, and the scene loads as before, to
  the bit.
- **Earth or rock:** a charge on the surface keeps 1.8 rather than 2, that is 0.9 of its mass, for
  every soil. No open source gives the share by soil type, beyond Glasstone and Dolan's remark
  that wetter ground couples more (§6.72).
- **Height.** The loss tapers with height as the share going into the ground does in Cooper's
  figure 29.7, e^(−1.457 HOB): about 33% on the surface, 1% at 2.4 charge radii.

The air's charges, balloon or mapped, are laid down with that mass (`Charge.coupled`). Nothing
here has been compared with a burst measured over soft ground. The standing names it as "Ground
that takes energy" and caps the peak and impulse at approximation. Its band is Kinney and
Graham's range: a mass between 0.75 and 1 of the charge's.

## Shown and exported

- **In the app,** the crater is shaded into the ground or the terrain when the run ends, never
  before. Its slopes come from the profile above, darker towards the bottom of the bowl, with its
  earth laid back over the air's colours. It is shaded rather than built, because the air model's
  ground is the domain's floor. The caption gives its size. Kept runs give it in Compare and in
  their CSV (apparent diameter, depth and lip height, at the run's end).
- **Headless,** the summary prints a line per crater.
- **USD export.** `--usd` and File ▸ Export for Rendering add `/Scene/Crater` (`Crater_1`, …): a
  patch of ground over each crater, flat until the run's last frame and cratered at it. The flat
  ground plane, or the terrain, is left open under the patch so the bowl shows. Its
  `bombcad:label` holds the crater's line.
- **`Terrain.cratered(_:)`** cuts the craters into a terrain for a scene that starts after the
  blast. The terrain must stand high enough: heights cannot go below z = 0, the air domain's floor,
  so raise its datum by more than the crater's depth first. Over a flat floor, use a terrain
  lifted above it.

![A crater in saturated soil shaded into the open ground after 100 kg of TNT, over the blast's peak overpressure: the bowl, the lip's crest and the ejecta thinning outwards](crater-open.png)

## Against measured craters

Predicted diameters are TNT's K on the TNT-equivalent mass, with each burst on the surface. The
band is one sigma. Where a figure is second-hand, it says so.

| Event | Charge | Ground | Predicted (band) | Measured | Measured over predicted |
|---|---|---|---|---|---|
| Prairie Flat, 1968 | 500 t TNT, sphere resting on the ground | Glacial soil, Suffield; high water table | 67.7 m (45–90) | 85.5 m across, 5.3 m deep | 1.26 |
| Dial Pack, 1970 | 500 short tons TNT, sphere resting on the ground | Glacial soil, Suffield | 67.7 m (45–90) | 70.1 m, 4.6 m deep (second-hand) | 1.04 |
| Snowball, 1964 | 500 short tons TNT, hemisphere | Glacial soil, Suffield; saturated | 67.7 m (45–90) | 73 m (second-hand) | 1.08 |
| Sailor Hat Bravo, 1965 | 500 short tons TNT, stack | Rock (basalt, unconfirmed), Kahoʻolawe | 43.6 m (29–58) | 69 m (second-hand) | 1.58 |
| Minor Scale, 1985 | 4,744 t ANFO, about 4 kt TNT, hemisphere | Dry lake bed, White Sands | 118 m (79–157) | 105 m, 24 m deep (second-hand) | 0.89 |
| Beirut, 2020 | Ammonium nitrate, 0.5 kt TNT (0.2–1.1) | Saturated fill | 97 m (65–129) | 117–124 m, 4–5 m deep | 1.24 |

- **Diameters.** Five of six fall within the band: the three Suffield shots, Minor Scale, and
  Beirut at its central yield. The last two sit within it only with TNT's K, the choice made on
  them (above). Sailor Hat's crater is half again as wide as rock's efficiency gives; its rock is
  unconfirmed, and if it was softer ground the gap closes. The estimate under-reads on average,
  by 1.18 over all six, as Glasstone and Dolan's remark that moist ground digs wider would lead
  one to expect.
- **Depths.** By the dry rule, the three wet sites' measured depths are 0.27 (Dial Pack), 0.31
  (Prairie Flat) and 0.19 (Beirut) of the estimate. With the water table near the surface, they
  are 1.23, 1.41 and 0.84 of it:

  | Event | Water table | Depth, dry rule | Depth, slumped (10–15°) | Measured | Measured over slumped |
  |---|---|---|---|---|---|
  | Prairie Flat | High: the crater "filled rapidly with water" | 16.9 m | 3.8 m (3.0–4.5) | 5.3 m | 1.41 |
  | Dial Pack | High, the same site | 16.9 m | 3.8 m (3.0–4.5) | 4.6 m | 1.23 |
  | Beirut | 1.5 m below the quay (GEER) | 24.2 m | 5.4 m (4.3–6.5) | 4–5 m | 0.84 |
  | Minor Scale | Deep (dry lake bed) | 18.5 m | — | 24 m (second-hand) | 1.32 of the dry rule |

  The Suffield shots' water-table depths were not found open: they are taken as within the slumped
  depth, which the craters' flooding implies, and any depth up to 3.8 m gives the same result. Two
  of the three wet craters lie within the slope's range once the radius's own under-reading is
  allowed for (Prairie Flat's radius is 1.26 of the estimate). Beirut is shallower still,
  0.04 of its diameter, "below the lower range" measured for large blasts (GEER), with its fill
  flowing into the basin. At dry White Sands, with no water table, the dry rule is 1.32 too
  shallow.
- **Beirut's yield.** Aouad and others found 257–287 t of TNT from the crater by another scaling
  law, below the 0.5 kt from the blast. On saturated soil with TNT's K, this estimate needs about
  0.95 kt for 120 m: inside the range of the yield estimates (0.2–1.1 kt), but nearly twice the
  central one. With the burst's height unknown, and the crater widened by fill flowing into the
  basin, neither figure checks the other.

Not found open, and wanted ([data wanted](data-wanted.md)): the test reports themselves. These
are Jones's Prairie Flat crater study, Roddy's tables for Snowball, Dial Pack and Mixed Company,
the DNA's Minor Scale reports, Gould's DNA 6187F, and the 200-event database of AFWL-TR-71-144.
The DTIC copies were refused or down while this was written.

## Limitations

- Empirical scaling only: no soil mechanics, ejecta, or ground shock driven by the charge
  (stage 2).
- The crater does not act on the blast or on anything during the run: debris, fragments, ground
  points and thermal sight lines see the pre-blast ground.
- Surface and above-ground bursts only; a charge below the surface counts as on it. Buried bursts
  scale differently (Cooper's W^(1/3.4) fits, §29.4) and are not covered.
- The depth is a rule of thumb in dry ground, and below a water table rests on one slope (10–15°)
  rather than on any measured relation with the water table's depth. Wet craters' widening and
  their slow slumping (hours in sand, months in clay; Glasstone and Dolan, §6.11) are not modelled.
- One K for every explosive, chosen on two events.
- The air's share is the same for every soil, and its taper with height is the crater's coupling
  curve, not a measured airblast one.
- Craters in the app are shaded, not cut into the air model's ground. The USD and
  `Terrain.cratered` give the shape.
- Several charges dig separate craters, which simply add where they overlap.

## Stage 2

A crater coupled to the blast near the charge: soil that flows, ejecta thrown into the air, and
the shock the charge drives directly into the ground, which also loads and vents the early blast
([distributed computing](distributed-computing.md#the-long-term-visions-effects)). It starts with
a check under the project's sharing rule, for an existing or in-progress model to adopt.

On 17 October 2026, for stage 1:

- **ContinuumKit** had no cratering, soil-flow or ejecta model.
- **Edgerton**'s "ejecta" are presentation effects for projectile impacts on gel.

Stage 2's material flow and fracture overlap Edgerton's volume solver and cohesive cracks, so
the check is to be redone then.

## Sources

- P. W. Cooper, *Explosives Engineering*, Wiley-VCH, 1996, chapter 29, "Scaling craters":
  equations 29.3–29.7, table 29.1, figures 29.6–29.7, examples 29.1–29.2. The book prints equation
  29.5's detonation pressure in kbar, but its figure 29.6 and example 29.1 work only in GPa.
- G. F. Kinney and K. J. Graham, *Explosive Shocks in Air*, 2nd edition, Springer, 1985:
  equation 1-4 and its scatter, and example 8-7.
- S. Glasstone and P. J. Dolan, *The Effects of Nuclear Weapons*, 3rd edition, 1977: §3.34, §6.09
  and §6.70–6.75.
- C. N. Kingery and G. Bulmash, *Airblast Parameters from TNT Spherical Air Burst and
  Hemispherical Surface Burst*, ARBRL-TR-02555, 1984: the 10% into the ground, as reported by
  Aouad and others below.
- D. J. Roddy, G. W. Ullrich, F. M. Sauer and G. H. S. Jones, "Cratering motions and structural
  deformation in the rim of the Prairie Flat multiring explosion crater", *Lunar Science VIII*,
  1977 (NTRS 19780057835): Prairie Flat's crater.
- *Roundup* (NASA Manned Spacecraft Center), 31 July 1970: the 500-ton crater at Suffield on
  23 July 1970, taken as Dial Pack's by its date, place and charge. Second-hand, through search
  results of the scan.
- Snowball's diameter (BRL Report 1818 for the charge; the crater from secondary accounts), Sailor
  Hat Bravo's (US Navy photograph KN-10831; Maui News, 2010), and Minor Scale's (White Sands
  Missile Range Museum, 2023): all second-hand.
- GEER-070, *The 2020 Beirut Explosion*, 2021, §3.2: crater, ground and water table; C. M. Aouad
  and others, "Beirut explosion: energy yield from the fireball time evolution", *Shock Waves*,
  2021: the hydrographic survey, the crater-based yield and Kingery and Bulmash's 10%; S. E. Rigby
  and others, *Shock Waves*, 2020: the 0.5 kt (0.2–1.1).
- A. W. Patteson, Operation Hardtack Project 1.4, 1960: lips of 15–20% of the crater's volume
  for surface bursts in dry sand, against Glasstone and Dolan's 55% (not used).
