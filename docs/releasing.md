# Releasing

How to make a Developer ID-signed, Apple-notarized build of the app that can be downloaded and
opened on another Mac. Nothing here tags, uploads or publishes anything.

`make app` alone produces an ad-hoc-signed `dist/BombCAD.app` for use on the machine that built
it.

## One-time setup

The release machine needs a **Developer ID Application** certificate with its private key in
the Keychain (an Apple Development certificate will not do), and a `notarytool` Keychain profile
holding the notary credentials. A profile is not tied to one app, so one made for another
project of the same team works too. Set it up interactively; never put passwords in scripts.

```bash
security find-identity -v -p codesigning
```

```bash
xcrun notarytool store-credentials "BombCAD-notary"
```

## Build a candidate

1. Set `CFBundleShortVersionString` (numeric, `major.minor.patch`) and `CFBundleVersion` (a
   positive integer) in `Support/Info.plist`, and commit. Keep the bundle identifier,
   `dev.bombcad.BombCAD`, unchanged.
2. Choose the identity and profile, check, and prepare:

```bash
export BOMBCAD_SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)"
export BOMBCAD_NOTARY_PROFILE="BombCAD-notary"
make release-check
make release
```

`release-check` confirms that exactly one matching Developer ID identity exists, that a profile
is named, that the checkout is clean, and that the version is well formed. The profile's
credentials are only tried on submission.

`release` (`Scripts/release.py prepare`) then:

1. runs `make check` (strict formatting lint, the test suite, the release-script tests and a
   build);
2. runs `make release-smoke`: `blastbench` built in release, run for a few seconds on solid and
   shell elements, bars that slip and base connections. The test suite builds for debugging, and
   Swift 6.4's optimiser once miscompiled the solvers' initialisers (`withUnsafeBytes`, which
   rethrows, inlined into an initialiser that throws, handed back a corrupt error from a closure
   that cannot throw), so that every structure crashed in a release build only (see
   `BufferCopy.swift`); then `make app-smoke`, the app built and a small project run from inside
   it, and a new document's window and sidebar drawn offscreen while its source switches between a
   charge and a gas cloud (`BombCAD interface-smoke`);
3. builds `dist/BombCAD.app` in release, and checks that the checkout is still clean, that the
   app's version matches the source, that every resource bundle the binary links (read from the
   binary, as each accessor names its own) and the licence text are inside it, and that it is
   arm64; then runs a small project from inside it (`BombCAD run`), which builds the solver and
   its shaders, and draws its views through a change of source (`BombCAD interface-smoke`);
