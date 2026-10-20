#if canImport(Glibc)
    // Linux's C library declares `stdout` a plain mutable global, which strict concurrency refuses
    // to read; Apple's does not.
    @preconcurrency import Glibc
#elseif canImport(Darwin)
    import Darwin
#endif

/// The headless studies' standard output.
package enum StudyOutput {
    /// A line at a time, so that a long study's lines show as they are printed, into a file too.
    package static func lineBuffered() {
        setvbuf(stdout, nil, _IOLBF, 0)
    }
}
