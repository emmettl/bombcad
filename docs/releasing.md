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
   it;
3. builds `dist/BombCAD.app` in release, and checks that the checkout is still clean, that the
   app's version matches the source, that every resource bundle the binary links (read from the
   binary, as each accessor names its own) and the licence text are inside it, and that it is
   arm64; then runs a small project from inside it (`BombCAD run`), which builds the solver and
   its shaders;
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

The source is under the MIT licence (`LICENSE`). MIT asks for the notice to travel with every
copy, so `make app` puts it in the app's resources and `release` refuses an app without it.
