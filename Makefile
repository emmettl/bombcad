.PHONY: build app run test release-smoke lint format icons ifc-converter ci-test check release-check release

CONFIGURATION ?= release

build:
	swift build

icons:
	swift Scripts/make-icon.swift

app:
	bash Scripts/build-app.sh "$(CONFIGURATION)"

run: app
	open dist/BombCAD.app

ifc-converter:
	python3 Scripts/prepare-ifc-converter.py

test: ifc-converter
	swift test

# The solvers built as a release is, run for a few seconds each: solid and shell elements, bars
# that slip and base connections. `swift test` builds for debugging, and the optimiser has
# miscompiled code that ran correctly there.
release-smoke:
	swift build -c release --product blastbench
	.build/release/blastbench shear --layers 12
	.build/release/blastbench shear --layers 12 --bond pullout
	.build/release/blastbench slab --shells 1
	.build/release/blastbench anchorage --standoff 25 --bases clamped,dowelled,soil,footing --time 0.05
	.build/release/blastbench anchorage --shells --standoff 25 --bases clamped,soil --time 0.05

lint:
	swift format lint --strict --recursive Package.swift Sources Tests Scripts

format:
	swift format format --in-place --recursive Package.swift Sources Tests Scripts

ci-test:
	python3 Scripts/test-release.py
	python3 Scripts/test-nightly.py

check: lint test ci-test build

release-check:
	python3 Scripts/release.py check

release:
	python3 Scripts/release.py prepare
