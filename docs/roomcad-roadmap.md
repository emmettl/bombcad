# RoomCAD and convolution reverb roadmap

Status: October 2026. The initial shared-package extraction is implemented:
`Packages/SimulationKit` supplies SceneModel (Box and Grid) and SceneView (OrbitCamera).
BombCAD consumes it with compatibility aliases.

The first acoustic backend is implemented in the separate `RoomCAD` package. It covers M2 items 1–3
and 5: a rectangular-room image-source model with octave-band absorption, air attenuation, and
stereo 32-bit float WAV export with a JSON description. Driftbox's own convolver plays the exported
files. See [Room-acoustics model](room-acoustics-model.md). A first RoomCAD app with versioned `.roomcad`
documents is also implemented (M1 items 3 and 4); see [RoomCAD app and documents](roomcad-app.md).
The wave solver and the Driftbox rack effect remain proposed work.

The save-file foundation is also implemented: DocumentKit and BombCAD's `.bombcad` document workflow
persist scene, run and view settings, with container integrity checks. See [Save files](save-files.md).
Native document windows, autosave and unsaved-close handling are implemented. The importer is
on main, with versioned embedded source meshes, stable part references and detached-edit round trips.

## Goal

Design a room, choose its surface materials, place a sound source and receivers, and generate
an impulse response that can be auditioned and exported for convolution reverb. A potential
Driftbox rack effect consumes those responses in real time; RoomCAD generates them offline.

The first useful deliverable is a rectangular room producing a stereo, 32-bit float WAV at
48 kHz, with one source and two receivers. A later hybrid model combines low-frequency wave
simulation with higher-frequency geometrical acoustics. Exporting a low-frequency response
at 48 kHz does not make it broadband.

## Architecture and sharing

Start with a shared Swift package containing focused library targets, consumed by separate
BombCAD and RoomCAD app packages. Prefer one repository while shared APIs are changing, so
both apps can be checked in the same commit. Decide the repository location before moving
existing sources; this document does not prescribe a migration of the current checkout.

| Module | Responsibility | Consumers |
|---|---|---|
| SceneModel | Geometry, transforms, openings and shared scene identifiers | Both apps |
| SceneView | Shared camera, bounds framing and viewport mathematics; implemented first | Both apps |
| DocumentKit | Versioned document containers and asset handling; foundation implemented | Both apps |
| GeometryImport | File readers, source meshes, parts, transforms and geometric diagnostics | Both apps |
| MetalSupport | Reusable device, buffer, shader-loading and dispatch utilities | Both solvers and rendering |
| SceneRender | Camera, selection, geometry and generic field rendering | Both apps |
| BlastCore | Blast equations, charges, measurements and validation | BombCAD |
| AcousticCore | Sources, acoustic propagation, boundaries and room-response generation | RoomCAD |
| ImpulseResponseKit | Response data, channel mapping, audio I/O and conditioning | RoomCAD; potentially Driftbox |
| ConvolutionDSP | Real-time convolution and response switching | RoomCAD preview; potentially Driftbox |

Extract shared code when there is an actual second consumer. Keep solver-specific shaders
with their owning targets and preserve package resource loading. Shared rendering consumes
scene and field data rather than importing a particular solver. Keep blast charges and sound
sources in app-specific documents around shared geometry; acoustic absorption and structural
material properties are separate concepts.

Driftbox's language, audio framework and rack interfaces must be inspected before deciding
whether it can consume Swift libraries. WAV plus documented channel mapping is the initial
interchange contract regardless of language. Structural solvers and editor components remain
in BombCAD until RoomCAD needs them and their dependencies can be extracted cleanly.

### Reuse the model-import work

The integrated BombCAD importer is a major shared foundation: OBJ/STL parsing, scale and axis
conversion, placement, mesh diagnostics, preview overlays and selection can serve both apps.
Its current implementation lives in BlastCore and BombCAD; extract the shared pieces when
RoomCAD needs them.

