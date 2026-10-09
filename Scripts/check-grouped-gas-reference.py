#!/usr/bin/env python3
"""Verify bounded gas references in a temporary CPU-only package, without app imports."""
from pathlib import Path
import argparse
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
SOURCES = [
    "ConservedGroupedGasGeometry",
    "ConservedGasReconstruction",
    "FiniteVolumePressureFit", "ExperimentalVolumePressureFitStudy",
    "BoxSurfacePressureReference", "ExperimentalInitialWallTraceStudy",
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
    "ConservedMovingGasTests",
    "ConservedGasReconstructionTests",
    "WallStencilSensitivityTests",
    "FiniteVolumePressureFitTests",
    "WallTraceDecompositionTests",
    "InitialWallTraceTests",
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
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--release', action='store_true', help='Use optimized CPU reference tests')
    args = parser.parse_args()
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
        command = ["swift", "test", "--package-path", str(package)]
        if args.release:
            command += ["-c", "release"]
        subprocess.run(command, check=True)


if __name__ == "__main__":
    main()
