import AVFoundation
import BlastRender
import CoreVideo
import Foundation
import Metal

extension QuarryRenderer {
    /// Copies the frame into a new pixel buffer for AVFoundation.
    func pixelBuffer(pool: CVPixelBufferPool) -> CVPixelBuffer? {
        var out: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out) == kCVReturnSuccess, let pixel = out else {
            return nil
        }
        CVPixelBufferLockBaseAddress(pixel, [])
        defer { CVPixelBufferUnlockBaseAddress(pixel, []) }
        output.getBytes(
            CVPixelBufferGetBaseAddress(pixel)!, bytesPerRow: CVPixelBufferGetBytesPerRow(pixel),
            from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        return pixel
    }
}

/// Writes the frames to an H.264 movie.
final class ClipWriter {
    let writer: AVAssetWriter
    let input: AVAssetWriterInput
    let adaptor: AVAssetWriterInputPixelBufferAdaptor
    var frame = 0
    let fps: Int32

    init(url: URL, width: Int, height: Int, fps: Int32) throws {
        try? FileManager.default.removeItem(at: url)
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: option(CommandLine.arguments, "--bitrate").flatMap(Int.init)
                        ?? 10_000_000
                ],
            ])
        input.expectsMediaDataInRealTime = false
        adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
            ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        self.fps = fps
    }

    func append(_ renderer: QuarryRenderer) {
        guard let pool = adaptor.pixelBufferPool, let pixel = renderer.pixelBuffer(pool: pool) else { return }
        while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.001) }
        adaptor.append(pixel, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: fps))
        frame += 1
    }

    func finish() {
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
    }
}

func parseVector(_ text: String) -> SIMD3<Float> {
    let v = text.split(separator: ",").compactMap { Float($0) }
    return SIMD3(v[0], v[1], v[2])
}
