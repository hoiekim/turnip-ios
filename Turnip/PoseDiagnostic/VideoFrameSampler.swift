import AVFoundation
import CoreVideo

struct SampledFrame {
    let frameIndex: Int
    let timestamp: TimeInterval
    let pixelBuffer: CVPixelBuffer
}

/// Decodes video frames at native fps via AVAssetReader (not AVAssetImageGenerator, which
/// reseeks per-frame and is both slower and less frame-accurate during fast motion), keeping
/// every 3rd frame per docs/DESIGN.md's pipeline step 2.
final class VideoFrameSampler {
    private let sampleStride = 3

    func sampleFrames(from url: URL, handler: (SampledFrame) async throws -> Void) async throws {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw PoseDiagnosticError.videoLoadFailed(underlying: nil)
        }

        let reader = try AVAssetReader(asset: asset)
        let outputSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        let trackOutput = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        trackOutput.alwaysCopiesSampleData = false

        guard reader.canAdd(trackOutput) else {
            throw PoseDiagnosticError.videoLoadFailed(underlying: nil)
        }
        reader.add(trackOutput)

        guard reader.startReading() else {
            throw PoseDiagnosticError.videoLoadFailed(underlying: reader.error)
        }

        var frameIndex = 0
        while let sampleBuffer = trackOutput.copyNextSampleBuffer() {
            defer { frameIndex += 1 }
            guard frameIndex % sampleStride == 0 else { continue }
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { continue }
            let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
            try await handler(SampledFrame(frameIndex: frameIndex, timestamp: timestamp, pixelBuffer: pixelBuffer))
        }

        if reader.status == .failed {
            throw PoseDiagnosticError.videoLoadFailed(underlying: reader.error)
        }
    }
}
