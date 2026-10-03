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
   app's version matches the source, that both shader bundles are inside it and that it is
   arm64;
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
a rejected notarization, a Gatekeeper refusal and a missing shader bundle each stop it before
an archive is written. On the development Mac the app has been signed with the Developer ID
identity and the hardened runtime and passes `codesign --verify --deep --strict`, and
`blastbench`, signed the same way, compiles the shaders and runs. No build has yet been
submitted for notarization.

The repository has no licence file. One is not needed to notarize, but should be chosen before
the source or a build is published.
