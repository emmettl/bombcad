import Foundation
import Testing
import simd

@testable import BlastModel

/// Envelope buildings whose glazing breaks in the air (`EnvelopeVenting`).
@Suite("Envelope venting", .serialized)
struct EnvelopeVentingTests {
    @Test("The fine grid's pane lookup is led by a header of 32 bytes, four entries, as the kernels read it")
    func paneLookupLayout() {
        // `PaneLookup` in Refine.metal is 32 bytes, and the kernels read its (cell, pane) entries
        // from the byte after it; at 48 bytes in Swift the last two pane cells were never found.
        #expect(MemoryLayout<PaneLookup>.size == 32)
        #expect(MemoryLayout<PaneLookup>.stride == 4 * MemoryLayout<SIMD2<UInt32>>.stride)
    }
}
