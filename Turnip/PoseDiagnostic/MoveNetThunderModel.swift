import CoreImage
import CoreVideo
import Foundation
import TensorFlowLite

/// Wraps a TensorFlowLiteSwift Interpreter for MoveNet Thunder (singlepose, int8).
/// See Turnip/Models/README.md for how to obtain the bundled model file.
///
/// An `actor` rather than a class for two reasons: TFLite's `Interpreter` is not thread-safe, so
/// inference calls must be serialized, and actors run on the cooperative pool — never the main
/// thread — so `runInference` (CIContext resize, BGRA→RGB repack, `invoke()`, dequantize) is
/// structurally kept off the UI thread. Being an actor also makes the model `Sendable`, so it can
/// be captured by the `@Sendable` frame handler in `VideoFrameSampler.sampleFrames`.
actor MoveNetThunderModel {
    private let interpreter: Interpreter
    private let inputWidth: Int
    private let inputHeight: Int
    private let ciContext = CIContext()

    init() throws {
        guard let modelPath = Bundle.main.path(forResource: "movenet_thunder_int8", ofType: "tflite") else {
            throw PoseDiagnosticError.modelNotFound
        }

        do {
            interpreter = try Interpreter(modelPath: modelPath)
            try interpreter.allocateTensors()
        } catch {
            throw PoseDiagnosticError.inferenceFailed("Failed to load MoveNet Thunder model: \(error.localizedDescription)")
        }

        // Read the input shape at runtime rather than hardcoding 256x256, so a future
        // model swap (e.g. escalating to BlazePose per the design doc) doesn't silently
        // feed the wrong tensor size.
        let inputShape = try interpreter.input(at: 0).shape.dimensions
        guard inputShape.count == 4 else {
            throw PoseDiagnosticError.inferenceFailed("Unexpected model input shape: \(inputShape)")
        }
        inputHeight = inputShape[1]
        inputWidth = inputShape[2]
    }

    func runInference(on pixelBuffer: CVPixelBuffer) throws -> [PoseKeypoint] {
        let inputData = try resizedRGBData(from: pixelBuffer)
        try interpreter.copy(inputData, toInputAt: 0)
        try interpreter.invoke()
        let outputTensor = try interpreter.output(at: 0)
        let values = Self.dequantize(outputTensor)
        return try PoseKeypoint.parse(from: values)
    }

    /// Resizes the source frame to the model's input size and packs it as interleaved RGB uint8,
    /// matching MoveNet Thunder's expected [1, height, width, 3] input tensor.
    private func resizedRGBData(from pixelBuffer: CVPixelBuffer) throws -> Data {
        let sourceImage = CIImage(cvPixelBuffer: pixelBuffer)
        let scaleX = CGFloat(inputWidth) / sourceImage.extent.width
        let scaleY = CGFloat(inputHeight) / sourceImage.extent.height
        let scaledImage = sourceImage.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))

        var resizedBuffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, inputWidth, inputHeight, kCVPixelFormatType_32BGRA,
            attributes as CFDictionary, &resizedBuffer
        )
        guard status == kCVReturnSuccess, let outputBuffer = resizedBuffer else {
            throw PoseDiagnosticError.inferenceFailed("Failed to allocate resize buffer")
        }

        ciContext.render(scaledImage, to: outputBuffer)

        CVPixelBufferLockBaseAddress(outputBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(outputBuffer, .readOnly) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(outputBuffer) else {
            throw PoseDiagnosticError.inferenceFailed("Failed to access resized pixel buffer")
        }

        let bytesPerRow = CVPixelBufferGetBytesPerRow(outputBuffer)
        let bgra = baseAddress.assumingMemoryBound(to: UInt8.self)

        var rgb = [UInt8](repeating: 0, count: inputWidth * inputHeight * 3)
        for row in 0..<inputHeight {
            let rowStart = row * bytesPerRow
            for col in 0..<inputWidth {
                let pixelOffset = rowStart + col * 4
                let outIndex = (row * inputWidth + col) * 3
                rgb[outIndex] = bgra[pixelOffset + 2]     // R
                rgb[outIndex + 1] = bgra[pixelOffset + 1] // G
                rgb[outIndex + 2] = bgra[pixelOffset]     // B
            }
        }

        return Data(rgb)
    }

    /// MoveNet's int8 build emits a quantized uint8 tensor; dequantize using the tensor's own
    /// scale/zero-point rather than assuming float32 output.
    private static func dequantize(_ tensor: Tensor) -> [Float] {
        if tensor.dataType == .uInt8, let quantization = tensor.quantizationParameters {
            return tensor.data.map { (Float($0) - Float(quantization.zeroPoint)) * quantization.scale }
        }

        let floatCount = tensor.data.count / MemoryLayout<Float32>.size
        return tensor.data.withUnsafeBytes { rawBuffer in
            Array(rawBuffer.bindMemory(to: Float32.self).prefix(floatCount))
        }
    }
}
