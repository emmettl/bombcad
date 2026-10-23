kind: added

**A first iPad viewer replays the runs a Mac keeps, scrubbed from its first frame.** BombCAD now
builds for iPadOS as a viewer: it pairs with a Mac sharing its GPU as another Mac would, lists
the kept runs with recordings in the projects that Mac shares (`BombCAD serve --share <project>`,
or the saved projects open in the app while it shares), fetches one over the session's sealed
socket and replays it with the app's renderer, its vent panels, envelope colours, thermal paint
and cloud as Replay shows them; frames scrubbed to before they arrive are sent next. Tried in the
iPad Simulator on 23 October 2026: the made-up district's recording, 233 frames and 252 MB, came
whole in 0.7 s over loopback, its first frame on screen after 0.45 s, a frame shown in 5 ms;
over the Wi-Fi measured on 22 October that is about six seconds, with no new compression. Tap a
building to outline it and see its damage at the frame shown, what its surfaces took and the
run's standing for both. `Scripts/build-ipad-viewer.sh --device` signs the viewer for a real iPad
with the team's development certificate; it then keeps its pairings in the Keychain, as the Mac
does. Not yet measured on a real iPad. Both ends need this version (worker protocol 18). See
[the spatial viewer](../../spatial-viewer.md).
