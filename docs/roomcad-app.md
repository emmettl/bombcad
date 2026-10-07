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

## The window

- **Plan and section.** Drawings of the room, looking down and looking north, with 1 m grid lines,
  the source in orange and receivers in blue. Drag a point to move it. Moves snap to centimetres and
  stay 5 cm inside the walls.
- **Inspector.** Edits everything that affects the response:
  - room dimensions;
  - each surface's absorption and scattering, either one value for all bands or band by band, with the
    material's name and reference;
  - the source and receiver positions and names, with receivers added or removed (1 to 16);
  - sample rate, duration, maximum reflection order and content;
  - low cut, the number of diffuse rays and the random seed, air absorption, temperature and
    humidity;
  - export conditioning.

  It also shows the estimated number of image sources per receiver.
- **Response.**
  - The response regenerates in the background 0.4 s after any input that affects it changes, so
    dragging or typing starts one run once you pause. A run for older inputs is cancelled at once.
  - A new document generates on opening. **Generate** (⌘R) forces a run, and **Cancel** (⌘.) stops
    one.
  - Export settings don't affect the response, since they are applied on export, so they don't start
    a run.
  - While a run is in progress the response is marked "Updating…"; until it finishes, the previous one
    stays in use.
  - The result shows each channel's peak envelope in dB.
  - It shows octave-band Sabine and Eyring estimates beside each channel's measured T30.
  - It shows arrival counts and generation time, the Schroeder frequency, and the share of energy from
    500 Hz to 4 kHz that arrived scattered.
  - It shows a warning when the reflection-order limit removed arrivals within the duration.
- **Audition.** Play a dry clip through the room.
  - Play starts at once with the latest response, even while a newer one is being generated; the new
    one takes over, from the same point, when it is ready. With no response yet, playback starts when
    the first one arrives.
  - The first receiver is heard on the left and the second on the right; a single receiver is heard
    on both.
  - A waveform strip shows the clip, and once a response exists, the clip dry and through the room
    on one time axis. Both lanes are drawn at the levels played, scaled together.
  - A red playhead follows playback. Click or drag the strip to move it; while you drag, the playhead
    follows silently, and playback continues from where you release it.
  - **Play/Pause**, or the space bar, resumes from the playhead, and the back button returns it to the
    start. The space bar works anywhere in the window except while a text field is being edited, where
    it types a space.
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
  beside it.

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

`scene.json` holds the room's size in metres (z up) and each surface's material. A material has a
name, a reference and eight octave-band absorption coefficients. The file also holds the source and
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
  - round trips, including per-band materials and moved documents on disk;
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
- **SpaceKeyTests:** a bare space in the editor's window toggles playback. Modified, repeated or other
  keys pass through, as do keys for other windows and spaces typed into a text field.
- **RoomCADTests:**
  - background generation and its delivery;
  - automatic regeneration: waiting for changes to settle, superseding older runs, ignoring repeats,
    invalid settings and results that arrive during the wait;
  - invalid settings;
  - cancellation, and a newer generation replacing one in progress;
  - the mapping between drawing and room coordinates, including clamping.

The window itself has not been checked on screen; its layout and controls are unverified by eye.
`RoomCAD --snapshot FILE.png` renders the starter room's plan and section offscreen. It also renders
the audition waveform with its playhead, and a generated response's envelope, decay table and
diagnostics. That was used to check the drawing code. It caught overlapping labels where receivers
coincide in one projection; labels now move apart. Form controls and toolbars do not render
offscreen.

## Limitations

- Undo has not been checked; SwiftUI may not register document edits with the undo manager.
- Inspector fields accept invalid values. The window reports them and disables **Generate** rather
  than preventing them.
- There is no late tail, and true-stereo (four-path) auditioning is not supported.
- Playback has not been heard: the mixing is tested offline, but the audio engine and controls are
  unverified by ear and by eye.
- There are no material presets, since sourced absorption data is roadmap M5.
- Only rectangular rooms are supported, and there is no 3D view.
- Generation blocks one core per document and is not shared between windows.
