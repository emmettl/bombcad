# Roadmap history

The roadmap's planned-work list as it stood on 11 October 2026, before it was reorganised by
area ([roadmap](roadmap.md)). Each item keeps the account of what was done for it and why; the
current plan, and what is now and next, is in the roadmap.

## Planned work, to 11 October 2026

### Validation first

More evidence is worth more than more features. The sources each step needs, and what is
needed from them, are listed in [Data wanted](data-wanted.md); the open sources found for
them on 10 October 2026 are ranked at the [top of that page](data-wanted.md#where-to-start-the-open-leads-ranked).

1. **The chamber's joints.** In the test they were cut through within milliseconds and the
   roof was left 95 mm up; the model's stay whole, carry an arching thrust that outlasts the
   load, and bring the roof back to 7 mm. And the 25 mm mesh, on which the peak (65 mm) has
   not converged and the wall tops tear on the rebound. (Done: bars resisting sliding across
   cracks, and cracks bridged across a section, which took the roof from thrown to about
   100 mm; cracks that turn with the stress until they open; then the detailing itself, as
   inclined bars across the chamfers and mats and ties in the down-stand, with a time step
   that allows for the bars and contact that holds eight nodes a cell. With the detailing the
   roof is about twice as stiff as the paper's model: 38 mm against 87 mm. The diagonal bars'
   size and the down-stand's steel are assumptions; see
   [Validation](validation.md#an-internal-explosion-in-a-reinforced-concrete-chamber).)
2. **A fourth and fifth structural test**, chosen to differ from those so far: a slab with
   steel in both faces, a member with stirrups, and a wall under an open-air charge. The
   high-strength slabs of the same contest are the obvious next case, since the geometry and
   loading are already set up; their data would have to come from Thiagarajan et al. (2015).
   (Done: a beam bent slowly to failure, Janney et al. (1956) via Xu and Lu (2016), whose
   peak moment the model gives within 3% on two meshes, with nothing fitted; it found
   splitting cracks along the bars softened over too wide a band, now fixed. See
   [Validation](validation.md#a-reinforced-beam-bent-to-failure). And Vecchio and Shim's beam
   OA1 without stirrups, via Bernardi et al. (2016), which fails in diagonal tension as the
   test did, 11–15% strong on fine meshes and 37% strong on coarse ones; see
   [Validation](validation.md#a-beam-failing-in-shear). And Saatci's drop-weight impacts on
   beams with and without stirrups (2007): with stirrups, light drops within 12–24% and heavy
   ones within −5% to +3% on 16 elements (+2% to +18% on 24) with the Model Code's tensile
   strain-rate law, chosen on these beams, the beam without stirrups broken by the
   heavy drop as in the tests and damaged by the light one, which it survived; beams' sectional shear check fails every beam under impact; see
   [Validation](validation.md#beams-struck-by-a-falling-weight). And Chiquito et al.'s
   full-scale slabs under 2–15 kg at 0.5 and 1 m (2023): the load within about a tenth of the
   empirical impulse, but the slab a third as far down as measured, barely spalled, not punched
   through under the charge, and falling apart once broken where the tests' hung on their bars;
   see [Validation](validation.md#slabs-under-close-in-charges). And slabs with steel in both
   faces, Wu et al. (2023) and Wang et al. (2022): under 1.6 kg at 0.5 m within −20% to +7% at
   the peak, but 40–70% under smaller charges, where the tests spalled; one layer and two barely
   told apart; contact charges hole the slabs, though not to size; Wang's slabs several times too
   stiff as supported, its aluminised charge's impulse three quarters as 10 kg of TNT; see
   [Validation](validation.md#slabs-with-steel-in-both-faces). Traced, one layer and two come out
   alike because the compression layer is fully engaged and the bars do a quarter of the work;
   hourglass control does several times an element's own bending (7–18% at the peaks), and
   softened with cracking, an option, it fixes OA1 and Janney's beam but folds the struck beams;
   see [Validation](validation.md#hourglass-control).) (And Peterson, Magnusson, Hallgren and Ansell's eighteen short beams struck by 70 kg at
   6.86 m/s, with and without stirrups, at shear spans of 0.4, 1 and 2 depths (2026), from their
   own records: the forces at a shear span of one depth within the scatter, the deep beams half
   as much again to twice as stiff; see
   [Validation](validation.md#short-beams-struck-to-a-shear-failure).) (And Alsubaei's perimeter walls under ANFO in the
   open (2015): column peaks within about 10% from 9 m out; the shielding not settled, the wing
   walls' length unknown; reinforced blockwork 31 mm against 28 mm as one material, running away
   as units and joints; see [Validation](validation.md#perimeter-walls-under-field-blasts).)

### Then the physics the evidence points to

3. **Charge model.** Close-in peaks are under-resolved: a mapped one-dimensional solution
   would help there; and the products' own composition for the hottest gas. (Close in, the
   reflected impulse converges to within 8% of Kingery–Bulmash from 0.3 m/kg^(1/3) on cells of
   a hundredth of the charge's cube root, or twice that refined, so the products' own equation
   of state is not needed for the load; see [Validation](validation.md#close-in).) (Done:
   afterburning, limited by mixing and oxygen, and thermally perfect air, which together bring
   the closed-room gas pressure within 8% of UFC 3-340-02 and the incident impulse in the open
   within 6% of Kingery–Bulmash; and the air's dissociation, as an option, which moves those
   by under 1% in the open and up to 6% in the densest rooms, at 3.6 times the cost; see the
   [air-blast model](air-blast-model.md#dissociating-air).)
4. **Shear in concrete.** (The [concrete strategy](concrete-strategy.md) proposes discrete bars,
   now an option that does not tell Wu's one layer of steel from two, then embedded cracks where
   members fail in shear; nonlocal cracking, also an option, brings OA1 within 8% only over a
   fitted length.) A member that failed in shear under a blast, to judge a sectional
   check for shells; a sectional check that works under impact, where the present one breaks
   every beam; and solid elements that fail in shear on coarse meshes, which cannot separate
   cracks 100 mm apart on 46 mm elements; crack tracking did not help without bond slip (see
   [the concrete model](concrete-model.md#limitations)). Bars that slip, now an option, give
   discrete cracks at the Model Code's spacing on any mesh and a mesh-independent shear beam,
   but 42–47% strong, and the slab's peak 18% low. Across discrete cracks, a shear stiffness that
   falls as they open (Walraven and Reinhardt, now an option) barely moves either; the beam's
   strength follows the interlock cap alone, 108–109% on both meshes at a fifth of it, which
   nothing measured supports: checked directly against Walraven and Reinhardt's push-off tests,
   the cap is 3% to 24% above what an unpressed crack carried, not five times. Bond lost where bars yield (now part of slip) spreads yield
   along them but leaves the slab at 88 mm; its stiffness with slip comes from cracks that keep
   to one element each, 90 mm apart over a shorter zone (98 mm if spread over the crack spacing).
   Driven along Walraven and Reinhardt's measured crack paths, a crack carries its cap alone, a
   twentieth to a fifth of what theirs carried pressed shut by their restraint, which the model
   cannot do; and with slip the slab cracks as a photograph of the test shows, ten cracks over
   600 mm, so its stiffness lies elsewhere (see [Validation](validation.md#its-cracks)). Traced by
   mechanism (`--work`), it lies in the concrete between the slab's cracks carrying tension, the
   bond's reaction, nothing counted twice and as much as the Model Code gives a tie
   (`--stiffening`, `tie`); softening it sooner fixes the slab but spoils the tie. Run on every
   test, slip is mesh-independent but too stiff nearly everywhere, so it stays an option (see
   [Validation](validation.md#bars-that-slip-across-the-tests)). OA1's excess
   with slip is not in cracks pressed shut; interlock that grows with pressure, now
   an option, matches the push-off tests but breaks beams under impact. (Beams now check each section's shear.) (Done: a test of a beam without stirrups that failed in shear; cracks whose axes
   turn with the stress until the crack opens, by default, after the lattice planes were
   found to mishandle inclined cracks, and a second crack once the tension has turned more
   than 30° from fixed axes; see [Cracking](concrete-model.md#cracking).) Peterson's short beams under impact (2026; see
   [Validation](validation.md#short-beams-struck-to-a-shear-failure)) fail without stirrups by
   splitting along their bars rather than by crushing their strut, and hold with stirrups where
   the tests' crushed it: the strut's crushing and splitting under impact are next.
5. **The concrete's tensile strain-rate law.** Saatci's heavy impacts were a quarter too
   stiff with Malvar and Ross's law, and the close-in slabs' spall had to overcome 17–21 MPa
   with it, where spalling tests find 10–15 MPa. (Done: the fib Model Code 2010's law, now the
   default, which brings the impacts within −5% to +15% and the contest slab to 96–103%; but
   under it the beam without stirrups breaks under the light drop it survived, split along its
   bars. Read over each crack's own band, the split's width was found four to six times too
   wide; corrected, the beam comes through on 16 elements and still splits on 24, and with bars
   that slip it comes through whole on both. Spreading the bars' steel through the concrete
   about them takes the mesh dependence away but leaves beams without stirrups too stiff and
   springing back from their peaks, keeping a third of the deflection the tests kept. So the bond between bars and concrete under
   impact, and the shear such a beam carries across cracks at these rates, are still open.)
   (Done: the bars' law, the CEB's as the fib Model Code 2010 re-adopted it, after a beam
   pushed slowly kept its deflection as the test's did and the same beam struck had yielded its
   bars half as far: Malvar and Crawford's law, which tension tests of bars find a fifth too
   strong at yield at these rates, held it elastic; with the bars taking their strain rate over
   their debonded length, not from the one element a crack runs through, so that the slab's
   hinge converges under it on fine meshes. Saatci's heavy drops now come within −6% to 0% on
   16 elements, Ando's within 13% on average; the contest slab goes 5–15% too far and its
   shells a quarter.) Which strengthening is the material's
   and which the specimen's inertia, already in the model, needs evidence from tests built to
   separate them.
6. **Close-in damage**: spalling of the faces, and a breach under the charge, which the
   close-in slabs show and the model does not produce on any mesh. (The
   [concrete strategy](concrete-strategy.md) proposes failed concrete turned to particles, not
   deleted, then a peridynamic zone if needed.) (Done: bars that outlive
   the concrete around them, as bare elements, so that a holed member hangs on its bars; see
   [Removal](concrete-model.md#removal). And a fracture energy that grows more slowly with
   strain rate than the strength, after which the reflected wave spalls the far face under a
   close-in charge, over a tenth of the area the tests show. Traced through the slabs: the spall
   needs the air fine enough to keep the shock a shock and 12 elements through the slab, and
   then comes off under the charge only; the concrete there is left broken but never removed,
   so there is no hole; and the tests' damage lies mostly along the mid-span hinge, following
   bending the model gets a third to a half of, after the wave wrapping under the slab takes
   back a quarter of its impulse. Confinement now comes from the stresses carried, not strains.
   See [Validation](validation.md#what-stops-the-spall-and-the-breach). Against Hupfauf's
   slabs under contact charges, the first debris comparison: the far face starts at about the
   debris's speed, within a factor of two, and cracks loose over about the spall crater, but
   the loose layer is held back, not thrown, and no slab is holed; a ball of hot air in contact
   gives about twice the products' impulse. See
   [Validation](validation.md#slabs-under-contact-charges). Removing fragments, concrete
   cracked open two ways, is now an option: it holes the slabs that were holed and those that
   held alike, so it is not the default; Wu's contact holes had been the step running away.
   See [holes](validation.md#holes-under-close-in-and-contact-charges).)
7. **The rebound.** The slab's mid-span hinge springs back twice as far as the specimen did on
   every mesh. (Done for beams: cracks that slide for good and ride up on their aggregate,
   after which beams struck by a falling weight keep their deflection as the tests did; the
   slab, whose hinge bends rather than slides, is unchanged. Since crack widths were read over
   each crack's own band, beams without stirrups keep about three quarters of the deflection
   the tests kept.) (Done: compaction of the pores under very high confined pressure, after
   Holmquist, Johnson and Cook; under the close-in slabs it is not what limits them.)
8. **Cut cells** between moving solids and the air. Moving walls already push the air (a
   piston test matches theory within 2%) and conserve the gas within 0.3%, so cut cells would
   now buy geometric precision only. Deferred.

### Then scale and scope

9. **Shells and beams that hold together like the solids.** (Done: the bars' dowel action in
   shells and beams, and punching at slab–column joints on Eurocode 2's strength, after which
   the slab hangs on its bottom bars; the shell frame now stands where the solid one does at
   250 kg, and the tall layouts need 4,000 kg to come down. Dowel action, Rasmussen's for a
   well-embedded bar, is probably too strong for bars near a face; see the
   [shell model](shell-model.md#limitations).)
10. **Contact that knows the shells' thickness.** (Done: shells and solids together, tied
   through the thickness, three times faster than all solid elements on the single-storey
   building with only its front wall solid, and in contact with each other once anything has
   failed; see the [shell model](shell-model.md#shells-and-solids-together).)
11. **Joints within materials**: bearings that separate; masonry's joints on coarse elements
   and in shells, as strengths that differ across and along the bed joints. (Done: several
   materials in one body; joints between materials that open at the bond of mortar to
   concrete; structural steel and annealed glass, the glass as shells in panes; and masonry
   as units and mortar joints in running bond, which open at the bond and slide by friction,
   on solid elements no more than half a course high: see the
   [concrete model](concrete-model.md#masonry-as-units-and-mortar-joints).)
12. **Adaptive resolution in the air**: several levels. (Done: one or two finer levels, by 2 or 4, in
   blocks of 4 × 4 × 4 cells that follow the shock, the second nested in the first, conservative
   across each level's edge, each with its own
   outline of blocks and structure, loading a deformable structure from the fine cells beside
   its faces, and carrying afterburning's fuel and oxygen; refined by 2, a grid gives the peaks of one twice as
   fine three to five times faster in the open, and in two levels those of one four times as fine,
   1.2 to 1.4 times faster than one level by 4. See the
   [air-blast model](air-blast-model.md#refining-near-the-shock). A finely resolved
   one-dimensional start, tried first, gave exact records close to a charge but no lasting gain.)
   Stationary [building envelopes](building-envelopes.md) now retain walls, roofs and openings
   in shared air without mechanics. Matched pinned-solid comparisons reproduce the exposure
   and integrated surface loads exactly; short computational scaling runs reach 64 buildings.
   Air resolution remains a separate cost and accuracy limit, and shell junction/opening
   approximations are retained as diagnostics in that study.
13. **Freestanding objects and supports.** Independent rigid bodies for parked cars and
   interior furniture, with gravity, friction, lift-off and collisions, coupled to the blast.
   Start with the staged checks below. Separately, make structural support assumptions visible
   and add connections with finite stiffness and strength where anchorage failure matters.
14. **Effects beside the blast**, one way and separable (see [Distributed
   computing](distributed-computing.md#the-long-term-visions-effects)). (Done, illustrative: a
   cased charge's [fragments](fragments.md), and the fireball's [thermal
   radiation](thermal-radiation.md) on the ground and faces of a scene, from the air model's own
   hot gas in its own shape, which needs afterburning and hot air to make a fireball of plausible
   size, painted onto the surfaces in the app as it goes and reckoned there or on another Mac, chosen
   by cost if asked,
   its luminous cells marched on the GPU as a partly transparent volume, and, as an option, the
   heat they radiate taken out of the gas, which halves the fluences, and compared with two TNT
   shots, whose pulse it gets wrong in shape, and gravity in the air as an option, under which
   the fireball rises but stays too hot; the radiation [conducted into
   the surfaces' materials](surface-heating.md) for their peak temperatures, with ignition
   thresholds from tests marked illustrative; the fireball's [rise and
   cloud](fireball-rise.md), handed over from the air model's final state to an integral model of
   a rising thermal in a standard atmosphere or a measured sounding, a wind growing with height,
   turbulent air and humid air, where it condenses, freezes and rains once saturated, its top
   within 4% on average and 21% shot by shot of the tops measured over 22 TNT detonations for
   their first two minutes, then spread as a gravity current and a Pasquill–Gifford puff
   drifting downwind, its path drawn and charted in the app; and [ground shock](ground-shock.md) away from the charge, the
   manuals' one-dimensional estimate or a layered soil column that loads and unloads at different
   stiffnesses, fed the overpressure on the rigid ground each frame and drawn in the app. The fireball's radiation is paused: gravity fixed its rise, but sub-grid mixing and an extinction limit left Dial Pack at about 21% radiated against 5.1%; the next candidates, if it resumes, are flame sheets round a fuel-rich core and the missing hot shock layer. Next: the measured growth
   of the cloud's top after two minutes, and a comparison with measured ground motion. The crater and the ground shock near the charge act back on the blast and remain
   outside these.)
15. **Terrain**, at neighbourhood and small-landscape scale. (Started: a heightfield ground, from
   shapes or a DEM, solid in the air's mask on every level; it hides the fireball, carries ground
   points, objects and the thermal paint; see [Terrain](terrain.md). Next: cut cells for its
   slopes, and footings and the ground's connection on a slope.)
16. **Gas deflagrations**, beside the charge. (Started, illustrative: a methane or propane cloud lit
   at a point, burning by Weller's regress variable and wrinkled by sub-grid turbulence from the
   air's σ-model mixing, and vent panels that release at a pressure. Closed vessels converge on the
   thin-flame model. In FM Global's chamber, lit at the back wall, the flame comes within a fifth
   of the tests' speeds beyond 3 m and peaks at 55–60% of their pressure; lit in the middle, at a
   sixth to a seventh, its back
   half stalling. See [Gas deflagrations](deflagration.md). Next: why it stalls, a young flame's
   speed on coarse cells, and the instabilities.)
17. **Large scenes**: surface bursts of hundreds of tonnes to kilotonnes over kilometres. (Started:
   checked against Kingery–Bulmash to 40 m/kg^(1/3) and over terrain at 500 t; refined twice at a low
   threshold, 16 m cells give 4 m cells' peaks in a quarter of the time; see [Large
   scenes](large-scenes.md); the app sets cells, domains and charges of that scale. Next: a refinement
   criterion that follows weak shocks.)
18. **Cost against fidelity**: the cheapest settings for a target, or the best within a budget. (Started:
   an advisor in the Run tab and `--advise`, its fidelity the standing's error bands and its cost a model
   within a factor of two of the timed runs; see [Performance](performance.md#choosing-settings). Next:
   costs measured on an unloaded Mac at kilometre scale, and more results weighed.)
19. **The model's spread from uncertain inputs.** (Done: `BombCAD ensemble` reruns nine
   validation cases over sampled strengths, bars, charges, standoffs and unclear supports, shared
   among Macs; see [Validation](validation.md#the-models-spread-from-uncertain-inputs).)
20. **Neighbourhoods of real buildings**, as exposure-only envelopes. (Started: rigid IFC and mesh
   imports, and OpenStreetMap footprints, as envelopes; see [building
   envelopes](building-envelopes.md#envelopes-from-imports-and-map-data).)

### Usability: exporting a run for rendering

- **Export a run for rendering elsewhere**, so a finished simulation can be rendered in
  Blender's Cycles with hardware ray tracing instead of a renderer of our own (see
  [Ray tracing](ray-tracing.md#the-shortcut-export-to-blender)). The app keeps no frames today,
  only gauge and deflection histories, so the frames would be written during the run, most
  simply as an option of [`BombCAD run`](run-comparison.md#headless-runs) at a chosen frame
  rate. In two steps:
  1. **Geometry as USD**, in its text form (`.usda`), which needs no library: the blocks and
     ground once, the structure's surface with its points sampled per frame and failed elements
     dropped, and the charge and gauges as markers. (Done: `BombCAD run --usd`, with the
     project's view as a camera, and checked in Blender 5.2; see
     [Exporting a run for rendering](usd-export.md).)
  2. **The blast as OpenVDB volumes**, one file per frame, from the overpressure the renderer
     already ray-marches (the solver's visualisation volume). Blender reads volumes only as VDB,
     so this needs either the OpenVDB library (a large C++ dependency) or a small writer of our
     own for dense float grids. The size wants watching: a medium grid is 8.4 million cells, about
     34 MB a frame before VDB's sparseness, so a few gigabytes for a 0.17 s event at 1,000 frames
     a second of simulated time.
     (Done: `BombCAD run --vdb`, with a writer of our own, checked against OpenVDB through
     macOS's USD; overpressure and the pressure gradient, about 14 MB a frame on the medium
     street grid. See [Exporting a run for rendering](usd-export.md#the-air).)
  3. **In the app**: File ▸ Export for Rendering… runs a copy of the project in the background
     and writes both, with peak overpressure and impulse as further grids. (Done.)

### Done from these lists

Done from these lists: blast loads against the full Kingery–Bulmash curves; a coupled test
(the internal explosion); shell elements for walls and slabs and beam elements for columns (2
to 35 times faster coupled, see the [shell model](shell-model.md)); debris loaded by the air
(pressure gradient and drag on loose nodes, with the reaction given back to the air); still
air skipped, with an identical answer (1.6 to 1.7 times faster on the street scene, see
[Performance](performance.md#air-solver)); hollow concrete blockwork as a material; a
structure's largest deflection reported beside its deflection now; and layouts for a close-in
column, a wall in front of a building, a glass façade, a car park, an underpass, a
block-built house, a blockwork wall, an eight-storey frame and a twelve-storey tower, the last
two collapsing over several seconds.
