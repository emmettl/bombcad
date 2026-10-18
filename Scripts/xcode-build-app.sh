#!/bin/bash
# Called by Xcode's "BombCAD App" target (Xcode/project.yml): builds dist/BombCAD.app with
# Scripts/build-app.sh in the scheme's configuration, so the app Xcode runs is the one `make app`
# makes, resource bundles and all.
set -euo pipefail
cd "$(dirname "$0")/.."
configuration="$(printf '%s' "${CONFIGURATION:-Debug}" | tr '[:upper:]' '[:lower:]')"
exec bash Scripts/build-app.sh "$configuration"
