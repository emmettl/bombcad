"""Point the Homebrew cask (emmettl/homebrew-tap, Casks/bombcad.rb) at a published release.

Run after `gh release create` has published vX.Y.Z with its ZIP and `.sha256`:

    python3 Scripts/update-homebrew-tap.py 0.5.0

It reads the checksum from the release's own `.sha256` asset, rewrites the cask's `version` and
`sha256`, and commits the change to the tap through the GitHub API. `--dry-run` prints the new
cask instead. It refuses a version that is not published, or a checksum that is not 64 hex digits.
"""

import argparse
import base64
import json
import re
import subprocess

REPOSITORY = "emmettl/bombcad"
TAP = "emmettl/homebrew-tap"
CASK = "Casks/bombcad.rb"


def gh(*arguments, stdin=None):
    return subprocess.run(["gh", *arguments], check=True, text=True, input=stdin,
                          stdout=subprocess.PIPE).stdout


def asset_name(version):
    return f"BombCAD-{version}-macos-arm64.zip"


def published_sha256(version):
    """The checksum the release itself publishes, as `<sha256>  <file>`."""
    text = gh("release", "download", f"v{version}", "--repo", REPOSITORY,
              "--pattern", f"{asset_name(version)}.sha256", "--output", "-")
    digest, _, name = text.strip().partition("  ")
    if not re.fullmatch(r"[0-9a-f]{64}", digest) or name.strip() != asset_name(version):
        raise ValueError(f"The release's .sha256 does not name {asset_name(version)}: {text!r}")
    return digest


def updated_cask(cask, version, digest):
    """The cask with its version and sha256 replaced; both lines must exist exactly once."""
    for key, value in (("version", version), ("sha256", digest)):
        pattern = re.compile(rf'^(\s*){key} "[^"]*"$', re.MULTILINE)
        if len(pattern.findall(cask)) != 1:
            raise ValueError(f"The cask has no single {key} line.")
        cask = pattern.sub(rf'\g<1>{key} "{value}"', cask)
    return cask


def current_cask():
    reply = json.loads(gh("api", f"repos/{TAP}/contents/{CASK}"))
    return base64.b64decode(reply["content"]).decode(), reply["sha"]


def commit(text, blob, version):
    body = json.dumps({
        "message": f"BombCAD {version}",
        "content": base64.b64encode(text.encode()).decode(),
        "sha": blob,
    })
    gh("api", "--method", "PUT", f"repos/{TAP}/contents/{CASK}", "--input", "-", stdin=body)


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("version", help="the published version, e.g. 0.5.0")
    parser.add_argument("--dry-run", action="store_true", help="print the new cask only")
    arguments = parser.parse_args()
    if not re.fullmatch(r"\d+\.\d+\.\d+", arguments.version):
        raise SystemExit("Give a numeric major.minor.patch version, without the v.")
    digest = published_sha256(arguments.version)
    cask, blob = current_cask()
    text = updated_cask(cask, arguments.version, digest)
    if arguments.dry_run:
        print(text, end="")
    elif text == cask:
        print(f"{TAP} already has {arguments.version}.")
    else:
        commit(text, blob, arguments.version)
        print(f"{TAP}: {CASK} now {arguments.version} ({digest}).")


if __name__ == "__main__":
    main()