Keep the source mesh, stable part identifiers and material-group references as the canonical
import. Voxel boxes are derived data for a particular solver and resolution. RoomCAD's
geometrical backend needs the original surfaces and normals, while a wave backend can reuse
occupancy sampling. Preserve named parts and assignments across resampling.

Separate file parsing from acceptance policies: BombCAD's solid-volume sampling requires
closed volumes, while an acoustic room can be represented by a closed enclosure of surfaces
and can contain thin surface partitions. A valid room interior must not be mistaken for an
occupied solid. Interior orientation, openings, leakage and enclosure checks therefore need
an acoustic-specific interpretation of the shared geometry.

Share geometric overlap and connectivity diagnostics, but keep blocked-charge checks,
structural support assumptions, source/receiver placement checks and solver conversion in
their respective adapters. Acoustic absorption/scattering assignments and structural strength/
reinforcement assignments reference the same parts through separate property sets.

## Save-file design proposal

Agree the document contract before the 0.2 importer release. The previous save path encoded
only a Scenario as JSON; the new foundation also saves run and view settings. The importer work adds source
meshes, part assignments and derived volumes to saved scenarios. Preserve support for those
files with a simple JSON reader; extensive legacy migrations are not a priority.

### Container and ownership

Use a native macOS document package (a directory presented as one file), with proposed
extensions `.bombcad` and `.roomcad`. Share container conventions, with application-specific
scene and settings codecs initially. Extract a common scene schema as RoomCAD takes shape. Archive packaging can be added for transport;
do not require ZIP handling in the initial document implementation.

```text
Example.roomcad/
  manifest.json          # Format identifier, schema version, document UUID and producer
  scene.json             # Geometry, instances, transforms, part references and asset IDs
  settings.json          # App-specific solver and export settings
  assets/                # Embedded source geometry and normalized meshes
  results/               # Optional retained responses and reports, with provenance
  preview.png            # Optional thumbnail
```

Introduce a shared DocumentKit for container reading/writing, versions, asset references and
migration infrastructure when implementing the format. App-specific codecs own blast and
acoustic settings; DocumentKit does not import either solver. Persisted schema types are
explicit contracts, not automatic dumps of live GPU or UI objects.

### Required semantics

- Give the document, assets, instances and parts stable IDs. Bind materials to source parts,
  never generated voxel indices. Scope existing importer part IDs to their source asset during
  migration; keep identity through resampling and define remapping explicitly for reimport.
- Store geometry in metres with a declared z-up coordinate system. Preserve source units,
  source-axis convention and import transform as provenance; avoid applying conversion twice.
- Embed the geometry needed to reopen the project on another Mac. Original OBJ/STL bytes are
  optional provenance; keep normalized mesh data with a versioned encoding and documented
  precision. Do not depend on the original external file path. External-link mode is deferred.
- Separate structural properties from acoustic absorption/scattering, both referencing the
  same parts. Preserve assignments and source geometry when transferring a scene between apps;
  app-specific settings need an explicit conversion, not a renamed extension.
- Retain solver settings needed to reproduce a run: resolution, atmosphere, sources/receivers,
  material assignments, numerical options, random seeds and export conditioning. Store camera
  and display preferences separately from physics settings. Do not save transient playback state
  as a simulation checkpoint.
- Regenerable voxel grids and previews are optional caches keyed by source, transforms,
  settings and generator version. Detached, locally edited geometry is authoritative and must
  be saved, including supports/reinforcement and its detached status; never silently regenerate
  it from the source. A stale cache must not overwrite authoritative edits.
- Simulation fields and audio responses are optional results. Tag them with input hashes,
  solver version, sampling/channel conventions and processing history; changing inputs marks
  them stale. Normal saves need not carry full simulation histories. Exact mid-run restart is
  outside the first format.
- Use a schema version independent of the app release number. Migrate known older versions;
  reject unsupported newer versions without overwriting the file. Report missing assets and
  invalid references clearly rather than silently dropping imported objects.
