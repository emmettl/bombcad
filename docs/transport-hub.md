# Transport hub, long-span steel and glass roof

The third planned building type on the roadmap (Scale and import) is a station: a train shed with a
long-span steel and glass roof, beside a glazed concourse (`ScenarioPreset.transportHub`,
`TransportHubPreset.swift`). It brings together the three pieces built for it:

- [laminated glass](building-envelopes.md#laminated-glass), which holds together once cracked;
- [glass falling from overhead](building-envelopes.md#glass-falling-from-overhead) onto the floor
  below;
- [slender steel members buckling](shell-model.md#buckling) in the shed's frames.

## The layout

**The train shed** is built of shells and beams.

- **Size.** A 36 m clear span (two island platforms and four tracks) by 48 m, its roof 12 m up.
- **Columns.** 305 UC columns in frames at 12 m, clamped at their bases.
- **Trusses.** Across each frame is a Vierendeel truss 3 m deep. Its chords are 300 × 12.5 mm
  square hollow sections and its posts 200 × 10 mm, at 3 m. A Warren truss's diagonals would not
  lie along the axes, as the shells' lines must.
- **Purlins.** 356 UB purlins run at 3 m along the shed on the trusses' top chords.
- **Glazing.** 10 mm toughened glass covers the whole roof. The structure model's glass is a
  brittle solid, so laminated glass is not built into it.
- **Openness.** Its ends and sides are open to the tracks.
- **Sizing.** The sections were sized here for the span and the glass's weight, not taken from a
  design. Under self-weight a truss's chords carry about 350 kN, under a tenth of their squash
  load.

**The concourse** stands 6 m to the side of the shed, as an envelope judged by
[envelope damage](building-envelopes.md#damage-for-envelope-buildings-built).

- **Size and walls.** 24 × 20 m and 8 m high, with 0.3 m concrete walls and roof.
- **Glazing.** Its front has sixteen 3 × 3 m panes, and its roof has twelve 3 × 2 m rooflights over
  the concourse floor. All are laminated: 6 + 1.52 mm PVB + 6 mm, in structural silicone with a
  20 mm bite (`LaminatedGlass.facade`).

**The charge** is 100 kg of TNT, a car's worth, in the forecourt 20 m in front of both buildings.

```sh
swift build -c release --product blastbench
.build/release/blastbench snapshot --preset hub --dx 0.5 --time 0.3 --envelope-damage --out hub.png
```

## What it shows

RESULTS

## Limitations

- **Laminated glass only on the envelope.** The shed's roof glass in the structure model is
  toughened, a brittle solid with no interlayer to hold it.
- **The trusses are Vierendeel frames.** A real long-span roof is more often a triangulated
  truss or arch, whose members carry axial force rather than bending. Members along the axes
  cannot be diagonal.
- **Perfect members.** The beams buckle at their Euler load or squash at their yield. With no
  imperfection or residual stress, a member of middling slenderness carries up to 1.5 times
  Eurocode 3's design buckling resistance ([buckling](shell-model.md#buckling)).
- **No falling test.** The concourse's falling glass is graded on the fragment criteria, with
  no falling test compared.
