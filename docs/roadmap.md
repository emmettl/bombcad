# Roadmap

Where the model is weakest, and what would be done about it. Each model document has its own
detailed list; this one puts them in order across the whole project.

## Standing of the project

BombCAD answers its original question: blast on simple structures can be simulated on a laptop
GPU at tens to a hundred times slower than real time, with physics that is verified against
theory. Against measurements it is close on one test (a slab) and too weak on another (a
full-scale internal explosion). It is not validated for engineering decisions, and nothing in
it should be used to judge the safety of a real structure.

## Limitations, most important first

| # | Limitation                                                              | Consequence                                                   | Detail |
|---|-------------------------------------------------------------------------|---------------------------------------------------------------|--------|
| 1 | The structural model has been compared with two tests, and fails one of them | On a slab test the peak converges to 112 mm against 108 measured; in a full-scale internal explosion the roof is thrown where the real one deflected 95 mm (the model is weak by about 1.6 on the charge) | [Validation](validation.md#an-internal-explosion-in-a-reinforced-concrete-chamber) |
| 2 | Shear failure and joints are the least reliable predictions             | Breach, punching, direct shear and wall–slab joints are indicative only | [Concrete model](concrete-model.md#limitations) |
| 3 | No afterburning in the charge model                                     | Incident impulse 13–22% low in the open; gas pressure in a closed room half the design value for light charges | [Air-blast model](air-blast-model.md#limitations) |
| 4 | Peak pressure is under-resolved near the charge                         | Close-in loading and spall are unreliable                     | [Air-blast model](air-blast-model.md#limitations) |
| 5 | Collapse and debris have never been compared with anything              | They look plausible; that is all                              | [Structural model](structural-model.md#limitations) |
| 6 | Moving solids are a staircase of whole cells                            | Wall positions are good to a cell; small fragments are crude  | [Structural model](structural-model.md#coupling-to-the-air) |
| 7 | One bonded body of up to eight materials, lattice-aligned geometry; debris pushed crudely by the air | Real buildings only roughly; thrown debris is approximate | [Structural model](structural-model.md#limitations) |
| 8 | The rebound after a slab's peak depends on the mesh, and there is no compaction | Rebound is too large on fine meshes; close-in crushing is wrong | [Concrete model](concrete-model.md#limitations) |
| 9 | The app's interface has not been reviewed by eye                        | Layout or interaction problems may exist                      | Below |

On the last point: the app's logic is covered by tests that drive its model without a window,
and its rendering is checked through offscreen snapshots, but its panels, text fields and file
dialogs were written without being seen on screen.

## Planned work

### Validation first

More evidence is worth more than more features. The sources each step needs, and what is
needed from them, are listed in [Data wanted](data-wanted.md).

1. **Why the chamber's roof is too weak.** Model the diagonal bars across the chamfers and the
   anchorage of the bars into the end walls, and place each mat at its true depth; then compare
   the charge at which the roof is thrown with the test and the paper's own model.
2. **A second and third structural test**, chosen to differ from the first two: a slab with
   steel in both faces, a member that failed in shear, and a wall under an open-air charge. The
   high-strength slabs of the same contest are the obvious next case, since the geometry and
   loading are already set up; their data would have to come from Thiagarajan et al. (2015).

### Then the physics the evidence points to

3. **Afterburning**, the charge model's first priority: the energy the detonation products
   release as they burn in air, limited by the oxygen they meet. It should raise the incident
   impulse in the open and the gas pressure in rooms, both of which are low by the amounts
   expected; UFC 3-340-02 and Kingery–Bulmash are its checks.
4. **Charge model.** Close-in peaks are under-resolved. Replace the balloon with a mapped
   one-dimensional solution or a products gas with its own equation of state.
5. **Shear in concrete.** Inclined cracks with their own opening and sliding, instead of damage
   shared between lattice planes.
6. **The rebound, and compaction** under very high pressure. The slab's mid-span hinge springs
   back twice as far as the specimen did on every mesh.
7. **Cut cells** between moving solids and the air. Moving walls already push the air (a
   piston test matches theory within 2%) and conserve the gas within 0.3%, so cut cells would
   now buy geometric precision only. Deferred.

### Then scale and scope

8. **Shells and solids together**: solid elements near a charge, where the stress through a
   wall's thickness matters, and shells and beams elsewhere.
9. **Several bodies and interfaces**: pieces that can separate or slide (infill against its
   frame, masonry joints), steel sections, glazing. Several materials in one body are done.
10. **Adaptive resolution in the air.**

Done from these lists: blast loads against the full Kingery–Bulmash curves; a coupled test
(the internal explosion); shell elements for walls and slabs and beam elements for columns (2
to 35 times faster coupled, see the [shell model](shell-model.md)); debris loaded by the air
(pressure gradient and drag on loose nodes, with the reaction given back to the air); still
air skipped, with an identical answer (1.6 to 1.7 times faster on the street scene, see
[Performance](performance.md#air-solver)).

### Usability, in parallel

- Review the app on screen and fix what is found.

## Things tried and set aside

- **Fixes for the wrong cause.** A fine mesh of the validation slab collapsed, and nonlocal
  crushing, a stronger hourglass cap, a frozen compressive rate factor and wider crushing
  bands were each tried before tracing one element through the collapse found the two real
  errors (Poisson swelling counted as cracking; a missing normalisation in the compressive
  rate law). Nonlocal crushing and a reduced form of the hourglass cap were kept, the first
  switched off by default; the rest were removed. The lesson: trace a failing element before
  changing the model.

- **Fixed design factors for strain rate** (UFC 3-340-02): deliberately conservative; they
  predict 130 mm for the slab test against 108 mm measured. The strain-rate laws are the
  default; the factors remain available as an option.
- **A rotating-crack concrete model**: simple and robust, but with no shear transfer across
  cracks it cannot hold together a slab without steel through its thickness.
- **Tension softening scaled by element size in reinforced concrete**: dissipates a crack's
  energy in every row of elements and makes the answer depend on the mesh.
- **Contact between nodes that were once neighbours**: creates energy when the element between
  them fails in compression, and blew a wall apart.
- **Retrieving the Kingery–Bulmash polynomial coefficients and a second open structural data
  set** automatically: the sources found either refused automated access or re-used each
  specimen for several shots. The coefficients, the design manual and the chamber test were
  later supplied by hand.
