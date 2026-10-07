# RoomCAD

Offline impulse responses of rooms, for convolution reverb: a macOS document app, the acoustic
model and response files. See the [roadmap](../docs/roomcad-roadmap.md) for what is planned.

| Module | Contents |
|---|---|
| RoomCAD | The document app: plan and section drawings, inspector, generation, auditioning, WAV export |
| Audition | Dry clips (bundled, generated or chosen), FFT convolution previews and loudness matching |
| RoomDocument | The versioned `.roomcad` format and response summaries |
| AcousticCore | Rectangular rooms, octave-band materials, air absorption, image sources, rendering, decay analysis |
| ImpulseResponseKit | Response metadata, 32-bit float WAV reading and writing, common-gain conditioning |
| acousticbench | Analytical checks and a reference room exported as stereo WAV |

```bash
swift run -c release --package-path RoomCAD RoomCAD
```

```bash
swift test --package-path RoomCAD
```

```bash
swift run -c release --package-path RoomCAD acousticbench --out roomcad-reference
```

The app and its documents are described in [RoomCAD app and documents](../docs/roomcad-app.md),
and the model, its checks and its limitations in
[Room-acoustics model](../docs/room-acoustics-model.md). The package uses the shared SimulationKit
for its document container and depends on nothing in BombCAD.
