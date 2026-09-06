import AVFoundation
import Foundation
import SwiftUI

@MainActor
final class PoseDiagnosticViewModel: ObservableObject {
    @Published private(set) var results: [PoseFrameResult] = []
    @Published private(set) var isRunning = false
    @Published var errorMessage: String?

    private let sampler = VideoFrameSampler()

    /// Runs MoveNet Thunder over `asset`, the video Home resolved from the tapped tile (see
    /// `SelectedVideo`).
    func runDiagnostic(on asset: AVURLAsset) {
        guard !isRunning else { return }
        results = []
        errorMessage = nil
        isRunning = true

        Task {
            defer { isRunning = false }
            do {
                let model = try await MoveNetThunderModel.load()
                try await sampler.sampleFrames(from: asset) { frame in
                    let keypoints = try await model.runInference(on: frame.pixelBuffer)
                    let result = PoseFrameResult(frameIndex: frame.frameIndex, timestamp: frame.timestamp, keypoints: keypoints)
                    PoseResultLogger.log(result)
                    await MainActor.run {
                        self.results.append(result)
                    }
                }
            } catch let error as PoseDiagnosticError {
                errorMessage = error.errorDescription
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
