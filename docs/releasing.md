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
2. builds `dist/BombCAD.app` in release, and checks that the checkout is still clean, that the
   app's version matches the source, that both shader bundles and the licence text are inside
   it and that it is arm64;
3. signs it with the hardened runtime and a secure timestamp, with no entitlement exceptions
   (the shaders are compiled at run time by Metal's own compiler service, which needs none);
4. submits a ZIP to Apple and waits up to 30 minutes, writing Apple's reply to
   `dist/notarization.json`; it stops unless the status is `Accepted`;
5. staples the ticket, validates it, re-verifies the signature and asks Gatekeeper to assess
   the app;
6. only then writes the release archive, its checksum and a manifest:

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
a rejected notarization, a Gatekeeper refusal, a missing shader bundle and a missing licence
each stop it before an archive is written. On the development Mac `blastbench`, signed with the
Developer ID identity and the hardened runtime, compiles the shaders and runs.

The whole path has been run for real, with the `BombCAD-notary` profile, on 2026-10-05:

| Build      | Commit    | Apple submission                       | Note                          |
|------------|-----------|----------------------------------------|-------------------------------|
| 0.1.0 (1)  | `cb90a14` | `5d9e4182-7794-49d2-a448-21d4eb68190d` | Superseded: no licence inside |
| 0.1.0 (2)  | `2a906cb` | `1bf60a66-4602-46a3-b940-7eda11545870` | Published as v0.1.0           |
| 0.1.1 (3)  | `646ff4e` | `59e35f9c-2aca-4144-8130-314d4604c5d5` | Published as v0.1.1           |

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

The source is under the MIT licence (`LICENSE`). MIT asks for the notice to travel with every
copy, so `make app` puts it in the app's resources and `release` refuses an app without it.
