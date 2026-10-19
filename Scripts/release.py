"""Prepare a Developer ID-signed, notarized release locally; never tags or publishes anything."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]
APP = "dist/BombCAD.app"
EXECUTABLE = "BombCAD"
MINIMUM_MACOS = "15.0"
# The shaders are compiled at run time from SwiftPM resource bundles; a target whose bundle is
# missing stops the app the first time it is used (0.3.0 crashed on New Document without
# ContinuumKit's contact search). Each target's generated accessor names its own bundle in the
# message it stops with, so the binary itself says which bundles it needs.
BUNDLE_REFERENCE = re.compile(rb"unable to find bundle named ([A-Za-z0-9_.-]+)")
# A small project, run headless from inside the packaged app: it builds the solver, which
# compiles the shaders of every bundle the air and the structures use.
SMOKE_PROJECT = "Samples/Neighborhood/layout.json"
# A structure on the fine (mapped) start, writing frames: its clock starts at the one-dimensional
# solution's hand-over, some 9 ms in, after four frames. 0.5.0's build waited forever there.
SMOKE_MAPPED = "Samples/MappedSmoke/layout.json"


def run(*arguments, capture=False, timeout=None):
    return subprocess.run(arguments, cwd=ROOT, check=True, text=True, timeout=timeout,
                          stdout=subprocess.PIPE if capture else None).stdout


def metadata(plist):
    version = plist.get("CFBundleShortVersionString", "")
    build = plist.get("CFBundleVersion", "")
    if not isinstance(version, str) or not re.fullmatch(r"\d+\.\d+\.\d+", version):
        raise ValueError("Use a numeric major.minor.patch version in Support/Info.plist.")
    if not isinstance(build, str) or not re.fullmatch(r"[1-9]\d*", build):
        raise ValueError("Use a positive integer build number in Support/Info.plist.")
    if plist.get("LSMinimumSystemVersion") != MINIMUM_MACOS:
        raise ValueError("Update the release requirements before changing the macOS baseline.")
    if not plist.get("CFBundleIdentifier"):
        raise ValueError("The app needs a stable bundle identifier.")
    return {"version": version, "build": build, "bundleIdentifier": plist["CFBundleIdentifier"],
            "minimumMacOS": MINIMUM_MACOS, "architecture": "arm64"}


def choose_identity(output, requested):
    identities = re.findall(r'([A-Fa-f0-9]{40}) "(Developer ID Application: [^"]+)"', output)
    matches = [(fingerprint, name) for fingerprint, name in identities
               if not requested or requested in (fingerprint, name)]
    if len(matches) != 1:
        raise ValueError("Select one valid Developer ID Application identity with --identity. "
                         "An Apple Development identity cannot be used for this release.")
    return matches[0][0]


def write_checksums(archive, manifest):
    digest = hashlib.sha256()
    with archive.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    checksum = digest.hexdigest()
    archive.with_suffix(archive.suffix + ".sha256").write_text(f"{checksum}  {archive.name}\n")
    archive.with_suffix(".json").write_text(json.dumps({**manifest, "sha256": checksum}, indent=2) + "\n")


def linked_bundles(binary):
    """The resource bundles a binary loads, by the names their accessors stop with."""
    names = sorted({name.decode() + ".bundle" for name in BUNDLE_REFERENCE.findall(Path(binary).read_bytes())})
    if not names:
        raise ValueError(f"{binary} names no resource bundles; the shaders would be missing.")
    return names


def missing_bundles(app):
    binary = app / "Contents/MacOS" / EXECUTABLE
    if not binary.is_file():
        return ["the executable"]
    return [name for name in linked_bundles(binary) if not (app / "Contents/Resources" / name).is_dir()]


def smoke(app):
    """Runs a small project from inside the app, as a user's copy would start a document."""
    with tempfile.TemporaryDirectory(prefix="bombcad-smoke-") as temporary:
        run(str(app / "Contents/MacOS" / EXECUTABLE), "run", str(ROOT / SMOKE_PROJECT),
            "--resolution", "coarse", "--duration", "0.002", "--out", str(Path(temporary) / "smoke.bombcad"))
        # Past the mapped start's hand-over with a structure and frames, within minutes: a run that
        # cannot step past it never ends.
        run(str(app / "Contents/MacOS" / EXECUTABLE), "run", str(ROOT / SMOKE_MAPPED),
            "--resolution", "coarse", "--duration", "0.016", "--frame-interval", "2",
            "--usd", str(Path(temporary) / "mapped.usda"), "--out", str(Path(temporary) / "mapped.bombcad"),
            timeout=600)
    # Its window and sidebar drawn offscreen through a change of source, as the Source menu makes it.
    run(str(app / "Contents/MacOS" / EXECUTABLE), "interface-smoke")


