import BlastModel
import Foundation
import Metal
import RadialBlast
import simd

// The air solver's view of the air: the visualisation texture and the field read back for display.
extension BlastSolver {
    /// The visualisation field every `stride`-th cell along each axis (`viewFieldSize`), each texel
    /// its block's extremes, as `rgba16Float` texels, eight bytes each, x fastest: for a view of
    /// the run drawn elsewhere. Cut out at the end of the batch that ended now if `frameRequest`
    /// or `viewFieldCapture` asked for it, so the GPU need not be waited for again; otherwise
    /// worked out now, blocking until done. Call it only while no batch is in flight.
    public func viewField(stride: Int) throws -> Data {
        precondition(!batchInFlight, "Cannot read the view field while a batch is in flight")
        precondition(stride >= 1)
        if let field = frameExtractor?.viewField(stride: stride, grid: grid, time: time, steps: stepCount) {
            return field
        }
        if frameExtractor == nil { frameExtractor = try FrameExtractor(library: library) }
        guard let frameExtractor, let commandBuffer = commandQueue.makeCommandBuffer(),
            let encoder = commandBuffer.makeComputeCommandEncoder()
        else { throw BlastError.allocationFailed("view field") }
        encodeVisualization(encoder)
        frameExtractor.encodeViewField(
            encoder, stride: stride, grid: grid, field: visualizationTexture, control: controlBuffer,
            write: .always)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        guard let field = frameExtractor.viewFieldData(viewFieldSize(stride: stride)) else {
            throw BlastError.allocationFailed("view field")
        }
        return field
    }

    /// The view field's texels along each axis at `stride`, rounded up.
    public func viewFieldSize(stride: Int) -> SIMD3<Int> {
        FrameExtractor.viewFieldSize(grid, stride: stride)
    }

    /// Rebuilds `visualizationTexture` from the current state, blocking until done.
    public func refreshVisualization() {
        precondition(!batchInFlight, "Cannot refresh while a batch is in flight")
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
            let encoder = commandBuffer.makeComputeCommandEncoder()
        else { return }
        encodeVisualization(encoder)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
    }

    func encodeVisualization(_ encoder: MTLComputeCommandEncoder) {
        var uniforms = makeUniforms()
        encoder.setComputePipelineState(visualizationPipeline)
        encoder.setBuffer(stateBuffers[current], offset: 0, index: 0)
        encoder.setBuffer(maskBuffer, offset: 0, index: 1)
        encoder.setBuffer(peakBuffer, offset: 0, index: 2)
        encoder.setBuffer(impulseBuffer, offset: 0, index: 3)
        encoder.setBytes(&uniforms, length: MemoryLayout<SolverUniforms>.stride, index: 4)
        encoder.setTexture(visualizationTexture, index: 0)
        dispatchGrid(encoder, pipeline: visualizationPipeline)
    }
}
