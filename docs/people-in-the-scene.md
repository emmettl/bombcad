# People in the scene: occupants and the people hurt

The quick estimate says which buildings' glass breaks and which walls are damaged. This page
covers the step after that: who is inside those buildings, and how many of them the estimate
would expect to be hurt. It places people in every envelope building by its use and the time of
day. It then combines the existing hazard outputs into a figure for each building and a total for
the district:

- each side's glass chances;
- the walls' and roofs' chances;
- the blast's own peak.

Each figure comes with a band and its standing. This is the first step of
emmettl/bombcad-work#41, "Injury and evacuation planning".

**Standing: illustrative.** Each injury rate is a published model, but each comes from other
events or other hazards: glass from explosives-safety risk work, walls from earthquakes, the
blast from animal tests. None has been fitted to the scenes it is used on. Against Beirut 2020,
the one event in reach, the counts read 4 to 12 times high. Where the people hurt are found agrees
better than how many. So the planner shows relative figures: shares, and changes against a
baseline you pin. The counts are behind **Show counts**, with that warning. Use it to compare
places of the charge, times of day and protections with each other. It is not for triage or
casualty planning.

## What holds and what does not (21 October 2026)

- **Holds: where the hurt are, roughly.** On Beirut at 0.5 kt, 80% of the people the estimate
  expects hurt are 0.5–1.7 km from the port. Al-Hajj et al. (2025) found 71% of a hospital
  sample there.
- **Does not: how many.** Within 2.5 km the estimate expects about 78,000 hurt and 900 killed.
  The records for the whole city are about 6,500 injured and 218 killed. The estimate's hurt
  include the minor cuts that hospital records miss. Even so, the figure closest to a hospital
  count is severely hurt or killed, 7,900, and that is about as many as all the injuries
  recorded.
- **Does not: indoors and out.** Nearly all the estimate's hurt are indoors, struck by glass. The
  hospital sample was 81% indoors. Falling glass and debris in the street are not modelled.
- **Not testable: the per-building figures.** No open record gives injuries building by building
  for any event. Mallonee et al.'s Oklahoma City table is behind a paywall.

## Where to see it

- **In the app**, once a quick estimate has the glass's chances, the sidebar's **People in the
  scene** section (under Envelope building damage) shows relative figures only:
  - first, a note that the figures are illustrative and relative;
  - the time of day: night (2 am), working day (2 pm) or evening (5 pm);
  - the use given to untagged buildings, residential by default;
  - a factor on the density;
  - **against a pinned baseline**: **Pin as Baseline** keeps the full estimate shown. After that,
    the section gives the change in the people hurt and in the severely hurt or killed, for
    example "−38% hurt (−40% to −36%) against the pinned baseline: the charge 60 m from the
    pinned one". It also names what changed: the charge's place or size, the time of day, the
    density, the untagged use, or the buildings' constructions (a protection);
  - where people are hurt: the share of those placed, the share hurt in each band of distance
    and that band's part of the hurt, and the five buildings with the largest share hurt.

  **Show counts** opens the absolute counts and their band, the buildings with the most people
  hurt, and the judge against Beirut. Its first line is the warning that the counts read 4 to 12
  times Beirut's record, and why.

  **Colour Buildings by People Hurt** colours each building by the share of its people expected
  hurt, on the chances' scale. With that colouring, dragging the charge previews the people hurt
  from the glass's chances alone, on 10 draws of the glass and 40 of the assumptions, and the
  change against the baseline follows. The walls and roofs follow when you let go. Elsewhere,
  the figures stay those of the last full estimate.

  The change is the ratio of the two estimates draw by draw, over the same draws of the
  assumptions (one seed; a preview's 40 are the first of a full estimate's 200). So the
  assumptions shared by both largely cancel, and the change's band is narrower than either
  estimate's own. The look's own doubts, such as the yield's, are not in it.
- **Headless**, `scenebench people <a district's inputs> [--time evening|workday|night]
  [--density 1] [--untagged residential] [--look kept.json] [--csv out.csv]` runs the full look
  and the people on it. It prints the totals, a table by distance band and by use, and the CIA
  cross-check below. `--look` keeps the look's chances so that later runs take a fraction of a
  second.

