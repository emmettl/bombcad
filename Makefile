.PHONY: build app run test release-smoke roomcad-test roomcad-app roomcad-icon roomcad-release-check roomcad-release lint format icons ci-test check release-check release

CONFIGURATION ?= release

build:
	swift build

icons:
	swift Scripts/make-icon.swift

app:
	bash Scripts/build-app.sh "$(CONFIGURATION)"

run: app
	open dist/BombCAD.app

test:
	swift test

# The solvers built as a release is, run for a few seconds each: solid and shell elements, bars
# that slip and base connections. `swift test` builds for debugging, and the optimiser has
# miscompiled code that ran correctly there.
release-smoke:
	swift build -c release --product blastbench
	.build/release/blastbench shear --layers 12
	.build/release/blastbench shear --layers 12 --bond pullout
	.build/release/blastbench slab --shells 1
	.build/release/blastbench anchorage --standoff 25 --bases clamped,dowelled,soil --time 0.05
	.build/release/blastbench anchorage --shells --standoff 25 --bases clamped,soil --time 0.05

roomcad-test:
	swift test --package-path RoomCAD
	python3 RoomCAD/Scripts/test-release.py

roomcad-app:
	bash RoomCAD/Scripts/build-app.sh "$(CONFIGURATION)"

roomcad-icon:
	swift RoomCAD/Scripts/make-icon.swift

roomcad-release-check:
	python3 RoomCAD/Scripts/release.py check

roomcad-release:
	python3 RoomCAD/Scripts/release.py prepare

lint:
	swift format lint --strict --recursive Package.swift Sources Tests Scripts RoomCAD/Package.swift RoomCAD/Sources RoomCAD/Tests RoomCAD/Scripts

format:
	swift format format --in-place --recursive Package.swift Sources Tests Scripts RoomCAD/Package.swift RoomCAD/Sources RoomCAD/Tests RoomCAD/Scripts

ci-test:
	python3 Scripts/test-release.py
	python3 Scripts/test-nightly.py

check: lint test roomcad-test ci-test build

release-check:
	python3 Scripts/release.py check

release:
	python3 Scripts/release.py prepare