def preflight(args):
    identity = choose_identity(run("security", "find-identity", "-v", "-p", "codesigning", capture=True), args.identity)
    if not args.notary_profile:
        raise ValueError("Supply a previously configured Keychain profile with --notary-profile.")
    if run("git", "status", "--porcelain", capture=True).strip():
        raise ValueError("Commit or set aside working-tree changes before preparing a release.")
    info = metadata(plistlib.loads((ROOT / "Support/Info.plist").read_bytes()))
    info["commit"] = run("git", "rev-parse", "HEAD", capture=True).strip()
    return identity, info


def release(args):
    identity, info = preflight(args)
    if args.command == "check":
        print(f"Release {info['version']} ({info['build']}): local signing prerequisites present. "
              "Notary credentials are verified when submitting.")
        return
    archive = ROOT / "dist" / f"BombCAD-{info['version']}-macos-arm64.zip"
    if archive.exists():
        raise ValueError(f"Archive already exists: {archive.name}. Move it aside explicitly before retrying.")
    # The long studies in full, which the pre-push checks shorten (Tests/*/FullStudies.swift).
    os.environ["BOMBCAD_FULL_STUDIES"] = "1"
    run("make", "check")
    run("make", "release-smoke")
    run("make", "app", "CONFIGURATION=release")
    if run("git", "status", "--porcelain", capture=True).strip():
        raise ValueError("The build changed the source checkout; review and commit the changes before releasing.")
    app = ROOT / APP
    built = metadata(plistlib.loads((app / "Contents/Info.plist").read_bytes()))
    if any(info[key] != built[key] for key in built):
        raise ValueError("Built application metadata differs from the release source.")
    missing = missing_bundles(app)
    if missing:
        raise ValueError(f"The app lacks its shader bundles: {', '.join(missing)}.")
    smoke(app)
    if not (app / "Contents/Resources/LICENSE").is_file():
        raise ValueError("The app lacks its licence text, which must ship with every copy.")
    architecture = run("lipo", "-archs", str(app / "Contents/MacOS" / EXECUTABLE), capture=True).strip()
    if architecture != "arm64":
        raise ValueError("This release channel expects an arm64 build.")
    run("codesign", "--force", "--sign", identity, "--options", "runtime", "--timestamp",
        str(app / "Contents/MacOS/IfcConvert"))
    run("codesign", "--force", "--sign", identity, "--options", "runtime", "--timestamp", str(app))
    run("codesign", "--verify", "--deep", "--strict", str(app))
    with tempfile.TemporaryDirectory(prefix="bombcad-notary-", dir=ROOT / "dist") as temporary:
        submission = Path(temporary) / "submission.zip"
        run("ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(app), str(submission))
        response = json.loads(run("xcrun", "notarytool", "submit", str(submission),
                                  "--keychain-profile", args.notary_profile, "--wait",
                                  "--timeout", "30m", "--output-format", "json", capture=True))
        (ROOT / "dist/notarization.json").write_text(json.dumps(response, indent=2) + "\n")
        if response.get("status") != "Accepted":
            raise ValueError("Notarization was not accepted. Inspect dist/notarization.json and "
                             "retrieve the submission log with notarytool before retrying.")
    run("xcrun", "stapler", "staple", str(app))
    run("xcrun", "stapler", "validate", str(app))
    run("codesign", "--verify", "--deep", "--strict", str(app))
    run("spctl", "--assess", "--type", "execute", "--verbose=4", str(app))
    smoke(app)
    run("ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(app), str(archive))
    write_checksums(archive, {**info, "signing": "Developer ID Application", "notarized": True})
    print(f"Ready for review: {archive}. No tag or release has been created.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["check", "prepare", "bundles", "smoke"])
    parser.add_argument("path", nargs="?", help="bundles: the binary; smoke: the app")
    parser.add_argument("--identity", default=os.environ.get("BOMBCAD_SIGNING_IDENTITY"))
    parser.add_argument("--notary-profile", default=os.environ.get("BOMBCAD_NOTARY_PROFILE"))
    args = parser.parse_args()
    try:
        if args.command == "bundles":
            print("\n".join(linked_bundles(args.path)))
        elif args.command == "smoke":
            app = Path(args.path)
            missing = missing_bundles(app)
            if missing:
                raise ValueError(f"The app lacks its shader bundles: {', '.join(missing)}.")
            smoke(app)
            print(f"{app} ran a project from inside its bundle.")
        else:
            release(args)
    except (ValueError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"Release preparation stopped: {error}\n")


if __name__ == "__main__":
    main()
