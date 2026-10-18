.PHONY: xcode build build-strict app app-smoke run test test-core release-smoke lint format icons ifc-converter ci-test check check-light check-remote check-anywhere check-affected release-check release

CONFIGURATION ?= release

build:
	swift build

# The package and its tests built, failing on any compiler warning in its own code (see
# Scripts/build-strict.py); what the checks build with.
build-strict:
	python3 Scripts/build-strict.py

icons:
	swift Scripts/make-icon.swift

app:
	bash Scripts/build-app.sh "$(CONFIGURATION)"

# An Xcode project for working on the source (Xcode/project.yml; needs `brew install xcodegen`).
xcode:
	xcodegen --spec Xcode/project.yml

run: app
	open dist/BombCAD.app

# The packaged app run headless from inside its bundle, as a downloaded copy starts: its resource
# bundles all there and the solver built from them.
app-smoke: app
	python3 Scripts/release.py smoke dist/BombCAD.app

ifc-converter:
	python3 Scripts/prepare-ifc-converter.py

# Keep the wall-clock playback bound unchanged and measure it without unrelated
# main-actor/GPU test work. The second invocation runs every other test exactly once.
PLAYBACK_TIMING_TEST := BombCADTests[.]SimulationModelTests/pacedPlayback

test: ifc-converter
	swift test --filter '$(PLAYBACK_TIMING_TEST)'
	swift test --skip '$(PLAYBACK_TIMING_TEST)'

# The core target alone: the solvers' tests, a few minutes on the CI mini. The application's
# tests, which take most of `make test`, are left to the full check.
test-core: ifc-converter
	swift test --filter 'BlastCoreTests\.'

# The solvers built as a release is, run for a few seconds each: solid and shell elements, bars
# that slip and base connections. `swift test` builds for debugging, and the optimiser has
# miscompiled code that ran correctly there. Then the packaged app, run from inside its bundle.
release-smoke:
	swift build -c release --product blastbench
	.build/release/blastbench shear --layers 12
	.build/release/blastbench shear --layers 12 --bond pullout
	.build/release/blastbench slab --shells 1
	.build/release/blastbench anchorage --standoff 25 --bases clamped,dowelled,soil,footing --time 0.05
	.build/release/blastbench anchorage --shells --standoff 25 --bases clamped,soil --time 0.05
	$(MAKE) app-smoke

lint:
	swift format lint --strict --recursive Package.swift Sources Tests Scripts

format:
	swift format format --in-place --recursive Package.swift Sources Tests Scripts

# The scripts' own tests, and the documents' relative links and anchors (check-doc-links.py).
ci-test:
	python3 Scripts/test-release.py
	python3 Scripts/test-nightly.py
	python3 Scripts/test-remote.py
	python3 Scripts/test-nightly-suspects.py
	python3 Scripts/test-build-strict.py
	python3 Scripts/test-concrete-matrix.py
	python3 Scripts/test-update-homebrew-tap.py
	python3 Scripts/test-check-affected.py
	python3 Scripts/check-doc-links.py

check: lint build-strict test ci-test

# What CI runs on each push to main, as a backstop to the full check run before pushing: about
# 15 to 20 minutes on the mini. The full check runs nightly and by hand (see
# docs/continuous-integration.md).
check-light: lint ci-test build-strict test-core release-smoke

# The same checks on the shared CI Mac, or on whichever of the two is quieter; TARGET picks
# another target. See docs/continuous-integration.md.
TARGET ?= check

check-remote:
	python3 Scripts/remote.py check $(TARGET)

check-anywhere:
	python3 Scripts/remote.py anywhere $(TARGET)

# The pre-push check sized to the change (Scripts/check-affected.py): documents and scripts get
# lint and ci-test, other code its own tests too, and the solver's core the full check-anywhere.
check-affected:
	python3 Scripts/check-affected.py

release-check:
	python3 Scripts/release.py check

release:
	python3 Scripts/release.py prepare