## Occupants

Each building gets one use. Where its map tags give one, it is the `building` tag's or the
`building:use` tag's (`BuildingUse`: residential, offices, shops and restaurants, schools, hospitals,
hotels, places of worship, industry and storage, unoccupied). New District and the map import
keep it on the building's construction. An untagged building (`building=yes`) takes the use
chosen in the planner, residential by default. In Beirut's map that is 14,095 of the 14,502
buildings. Floor area is the footprint times a storey every 3 m of height. For map buildings the
footprint is the cells' area; for other envelopes it is the bounds'.

People when full, as gross floor area per person, m² (`OccupantInjury.floorAreaPerPerson`):

| Use | m² a person | From |
|---|---|---|
| Residential | 30 | Between the IBC's design load for residential, 18.6 m² gross (Table 1004.5, 200 ft²), and Finland's 40.8 m² of dwelling per person (2018). Lebanon's figure was not found. Assumed |
| Offices | 12 | BCO (2018): 9.6 m² of net area per workplace, taken as about 12 m² gross |
| Shops and restaurants | 15 | A quarter of the IBC's mercantile design load (5.6 m², 60 ft²), which is a maximum for exits. Assumed |
| Schools | 10 | Assumed |
| Hospitals | 25 | Assumed |
| Hotels | 35 | Assumed |
| Places of worship | 10 | Assumed |
| Industry and storage | 50 | Between the IBC's industrial (9.3 m²) and warehouse (46 m²) loads |

The share present at each time (`OccupantInjury.present`) is Hazus's default distribution of
population (FEMA, Hazus Earthquake Model Technical Manual 4.2, Table 12-2) where it gives one:

| Use | 2 am | 2 pm | 5 pm | Out of doors (2 pm, 5 pm) |
|---|---|---|---|---|
| Residential | 0.99 | 0.45 (0.75 of those not at work or school, about 0.6 of residents) | 0.50 | 0.30 |
| Offices, shops, hospitals by day | 0.02 | 0.98 | 0.49 | 0.01, 0.02 |
| Industry | 0.10 | 0.80 | 0.50 | 0.10 |
| Hotels | 0.999 | 0.19 | 0.299 | 0.01, 0.02 |

Hazus gives no rows for the others: schools (0, 0.9, 0.1), hospitals at night and in the
evening (0.7, 0.8) and places of worship (0, 0.05, 0.1) are assumed. Out of doors at night is
0.001 everywhere. Hazus counts the people by its own census tracts. Here they come from floor
area, so its shares are applied to each building's own people when full. Its 5 pm row also has
commercial visitors and people commuting, which have no building here.

On Beirut's district this places about 450,000 people in the 5 × 5 km square at 5 pm and 830,000
at 2 am. That has not been checked against a census: the square holds most of the
municipality, Bourj Hammoud and part of the suburbs, and the residential density of 30 m² a
person is an assumption. The factor is there to change it.

## What hurts them

For each building, and each group of its people, the chances of being hurt combine as
independent causes (`OccupantInjury.estimate`):

- **Glass, indoors.** Kummer's model (31st DoD Explosives Safety Seminar, 2004, Table 3) relates
  the share of a building's panes broken to its occupants hurt:

  | Panes broken | Hurt | Severe | Killed |
  |---|---|---|---|
  | 1% | 0.1% | 0.01% | 0.001% |
  | half | 10% | 1% | 0.1% |
  | all | everyone | 10% | 1% |

  Between those points it is interpolated on logarithms. The share broken is the estimate's
  expected share, its sides weighted by their length. No open study links GSA's or ISO 16933's
  hazard levels to injury, so the chance of glass thrown past 3 m is not used. DDESB TP-14
  (Revision 4) uses the same form, a power of the share broken. Its coefficients are in tables
  this step did not extract.
