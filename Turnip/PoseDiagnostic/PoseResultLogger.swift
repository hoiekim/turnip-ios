import os

enum PoseResultLogger {
    private static let logger = Logger(subsystem: "com.hoiekim.turnip", category: "PoseDiagnostic")

    static func log(_ result: PoseFrameResult) {
        logger.info(
            "frame \(result.frameIndex) t=\(String(format: "%.2f", result.timestamp))s avgConfidence=\(String(format: "%.2f", result.averageConfidence)) usableKeypoints=\(result.usableKeypointCount)/17"
        )
    }
}
