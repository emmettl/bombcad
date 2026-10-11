# Blind test 1: the predictor's assumptions

Written and committed before the first run of the test, as [the protocol](../../../docs/blind-tests.md)
asks (rule 3). Frozen commit: `1c857744802e8cfd2d536f8379d68dad1a85e743`. The harness is
`Sources/BlastCore/HrynykSlabTest.swift` and `Sources/blastbench/HrynykBench.swift`
(`blastbench hrynyk`), on the frozen commit, with nothing else changed; it reads
`Samples/Hrynyk2013/inputs/slabs.json` itself, so that its numbers come from the inputs as written.

## What the predictor has and has not read

- Read: `docs/blind-tests.md`, `Samples/Hrynyk2013/README.md`, `FROZEN`, `SEALED.sha256` (the
  hashes only) and `inputs/slabs.json`; BombCAD's code (the impact, slab and ensemble benches,
  the structure solver's API, the regime defaults, the standing and error bands); in
  `docs/validation.md` its summary and the section on beams struck by a falling weight, and the
  one-line pointer to this test the extractor added.
- Not read or listed: the sealed folder `/Volumes/StudioData/bombcad/blind/` other than this
  predictor's own folder in it, `/Volumes/StudioData/bombcad/data/Hrynyk2013/`, the thesis, its
  abstract, the VecTor records, anyone's simulation of these slabs. `docs/data-wanted.md`,
  `docs/concrete-strategy.md` and `docs/validation-review.md`, which mention Hrynyk, were left
  unopened in case they quote a result.
- Per the orchestrator's addendum (rule 2, b651c20): no other Claude session's transcript was
  searched or read, with the session-management tools or otherwise, and no memory note about
  this test was read. The orchestrator's message said it held no results, and it held none.

## The model

**Defaults throughout.** No model option is turned on or off. The material carries
`rateDependent = true`, as the app's reinforced concrete preset and every calibrated impact
bench (Saatci, Ando, Peterson) do; the model's loading is set to impulsive (a blow), which for
solid elements leaves every default as it is. Bars perfectly bonded and smeared (the defaults);
no air.

**Mesh: 16 solid elements through the 130 mm (8.11 mm cubes, 222 × 222 × 16 in the slab).** The
standing's evidence for drop-weight impacts is on 16 elements through ("moderate for impact on
16 elements but not on 24"); the calibrated beams were compared there. `BombCAD run --advise`
advises the air's settings for a charge, and this test has no charge or air, so it gives
nothing here; the standing's error bands have no drop-weight entry (see the predictions'
README). The plan is divided into an even number of elements nearest that size (1800/222 =
8.108 mm), so that the slab's centre falls on a node; the thickness becomes 16 × 8.108 =
129.7 mm.

**Concrete** (per slab, from `specimens`): fc at the test age; the secant modulus Ec as the
modulus (as the Ando bench takes its measured modulus); ft* as the tensile strength (the
measured tensile strength, as the Saatci bench takes its own); fracture and crushing energy by
the model's own correlation with fc (not given); Poisson's ratio 0.2 (default); density 2,441
kg/m³ from the mix (cement, sand, water and stone per m³); aggregate 13 mm. The strain at fc is
not an input the model takes.

**Bars** (Table 3.2 values): E, fy and fu as given; a measured curve of plastic strain: the
yield plateau to the strain at hardening (less the yield strain), rising to fu at the strain at
fu (less fu/E) as Mander's power curve with exponent 2 (three points between), holding to
rupture. **Rupture strain, not given: 1.3 times the strain at fu** (0.161 for #3, 0.205 for
10M, total strain), a typical ratio of hot-rolled bars' elongation at fracture to their uniform
elongation. The bars' strain-rate law is the default.

