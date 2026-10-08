# RoomCAD app and documents

RoomCAD is a macOS document app for designing a rectangular room and generating its impulse response.
It lives in the `RoomCAD` package:

- `Sources/RoomCAD` is the SwiftUI app.
- `Sources/RoomDocument` holds the document format and the response summary. It has no SwiftUI.

The acoustic model is described in [Room-acoustics model](room-acoustics-model.md). This is milestone
M1 of the [RoomCAD roadmap](roomcad-roadmap.md), without the shared geometry-import and rendering
extractions.

## Running it

```bash
swift run -c release --package-path RoomCAD RoomCAD
```

```bash
make roomcad-app
```

The second command builds `RoomCAD/dist/RoomCAD.app`, ad-hoc signed. Its icon (a room in plan, with
a source's wavefronts and one path reflecting off a wall to a listener) is drawn by
`RoomCAD/Scripts/make-icon.swift`; `make roomcad-icon` redraws `RoomCAD/Support/AppIcon.icns`. That bundle declares the
`.roomcad` document type. It is not notarized, and RoomCAD has no release process yet.

RoomCAD opens a new room at launch rather than the Open panel, unless macOS restores windows or a
document is opened from Finder.

### Releasing RoomCAD

`RoomCAD/Scripts/release.py` makes a Developer ID-signed, notarized build, with the same steps as
BombCAD's (see [Releasing](releasing.md)). It never tags or publishes anything. It uses the same
certificate and notary profile: `ROOMCAD_SIGNING_IDENTITY` and `ROOMCAD_NOTARY_PROFILE`, or BombCAD's
variables if those are unset. Set the version in `RoomCAD/Support/Info.plist`, commit, then run:

```bash
make roomcad-release-check
make roomcad-release
```

The script requires a clean checkout and a well-formed version. It runs RoomCAD's strict lint, its
tests and the release script's tests, then builds `RoomCAD/dist/RoomCAD.app` in release and checks
that the app:

- matches the source's version;
- is arm64;
- carries its bundled recordings with their credits, the icon, `LICENSE` and
  `THIRD-PARTY-NOTICES.md`.

It then signs the app with the hardened runtime and submits it to Apple, stopping unless notarization
is accepted. Finally it staples and validates the ticket, re-verifies the signature and asks
Gatekeeper to assess the app. Only then does it write `RoomCAD-<version>-macos-arm64.zip` with its
checksum and manifest.

RoomCAD 0.1.0 (build 1) was released this way on 2026-10-07, from commit `1e8c68d`, with Apple
submission `fe528b2d-59cd-4a64-a889-096177cdcc20`:

- Apple accepted it, the ticket was stapled and validated, and Gatekeeper assessed the app as
  `Notarized Developer ID`.
- A fresh expansion of the final ZIP matched its checksum, validated its stapled ticket, passed
  `codesign --verify --deep --strict` and was accepted by `spctl`. It holds the recordings with their
  credits, the icon, `LICENSE` and `THIRD-PARTY-NOTICES.md`, and it rendered its offscreen snapshot.
- The ZIP, checksum and manifest are attached to the GitHub release `roomcad-v0.1.0`, tagged on that
  commit. It is not marked latest, so the repository's latest release remains BombCAD's. The copy
  downloaded back matched the checksum.
- The tag is on the RoomCAD branch, not main, because main had moved on with uncommitted work in
  progress at the time.

The release tests run with `make roomcad-test`, with every external tool stubbed out. They check that
a rejected notarization, a Gatekeeper refusal, missing recordings and missing licences each stop the
script before an archive is written.

## The window

- **Plan and section.** Drawings of the room, looking down and looking north, with 1 m grid lines,
  the source in orange and receivers in blue. Drag a point to move it. Moves snap to centimetres and
  stay 5 cm inside the walls. A room of any shape (a mesh) is drawn as its outline edges projected
  onto each view, over its dashed bounding box.
- **Inspector.** Edits everything that affects the response:
  - room dimensions, or with **Shape** a floor plan (L, T or trapezoid to start from). Its corners
    can be edited as numbers or dragged by their handles in the plan view, which numbers its walls;
  - for a room of any shape, built from solids by a preset (see
    [Rooms of any shape](room-acoustics-model.md#rooms-of-any-shape)): its size is shown but not
    edited, and each of its materials is edited with its label and area. **Shape** turns it back into
    a box or a floor plan. Its openings are open faces, so the openings list is not offered;
  - each surface's absorption and scattering, either one value for all bands or band by band, with the
    material's name and reference;
  - whole rooms from **Load Room Preset…** (see below);
  - published materials: the books icon beside each surface's absorption chooses one of 90 surfaces
    in 11 categories, and **Scattering preset** inside chooses one of 7 measured scattering sets (see
    below);
  - the source and receiver positions and names, with receivers added or removed (1 to 16);
  - under **Objects**, fitted zones: boxes of chairs, desks, pews or ornament that scatter sound,
    each with its corners, how often sound meets an object per metre, and the objects' absorption
    (see [Fitted zones](room-acoustics-model.md#fitted-zones)). **Add Seating Zone** starts from an
    estimate for upholstered seats. Zones are drawn as hatched brown boxes;
  - openings: open doors, windows or hatches on any surface, or any numbered wall of a plan, by name,
    place, centre and size (see
    [Openings](room-acoustics-model.md#openings)). They are drawn as green gaps in the walls or as
    dashed outlines;
  - each receiver's microphone: pattern, azimuth and elevation, with **Arrange First Two as a Stereo
    Pair** for A–B, XY, ORTF, NOS or Blumlein (see
    [Microphones](room-acoustics-model.md#microphones)). Directional microphones show their aim as an
    arrow in the drawings;
  - sample rate, duration, maximum reflection order and content;
  - low cut, the number of diffuse rays and the random seed;
  - the wave solver for low frequencies, on for new documents, with an automatic or fixed crossover;
  - air absorption, temperature and humidity;
  - export conditioning.

  It also shows the estimated number of image sources per receiver.
- **Response.**
  - The response regenerates in the background 0.4 s after any input that affects it changes, so
    dragging or typing starts one run once you pause. A run for older inputs is cancelled at once.
  - That run is a preview. It spends a quarter of the wave solver's budget, which lowers its crossover
    by about a sixth, and uses a quarter of the rays, so it arrives two to four times sooner. Once the
    inputs have stayed the same for 1.5 s after a preview, the full-quality response follows. Until
    then the status reads "Preview quality".
  - A new document generates on opening, a preview and then the full response. **Generate** (⌘R)
    forces a full-quality run, and **Cancel** (⌘.) stops one.
  - Export settings don't affect the response, since they are applied on export, so they don't start
    a run.
  - While a run is in progress the response is marked "Updating…"; until it finishes, the previous one
    stays in use. The toolbar shows the run's stage and how far it has got, such as "Tracing rays 40%"
    or "Wave solver 67%".
  - The result shows each channel's peak envelope in dB. The picker above it switches to its spectrum
    or its early arrivals.
    - **Spectrum:** from 20 Hz to 20 kHz, twelve points to an octave, each averaged over a sixth of an
      octave, with the wave solver's crossover marked.
    - **Early arrivals:** the energy above 500 Hz in 0.25 ms bins, from emission to 80 ms after the
      first direct sound, in dB, so the direct sound and early reflections show one by one.
  - It shows octave-band Sabine and Eyring estimates beside each channel's measured T30.
  - It shows arrival counts and generation time. It also shows the wave solver's crossover, grid and
    its approximate memory, time and runs, with how many ran on the GPU and how many on the CPU. It also gives its phase-velocity
    error at the crossover, and the decay each of its bands had before it was matched to Eyring's
    estimate. Then come the Schroeder
    frequency and the share of energy from 500 Hz to 4 kHz that arrived scattered.
  - It shows a warning when the reflection-order limit removed arrivals within the duration.
- **Audition.** Play a dry clip through the room.
  - Play starts at once with the latest response, even while a newer one is being generated; the new
    one takes over, from the same point, when it is ready. With no response yet, playback starts when
    the first one arrives.
  - The first receiver is heard on the left and the second on the right; a single receiver is heard
    on both. With a stereo pair, that is its stereo image.
  - A waveform strip shows the clip, and once a response exists, the clip dry and through the room
    on one time axis. Both lanes are drawn at the levels played, scaled together.
  - A red playhead follows playback. Click or drag the strip to move it; while you drag, the playhead
    follows silently, and playback continues from where you release it.
  - **Play/Pause**, or the space bar, resumes from the playhead, and the back button returns it to the
    start. The space bar works anywhere in the window except while a text field is being edited, where
    it types a space. Pressing Return in a field, or clicking a drawing or the waveform, ends the
    editing. Text fields don't take the keyboard when a window opens, as macOS would otherwise arrange.
  - Changing the room, the loudness matching or looping keeps the position. Choosing another clip
    starts it from the beginning.
  - A slider balances the dry and wet sound while it plays; the lanes fade to match.
  - **Match loudness** gives the two equal energy, so switching between them compares the room
    rather than the level. Without it, levels are physical: the dry sound is the source heard 1 m
    away in open air. Either way, one common gain keeps the mix below 0.9 full scale.
  - Clips are bundled anechoic recordings, generated test signals (a pink-noise burst and clicks) or
    any audio file you choose. The recordings are an operatic voice and synthesized drums from the
    OpenAIR library (CC BY-SA), and violin pizzicato from the University of Iowa Musical Instrument
    Samples (free to use). The window shows each clip's credit. Sources, licences and edits are in
    `RoomCAD/Sources/Audition/Clips/CREDITS.md`, which ships inside the app. Files are mixed to mono, converted to the
    response's sample rate and cut to 60 s.
- **Export WAV** (⌘E). Writes the conditioned response as 32-bit float WAV, with its JSON description
  beside it. Exports are always full quality: if the current response is a preview or out of date, the
  full one is generated first and then written.

## Room presets

**Load Room Preset…** at the top of the inspector replaces the room with a furnished example:

| Preset | Size | Surfaces |
|---|---|---|
| Living room (new documents) | 5.5 × 4.2 × 2.5 m | Carpet, plastered walls and ceiling, curtained window |
| Office | 6 × 5 × 2.8 m | Carpet tiles under desks, suspended tile ceiling, plasterboard, a glazed wall |
| Classroom | 9 × 7 × 3.2 m | Linoleum under rows of desks, tile ceiling, hard walls, windows |
| Tiled bathroom | 2.6 × 2 × 2.4 m | Ceramic tiles throughout; empty and very live |
| Vocal booth | 2.4 × 2 × 2.3 m | Fabric-covered rockwool panels, foam ceiling, carpet |
| Concrete hall | 24 × 16 × 5 m | Bare rough concrete, like an empty car park level |
| Chamber music hall | 28 × 18 × 11 m | Audience in upholstered seats, wooden linings, hard ceiling |
| Stone church | 36 × 14 × 16 m | Limestone walls and vault, wooden pews over the floor |
| L-shaped living room | 8 × 6 × 2.6 m L | Carpet, plastered walls; the listener round the corner |
| Fan-shaped hall | 16 → 10 m wide, 20 m deep, 8 m high | Stage at the narrow end, audience seating, wooden walls |
| Shoebox concert hall | 26 × 18 × 14 m, and an 8 m stage house | Balcony round three sides, upholstered seats, wooden linings |
| Raked auditorium | 26 m deep, 18 → 32 m wide, 10–13 m high | Raked seating, rear tier, sloping ceiling, brick walls |

The last two are built from solids. They have six materials, labelled audience, floors, walls,
ceiling, stage floor and stage walls, instead of six box surfaces.

Every surface's absorption comes from the published table below. Scattering comes from a published
set where one fits: theatre audience in the hall, and rows of desks in the office and classroom.
Elsewhere it is illustrative, and the material's reference says so.

A preset places the source and two listeners. Its duration is 1.5 times the slowest Eyring time from
125 Hz to 4 kHz, between 0.5 and 8 s; rooms that are not diffuse can decay more slowly than that. The
reflection order is capped at 120 to keep the image sources quick, and scattering carries the late
energy beyond it.

Loading asks for confirmation, because it replaces the size, surfaces, positions, duration and order.
Sample rate, air, low cut, rays, seed, content and the points' identities and names are kept.

Measured on the development Mac (T30 at 1 kHz, from the left listener). Generation times for the
other presets were measured before the speed-ups, which made the three remeasured here about four
times faster:

| Preset | Duration | Eyring at 1 kHz | T30 at 1 kHz | Generation |
|---|---|---|---|---|
| Living room | 1.9 s | 0.34 s | 0.38 s | 0.9 s |
| Office | 0.8 s | 0.33 s | 0.49 s | 1.4 s |
| Classroom | 1.3 s | 0.54 s | 0.69 s | 2.2 s |
| Tiled bathroom | 7.9 s | 2.63 s | 2.98 s | 1.0 s |
| Vocal booth | 0.5 s | 0.02 s | 0.03 s | 1.0 s |
| Concrete hall | 8.0 s | 7.75 s | 7.87 s | 4.4 s |
| Chamber music hall | 1.8 s | 1.13 s | 1.16 s | 0.4 s |
| Stone church | 8.0 s | 7.08 s | 7.44 s | 1.25 s |

## Material presets

The absorption presets are the table in the annex of Vorländer's *Auralization* (Springer, 2008), as
collected in pyroomacoustics' materials database (MIT licence). They cover hard surfaces, linings,
glazing, wood, floor coverings, curtains, seating, audience, and wall, ceiling and special absorbers.
The scattering presets come from the same database and cover diffusers, theatre audience, classroom
tables, amphitheatre steps, and studio wall and ceiling boxes.

The data starts at 125 Hz, and some entries stop at 4 kHz or earlier. The 63 Hz band takes the 125 Hz
value, and missing high bands take the highest published one. The material's reference names the
source and the extended bands.

Few absorption entries have published scattering. Choosing a material therefore sets its name and
absorption and keeps the surface's scattering; a scattering preset sets only the scattering. The
generated table is `Sources/AcousticCore/MaterialPresetData.swift`, pinned to the source commit, and
pyroomacoustics' licence is in `RoomCAD/THIRD-PARTY-NOTICES.md`, which also ships in the app.

## Document format

A `.roomcad` document is a SimulationKit package (see [Save files](save-files.md)) with
`documentType` `roomcad` and producer `RoomCAD`:

```text
Example.roomcad/
  manifest.json
  scene.json              # dev.roomcad.scene, version 1
  settings.json           # dev.roomcad.settings, version 1
  results/response.wav    # optional: the last generated response, unconditioned
  results/response.json   # optional: its description, settings and diagnostics
```

`scene.json` holds the room's size in metres (z up), each surface's material, and any openings. A material has a
name, a reference and eight octave-band absorption coefficients. A room may also have fitted zones (name,
corners, density, absorption per band and reference), and a floor plan
(corners and one material per wall) or a mesh (vertices; faces, each a list of corners with a
material index and whether it is open; the materials; and their labels). The file also holds the source and
receivers, each with a UUID, name and position.

`settings.json` holds the atmosphere and air-absorption switch. It also holds the sample rate,
duration, maximum reflection order, content, low-frequency cutoff and export settings:

- peak level, or none;
- fade-out length;
- whether to remove the leading delay.

The retained response is stored exactly as generated, so export settings can change without
regenerating. Its description records the settings that produced it. The document compares those
with its own to decide whether the response is current. A response from another generator is
rejected.

A response larger than 48 MB is not kept, and the window says so. A 30 s, 16-channel response at
48 kHz is 92 MB, for example.

On reading, a document is rejected if:

- it belongs to another app;
- it uses an unknown or newer scene or settings encoding;
- its settings are invalid (for example a receiver outside the room or too many image sources);
- two points share an identity;
- its response is missing its audio or its description.

Files this version does not interpret, such as a future `view.json`, are kept when the document is
saved again.

## Verification

`swift test --package-path RoomCAD` covers the following:

- **RoomDocumentTests:**
  - round trips, including per-band materials, floor plans, meshes and moved documents on disk;
  - retained responses and when they go stale;
  - preserved unknown files and rejected documents;
  - responses too large to retain;
  - export conditioning on a copy, with one common gain and shift;
  - the response summary.
- **AuditionTests:**
  - FFT convolution against direct convolution;
  - repeatable test signals;
  - files mixed to mono and resampled, keeping pitch;
  - preview channel mapping and padding;
  - loudness matching to equal energy;
  - mixes below the ceiling.
- **Audition display:** waveform overviews, and playback position after a seek, with and without
  looping.
- **AuditionPlayerTests:**
  - a clip shown alone until it is prepared;
  - duplicate preparation requests joined;
  - seeking clamped to the clip;
  - choosing a clip resets the playhead;
  - matching changes the wet level only.
- **SpaceKeyTests:**
  - a bare space in the editor's window toggles playback;
  - modified, repeated or other keys pass through, as do keys for other windows and spaces typed into
    a text field;
  - a new window's text field gives up the keyboard.
- **RoomCADTests:**
  - background generation and its delivery;
  - automatic regeneration: waiting for changes to settle, superseding older runs, ignoring repeats,
    invalid settings and results that arrive during the wait;
  - invalid settings;
  - cancellation, and a newer generation replacing one in progress;
  - the mapping between drawing and room coordinates, including clamping;
  - the wording of generation progress and of the wave solver's engines.

The window itself has not been checked on screen; its layout and controls are unverified by eye.
`RoomCAD --snapshot FILE.png [PRESET]` renders the starter room's plan and section offscreen, or a
preset's, given its identifier such as `raked-auditorium`. It also renders
the audition waveform with its playhead, and a generated response's envelope, spectrum, early
arrivals, decay table and diagnostics. That was used to check the drawing code. It caught overlapping labels where receivers
coincide in one projection; labels now move apart. It also showed the two halls' outlines, with
their stage houses, balconies, rake and rear tier, as intended. Form controls and toolbars do not render
offscreen.

## Limitations

- Undo has not been checked; SwiftUI may not register document edits with the undo manager.
- Inspector fields accept invalid values. The window reports them and disables **Generate** rather
  than preventing them.
- There is no late tail, and true-stereo (four-path) auditioning is not supported.
- Playback has not been heard: the mixing is tested offline, but the audio engine and controls are
  unverified by ear and by eye.
- Most material presets have no published scattering, so most room presets' scattering is
  illustrative.
- Rooms are boxes or floor plans with vertical walls, and there is no 3D view.
- Generation uses several cores per document, and documents generating at once share them.
