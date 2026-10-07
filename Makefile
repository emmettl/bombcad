.PHONY: build app run test lint format icons ci-test check release-check release

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
