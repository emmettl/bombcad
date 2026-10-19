import Foundation
import Testing

/// Whether the long studies run in full: with `BOMBCAD_FULL_STUDIES=1` in the environment, as the
/// nightly full check (.github/workflows/nightly.yml) and `make release` (Scripts/release.py) set
/// it. Without it, as in the pre-push checks (`make check-affected`, `make check`), a test that
/// carries `.fullStudy` is skipped, and its suite keeps a check-time version of it that goes down
/// the same code to the same kind of answer, on a smaller problem. Each gated test says what its
/// check-time version is (docs/continuous-integration.md, "Full studies").
///
/// The same in BlastCoreTests (Tests/BlastCoreTests/FullStudies.swift).
enum FullStudies {
    static let enabled = ProcessInfo.processInfo.environment["BOMBCAD_FULL_STUDIES"] == "1"
}

extension Trait where Self == ConditionTrait {
    /// Runs the test only with `BOMBCAD_FULL_STUDIES=1` (nightly and before releases).
    static var fullStudy: Self {
        .enabled(
            if: FullStudies.enabled,
            "A full study: runs with BOMBCAD_FULL_STUDIES=1, nightly and in make release")
    }
}
