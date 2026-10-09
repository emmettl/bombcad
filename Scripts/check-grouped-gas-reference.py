#!/usr/bin/env python3
"""Verify bounded gas references in a temporary CPU-only package, without app imports."""
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
SOURCES = [
    "ExperimentalMovingLoadStudy",
    "MovingWallPressureQuadrature", "ExperimentalMovingPressureStudy",
    "LimitedMovingGroupScatter",
    "AdvectedQuadraticGas", "ExperimentalMovingEntropyStudy",
    "ExperimentalMovingTrajectoryStudy",
    "MovingConnectedGasGroups", "ExperimentalMovingGroupsStudy",
    "TranslatingBoxSpaceTimeGeometry", "ExperimentalTranslatingBoxGeometryStudy",
    "MovingShockReflection", "ExperimentalMovingReflectionStudy", "NormalShockReflection", "ExperimentalWallReflectionStudy", "RigidBoxBody", "FractionalBoxGeometry", "FractionalGasTransport", "FractionalEulerFlux",
    "IdealGasWallRiemann", "ConnectedGasGroups", "ExperimentalConnectedGasStudy",
    "ExperimentalConnectedLoadStudy", "LimitedGroupedGasFlux", "LimitedTubeFlux",
    "ExperimentalPistonWaveStudy", "PlanarPistonWave", "PrescribedPistonTube",
]
TESTS = [
    "MovingLoadStudyTests",
    "SampledMovingGasFluxTests",
    "MovingPressureQuadratureTests",
    "MovingTimeIntegrationTests",
    "LimitedMovingReconstructionTests",
    "MovingEntropyTests",
    "MovingTrajectoryTests",
    "MovingConnectedGasGroupsTests",
    "TranslatingBoxSpaceTimeTests",
    "MovingShockReflectionTests", "NormalShockReflectionTests", "SurfaceWallLoadTests", "LimitedGroupedGasFluxTests", "FractionalEulerFluxTests", "FractionalEulerWallTests",
    "IdealGasWallRiemannTests", "GasQuadratureTests", "ConnectedLoadStudyTests", "LimitedTubeFluxTests",
]


def main():
    with tempfile.TemporaryDirectory(prefix="bombcad-gas-reference-") as directory:
        package = Path(directory)
        for folder in ["Sources/BlastCore", "Tests/BlastCoreTests"]:
            (package / folder).mkdir(parents=True)
        (package / "Package.swift").write_text('''// swift-tools-version: 6.4
import PackageDescription
let package = Package(name: "GroupedReference", platforms: [.macOS(.v15)], targets: [
    .target(name: "BlastCore"),
    .testTarget(name: "BlastCoreTests", dependencies: ["BlastCore"])
])
''')
        for names, folder in [(SOURCES, "Sources/BlastCore"), (TESTS, "Tests/BlastCoreTests")]:
            for name in names:
                shutil.copyfile(ROOT / folder / f"{name}.swift", package / folder / f"{name}.swift")
        subprocess.run(["swift", "test", "--package-path", str(package)], check=True)


if __name__ == "__main__":
    main()