4. signs it with the hardened runtime and a secure timestamp, with no entitlement exceptions
   (the shaders are compiled at run time by Metal's own compiler service, which needs none);
5. submits a ZIP to Apple and waits up to 30 minutes, writing Apple's reply to
   `dist/notarization.json`; it stops unless the status is `Accepted`;
6. staples the ticket, validates it, re-verifies the signature, asks Gatekeeper to assess
   the app and runs the small project from inside the signed app again;
7. only then writes the release archive, its checksum and a manifest:

```text
dist/BombCAD-0.1.0-macos-arm64.zip
dist/BombCAD-0.1.0-macos-arm64.zip.sha256
dist/BombCAD-0.1.0-macos-arm64.json
```

The manifest records the version, build, source commit, architecture, minimum macOS, checksum
and signing status. The script will not overwrite an existing archive.

If notarization is rejected, read `dist/notarization.json` and fetch the submission's log with
`xcrun notarytool log <id> --keychain-profile BombCAD-notary`. If the wait times out, find the
submission with `notarytool history` before submitting again; a timed-out submission is not an
accepted one.

## Before publishing

Expand the final ZIP somewhere fresh and test that copy, ideally downloaded through a browser on
another Mac with Gatekeeper enabled: first launch, Metal rendering, a run of each preset, and
opening and saving a layout.

## The pictures

When a release retakes the docs' pictures, a run of an hour or more (the office on fin plates at
3 s, the large-panel street charge) also saves a checkpoint shortly before each picture's time,
kept under `/Volumes/StudioData/bombcad/checkpoints/<image>/` with a README giving the command and
the commit, so later changes to how things are drawn retake it in minutes ([retaking a doc image
from a checkpoint](checkpoints.md#retaking-a-doc-image-from-a-checkpoint)).

## The notes

Each change a user would notice adds a fragment under
[release-notes/next](release-notes/next/README.md) in its own push. Before building, assemble them
into the version's notes with `python3 Scripts/release-notes.py assemble X.Y.Z`, read the result as
a whole, and commit it.

## After publishing: the Homebrew cask

The app installs with `brew install emmettl/tap/bombcad`, from the cask in
[emmettl/homebrew-tap](https://github.com/emmettl/homebrew-tap) (`Casks/bombcad.rb`), which also
links the app's headless runner as `bombcad`. Once `gh release create` has published the ZIP and
its `.sha256`, point the cask at it:

```bash
python3 Scripts/update-homebrew-tap.py 0.5.0
```

It takes the checksum from the release's own `.sha256`, rewrites the cask's `version` and `sha256`
and commits that to the tap through the GitHub API (`--dry-run` prints the new cask instead). Then
check it as Homebrew would: `brew update`, `brew audit --cask --strict --online emmettl/tap/bombcad`
and `brew style emmettl/tap`. The official homebrew-cask repository needs more evidence of use
than this project has yet, so the tap is the only route for now.

## Checked so far

The release tests (`make ci-test`) exercise the script with every external tool stubbed out:
a rejected notarization, a Gatekeeper refusal, a missing shader bundle (including one the binary
links that a fixed list would have missed) and a missing licence each stop it before an archive
is written, and the packaged app is run before signing and before archiving. On the development Mac `blastbench`, signed with the
Developer ID identity and the hardened runtime, compiles the shaders and runs.

The whole path has been run for real, with the `BombCAD-notary` profile, from 2026-10-05:

| Build      | Commit    | Apple submission                       | Note                          |
|------------|-----------|----------------------------------------|-------------------------------|
| 0.1.0 (1)  | `cb90a14` | `5d9e4182-7794-49d2-a448-21d4eb68190d` | Superseded: no licence inside |
| 0.1.0 (2)  | `2a906cb` | `1bf60a66-4602-46a3-b940-7eda11545870` | Published as v0.1.0           |
| 0.1.1 (3)  | `646ff4e` | `59e35f9c-2aca-4144-8130-314d4604c5d5` | Published as v0.1.1           |
| 0.1.2 (4)  | `239a67e` | `aa446aa3-ba2e-486b-9ef3-ad5651ec6948` | Published as v0.1.2           |
| 0.2.0 (5)  | `6eef870` | `678f1bcd-04bc-4c3d-a2d2-f2fad6ffdc29` | Superseded, not published     |
| 0.2.0 (6)  | `5d930d7` | `7dcc4ec3-0956-4be4-9e4b-972c2e29abca` | Published as v0.2.0           |
| 0.3.0 (7)  | `b524a9d` | `de90ca6f-1803-4cd9-998b-525980d409c6` | Published as v0.3.0; crashes  |
| 0.3.1 (8)  | `c874a6a` | `21d1ff1a-9ebd-45cf-98d6-712264341f22` | Made with the fix, not published |
| 0.4.0 (10) | `9482ba7` | `b548eb9b-5031-48cd-800e-124a207db04e` | Published as v0.4.0           |
| 0.5.0 (11) | `cde4b514` | `da25d621-e049-4f08-99bc-39ca876f0e3d` | Published as v0.5.0           |
| 0.5.1 (12) | `1b79ae33` | `0db0948d-6e0b-4584-8fcb-c6f0d2c80a77` | Published as v0.5.1           |

For each, Apple accepted the submission, the ticket was stapled and validated, and Gatekeeper
assessed the app as `Notarized Developer ID`. A fresh expansion of build 2's final ZIP matched
its checksum, validated its stapled ticket, passed `codesign --verify --deep --strict`, was
accepted by `spctl` and holds the licence text. On 2026-10-06 build 2 was reported to work fine
on a second Mac. The individual checks under "Before publishing" were not recorded one by one.

Build 2's ZIP, checksum and manifest are attached to the GitHub release `v0.1.0`, published on
2026-10-06 with its tag on `2a906cb`; the copy downloaded back from it matched the checksum.
The repository was made public the same day, so anyone can download it.

Build 3 (0.1.1) went the same way on 2026-10-06: Apple accepted it, and a fresh expansion of
its ZIP matched the checksum, validated its stapled ticket, passed
`codesign --verify --deep --strict`, was accepted by `spctl` as `Notarized Developer ID`, and
holds the licence text and both shader bundles. Its ZIP, checksum and manifest are attached to
the GitHub release `v0.1.1`, tagged on `646ff4e`; the copy downloaded back matched the
checksum. The notary step had to be run from Terminal.app: in shells started by the Claude
desktop app, `notarytool` reported no `BombCAD-notary` profile.

Build 4 (0.1.2) went the same way on 2026-10-07, with `notarytool` working from a desktop-app
shell this time. Its first attempt stopped at `make check`'s strict lint, as the code added since
0.1.1 had not been formatted; after `swift format`, all 146 tests passed, Apple accepted it, and
a fresh expansion of its ZIP matched the checksum, validated its stapled ticket, passed
`codesign --verify --deep --strict`, was accepted by `spctl` as `Notarized Developer ID`, and
holds the licence text and both shader bundles. Its ZIP, checksum and manifest are attached to
the GitHub release `v0.1.2`, tagged on `239a67e`.

Build 6 (0.2.0) went the same way on 2026-10-11, after build 5 from an earlier commit was made
and superseded without being published. Its `make check` twice stopped on the app suite's timing
tests while other sessions' long runs held the GPU (each passing alone); in a window with every
other GPU job suspended, all 278 app and 868 core tests passed, Apple accepted it, and a fresh
expansion of its ZIP matched the checksum
(`4bbf08e2e2151b2754d913c028085eb501eda9f40f5ca497ee7e72fc37e6b9af`), validated its stapled
ticket, passed `codesign --verify --deep --strict`, was accepted by `spctl` as
`Notarized Developer ID`, and holds the licence text and both shader bundles; `make release-smoke`
passed. Its notes, reviewed independently, are in `docs/release-notes/0.2.0.md`. Its ZIP,
checksum and manifest are attached to the GitHub release `v0.2.0`, tagged on `5d930d7`.

Build 7 (0.3.0) was prepared and published on 2026-10-15 from `f5a9261`, with `make release` run once inside
`gpu-slot` and the app's tests now deterministic: all 300 app and 921 core tests passed, Apple
accepted it, and a fresh expansion of its ZIP matched the checksum
(`c42fb6b3634087187807ff9f156dcb0430eced31049309fa291f434a79bd8e17`), validated its stapled
ticket, passed `codesign --verify --deep --strict`, was accepted by `spctl` as
`Notarized Developer ID`, and holds the licence text and both shader bundles; `make release-smoke`
passed. Its notes, reviewed independently, are in `docs/release-notes/0.3.0.md`. Its ZIP, checksum
and manifest are attached to the GitHub release `v0.3.0`, tagged on `b524a9d`.

Build 7 crashes on New Document, or whenever it first builds a structure's solver: ContinuumKit 0.1.0-alpha.25
added a resource bundle (its contact search) that `build-app.sh`'s fixed list never copied, and
the release checked only BombCAD's two bundles, and never ran the packaged app. "Both shader
bundles" above was true and not enough. The bundles now come from the binary, and the release runs
the packaged app (above); run headless from inside its bundle, build 7 stops with "unable to find
bundle named ContinuumKit_ContactSearchMetal", the same as the crash reports.

Build 8 (0.3.1) was made on 2026-10-16 with the fix, from a commit not on main, to try it: all
300 app and 922 core tests passed, the packaged app ran the small project before signing, signed,
and from a fresh expansion of its ZIP, which Apple accepted and Gatekeeper assessed as
`Notarized Developer ID`. It was not published: no one was using 0.3.0 yet, so 0.3.1 waits for
the normal process, and takes build 9 or later.

Build 9 (0.4.0) was begun on 2026-10-16 from `92ac96d7` and stopped during its tests, before signing
or notarization: a crash on removing the gas cloud had just been found on main. It was never made or
published; 0.4.0 takes build 10, which also draws a new document's views through a change of source
before signing and again before archiving (`BombCAD interface-smoke`, part of `make app-smoke`).

Build 10 (0.4.0) was prepared on 2026-10-17 from `9482ba7`, with `make release` run once inside
`gpu-slot`. All 306 app and 979 core tests passed. The packaged app ran the small project and drew its
views through a change of source before signing and again before archiving. Apple accepted it
(submission `b548eb9b-5031-48cd-800e-124a207db04e`). A fresh expansion of its ZIP:

- matched the checksum (`78e1fe35e64abc82305fb383aacf2cf3164e733f2f43d25d8b8914ee06e44826`);
- validated its stapled ticket;
- passed `codesign --verify --deep --strict`;
- was accepted by `spctl` as `Notarized Developer ID`;
- holds the licence text and the four resource bundles its binary links (BombCAD's two,
  ContinuumKit's contact search and scene render);
- is version 0.4.0, build 10, arm64;
- ran the small project from inside its bundle and drew its views through a change of source
  (`make app-smoke`'s two steps, on that copy).

Its notes, reviewed independently, are in `docs/release-notes/0.4.0.md`. Its ZIP, checksum and
manifest are attached to the GitHub release `v0.4.0`, published on 2026-10-17 with its tag on
`9482ba7`; the copy downloaded back matched the checksum, validated its stapled ticket, passed
`codesign --verify --deep --strict` and was accepted by `spctl`.

Build 11 (0.5.0) was prepared on 2026-10-19 from `cde4b514` on the branch `release/0.5.0`:
`b6a7abec` from main, which passed `make check-anywhere`, then the version, the notes' late
changes and retaken pictures, and three fixes picked from main (a run on the fine start that
samples no longer hangs, the release smoke that guards it, and a placement test that no longer
depends on the Mac's load). A first `make release` on `6b57a0a5` stopped in its tests before
signing: that placement test, run with every other session's GPU work beside it. With no quiet
window and `make release` run outside `gpu-slot`, all 347 app and 1182 core tests passed, the
packaged app ran the small project and the structure on the fine start, and drew its views
through a change of source, before signing and again before archiving. Apple accepted it
(submission `da25d621-e049-4f08-99bc-39ca876f0e3d`). A fresh expansion of its ZIP:

- matched the checksum (`222c94d3fe5094be59ac18f4f22a34c634876d6951f086a45c688f411ce30e16`);
- validated its stapled ticket;
- passed `codesign --verify --deep --strict`;
- was accepted by `spctl` as `Notarized Developer ID`;
- holds the licence text and the four resource bundles its binary links (BombCAD's two,
  ContinuumKit's contact search and scene render; RadialBlast has none);
- is version 0.5.0, build 11, arm64;
- ran the small project and the structure on the fine start from inside its bundle and drew its
  views through a change of source (`Scripts/release.py smoke`, on that copy);
- opened one of the user's projects by hand, which the user reported working.

Its notes, reviewed independently, are in `docs/release-notes/0.5.0.md`; on the release page their
links point at the docs as tagged. Its ZIP, checksum and manifest are attached to the GitHub release
`v0.5.0`, published on 2026-10-19 with its tag on `cde4b514`; the copy downloaded back matched the
checksum, validated its stapled ticket, passed `codesign --verify --deep --strict` and was accepted
by `spctl`. The Homebrew cask (`emmettl/tap/bombcad`) was moved to 0.5.0 by
`Scripts/update-homebrew-tap.py 0.5.0`, and `brew audit --cask --strict --online` passed.

Build 12 (0.5.1) was prepared on 2026-10-19 from `1b79ae33` on the branch `release/0.5.1`: the
`v0.5.0` tag with the fixes for 0.5.0's four known limitations picked from main or made on the tag
(the fine start's clocks in two parts, the refined panes' table, shells' springs and links on a
restart, each shell's own rule through its thickness), the wave-speed guard made safe from fast
math, and a fragment test's race. Its full check passed with `make check-anywhere` before the last
clock fix, and solver digests matched 0.5.0's on all seven cases plain, recommended and refined.
A first `make release` on `80a183af` stopped in its tests before signing, on that race
(`FragmentOverlayTests`: a run kept as its last fragment frame landed). The second passed all 347
app and 1189 core tests, and Apple accepted it (submission `0db0948d-6e0b-4584-8fcb-c6f0d2c80a77`).
A fresh expansion of its ZIP matched the checksum
(`9f445554c5f793b0cc100932812b360848d7b518d411b1d25c5a0817b2005765`), validated its stapled
ticket, passed `codesign --verify --deep --strict`, was accepted by `spctl` as
`Notarized Developer ID`, holds the licence and the same four resource bundles, is 0.5.1, build 12,
arm64, and ran the small project and the structure on the fine start from inside its bundle. The
user had said to publish once it was ready. It was published on 2026-10-19 as `v0.5.1`, tag on
`1b79ae33`, with its notes' links pointing at the docs as tagged; the copy downloaded back matched
the checksum, validated its ticket, passed `codesign` and was accepted by `spctl`. The Homebrew
cask was moved to 0.5.1 and `brew audit --cask --strict --online` passed.

Build 13 (0.6.0) was prepared on 2026-10-20 from `27fb9be7` on the branch `release/0.6.0`:
main at `86496801` with its notes assembled from 72 fragments (the main changes first, then New,
Changed, Fixed and Known limitations), and one fix picked from main (`14d084fd`, an unused
binding that the strict build in `make release` caught from a file split). A first `make release`
stopped there, before signing. The second passed `make check` (399 app and 803 model tests, the
core GPU suites, build-strict with no warnings), the release smoke runs and the app's own run and
interface smoke from inside its bundle, and Apple accepted it. A fresh expansion of its ZIP
matched the checksum (`face37a4fda6794923f18659312bd7247747d8780ae11a3c64fcdfad25b14bfb`),
validated its stapled ticket, passed `codesign --verify --deep --strict`, was accepted by `spctl`
as `Notarized Developer ID`, holds the licence and the four resource bundles, is 0.6.0, build 13,
arm64, and ran a project from inside its bundle. The user said to publish; it was published on
2026-10-20 as `v0.6.0`, tag on `27fb9be7`, with its notes' links pointing at the docs as tagged.
The copy downloaded back matched the checksum, validated its ticket, passed `codesign` and was
accepted by `spctl`. The Homebrew cask was moved to 0.6.0 and `brew audit --cask --strict
--online` passed.

The source is under the MIT licence (`LICENSE`). MIT asks for the notice to travel with every
copy, so `make app` puts it in the app's resources and `release` refuses an app without it.
