# ContinuumKit adoption

BombCAD pins [ContinuumKit `0.1.0-alpha.30`](https://github.com/emmettl/ContinuumKit/releases/tag/0.1.0-alpha.30)
and commits the resolved Git revision (`2f14a4a`). Alpha.30 carries the Linux stand-in for
Apple's simd that BlastModel's own shim was (`Sources/LinuxSIMD`, the same operation order and
fusing, checked against Apple's by `SIMDParityTests`), so BombCAD's copy is gone; the Mac never
compiles it. Alpha.29 changed nothing that the Mac compiles for the modules BombCAD uses; its
CPU libraries build on Linux, which BlastModel needs there (the BlastModel split, [Scripts/split](../Scripts/split/README.md)). Since alpha.19 the pressure-gradient
fit (`FiniteVolumePressureFit`) solves its least squares with the shared `PivotedQR`;
since alpha.25 contact's table and search are the shared `ContactSearchMetal`; since alpha.26
its timber shells and beams run a single-precision copy of the shared `TimberFailure`, which
BombCAD contributed ([ContinuumKit#93](https://github.com/emmettl/ContinuumKit/pull/93)) and tests
its copy against (`TimberTests`); since alpha.28 the 3D view (`SceneRender`'s `OrbitControlView`)
is no stop in the window's Tab loop ([ContinuumKit#94](https://github.com/emmettl/ContinuumKit/pull/94)),
as BombCAD's real-screen review asked (alpha.27 was tagged but never published: its release runs
met the Mac mini's new Homebrew Python, which [ContinuumKit#95](https://github.com/emmettl/ContinuumKit/pull/95)–[#97](https://github.com/emmettl/ContinuumKit/pull/97) keep out of the gate). Source picking and fragment segments use the
shared closed-box query in `SceneModel`; application ownership and mechanical
coupling remain in BombCAD.

## Document diagnostics adoption — 9 October 2026

The exact `0.1.0-alpha.5` pin resolves to
`7d5ef9d0ca7b415d3fef86b5400017bb43111a3c`. Shared project errors now identify malformed
payload filenames and missing, mistyped or invalid manifest fields, including asset array
paths. Unsupported package versions still fail before other metadata is decoded.

The [exact-tag release workflow](https://github.com/emmettl/ContinuumKit/actions/runs/37974874568)
passed on the physical Mac mini before publication, including 141 independent tests,
verified Metal compute and the clean optimized Git consumer. BombCAD's 15 selected
document-integration tests cover the shared errors, application settings/view diagnostics
and project round trips. Its optimized app build and packaged CLI checks also pass;
malformed settings and missing manifest metadata fail before starting a simulation.

App-linked CAD module source is identical to alpha.4 except DocumentKit. The prerelease
also contains acoustic reference/conformance additions in BenchmarkSupport and a bounded
linear-wave extraction design checkpoint; these do not extract a shared wave-update solver.

## CAD foundations transition — 8 October 2026

The initial transition moved BombCAD and the then-nested RoomCAD package to the public
ContinuumKit repository, exactly pinned to `0.1.0-alpha.1`. Each package committed its
`Package.resolved`.

The original five module names remain: SceneModel, SceneView, SceneRender, GeometryImport
and DocumentKit. Their implementations and Scene.metal originated at BombCAD commit
ad130448dc8a3d8b3181ad0107defcd38c29aef3 and are byte-identical in this release.
The original local package is retired after both consumers' dependency transitions.

Keep the compatibility aliases in BlastCore/BlastRender. Saved documents still use
`dev.simulationkit.project`; no data migration or schema change is introduced.

SwiftPM names resource bundles after the package: application packaging and RoomCAD's
release checks now include `ContinuumKit_SceneRender.bundle`. Test the packaged app's
shader/resource lookup as well as executable compilation.

Library verification belongs to ContinuumKit's independent tests and clean Git consumer.
Applications retain their integration, model, measured-scene and UI checks. The observed
RoomCAD full-suite calibration discrepancy remains a separate issue; this migration
does not adjust its assertions or change acoustic behavior.

## Spatial query adoption — 9 October 2026

The closed-box queries from [ContinuumKit PR #7](https://github.com/emmettl/ContinuumKit/pull/7)
are released at `0.1.0-alpha.4`, commit `d3c7367ba43940155f7e33da738e6f5058723fd5`.
Source picking and fragment segments use the
shared geometry while retaining their original parallel thresholds and stationary
contact convention. The shared product needs no renderer or application schema.

Core verification passes all 57 tests, the optimized fetched Git consumer, actual
Metal compute and offscreen rendering, and adiabatic/acoustic reference reports on
M4 Max. The [exact-tag release workflow](https://github.com/emmettl/ContinuumKit/actions/runs/37854603915)
verifies the fetched version on the physical Mac mini before publication.
BombCAD retains application source-picking, multiple-owner,
fragment streaming/worker, import/document and headless-run checks. Its optimized
application build also succeeds. The manifest uses an exact version requirement,
and `Package.resolved` retains the reviewed release revision for reproducibility.

After integration with the current application branch, 188 selected tests and eleven
release/nightly script checks pass. The optimized app package passes deep strict
signature verification. Its bundled executable completes a headless two-structure
scene, writes a version-4 project retaining both response histories, and exports CSV
and USD with object attribution. These application checks preserve the documented
model scope; they do not establish new physical validation.

## Planar ideal-gas wall reference — 10 October 2026

The exact alpha.13 dependency resolves to
`b6ff3ca28eb96bbac23ec15d93a13afda99b2be9`. The public CompressibleFlow product
now supplies the stateless wall-pressure relation through BombCAD's internal bridge.
The bridge preserves the application's result shape and invalidState failure
category. Geometry, signed wall-frame velocity, reconstruction, gas transport,
timestep selection and accepted wall impulse/work integration remain app-owned.
CAD foundation source is unchanged from alpha.5.

Ordinary-state operation order and the incident-state signal estimate are preserved.
Near gamma = 1, the shared rarefaction uses log1p/exp; invalid or unrepresentable
intermediates and non-vacuum pressure underflow now fail explicitly. Two application
bridge tests cover these deliberate numerical adaptations. The signal estimate is
not an exact shock-front speed or a universal downstream-characteristic certificate.

The reproducible comparison uses immutable pre-adoption commit
`089d0a25475a3de8c541dd1a6531c7503e60163c`, with the identical benchmark fixture
copied into its disposable build. The baseline retains its original source and
existing compiler warnings. Both variants use the same release build flags.
The benchmark requires byte-identical complete reports for 360 ordinary wall cases,
twelve piston runs (three spacings, both wall directions, both reconstruction modes),
33 native field clocks per piston and every accepted wall-load interval, plus eight
public wall-reflection histories and the eight-case wall-pressure study. Reflection
records expose their complete public history, rather than every interior field.
Independent postconditions check clocks, case identity and mass/momentum/energy
accounting; deliberate corruption controls test completeness and rejection.

Run `bash Scripts/check-wall-adoption.sh /absolute/output/path` from a clean
committed candidate, or dispatch Check with suite `wall-adoption` on the physical
Mac mini. Reports retain original/shared values, resolved Git pins, source hashes
and host/toolchain identity. Full app CI remains separate and verifies the packaged
app signature after lint, script checks, build and tests.

[Acceptance record](wall-adoption-verification.json) records the measured producers,
application gates and source equivalence across the integration checkpoint. This
adoption establishes numerical preservation for the declared cases. Measured blast
accuracy and bulk gas/moving-geometry extraction remain separate tasks.

## Prescribed gas packet adoption — 10 October 2026

Exact alpha.14 resolves to f5543e3c336a80ec86868c3f0f245b688dfba148. The internal
FractionalGasTransport name now aliases public PrescribedGasTransport; its local
104-line numerical implementation is retired. Caller transfer graphs, geometry,
volume trajectories, reconstruction, Euler fluxes, reservoirs, timesteps and body
integration stay app-owned. Unchecked construction/views, checked extensive-state
advance, failure categories and the dry cleanup budget retain the source contract.

The new packet comparison freezes pre-adoption main e5ead4b55ad20684fde635ca2c56d830fefd4037
and copies the identical fixture into its disposable build. It retains two accepted
remap replays (all 32 intervals and native cells per profile), 32 moving histories
covering two spacings, aligned/rotated bodies, Euler/Heun, linear/conserved-quadratic
reconstruction and uniform/nonuniform gas. Every one of their 128 declared physical
intervals retains full native cells, partitions, reservoir packets and wall impulse,
moment/work arrays. Actual opening and closing transitions occur in these histories.
The sealed-work, geometry-remap, static-connected and crossing studies retain their
complete public records; those records do not expose every internal field. The
existing complete wall/piston benchmark is also required.

Independent validators check completeness, physical clocks, native state/bit identity,
positive gas, partition support and gas/reservoir/wall mass/momentum/energy budgets.
Corruption controls alter both copies to test beyond paired equality. Run
`bash Scripts/check-packet-adoption.sh /absolute/output/path` from a clean committed
candidate or dispatch suite `packet-adoption` on the physical mini. Full app/package
checks remain separate; [acceptance](packet-adoption-verification.json) records exact
measured source scopes, failures, repairs and integration.

The earlier adiabatic framework pin remains frozen. Its original packet source is
now canonical verification-only data with a protected Git blob/hash. A separate
SharedAdiabaticBenchmark resolves exact alpha.14 and copies the actual production
alias. Both adapters use identical cases and compare every recorded sample, while
retaining independent conformance/refinement gates and correct source metadata.
This preserves historical evidence and checks the current reusable implementation.

## Prescribed Euler adoption acceptance

The experimental fractional Euler operator now binds directly to released
alpha.16, including the public result assembly used by app-owned SSPRK2 wrappers.
Geometry, traces/limiting, aggregation/scatter, volume trajectories, reservoirs,
timestep/body policy and production Metal air remain here. Two source files need
explicit CompressibleFlow imports for the newly external Face/Wall declarations;
their numerical bodies are unchanged. Complete two-host app/benchmark/package
gates pass; the [acceptance aggregate](euler-adoption-verification.json) preserves
source identities, initial failures/corrections and current peer integration. The [comparison fixture](../Fixtures/EulerAdoptionBenchmark/README.md)
freezes the current pre-adoption application and retains all affected native
Euler/staged/tube/group/moving-gas/piston/wall evidence. Earlier releases and
historical fixture identities remain verifiable.

## Contact search adoption — 15 October 2026

Structure and shell contact now use ContinuumKit's `ContactSearchMetal`
([alpha.25](https://github.com/emmettl/ContinuumKit/releases/tag/0.1.0-alpha.25), extracted from
BombCAD at `659091b`; see [ContinuumKit#91](https://github.com/emmettl/ContinuumKit/pull/91)).

`ShaderLibrary` compiles `MetalContactSearch.functionSource()` ahead of BombCAD's shaders, and
BombCAD's contact code calls the shared functions:

- `contactCell` and `contactBucket`, and their shell twins, call `cksCell` and `cksEntry`;
- the clearing pass calls `cksClearEntry`, and the insertion chain `cksInsert`;
- the listing test calls `cksListed`, and the entries a search visits are chosen by `cksSearches`.

Rubble and contact between bodies reach the table through the same wrappers. The pair forces,
lattice-neighbour exclusion, buried nodes, the movement thresholds, the stamp, the table's sizing
and its buffers stay in BombCAD, so the order of every sum is unchanged.

Built from the same tree with and without the shared functions:

- all seven `blastbench digest` cases are bit-identical, including the walls that fail (20
  elements each, solid and shell);
- so are the node hashes of `blastbench contact-profile` over 1,500 steps for the solid
  building, the shell building, the solid building with its front wall breaking up (4,625
  elements broken), and the terraced houses in contact.

## Terrain cut cells — 15 October 2026

Before the terrain's [cut cells](terrain.md#cut-cells) were written, ContinuumKit, its
extraction notes and open branches, and Edgerton were checked for anything to reuse. Nothing
fitted: CompressibleFlow is a CPU, first-order (Rusanov) fractional-volume flux for
prescribed geometry, with moving cut cells on its roadmap; Edgerton has no flow solver; BombCAD's
own CPU fractional-volume code (`FractionalBoxGeometry`, merging connected small cells) is for
moving boxes and not on the GPU. The new scheme is a Metal kernel inside BombCAD's split
MUSCL–HLLC sweeps: static heightfield geometry, apertures by quadrature, a mirrored-Riemann
wall pressure and flux redistribution per column once a step.

**A candidate, not yet.** The geometry (`TerrainCutGeometry`: α, apertures and walls of a
heightfield, by quadrature) is pure Swift with its own tests and would sit naturally beside
CompressibleFlow's fractional geometry. The kernel is bound to BombCAD's state layout, sweeps,
tiles and gravity table, and has one consumer. Cut cells are now the terrain's default, refined
or not (15 October 2026). Propose the geometry, and the redistribution as a reference CPU
routine, if a second consumer (ContinuumKit's own moving cut cells, or Edgerton) wants them.

## Overlap with Edgerton and candidates for ContinuumKit — 14 October 2026

A read-only audit of three repositories:

- BombCAD at `0fc49f6`.
- ContinuumKit `origin/main` at `eba5995`. The newest tag is alpha.23. BombCAD pins alpha.21, RoomCAD alpha.23 and Edgerton alpha.22.
- Edgerton `origin/main` at `8fc6a3208`, a private repository owned by Codex.

No code moved. The aim is that no piece of research is done twice, and that well-tested numerics useful to more than one project end up in ContinuumKit.

The ContinuumKit rules this audit took as given (its `ROADMAP.md`, `ARCHITECTURE.md` and `VERIFICATION.md`):

- A primitive needs a contract, no application imports, independent references, refinement checks where relevant, recorded provenance, a clean consumer and an exact-tag release.
- Calibrated laws (gel, peel, concrete) stay with their applications.
- Different physics is not merged because it shares a place.
- General 3D contact, fracture policy and uncertainty statistics stay with applications for now.

**ContinuumKit today.**

- Released:
  - The CAD foundations (from BombCAD).
  - Closed-box queries (from BombCAD; a Double version for RoomCAD).
  - Acoustic references and the CPU/Metal linear wave update (from RoomCAD).
  - `CompressibleFlow`: the ideal-gas wall Riemann relation, prescribed gas transport, and the fractional Euler flux with γ = 1.4 (all from BombCAD).
  - `SpectralTransforms` (from RoomCAD).
  - `Numerics`: affine fit, `PivotedQR` (which replaced BombCAD's weighted QR) and through-origin least squares.
  - `Thermodynamics.AdiabaticReservoir` (from Edgerton).
  - `SolidMechanics.OrthotropicPlaneStress` (Edgerton's plywood P1, alpha.22).
- Merged on 14 October but in no release:
  - Edgerton's veneer compression and veneer damage laws.
  - Fixed-direction normal contact flow.
  - Restarted GMRES.
  - The isotropic tetrahedron with its work correction.

  These were verified on the mini only. They await a release the user authorises, and Edgerton's adoption of them is deferred.

**Edgerton today.**

- A gel-first visual laboratory, with an apple as the stretch target and Target Mechanics coupons for steel, plywood and (just begun) concrete.
- It has no `Tests/` target. Verification is through CLI study modes and Python checkers, and no quantitative agreement with experiment is claimed.
- The parts that matter here:
  - **Explicit 3D gel:** a lattice of springs and tets, 26-neighbour.
  - **Contact:** a GPU node-sphere spatial hash, frictionless, with optional swept prediction. Capsule-surface penalty contact, and an implicit discrete-gradient contact.
  - **Steel:** finite-strain J2 plasticity. It is rate-independent and isothermal, with failure-initiation and cohesive crack-band coupons.
  - **Hex elements:** fully integrated Hex8 was rejected in bending (9.8× too stiff, from parasitic shear); Hex27 passes. There is no hourglass control.
  - **Implicit Newton–GMRES:** about the same cost as explicit at matched accuracy.
  - **Rate effects:** none outside the gel's viscoelastic branches.
  - **Shock EOS:** none.
  - **Penetration:** no penetration law; the visual mode uses a drag-form impact.
- Concrete milestone C1, a read-only inventory of BombCAD's law at `01e5896` (12 October, 23,414 Metal queries over 14 paths), is done. C2, adapter parity, is next. The plan says BombCAD leads on the concrete law.

### The overlaps

The **ContinuumKit** column gives its status: released, merged but unreleased, absent, or held by its rules.

| Topic | BombCAD: state and evidence | Edgerton's counterpart | ContinuumKit | Recommendation |
|---|---|---|---|---|
| Concrete law (cracking, crushing, interlock, dowels, bond slip) | Total-strain law with three turning cracks. Unit laws within 2–6%; members 98–137%; nothing converges ([validation](validation.md#convergence-on-todays-defaults)). A ~1,300-line Metal kernel on BombCAD's lattice | C1 inventory of `01e5896`; C2 adapter next; no law of its own | Held: calibrated laws stay in applications | **Coordinate now.** Since `01e5896` the law has changed: a 100 µs strain-rate window is the default (`5f5772d`), and the compaction start and bare-bar rules for materials softer than structural concrete changed (`278e111`, `dbcabf2`, `b9f995e`). C2 should pin a named BombCAD revision and say which options it adopts. BombCAD stays the owner |
| Concrete and steel rate effects | CEB-FIP MC1990, fib MC2010 and CEB 187 dynamic increase factors (within 6–7%), and the strain-rate window. Tension at 1–100 /s is blocked for want of data; under-strengthens events shorter than ~30 µs | None (steel is rate-independent; the gel has viscoelastic branches only) | Absent | **Leave in BombCAD**, and offer the factors as small pure functions when Edgerton's C or T milestones reach rate. If a second consumer appears, extract them as scalar laws with their published curves as references |
| Compaction and shock EOS | HJC-type compaction floor only (3 GPa at 12% checked); locks under contact charges | None (HJC only as a captured BombCAD trace) | Absent; `Thermodynamics` is meant for EOS later | **Coordinate before either starts.** Spall and contact charges (BombCAD) and plate perforation (Edgerton T4) both need a solid shock EOS such as Mie–Grüneisen. It is a natural ContinuumKit scalar law, verified against Hugoniot data; one owner should write it |
| Steel | Cyclic Menegotto–Pinto bars with CEB rate (within 3%), plus a von Mises S355 solid | T1/T2 finite-strain J2 (45 coupon checks, ≤ 0.9%), T3 failure initiation and cohesive crack band; plate convergence still failing | Held ("separately bounded research") | **Leave both**: different scopes (rebar in members against plate coupons). When BombCAD needs steel plates or members as solids, it should adopt Edgerton's J2 through ContinuumKit, not grow its own |
| Hex elements and hourglass control | One-point hex with Flanagan–Belytschko stiffness hourglass control, which does 7–15% of the work at peaks (22–26% on four elements through Wu's slabs) and 37% in Hrynyk's cone band. Planned: Belytschko–Bindeman assumed strain or selective full integration | Hex8 full integration rejected in bending (9.8×/3.2× energy, parasitic shear); Hex27 3×3×3 passes; no hourglass control | Absent (only the tetrahedron) | **Flag: BombCAD is about to research this.** Edgerton's evidence rules out plain full integration for bending; take the assumed-strain route. Read `PLYWOOD_CONCRETE_PLAN.md` §Steel and the Hex8/Hex27 studies first |
| Shells and beams | MITC4 degenerated shell (Navier within 3%), fibre beams, EC2 punching check | Orthotropic plane-stress layered shell (P1, now in ContinuumKit), rejected Timoshenko two-ply beam | `OrthotropicPlaneStress` released | **Leave.** BombCAD's shells are layered concrete. Adopt the orthotropic law only if timber or plywood walls are ever wanted |
| Contact | Deterministic GPU node-sphere hash (atomic-min slots, wrapped table, stamps), friction, safeguards against creating energy. The exact pair skip took pair time 30% lower. Rubble particles; cross-body contact with momentum to 1e-3 | Its own GPU node-sphere hash (frictionless), capsule-surface penalty, swept prediction, implicit discrete-gradient contact. Apple passage still deeply overlapped at 4× penalty | `NormalContactFlow` (scalar, fixed direction) merged unreleased; general 3D contact held | **Duplication.** Two GPU node-sphere broad phases. Propose a deterministic GPU spatial-hash broad phase as a ContinuumKit candidate (stage "stabilizing"): BombCAD's table, with Edgerton as second consumer. Pair forces and policy stay in each application. BombCAD's 1 m/s separation limit and kick cap may help Edgerton's deep overlap |
| Punching, plugging, penetration | No penetration model. Hrynyk's blind test: cones form but do not slide, and none of the slabs punched in the model while all three did in the test. Candidates: an embedded sliding crack (E-FEM), removal at shear strain, a finer ring | T3 crack band and cohesive interfaces; T4 plate impact (plug, perforation) planned; no concrete punching | Absent; fracture is "consider" in Stage 5 | **Flag: both are about to research crack representation for plugging.** Agree one thread: BombCAD's E-FEM sliding crack for concrete, informed by Edgerton's cohesive crack-band coupons, which are already gated. Do not build a second cohesive kernel |
| Fracture regularisation | Crack band on fracture energy (within 5%); nonlocal averaging (stage 2) | Veneer damage with band length (in ContinuumKit, unreleased) | Merged, unreleased | **Leave.** Same idea, different physics; ContinuumKit forbids merging it. Cite each other's checks |
| Implicit solvers | None (explicit only) | Newton–GMRES; no clear win over explicit | GMRES merged, unreleased | No action. If BombCAD needs quasi-static members (Peterson, standing under gravity), use ContinuumKit's GMRES |
| Tetrahedra | None (lattice hexes and shells) | Isotropic tets for gel and apple | Merged, unreleased | No action now. A tetrahedral IFC structure path would start from it |
| Soil column and footings | Layered 1D column with hysteresis and transmitting base (exact energy; d'Alembert and c/4H within 1%). Gazetas, Wolf cones and CyclicSand footings (FoRCy within 11–14%) | None | Absent | **Leave in BombCAD.** The column is pure Foundation and the most portable model here, but it has no second consumer |
| Blast references (Kingery–Bulmash, Kinney–Graham, UFC 3-340) | Swisdak polynomials within 1% of his table; pure Foundation | None | Absent; charges are "BombCAD-owned" | **Leave**, unless another project needs blast loads |
| Air solver, refinement, afterburning, mixing | Metal HLLC/MUSCL with refinement levels (Sod, Sedov, KB checks) | Acoustic leapfrog; 2D forced wave not migrated | Euler flux (γ = 1.4) and gas transport released from BombCAD; blast solver a "later backend extraction" | **Leave** the production solver. ContinuumKit's next step there is its own decision |
| Deflagration, thermal radiation, Mott fragments, masonry joints | Each with its own checks; app-specific physics | None (fragments are rigid pieces with inertia) | Absent | **Leave** in BombCAD |
| Evidential standing and error bands | Standing table and error bands with mesh, spread and scatter tables; tests fail when an option lacks an entry. `EnsembleSampling` (Latin hypercube, SplitMix64, rank correlation) | Repeats "verification is not validation" but has no standing framework | Absent; uncertainty statistics are caller-owned | **Candidate, small.** `EnsembleSampling` and the generic `ErrorBand` type could go to `Numerics`. BombCAD's tables stay. Worth it only if Edgerton wants bands for its coupon or impact comparisons |

### The actions, ranked

1. **Before Edgerton's C2, tell Codex what changed in BombCAD's concrete law.**
   - What changed: the strain-rate window became the default; the soft-material compaction and bare-bar rules moved.
   - Agree: that C2 pins a named BombCAD revision and lists the options it takes.
   - Cost: under an hour. Who: the user to Codex, with a Claude session writing the note.
2. **Before BombCAD's element work, read Edgerton's Hex8/Hex27 evidence.**
   - The work in question: replacing hourglass control, and the stage-2 embedded crack.
   - Plan the assumed-strain hex rather than plain full integration.
   - Cost: an hour or two. Who: the Claude session that takes up concrete stage 2.
3. **Agree one research thread for crack representation in plugging and punching.**
   - BombCAD's E-FEM sliding crack and Edgerton's T3/T4 cohesive crack band should not grow apart.
   - Cost: a short design note in each plan. Who: a Claude session drafts; the user takes it to Codex.
4. **Propose a deterministic GPU contact broad phase as a ContinuumKit candidate.**
   - The candidate: BombCAD's wrapped hash table with ordered slots and moved marks, with Edgerton as the second consumer.
   - Cost: days to the ContinuumKit standard (contract, independent oracle, two-host release, parity in both applications).
   - Who: a Claude session writes the contract and the BombCAD side; Codex reviews and owns the Edgerton adoption.
   - Done: [ContinuumKit#91](https://github.com/emmettl/ContinuumKit/pull/91) (`ContactSearch`, `ContactSearchMetal`), released in alpha.25 and adopted by BombCAD with `blastbench digest` bit-identical (see above). Edgerton's adoption is Codex's.
5. **Plan one solid shock EOS for ContinuumKit before either application needs it.**
   - Its uses: spall and contact charges (BombCAD), perforation (Edgerton T4).
   - Cost: a few days with Hugoniot references. Who: whichever project reaches it first, after agreeing on it.

The release of Edgerton's four merged primitives as alpha.24 needs the user's authorisation and belongs to Codex. BombCAD needs nothing from alpha.22 or alpha.23 and stays on alpha.21 until it adopts something new.

## Notes for Edgerton

### Concrete law changes since C1's inventory (`01e5896`), for C2 — 14 October 2026

C1 inventoried BombCAD's concrete law at `01e5896` (12 October 2026). Since then:

1. **The strain-rate window is the default (`fa13bb9`, then `5f5772d`).**
   - The rate laws (CEB-FIP MC1990 compression, fib MC2010 tension, CEB 187 steel) see the strain rate averaged over 100 µs.
   - Before, it was averaged over the last 50 structural steps, a window that shrank with the element and the step.
   - The kernel is unchanged; only the uniform changes. `rateFilter` is now `1 / StructureModel.strainRateWindow` (1e4 per second), where it was `1 / (50 · criticalTimeStep)`. Solids and shells both.
   - `strainRateWindow = nil` (saved as 0) restores the 50-step average.
   - A saved model without the field now runs with 100 µs.
   - Events shorter than about 30 µs are under-strengthened.
2. **Compaction for materials softer than structural concrete, meaning bulk modulus below 12 GPa (`278e111`).**
   - The HJC compaction curve's rise above crushing is scaled by K / 12 GPa.
   - With K ≥ 12 GPa, the original path runs bit for bit.
3. **Compaction start and bare bars, again only below K = 12 GPa (`dbcabf2`, `b9f995e`).**
   - Compaction counts from the volume an element had when it was last confined, if it was crushed past the curve's onset unconfined.
   - An element left as bare bars is removed at a quarter of its volume.
   - Structural concrete keeps the old rules bit for bit until the concrete cases have been rerun with the new ones.
4. **`ElementState` grows from 192 to 196 bytes (`dbcabf2`).**
   - A trailing `float compactionStart` (zero unless the rule in item 3 applies).
   - `static_assert(sizeof(ElementState) == 196)` holds it to `StructureSolver.stateStride`.
   - The planned E-FEM sliding crack would take it to 212 bytes behind a function constant (on a branch, not on main); read the size from `stateStride`.

Nothing else in the constitutive path changed. The contact pair skip (`afa5c84`) touches only contact.

**Recommendation for C2:**

- Pin a named BombCAD revision at or after `b9f995e`, for example the main of the day.
- List the options the adapter takes, including `strainRateWindow`.
- Read the state size from `stateStride` rather than writing in 192 or 196.
- For structural concrete, C1's 14 paths should still agree, except for rate-dependent queries, which need the new `rateFilter`.
