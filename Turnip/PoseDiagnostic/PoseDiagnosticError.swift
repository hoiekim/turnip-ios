import Foundation

enum PoseDiagnosticError: LocalizedError {
    case modelNotFound
    case videoLoadFailed(underlying: Error?)
    case inferenceFailed(String)

    var errorDescription: String? {
        switch self {
        case .modelNotFound:
            return "MoveNet Thunder model not found. See Turnip/Models/README.md for download instructions."
        case .videoLoadFailed(let underlying):
            if let underlying {
                return "Failed to load the selected video: \(underlying.localizedDescription)"
            }
            return "Failed to load the selected video."
        case .inferenceFailed(let message):
            return "Pose inference failed: \(message)"
        }
    }
}