- Stage complete writes and replace the document through the document framework's coordinated
  save mechanism. A failed or interrupted save must leave the previous document usable.
  Validate relative asset paths, finite numbers, reference integrity and file/mesh size limits.

### Implementation steps and acceptance

1. Inventory persisted fields in current Scenario and the integrated importer; identify missing
   simulation settings and authoritative detached edits. Check in a format specification and
   small example documents before implementing codecs.
2. Implement versioned manifest and asset handling in DocumentKit, with BombCAD's document
   adapter and a reader for legacy Scenario JSON. Legacy opening must not rewrite the source
   until the user saves a new project. Keep JSON scene export as an interchange/debugging option.
3. Wire the document package into open/save, document type registration and the existing editor.
   Embed imported geometry and migrate part/material relationships without losing edits.
4. Test round trips, moved/copied documents, absent original imports, legacy files, detached
   geometry, unsupported versions, corrupt assets and interrupted saves. Verify that reopening
   restores simulation settings, and that changing resolution preserves part assignments.
5. Add RoomCAD's settings adapter and optional IR result storage when its scaffold exists.
   Export WAV separately for convolution engines; a RoomCAD document is not the reverb file.

Done when: imported projects reopen on another Mac without their original source files, all
authoritative edits and reproducibility settings survive saving, and legacy layouts still open.
The `.bombcad` package container and referenced source-mesh assets are implemented.
`.roomcad` and a common application-neutral scene schema remain planned.

## Milestones

Each milestone ends in a usable artifact or a measured result. Numerical tolerances below are
initial acceptance targets, to be revisited explicitly if evidence shows they are unsuitable.

### M0 — Establish contracts and reference cases

1. Inspect Driftbox's audio engine, sample-rate handling, rack API and existing DSP utilities.
2. Define response data: sample rate, channels, source/receiver mapping, time origin, gain
   convention, usable frequency band and provenance.
3. Specify mono-to-stereo as two responses from one source. Reserve true stereo for four
   paths, LL, LR, RL and RR, with an explicit file/channel convention.
4. Define complete-response and reflections-only exports. Preserve propagation delay in the
   complete response; document any delay removal in the reverb export.
5. Choose reference rooms, source/receiver positions and analytical checks. Set performance
   budgets on a named Mac, including generation time, memory and preview CPU usage.
6. Agree the shared save-file contract above, including legacy migration, asset ownership and
   app-specific settings. Treat BombCAD's importer document reliability as a 0.2 readiness gate.

Done when: a short design contract and reference fixtures are checked in, and Driftbox's
integration requirements and any unresolved decisions are recorded.

Progress (October 2026):

- **Driftbox inspected (item 1).** The web app (TypeScript, Web Audio) is the frozen reference. Its
  rack runs in one AudioWorklet with no FFT or convolution, so it cannot use Swift. Native Driftbox
  (Swift 6.4, macOS 26) is the active product:
  - Its DSP is shared across Mac, Windows, Android and Linux, and the engine runs at a fixed 48 kHz.
  - It has 128-frame rack blocks and render paths that are allocation-free.
  - Its `WAVDecoder` already reads 32-bit float and extensible WAVs and resamples linearly.
  - `DriftboxDSP` already has a zero-latency `PartitionedConvolver` and a two-stage convolution
    reverb.
  - Rack patches are JSON shared with the web reference, and loaded audio is session-only.
- **Implications for M6.** A convolution module must either get a native-only exception to the
  conformance rule, like the plugin modules, or a matching web module. Saved patches must say how
  they refer to impulse-response files.