**Reinforcement layout**: four layers smeared each through a band one element deep centred at
its own height (the impact benches' convention), the area per layer A/(s × h) along its own
direction: outer layers at mid-depth ± (outer centre to centre)/2, inner at ± (inner)/2, from
the inputs (#3: ±44.5 and ±35 mm; 10M: ±45.5 and ±34 mm). **The bars along x are taken as the
outer layer in both mats** (symmetric through the depth, as the inputs say); which direction is
outer is not given and, the slab and supports being square, matters little. Bars run the full
plan (to about the edges, hooked: perfect bond takes them as anchored). **The links tying the
mats are left out**: their number and spacing are not given, and the inputs say they are not
shear reinforcement for the impact region.

**Supports.** At each corner, on the diagonal, 145 mm in from both edges (node 18, 145.9 mm):
a steel bearing plate (structural steel) **taken as 100 mm square** (12 elements, 97.3 mm; not
given; the Saatci bench's assumed bearing length) **and 20 mm thick** (2 elements, 16.2 mm) under
the slab, and one alike over it (the socketed plate's size and thickness not given), bonded to
the slab. The spherical pin beneath is a 5 × 5 patch of nodes (32 mm square) at the centre of
the lower plate's underside that rests on its support (pushes up, lifts off freely); the ball
above is a 5 × 5 patch at the centre of the upper plate's top that is held down (cannot rise,
falls away freely). The patches let the corner turn freely in both directions. *(Changed after
the smoke run to one node each, with elastic plates: see change 1 below.)* Sideways, the
lower patch is held as the inputs' lateral restraints say, with the slab's corners south (0, 0),
east (1.8, 0), north (1.8, 1.8) and west (0, 1.8): east pinned (x and y), north held in x (free
along the north-east edge, y), south held in y (free along the south-east edge, x), west free.
The about 5 kN per tie rod on the top bearings is left out (not known per corner; small).

**The weight.** Its flat steel face, 300 mm square in the test, is a 292 mm square (36 elements:
of the two even counts nearest 300 mm, 292 and 308 mm, equally near, the smaller) of elastic
steel two elements (16.2 mm) thick, bonded to the slab's top at the centre: the face of a
concrete-filled section, much stiffer than a plate alone, so not let yield. The face's nodes all
start down at 8.0 m/s and the rest of the weight's mass (the impact's mass less the face's
10.8 kg) is shared among its top nodes; the weight leaves once its mean velocity turns up (the
beam benches' rule), its mass coming off the face, which stays bonded on the slab (10.8 kg, a
hundredth of the slab's tonne). It is not let strike again after its bounce. Gravity is on.

**Repeated impacts.** One model carried through impacts 1 to 4 (150, 180, 210, 240 kg). Before
the first, the slab is brought to rest under its own weight; after each impact's 200 ms it is
brought to rest by mass-proportional damping of 400 per second for 80 ms and its velocities
zeroed, standing for the time the test left it between impacts. Every impact is run for 200
ms whatever happens.

## The outputs, as the harness measures them

1. **Peak midpoint displacement**: the largest downward displacement of the slab's bottom face
   at its centre node (the lowest node at the centre still held by an element, if the bottom
   comes away) in the impact's 200 ms, less where it stood at the impact's start.
2. **Residual**: where that node stands once the slab has been brought to rest after the impact,
   less where it stood at the start. Also recorded, not the prediction: the mean over the last
   30 ms of the 200 ms run, as the beam benches take it.
3. **Peak total support reaction**: the sum over the four corners of the upward forces on the
   lower patches (where the load cells were) while they rest on their supports, sampled every
   25 µs, less its value at the impact's start (the slab's own weight, as load cells zeroed
   before an impact would read): its peak. Also recorded: its peak averaged over 0.5 ms.
4. **Peak impact force**: the weight's mass times its deceleration (its contact force over its
   mass: the change of its mean speed over each 25 µs sample, plus gravity), nil before contact
   and after it leaves, padded with 20 ms of nil either side, filtered by a tenth-order
   Butterworth low-pass at 1.2 kHz (five second-order sections, bilinear, cutoff pre-warped)
   forward and then backward; its peak.
5. **Punching**, judged at rest after the impact: punched if (a) the bottom face's elements are
   removed or left as bare bars over at least 0.09 m² (the face's area) within 450 mm of the
   centre (a square), and (b) in every one of the 16 element layers there is, within the same
   square, an element removed or bare or cracked open by 1 mm or more (a crack through the
   thickness, which bending alone does not open in the compressed top). **Penetration**: the
   step down at the face's edge, the face's perimeter nodes against the top face two elements
   (16 mm) outside it, gained in the impact (and in total).
6. **First punching impact**: the first of the four that meets 5.

**Broken**: the model's slab is predicted broken from an impact on if the weight has not left
it by the end of the 200 ms (gone through) or the solution blows up; it is otherwise run and
reported on all four impacts.

## Secondary runs (reported, not scored)

- **8 elements through** (16.4 mm cubes, 110 × 110 × 8), all three slabs, four impacts: how far
  the mesh moves the answer.
- **The model's spread over its uncertain inputs**: a Latin hypercube of 8 samples and the
  middle (seed 1) per slab, on 8 elements through (on 16 it would take days), four impacts:
  fc ±5% (normal), ft* ×(1 ± 10%) (log-normal), the fracture energy ×(1 ± 30%) (log-normal, the
  ensembles' own), bar yield and ultimate ±3% (the ensembles' measured coupons), speed ±2%
  (normal), the bearing plates 75–150 mm (uniform) and the rupture strain 1.1–1.6 times the
  strain at fu (uniform). The 5th and 95th percentiles of each output over the samples, as
  ratios to the coarse mesh's middle, are applied to the primary prediction as its uncertainty
  for quantities 1 and 3. If time runs short the sample count is cut, and that is said.
- No 24-element run: about five times the cost of 16, which is already hours a slab.

Nothing in these assumptions will be changed after a run to bring a result towards what the
test may have given. If a run shows a harness error (a value contradicting the inputs, or a
crash), the fix and its reason will be added below, dated, before the predictions are committed.

## Changes after the first run

**1. 2026-10-11, after a 5 ms smoke run (TH2, impact 1, 8 and 16 elements, cut short): each
corner seated on one node above and one below, and the bearing plates elastic** (commit
87ff5a7). The 5 × 5 seats under and over each corner clamped it between them: as the corner
turned, the lower seat pressed up on one edge and the upper seat down on the other, a couple
32 mm long. In 5 ms the load cells' sum rose to 1.3 MN while the seats above pulled down by
0.85 MN, more than the weight's momentum could give, and against the inputs' corners that
"rotate freely". Seated on one node each, on one vertical line, the corner turns freely; the
plates are elastic steel because one node now carries each corner's reaction, which would
yield structural steel locally where the real pin's seat spreads it. This was a harness error,
judged on the model's own consistency; no measurement was seen.
