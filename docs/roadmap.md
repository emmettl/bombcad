# Roadmap

Where the model is weakest, and what would be done about it. Each model document has its own
detailed list; this one puts them in order across the whole project.

## Standing of the project

BombCAD answers its original question: blast on simple structures can be simulated on a laptop
GPU at tens to a hundred times slower than real time, with physics that is verified against
theory and, in one case, close to a measurement. It is not validated for engineering decisions,
and nothing in it should be used to judge the safety of a real structure.

## Limitations, most important first

| # | Limitation                                                              | Consequence                                                   | Detail |
|---|-------------------------------------------------------------------------|---------------------------------------------------------------|--------|
| 1 | The structural model has been compared with one test, and is only nearly mesh-converged on it | Unknown accuracy elsewhere; peaks within about 10% | [Validation](validation.md#results) |
| 2 | Shear failure is the least reliable prediction                          | Breach, punching and direct-shear results are indicative only | [Concrete model](concrete-model.md#limitations) |
| 3 | Peak pressure is under-resolved near the charge                         | Close-in loading and spall are unreliable                     | [Air-blast model](air-blast-model.md#limitations) |
| 4 | Incident impulse is 13–23% low; blast loads are checked at only three ranges | Loads on walls look right where checked, but the charge model is crude | [Validation](validation.md#blast-loads-against-empirical-references) |
| 5 | Collapse and debris have never been compared with anything              | They look plausible; that is all                              | [Structural model](structural-model.md#limitations) |
| 6 | Moving solids are a staircase of whole cells                            | Wall positions are good to a cell; small fragments are crude  | [Structural model](structural-model.md#coupling-to-the-air) |
| 7 | One deformable body, one material, lattice-aligned geometry             | Real buildings cannot be represented                          | [Structural model](structural-model.md#limitations) |
| 8 | The rebound after a slab's peak depends on the mesh, and there is no compaction | Rebound is too large on fine meshes; close-in crushing is wrong | [Concrete model](concrete-model.md#limitations) |
| 9 | The app's interface has not been reviewed by eye                        | Layout or interaction problems may exist                      | Below |

On the last point: the app's logic is covered by tests that drive its model without a window,
and its rendering is checked through offscreen snapshots, but its panels, text fields and file
dialogs were written without being seen on screen.

## Planned work

### Validation first

More evidence is worth more than more features. The sources each step needs, and what is
needed from them, are listed in [Data wanted](data-wanted.md).

1. **A second and third structural test**, chosen to differ from the first: a slab with steel in
   both faces, a member that failed in shear, and a wall under a real charge. The high-strength
   slabs of the same contest are the obvious next case, since the geometry and loading are
   already set up; their data would have to come from Thiagarajan et al. (2015).
2. **Blast loads against the full Kingery–Bulmash curves.** Three tabulated points are used
   now, and the impulse on a wall agrees within 5% to 10% at them; the polynomials would extend
   the check closer in and farther out.
3. **A coupled case**: charge, stand-off, wall and measured deflection in one test.

### Then the physics the evidence points to

4. **Charge model.** The incident impulse is low and close-in peaks are under-resolved. Replace
   the balloon with a mapped one-dimensional solution or a products gas with its own equation
   of state.
5. **Shear in concrete.** Inclined cracks with their own opening and sliding, instead of damage
   shared between lattice planes.
6. **The rebound, and compaction** under very high pressure. The slab's mid-span hinge springs
   back twice as far as the specimen did; elements that bend (item 8) are the likeliest fix.
7. **Cut cells** between moving solids and the air. Moving walls already push the air (a
   piston test matches theory within 2%) and conserve the gas within 0.3%, so cut cells would
   now buy geometric precision only. Deferred.

### Then scale and scope

8. **Shell and beam elements**, or coarser solid elements away from damage, so that a whole
   building is affordable.
9. **Several bodies and materials**: steel frames, glazing, masonry with joints.
10. **Adaptive resolution in the air.**

### Usability, in parallel

- Review the app on screen and fix what is found.

## Things tried and set aside

- **Fixed design factors for strain rate** (UFC 3-340-02): too conservative to reproduce the
  slab test, which they predict collapses. They remain available as an option.
- **A rotating-crack concrete model**: simple and robust, but with no shear transfer across
  cracks it cannot hold together a slab without steel through its thickness.
- **Tension softening scaled by element size in reinforced concrete**: dissipates a crack's
  energy in every row of elements and makes the answer depend on the mesh.
- **Contact between nodes that were once neighbours**: creates energy when the element between
  them fails in compression, and blew a wall apart.
- **Retrieving the Kingery–Bulmash polynomial coefficients and a second open structural data
  set** during development: the sources found either refused automated access or re-used each
  specimen for several shots. Tabulated Kingery–Bulmash values at three scaled distances were
  found in a United Nations guideline and are used instead.
