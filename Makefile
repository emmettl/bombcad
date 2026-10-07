.PHONY: build app run test roomcad-test roomcad-app roomcad-icon lint format icons ci-test check release-check release

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

roomcad-test:
	swift test --package-path RoomCAD

roomcad-app:
	bash RoomCAD/Scripts/build-app.sh "$(CONFIGURATION)"

roomcad-icon:
	swift RoomCAD/Scripts/make-icon.swift

lint:
	swift format lint --strict --recursive Package.swift Sources Tests Scripts RoomCAD/Package.swift RoomCAD/Sources RoomCAD/Tests RoomCAD/Scripts

format:
	swift format format --in-place --recursive Package.swift Sources Tests Scripts RoomCAD/Package.swift RoomCAD/Sources RoomCAD/Tests RoomCAD/Scripts

ci-test:
	python3 Scripts/test-release.py

check: lint test roomcad-test ci-test build

release-check:
	python3 Scripts/release.py check

release:
	python3 Scripts/release.py prepare
