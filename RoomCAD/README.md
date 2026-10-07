# RoomCAD

Offline impulse responses of rooms, for convolution reverb. This package currently holds the
acoustic model and response files; the RoomCAD app is planned (see the
[roadmap](../docs/roomcad-roadmap.md)).

| Module | Contents |
|---|---|
| AcousticCore | Rectangular rooms, octave-band materials, air absorption, image sources, rendering, decay analysis |
| ImpulseResponseKit | Response metadata, 32-bit float WAV reading and writing, common-gain conditioning |
| acousticbench | Analytical checks and a reference room exported as stereo WAV |

```bash
swift test --package-path RoomCAD
```

```bash
swift run -c release --package-path RoomCAD acousticbench --out roomcad-reference
```

The model, its checks and its limitations are described in
[Room-acoustics model](../docs/room-acoustics-model.md). The package depends on nothing in
BombCAD.