- **The walls and roof, indoors.** These use Hazus's indoor casualty rates for its moderate and
  extensive damage states (Tables 12-4 and 12-5). For most building types they are:

  | Damage | Hurt, all severities | Severity 2 or worse |
  |---|---|---|
  | Moderate | 0.28% | 0.03% |
  | Extensive | 1.1% | 0.1% |

  Unreinforced masonry's extensive rates are twice those. The estimate's walls damaged
  moderately take the moderate rates, and its walls damaged heavily take the extensive ones. A
  roof damaged moderately counts as moderate damage for the top storey's people. These are
  earthquake rates, borrowed because there is no open table of injuries against blast damage.
  The estimate gives no chance of collapse (its standing does not support one:
  [glass-probability.md](glass-probability.md#walls-and-roofs)), so collapse, which killed most
  of those who died in the Murrah building, is not here.
- **The blast itself, by blown-out windows and out of doors.** These use Eisenberg's probits as the
  TNO Green Book gives them: eardrum rupture `Y = −12.6 + 1.524 ln p`, on the incident plus dynamic
  pressure (50% at UFC 3-340-02's 15 psi), and death from the lungs `Y = −77.1 + 6.91 ln p`. The
  pressure is the Kingery–Bulmash free field at the side's distance: no shielding, no reflection.
  - Inside, they apply to the people within 3 m of a side (GSA's condition 3b zone), weighted by
    the side's chance of being blown out.
  - Outside, they apply to the people out of doors by the building, at its nearest side.

**Severely hurt or killed** takes Kummer's severe tenth, Hazus's severity 2 or worse, and the
lungs. **Killed** takes Kummer's hundredth and the lungs, and leaves out Hazus's severity 4, which
is a hundred-thousandth.

**The band** is 5–95% over 200 draws of the assumptions, each drawn log-normally once for the
whole district, since an assumption is the same everywhere:

| Assumption | Factor it lies within, nine times in ten |
|---|---|
| The density | ×1.5 |
| Glass's rate | ×3 |
| The walls' rates | ×3 |
| The share out of doors | ×2 |

The look's own uncertainty (the yield, the glass's strength, the surrogate's scatter) is already
in the chances, as their means, and is not in the band. A preview draws the assumptions 40 times.

On Beirut's district the people take 0.2 s on the Studio after the look, so they follow a drag.

## Judged against Beirut (21 October 2026)

The scene is [Beirut's district](beirut-2020.md): 14,169 map buildings within 2.5 km, 0.5 kt, 4 m
cells, the quick estimate's full look (100 draws, yield within ×1.5). The people are placed for
5 pm, the explosion having been at 18:08 (`scenebench people … --time evening`).

**What the records say.**
- The totals:
  - OCHA (21 August 2020) gives at least 180 killed and over 6,500 injured;
  - UNFPA gives 220 killed and over 7,000 injured;
  - the usual total is 218 killed.
- No open record counts injuries by neighbourhood or distance.
- Hospital samples give the spread. These are full papers unless marked as abstracts:
  - Al-Hajj et al. (*Scientific Reports*, 2025; n = 310, abstract): 71% of victims at 500–1,700
    m, 81% indoors, 48% at home.
  - Al-Hajj et al. (2023, 791 patients from five hospitals, abstract): a mean distance of 2.4 km
    (standard deviation 1.9 km), so many were outside this scene. A quarter were admitted.
  - Al-Hajj et al. (*Trauma Surgery & Acute Care Open*, 2023; 3,278 records from 16 hospitals):
    lacerations, which they put down to unlaminated glass, were 40–43% of outpatients.

**What the estimate gives**, within the 2.5 km of the scene:

| Distance | People | Hurt | Severely or killed | Share hurt | Panes broken |
|---|---|---|---|---|---|
| 0–0.5 km | 1,725 | 1,330 | 222 | 0.77 | 0.94 |
| 0.5–0.75 km | 12,363 | 7,500 | 746 | 0.61 | 0.98 |
| 0.75–1 km | 24,659 | 13,574 | 1,356 | 0.55 | 0.96 |
| 1–1.5 km | 81,485 | 33,558 | 3,355 | 0.41 | 0.80 |
| 1.5–2 km | 102,527 | 15,193 | 1,519 | 0.15 | 0.52 |
| 2–2.5 km | 127,459 | 5,728 | 573 | 0.045 | 0.25 |
| The square's corners | 103,355 | 1,276 | 128 | 0.012 | 0.08 |
| **In all** | **453,573** | **78,159 (21,114–171,228)** | **7,900 (2,199–17,236)** | | |

Of the hurt, glass accounts for 77,920, the blast itself for 224 and the walls and roofs for 15.
It expects 881 killed.

**Against the records:**
- The hurt are 12 times the injured recorded in the whole city. Even the band's low end is three
  times. Hospital counts miss minor cuts, while Kummer's "hurt" includes them. Toulouse's AZF
  survey found one in four people within 1.7 km reporting an injury, a measure much closer to
  Kummer's than a hospital's (Rivière et al., 2006, summary). So 12 times overstates the gap for
  the minor injuries, but no record of Beirut's can say by how much.
- The severely hurt or killed, 7,900, are about as many as all the injured recorded, and about
  five times the quarter admitted in the hospital sample.
- The killed, 881, are four times the 218 recorded.
- The spread: 80% of the hurt are 0.5–1.7 km out, against the hospital sample's 71% (a sample
  that includes people beyond the scene); nearly all are indoors, against 81%.
- By time of day, on the same look: at 2 am, 834,000 people and 192,000 hurt; at 2 pm, 449,000
  and 82,000.

**Why it reads high.** Glass is nearly all of it. Inside 1.5 km the estimate breaks 80–98% of
panes, and Kummer's curve is steep near full breakage: 80% broken gives 0.48 hurt, while half
broken gives 0.1. Whether that breakage is too high is not settled (below). The density,
unchecked (above), may add to it.

**The breakage against the survey (21 October 2026).** The 80–98% is the model's own: the runs
break 0.96–1.00 of panes on sides above 7 kPa ([the 19 October trace](glass-probability.md#why-it-over-breaks-against-geer-19-october-2026)),
and the quick estimate's chances follow the runs. Against GEER it looks high:
- GEER's W1 or worse is 0.84–0.35 at 0.5–1.5 km;
- its W3 is 0.76–0.17.

That trace found the comparison is not like for like. GEER classed openings, frames and doors with
the windows, from photographs taken two months on, after repairs. Its W1 carries 10–20% of windows
broken, and 17% of façades at 20–30 kPa showed nothing, where every pane breaks. Stronger glass
could not fit both W1 and W3, and the loads were not too high. So the survey does not show that
the glass over-breaks.

The one count of glass, the army's 0.69 million m² broken, is 3.8 times below the model's
([beirut-2020.md](beirut-2020.md#glass-as-a-mix-of-panes)). But it multiplies the share broken by
a glazed share that is assumed, and the two cannot be separated.

So the breakage is consistent with the model's runs and not shown wrong by the survey, and the
one count suggests it, or the glazed share, is high. Kummer's curve takes the share broken, not
the area, so the glazed share does not enter the injuries. Glass breaking that ran high would.
The glass model is unchanged.

**A cross-check on the walls.** The Chemical Industries Association's siting curves (1998, as
DNV's Phast documents them) give the probability of death inside a building against side-on
overpressure: a two-storey brick house's curve for masonry, a four-storey office's for the rest.
On the same people they would kill 3,411, 16 times the record. Those curves are cautious by
design, for siting plants, and the estimate does not use them.

**No other judge.**
- Oklahoma City (Mallonee et al., *JAMA* 1996) gives 361 in the Murrah building, 319 injured and
  163 killed, and injury rates of 38–100% in four adjacent buildings. Those rates and the
  distances are in the paywalled table, and the scene is not built.
- Nairobi 1998, Khobar 1996, Tianjin 2015 and Halifax 1917 give totals only.
- Wartime bombing gives casualties per ton over many bombs, not per building for one charge.

## The decision this records

The kill criterion for emmettl/bombcad-work#41's first step was a standing so weak that only
illustrative numbers could be shown. Then they must be labelled so prominently that the tool
misleads less than it helps. On the one event in reach the absolute counts are 4 to 12 times
high. On 21 October the user decided:
- the planner shows relative figures: shares by building and by band, the colouring, and
  changes against a pinned baseline;
- the counts and their band go behind **Show counts**, with the warning;
- `scenebench people` keeps the counts.

**The counts are not to be calibrated on Beirut.** One event's two totals, of a different
definition, would fix a factor and hide the over-breaking that causes it. The next stage needs:

- injuries by place: AZF's tables by zone, Mallonee's per-building table, or the full Al-Hajj
  (2025) paper;
- a count of broken glass whose glazed share is known, to say whether the breakage close in is high.

Until then this step stops here: the feature is in the app as illustrative and relative, and the
counts are not for use.

## Limitations

- The injury rates come from other hazards and events:
  - glass: Kummer's model, a risk-analysis model whose basis this step did not check;
  - walls: Hazus's earthquake rates;
  - the blast: probits from animal tests.
- No collapse, no fragments (a cased charge's) and no envelope debris: these are a run's, not the
  quick estimate's. Glass falling into the street and people thrown by the blast are not
  modelled either.
- One use per building, nearly all of a map's assumed. One density per use, with no vacancy and
  no ground-floor shops under flats. The people out of doors stand at their building's nearest
  side.
- The blast is taken from the free field, with no shielding. The glass is taken from the share of
  panes broken alone, not from where the people sit in the rooms.
- The band covers the assumptions, not the yield or the look's other doubts.

## Future work

- Fetch the AZF zone tables (Santé publique France's full reports), Mallonee's table and the full
  Al-Hajj (2025) paper. Build Oklahoma City's block (about 1,800 kg TNT) and judge the four
  adjacent buildings' 38–100%.
- Take TP-14's glass and building-collapse coefficients (Revision 4, tables A-12 to A-17) from the
  report itself, in place of Kummer's three points and Hazus's earthquake rates.
- Evacuation: the people out of doors by a stand-off line, and the routes away.
- Each storey's people against each storey's glass, once façade strips carry their storey's
  share broken.

## Sources

- FEMA, *Hazus Earthquake Model Technical Manual*, Hazus 4.2 SP3, 2020: Table 12-2 (population
  by time of day) and Tables 12-3 to 12-8 (indoor casualty rates).
- P. O. Kummer, *Glass breakage and injury: yet another new model?*, 31st DoD Explosives Safety
  Seminar, 2004 (DTIC ADA548172), Table 3.
- DDESB Technical Paper 14, Revision 4, *Approved methods and algorithms for DoD risk-based
  explosives siting*, 2009 (DTIC ADA507495): the form of its glass and building-collapse models.
- TNO, *Methods for the determination of possible damage* (the Green Book, CPR 16E), 1992:
  Eisenberg's probits for eardrum rupture and lung death.
- UFC 3-340-02 (2008) §1-11: eardrum rupture at 5 and 15 psi.
- British Council for Offices, *Office occupancy: density and utilisation*, 2018.
- International Building Code, Table 1004.5, occupant load factors.
- Chemical Industries Association, *Guidance for the location and design of occupied buildings on
  chemical manufacturing sites*, 1998, its vulnerability curves as DNV's Phast *Vulnerability
  model theory* (2023) gives them.
- S. Al-Hajj et al., Spatial and contextual factors influencing injury patterns and severity
  resulting from the 2020 Beirut blast, *Scientific Reports* 15 (2025), doi
  10.1038/s41598-025-23642-3 (abstract).
- S. Al-Hajj et al., *Trauma Surgery & Acute Care Open* 8 (2023) e001103; and S. Al-Hajj et al.,
  2023, 791 patients from five hospitals (AUB ScholarWorks, abstract).
- OCHA, *Lebanon: Beirut port explosions*, Situation Report No. 6, 21 August 2020; UNFPA
  Lebanon, August 2020.
- S. Mallonee et al., Physical injuries and fatalities resulting from the Oklahoma City bombing,
  *JAMA* 276 (1996) 382–387 (abstract).
- S. Rivière et al., *Health effects of the AZF explosion: the population of Toulouse*, Santé
  publique France, 2006 (summary).
