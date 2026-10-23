# A spatial viewer: kept runs on an iPad, then a Vision Pro

emmettl/bombcad-work#43, a big bet: walk a district's result at full scale, standing in the
street, seeing the overpressure arrive, the panes go and the fireball rise, scrubbed through a
kept run's recording ([Replaying a run](using-the-app.md#replaying-a-run)). It is for people who
do not read pressure plots: planners, clients, inquiries. The first step was to send a kept
recording to an iPad over the thin client's protocol
([Macs nearby](distributed-computing.md#macs-nearby-without-ssh)) and scrub it there. What would
kill it: frames at district scale too big for Wi-Fi without a new compression path.

## The first step, 23 October 2026

**What it took to build for an iPad.** Less than feared. BlastModel, BlastCore (the solver, its
shaders compiled at run time) and BlastRender (`SceneRenderer`, the codecs' view types,
`ViewUpload`) built for the iPad Simulator unchanged once the package named iOS 18 as a
platform (its `Mutex` needs it). The app target, BombCAD, holds everything else: the timeline
codec and player (`TimelineCodec`, `RunTimelinePlayer`), `SceneViewCodec`, the worker protocol
and client, pairing and the nearby sessions. Rather than moving those into a library (a few
hundred declarations made public, beside sessions editing them), the target itself now builds
for iPadOS, with BombCAD on an iPad a viewer (`ViewerApp.swift`) instead of the Mac's document
app. What stood in the way, and what was done:

| On the iPad | Where | Done |
|---|---|---|
| ContinuumKit's SceneRender imports AppKit (`OrbitControlView`); the app takes it only for that | MetalView, charge dragging | the dependency is the Mac's alone; the Mac's viewport and drag handlers left out |
| AppKit, `NSViewRepresentable`, `NSColor`, `NSAlert`, `NSDocumentController`, `\.newDocument`, `Settings` | BombCADApp, ContentView, ProjectEditor, AppSettingsView, NearbySettingsSection, InterfaceSmoke, the SceneKit import previews (ImportComparisonView, ImportRecoveryView), New District's window, Export for Rendering's sheet | the Mac's own windows, left out (`#if os(macOS)`) |
| `.toggleStyle(.checkbox)`, `NSColor` backgrounds | IFC and import lists, run comparison, charge inference | `checkboxToggleStyle()` and two colours in PlatformCompatibility.swift |
| `Process` (workers, SSH, `ps`, the IFC converter), `homeDirectoryForCurrentUser`, `Host` | SweepWorkerClient, NearbyWorkers, RemoteGate, IFCImporter, NearbyPairing | an iPad starts no processes: those fail, saying so |

Nothing changes on the Mac: the guarded code is what it was, and the Mac's build, lint and tests
are as before. `Scripts/build-ipad-viewer.sh` builds the target for the Simulator with
`xcodebuild` and puts the executable and its resource bundles into an app
(`Support/Viewer-Info.plist`), signed ad hoc.

**The protocol: protocol 18.** A viewer is a client of a session like any other: it pairs as a
Mac does (X25519, the six-digit code both show, the sharing Mac's user allowing it), and its
session runs on the sealed socket of
[22 October](distributed-computing.md#the-bulk-on-a-socket-and-the-thin-clients-controls-22-october-2026).
New messages (`SharedTimelines.swift`):

- `timelines` asks the worker for the kept runs with recordings in the projects its Mac shares;
  `timelineList` answers with each one's project, run, frames, bytes and end.
- `fetchTimeline` asks for one; the worker sends a `timelinePart` a file, each as stored (already
  lzfse): the kept run's own record (its scene, its thermal receivers and its cloud, for the
  layers), the manifest, the view's setup, then the frames: the first and the last, then the
  middle of each gap in turn, so that a viewer scrubbing before the rest arrive finds a frame near
  wherever it stops. `timelinePrefer` sends a frame ahead of its turn: the viewer asks for the one
  scrubbed to when it has not come. `timelineSent` ends it, with what sending cost; `cancel`
  stops it.
- What is shared: the projects named by `BombCAD serve --share <project>` (once each), or, in the
  app, the saved projects open while it shares its GPU; their kept runs' recordings as saved in
  the package. A worker refuses any other project, a run not kept there, and any path in a
  manifest leading out of the run's folder, and the viewer checks every file's path again before
  writing it.
- Old clients: the worker greets with protocol 18, and a client of 17 refuses it, as any
  version apart is refused; the adverts' TXT records say 18, so a Mac of 17 greys it out before
  connecting (SharedTimelineTests checks both).

The viewer writes the files into a folder laid out as the run's own, so the Mac's
`RunTimelinePlayer` plays it unchanged, and draws it with `SceneRenderer` as Replay does: the
field and the structures from each frame, the vent panels opened, the envelopes' damage colours,
the thermal paint (the receivers laid out again from the run's scene and spec) and the cloud's
outlines from the frame it was handed over in. The slider scrubs among the frames in, asking for
one that is not; Play steps through those in; one finger orbits, two pan, a pinch zooms.

**Tried in the iPad Simulator** (iPad Pro 11-inch, iOS 27), the Studio serving with
`BombCAD serve --share`, at load averages of 250 to 350 from other sessions' runs:

- **Bonjour found the Mac but handed the app nothing**: the Simulator's browser resolved the
  Mac's services (its log shows the queries) and never called back with a result, as a test
  process's never do on the Mac (Local Network privacy, it seems). So the viewer also takes the
  Mac's address and the two ports `BombCAD serve` now prints ("host pairing-port session-port"),
  and pairs and connects that way. The session port moves each time a Mac pairs (the listener
  starts anew with the new key), so `serve` prints the ports again then.
- **Pairing**: both showed the same code, the Mac's user allowed it, the iPad confirmed it; kept
  in a file in the app's own container, since the Keychain needs a team's signing (the ad hoc
  build's Keychain pairing was gone once it quit).
- **The session** opened on the sealed socket over loopback.

**What the recordings weigh** (`SpatialViewerStudyTests`, `BOMBCAD_VIEWER_STUDY=<folder>`, which
keeps a run with its recording, saves the project and takes each frame apart): the made-up
district (File ▸ New District on Fixtures/SyntheticDistrict, 1 t, uniform air, its cloud
followed), and three buildings across a street to 50 ms with thermal receivers 4 m apart and the
cloud. The district ran without thermal receivers: with them, even 20 m apart, its debug run
spent over an hour in the thermal march, nearly all of it in `Terrain.highest`, which scans the
whole heightfield for every ray (flagged as a task of its own).

| Recording | Frames | Stored | A frame, stored: mean, median, largest | A frame raw | Its field | Its structures | Layers in all, raw |
|---|---|---|---|---|---|---|---|
| District, to 1.3 s | 233 | 250.5 MB | 1.08, 1.22, 1.78 MB | 2.69 MB (2.5 times) | 2.69 MB | none (its buildings are envelopes) | envelope damage 1.9 kB in 3 frames, the cloud in 1 |
| Street, to 50 ms | 131 | 60.9 MB | 0.47, 0.56, 0.77 MB | 1.32 MB (2.8 times) | 1.28 MB | 0.04 MB | thermal paint 48 kB in 48 frames, the cloud in 1 |

Beside them, the kept run's own record: 1.18 MB for the district (its scene and buildings), 0.07 MB
for the street. The frames are the field; the layers are nothing beside them. And a kept recording
is bounded: the recorder keeps a run within its space (Settings ▸ Replay, 256 MB by default),
recording less often past it, as the district's 250 MB shows.

**Fetched and scrubbed in the Simulator**, the viewer's own measure (`BOMBCAD_VIEWER_AUTO=1`:
it opens the first shared run, scrubs every 0.2 s to a frame not yet in while the rest come,
then shows every frame in a shuffled order), over loopback, so the link is not Wi-Fi's:

| Recording, viewer build | Fetched whole | First frame shown | A frame shown: median, 95%, largest | A frame scrubbed to before it came |
|---|---|---|---|---|
| District, release | 251.8 MB in 0.71 s (356 MB/s) | 0.45 s | 4.6, 11.3, 13.9 ms | 171 ms (2 of them) |
| Street, debug | 61.1 MB in 0.56 s (108 MB/s) | 0.40 s | 9.6, 15.1, 16.7 ms | none asked |

"Shown" is reading the frame's file, decompressing, decoding and uploading it, with the GPU done
with the last: what a scrub costs once the frame is in. It is the Simulator on the Studio's GPU,
not an iPad's. The first frame's 0.4 s is mostly fixed: the session, the worker starting and
reading the project; the bytes before it (the run's record, the manifest, the setup and a frame)
are 0.6 to 3 MB.

**Over Wi-Fi**, from the sealed socket's 22 October rates (40 to 45 MB/s from the Studio, the
frames' way; 8 to 46 on the TLS connection; 4 to 7 for frames when Network.framework carried
them), by the bytes above:

| | Sealed socket, 40 to 45 MB/s | TLS fallback, 8 to 46 MB/s | Network.framework's worst, 4 to 7 MB/s |
|---|---|---|---|
| District, whole (251.8 MB) | 5.6 to 6.3 s | 5.5 to 31 s | 36 to 63 s |
| Street, whole (61.1 MB) | 1.4 to 1.5 s | 1.3 to 7.6 s | 9 to 15 s |
| The first frame (about 3 MB after the session) | under 0.1 s | under 0.4 s | under 0.8 s |
| Any recording at the default space (256 MB) | 5.7 to 6.4 s | 5.6 to 32 s | 37 to 64 s |

**The kill condition does not hold for kept recordings.** A district's is about 1 MB a frame
and at most its recording's space, so on the socket it is all on the iPad in about six seconds,
scrubbable from its first frame in under a second, with no new compression. Played as it comes
rather than fetched, 24 frames a second of it would need 26 MB/s, which the socket carries and
Network.framework's slow case does not. What would bring the condition back is the next step's
scale, below.

**Not measured:** a real iPad (its Wi-Fi, its GPU drawing the field, its memory with 250 MB of
frames on disk and one in memory at a time); the app's own sharing (the open documents, a code
path tested only through `serve`); the time a frame scrubbed to waits on Wi-Fi, which depends on
how much is in flight ahead of it (a frame or two, 25 to 90 ms at the socket's rate, by
estimate). The envelope damage colours, the vent panels and the cloud are drawn by the same
calls as the Mac's Replay; the district showed its buildings' colours, the street its thermal
paint; no scene had vent panels.

## On a real iPad: signing, the Keychain and picking, 23 October 2026

The user has an iPad mini and an iPad Pro (M2). Neither was paired with the Studio on 23 October
(`xcrun devicectl list devices` showed only an iPhone), and the user was away until 27 October,
so the device measurements wait for them. What a device needs is ready:

- **A device build.** `Scripts/build-ipad-viewer.sh --device [debug|release]` builds the target
  for `generic/platform=iOS` and assembles `dist/BombCAD-iPad-device.app` as the Simulator's
  build is assembled. Then it signs for development by team UCF9FS9FWW, the team of the
  Developer ID builds, with the keychain's "Apple Development" certificate of that team. It
  embeds the development profile Xcode keeps for the team: one for `dev.bombcad.viewer` if there
  is one, else the team's wildcard "iOS Team Provisioning Profile: *". The wildcard is there
  (Xcode made it for the user's other iOS app) and lists eight devices, among them UDIDs of an M2
  iPad (00008112-…) and of an A15 or A12 one, likely the two iPads. If an iPad isn't on it, the
  install says so, and running any of the team's apps on it from Xcode once registers it. The
  entitlements are the profile's for this bundle id: application identifier, team, get-task-allow,
  and the keychain group `UCF9FS9FWW.dev.bombcad.viewer`. Installing on a device checks the
  platform keys Xcode writes (`CFBundleSupportedPlatforms`, `DTPlatformName`, `DTSDKName`), so the
  script now adds them to both builds. `BOMBCAD_IPAD_PROFILE` and `BOMBCAD_IPAD_IDENTITY` choose
  others.
- **The bundle id** stays `dev.bombcad.viewer`, beside the Mac's `dev.bombcad.BombCAD`.
  `Support/Viewer-Info.plist` already had the Local Network usage string and the two Bonjour
  services (`_bombcad._tcp`, `_bombcad-pair._tcp`) that browsing needs on a device. No
  entitlement is needed for Bonjour; the multicast one is for raw multicast only.
- **Pairings go back to the Keychain when signed.** The viewer keeps them in the Keychain, as
  the Mac does (`KeychainPairingStore`), when the app carries a provisioning profile (and with it
  the keychain group). The ad hoc Simulator build has no profile, so it keeps the file in its
  container, as before.
- **What the viewer now measures** (`BOMBCAD_VIEWER_AUTO=1`, and `BOMBCAD_VIEWER_PROJECT=<name>`
  to choose the run): besides fetching and showing a frame, the GPU's own time drawing each view
  (the command buffer's GPU start to end, at the drawable's size), and the app's memory as the
  system counts it against the app's limit (`phys_footprint`, its peak, and the limit, which
  `os_proc_available_memory` gives on a device and not in the Simulator).
- **Picking a building.** A tap on an envelope building outlines it, as the Mac outlines the one
  it inspects, and shows a card with:
  - its name;
  - its damage as of the frame shown, in the colours the view paints;
  - its surfaces' peak and mean impulse over the run;
  - the run's standing for envelope damage and for surface exposure, each badge opening its
    evidence as on the Mac.

  A tap elsewhere clears it. The card leaves out the Mac inspector's glass chances: a kept run
  keeps each building's damage colour in its frames and its exposure summary, not the judgement
  the chances come from, so showing them needs the Mac to send them (a later step).

**Tried again in the Simulator** (iPad Pro 11-inch M5, iOS 27, release), serving from a Developer
ID-signed `BombCAD serve --share` of the two study projects:

- The tap picked "yes way/117" in the district, a heavy building at 1024 ms: peak 25.9 kPa, mean
  impulse 441 kPa·ms over 2064 m², standings "Approximate" and "Illustrative". It was outlined
  in the view.
- The district again, over loopback: 251.8 MB in 0.74 s, first frame after 0.33 s, a frame shown
  in 4.6 ms median (12.5 at the 95th percentile). Memory in use stayed at 297 MB: the frames are
  on disk, one in memory at a time.
- The Simulator's GPU times (0.2 ms a view at 1668 by 1820) are not to be believed: they are the
  Simulator's timestamps on the Studio's GPU. The iPads' are the ones to read.
- **Bonjour found the signed Mac.** Served from the Developer ID-signed build, the Mac showed under
  "Sharing nearby" in the Simulator ("Pair with Studio viewer test", Apple M4 Max). On the first
  day, from a build not signed that way, browsing handed the app nothing. Pairing by address
  stays for when it does not.

**Still to measure, on each iPad:** fetching the district and the street over Wi-Fi, the first
frame, a frame shown, the GPU's time a view and scrubbing. The iPad mini's limits matter most:
its memory with the 250 MB district on disk, and whether its GPU draws a view within a frame.
Those replace the Wi-Fi estimates above. The steps are on emmettl/bombcad-work#43.

## What blocks the Vision Pro step

Walking a district at full scale is more than this viewer on a headset:

- **Nothing to run it on here.** Xcode has the visionOS SDK but no visionOS Simulator runtime is
  installed (only iOS and watchOS), and there is no device. Built for the visionOS Simulator, the
  whole package compiled but for one of the Mac's views (CloudSection.swift, its body too slow to
  type-check on visionOS), which would be left out as the others are.
- **The cheapest first look** is this iPad viewer run on a Vision Pro as an iPad app, in a window:
  no immersion, but the same scrubbing, once signed with a team.
- **Immersion needs the renderer changed.** `SceneRenderer` marches the field through every pixel
  of one drawable from an orbiting camera (eye, target, field of view). A full space
  (CompositorServices) gives it two views a frame with their own view and projection matrices,
  asymmetric frusta, and wants depth to composite, at 90 frames a second. The camera has to
  become those matrices, the pass has to draw both eyes (layered or twice), and whether marching
  half a million texels per pixel per eye holds 90 Hz on a headset's GPU is unknown.
- **Full scale wants a finer field near the viewer.** A recording keeps the field at most about
  half a million texels (`RunTimelineRecorder.stride`): on the district every few cells,
  metres apart, which from a street is blocky. Standing in it wants the cells around the viewer
  at full resolution (a crop near the eye, or the refinement levels' fine cells), which is where
  frames grow past a megabyte and a compression path, or a field cut out on the Mac for where
  the viewer stands, may be needed after all.
- **Anchoring and scale**: placing the scene in the room at 1:1, ground at the floor, the charge
  where the user says; the model's metres already are the world's.

## How to try it

1. On the Mac: `BombCAD serve --share <saved project>` (or the app with Settings ▸ Macs nearby
   sharing and the project open). It prints the ports it listens on.
2. In the Simulator: `Scripts/build-ipad-viewer.sh` (debug or release), then
   `xcrun simctl install booted dist/BombCAD-iPad.app` and `xcrun simctl launch booted
   dev.bombcad.viewer`.
   On an iPad, with Developer Mode on (Settings ▸ Privacy & Security), connected by USB once and
   this Mac trusted: `Scripts/build-ipad-viewer.sh --device`, then
   `xcrun devicectl device install app --device <id> dist/BombCAD-iPad-device.app` and
   `xcrun devicectl device process launch --device <id> dev.bombcad.viewer`, the id from
   `xcrun devicectl list devices`. Allow it the local network when it asks.
3. In the viewer, pair with the Mac (by Bonjour, or by address: "<host> <pairing port>
   <session port>", 127.0.0.1 in the Simulator), allow it on the Mac, tap the Mac, then a kept
   run. Tap a building for its damage.