- **Response contract (items 2–4).** This is implemented as `ResponseMetadata` in ImpulseResponseKit
  and documented in [Room-acoustics model](room-acoustics-model.md#output). The defaults are
  48 kHz, one channel per receiver, emission at frame 0, a common gain only, and both complete and
  reflections-only content.
- **Still open.** Fixed performance budgets and a measured reference room are not yet chosen. The
  acousticbench reference room is illustrative.

### M1 — Create the shared foundation and RoomCAD scaffold

1. Extract geometry and camera code with minimal API changes; separate them from blast state.
2. Decouple rendering from BlastCore through concrete scene and field descriptions.
3. Add RoomCAD and acousticbench entry points with local SwiftPM dependencies.
4. Display a rectangular room, one source and two receivers, with editable dimensions and
   positions. Save/load a versioned RoomCAD document.
5. Extract Metal utilities only as AcousticCore starts using them.
6. Integrate the model-import work and identify its shared parsing, source geometry, transforms,
   diagnostics and preview components. Extract GeometryImport without changing BombCAD's
   solid-volume acceptance policy; add separate RoomCAD enclosure and surface adapters when
   imported rooms are introduced. Retain regression fixtures for both interpretations.

Done when: both apps build, existing BombCAD checks pass, and RoomCAD round-trips a scene
and renders its source and receiver positions. Shared shader resources load in both apps.

Progress (October 2026): items 3 and 4 are implemented. RoomCAD is a separate SwiftPM package with
the RoomCAD app and the acousticbench tool. It depends on SimulationKit's DocumentKit and on nothing
in BombCAD.

The app edits a rectangular room, its surfaces, one source and 1 to 16 receivers in plan and section
drawings and an inspector. It saves and reopens versioned `.roomcad` documents, which can keep the
last response and track when it goes stale. It generates responses in the background and exports
WAV. Both apps build and the round-trip tests pass. The drawings are checked by an offscreen snapshot;
the window has not been seen on screen.

Items 1, 2, 5 and 6 are not done:

- **Item 1.** The 2D drawings need no shared camera.
- **Item 2.** Rendering is not shared yet.
- **Item 5.** AcousticCore uses Accelerate, not Metal.
- **Item 6.** GeometryImport extraction waits for imported rooms.

There are no shared shader resources yet.

### M2 — Produce the first usable stereo reverb file

1. Implement an image-source model for direct sound and specular reflections in a rectangular
   room. Bound reflection order and response duration explicitly.
2. Add per-surface, frequency-dependent absorption. Document conversion from energy
   absorption to reflection amplitude and the assumed reflection phase; absorption alone
   does not determine phase.
3. Construct the response using fractional arrival times and band filters. Keep source
   calibration, distance attenuation and receiver sensitivity explicit.
4. Add a bounded late-tail model if needed for auditioning. Identify any synthetic tail as
   such and record its parameters; finite reflection order must not silently truncate decay.
5. Export stereo 32-bit float WAV at 48 kHz plus metadata. Offer complete and reflections-only
   responses. Preserve relative channel gains and timing with one common gain adjustment.
6. Add a preview using a known dry audio clip, wet/dry control and level-matched comparisons.

Done when: an exported response plays in an independent convolution engine; direct and
first-reflection arrival times agree with path length divided by sound speed to within one
output sample, and an anechoic case has the expected distance scaling and no spurious tail.
Output is labelled as geometrical acoustics with approximate low-frequency behaviour.

Progress (October 2026): items 1–3 and 5 are implemented, and the acceptance checks pass:

- **Arrival timing.** The worst arrival-time error is 0.42 samples.
- **Anechoic room.** Energy follows 1/r² to 10⁻⁴, with no tail.
- **Independent engine.** Native Driftbox's decoder and partitioned convolver play the exported
  stereo file and match direct convolution.
- **Labelling.** The output is labelled as geometrical acoustics, approximate below the Schroeder
  frequency.

Without scattering, the rendered decay in the 250 Hz–8 kHz bands is 20–70% longer than
Eyring's estimate. The decay matches what specular reflection predicts, but M4's scattering is
needed before the reverb sounds like a real room. Item 6 (preview) is implemented in the RoomCAD
app. It has a dry clip, a live wet/dry balance and optional loudness matching, and it plays through
two synchronized players; see [RoomCAD app and documents](roomcad-app.md#the-window). Item 4 (late
tail) is not done.

### M3 — Establish a trustworthy low-frequency wave solver

1. Implement linear acoustics using pressure perturbation and particle velocity. Reuse GPU
   infrastructure rather than carrying tiny acoustic signals in BombCAD's absolute energy.
2. Add a calibrated band-limited source and receiver interpolation. Account for the source
   spectrum when deriving the room transfer response; avoid inversion outside its useful band.
3. Implement rigid boundaries first, then passive absorbing/impedance boundaries. Never apply
   BombCAD's air-sleep thresholds or shock-triggered refinement to acoustic propagation.
4. Measure amplitude decay, phase error and directional error for travelling waves across
   amplitudes, cells per wavelength and propagation distances. Check absorbing boundaries.
5. Check rectangular-room modes against analytical frequencies and repeat on finer grids.
6. Measure generation time and memory, then choose a supported frequency ceiling from the
   measured error and cost rather than a fixed cells-per-wavelength rule alone.

Done when: a published benchmark report states the usable band and propagation distances,
with targets of less than 1% modal-frequency error and less than 1 dB amplitude error over
the declared travelling-wave test distance. Linear amplitude scaling and stable passive
boundaries are demonstrated. Failures narrow the supported band rather than being hidden.

Progress (October 2026): a CPU FDTD solver is implemented in `AcousticCore`, with locally reacting
impedance walls and a calibrated source. Rigid-room modes are within 0.25% of the analytical values,
and free-field level within 0.03 dB with no timing offset. Axial decay between absorbing walls is
within 6% of theory. The crossover's top is resolved at 10 points per wavelength, and work is
budgeted. It runs on the CPU rather than the GPU, and a fuller benchmark report (phase and directional
error against distance) is not done. See [Room-acoustics model](room-acoustics-model.md#low-frequencies-the-wave-solver).

### M4 — Generate broadband hybrid room responses

1. Add higher-frequency scattering and diffuse propagation, using ray tracing or another
   documented model to improve the reflection-only prototype.
2. Choose an overlap band in which both wave and geometrical models are usable.
3. Align time origins, source spectra, gain conventions and channels before blending.
4. Use complementary crossover filters and test for double counting, cancellation, spectral
   discontinuities and changes in decay around the crossover.
5. Compare mode frequencies, early reflections, band energy-decay curves and reverberation
   estimates against reference cases and at least one measured room response.
6. Save the solver settings, random seed, crossover and validated band with every export.

Done when: reproducible broadband stereo responses have no unexplained crossover artifacts,
and a validation report distinguishes agreement with measurements from modelling assumptions.
Listening comparisons supplement the numerical checks.

Progress (October 2026): item 1 (scattering) is implemented for rectangular rooms. Image sources
carry the specular part, weakened by 1 − s at each reflection. Ray tracing with Lambert reflection
carries the energy scattered at least once, rendered as a dense, seeded random reflection pattern.

The tracer's detector matches the diffuse-field rate 4πc/V to within 3%. Full scattering brings the
decay to within 6% of Kuttruff's corrected Eyring estimate. The illustrative reference room now decays
between its Eyring and Sabine times instead of 50–70% longer. See
[Room-acoustics model](room-acoustics-model.md#scattered-energy).

Items 2–4 are implemented with the M3 solver:

- **Crossover.** An automatic crossover at twice the Schroeder frequency, within 80–250 Hz and the
  budget.
- **Alignment.** Time origins and gain conventions are aligned by deconvolving the source against free
  field.
- **Blending.** Complementary zero-phase crossovers sum to one. The two models agree within 1.5 dB at
  the crossover across the presets, except for an apparent seat dip in the chamber hall.

Item 5 (comparison with measured rooms) and item 6's validated band are not done.

### M5 — Make RoomCAD useful for designing and auditioning spaces

1. Expand beyond rectangular rooms with openings, connected spaces and practical geometry
   editing. State the supported geometry for each acoustic backend.
2. Add material presets with sourced absorption data and visible assumptions for scattering.
3. Show response waveform, spectrum, early arrivals and band decay, plus generation progress
   and estimated memory. Report decay estimates only where the response supports them.
4. Add presets, repeatable export settings, cancellation and caching keyed by scene and solver
   settings. Distinguish preview quality from export quality.
5. Test editing, export and auditioning on screen with rooms of different sizes and decay times.

Done when: a user can build, save, reopen, audition and export a room without editing code,
and can see the output's frequency coverage and modelling assumptions.

Progress (October 2026): the RoomCAD app covers saving, reopening, auditioning and export without
code. Item 2 has started: 90 absorption and 7 scattering presets come from the annex of Vorländer's
*Auralization*, via pyroomacoustics. Bands outside the published range are extended and labelled in
each material's reference. Most surfaces still need scattering values. See
[RoomCAD app and documents](roomcad-app.md#material-presets).

### M6 — Add a convolution reverb to Driftbox rack

1. Integrate response loading through the existing rack architecture, sharing DSP code only
   where the host language and dependencies support it.
2. Implement partitioned FFT convolution or integrate an appropriate existing engine. Measure
   latency and CPU use for short and long responses; account for latency in the dry path.
3. Decode, resample, allocate and prepare responses outside the audio callback. Keep processing
   free of blocking I/O, locks and allocation.
4. Add click-free response switching, wet/dry, output gain and saved rack state. Define whether
   saved sessions embed responses or refer to files and handle missing files explicitly.
5. Start with mono-to-stereo; add true stereo after the four-path format and routing are tested.
6. Verify impulse input reproduces the loaded response, compare against direct convolution
   offline, and test sample-rate changes, block sizes, bypass and switching under playback.

Done when: RoomCAD exports load directly into Driftbox, survive a session save/reopen, and
process within the M0 latency/CPU budget without audible switching artifacts or dropouts.

### M7 — Optional vibrating partitions and transmission

1. Extract StructureCore only when partition vibration becomes an active requirement.
2. Validate elastic modes, damping and small-amplitude air/structure coupling separately from
   BombCAD's blast and damage tests.
3. Add physical partition properties and check transmission against analytical and measured
   references, including mesh convergence and acoustic impedance mismatch.
4. Generate responses between connected rooms with transmission and openings distinguished.

Done when: a documented class of partitions has validated vibration and transmission over
a declared band. Damage and collapse are outside this milestone.

## Order and dependencies

M0 → M1 → M2 delivers the first usable reverb. M3 can follow the shared foundation while M2
provides an audible reference. M4 requires M2 and M3. M5 expands the product after a reliable
export path exists. M6 can begin with M2 files and does not depend on the hybrid solver.
M7 is optional and should not delay impulse-response export or Driftbox playback.

No dates are committed. Size the milestones after M0 and the first GPU benchmarks; full-band
wave simulation and validated wall transmission are the largest uncertainties.

## References

- [SwiftPM package structure](https://docs.swift.org/latest/documentation/packagemanagerdocs/introducingpackages/)
  and [dependencies](https://docs.swift.org/swiftpm/documentation/packagemanagerdocs/addingdependencies/).
- [JUCE convolution API](https://docs.juce.com/master/classjuce_1_1dsp_1_1Convolution.html):
  a reference for impulse-response loading and partitioned convolution, not a Driftbox engine decision.
- [HiFi-HARP](https://arxiv.org/abs/2510.21257): an example of broadband room responses combining
  low-frequency wave simulation with higher-frequency ray tracing.
- [BombCAD air limitations](air-blast-model.md#limitations): precision, boundaries and geometry
  issues that prevent treating the existing blast solver as an audio solver without changes.
