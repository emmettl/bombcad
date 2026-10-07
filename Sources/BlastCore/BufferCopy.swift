import Metal

extension MTLBuffer {
    /// Copies `array` into the start of the buffer.
    ///
    /// Never inlined, so that `withUnsafeBytes`, which rethrows, stays out of the solvers' throwing
    /// initialisers: inlined there, Swift 6.4's optimiser (-O) let it hand back a corrupt error from
    /// a closure that cannot throw, and the release build crashed building a structure.
    @inline(never)
    func copy<Element>(_ array: [Element]) {
        array.withUnsafeBytes { bytes in
            if let base = bytes.baseAddress, !bytes.isEmpty {
                contents().copyMemory(from: base, byteCount: bytes.count)
            }
        }
    }
}
