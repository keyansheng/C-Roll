import AVFoundation
import CoreImage

/// Accessed only on CameraController's serial processing queue.
final class MovieRecorder {
    let url: URL
    private let settings: CameraSettings
    private let inputLabel: String
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var timeline = CaptureTimeline()
    private(set) var frameCount = 0

    init(settings: CameraSettings, folder: URL, inputLabel: String = "Bayer RAW") throws {
        self.settings = settings
        self.inputLabel = inputLabel
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = "GATE_" + Date().formatted(.dateTime.year().month().day().hour().minute().second()).replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        url = folder.appendingPathComponent(name + "_" + UUID().uuidString.prefix(6) + ".mov")
    }

    private func prepare(size: CGSize) throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        var output: [String: Any] = [AVVideoCodecKey: settings.codec.avCodec,
                                  AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height)]
        if settings.codec == .hevc {
            output[AVVideoCompressionPropertiesKey] = [AVVideoAverageBitRateKey: settings.bitrateMbps * 1_000_000,
                                                      AVVideoExpectedSourceFrameRateKey: settings.fps,
                                                      AVVideoMaxKeyFrameIntervalKey: settings.fps * 2,
                                                      AVVideoAllowFrameReorderingKey: false]
        }
        if settings.profile == .rec709 {
            output[AVVideoColorPropertiesKey] = [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                                                 AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                                                 AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2]
        }
        guard writer.canApply(outputSettings: output, forMediaType: .video) else {
            throw CameraFailure.message("This device cannot encode \(settings.codec.rawValue) at the selected size.")
        }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: output)
        input.expectsMediaDataInRealTime = true
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height),
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ])
        guard writer.canAdd(input) else { throw CameraFailure.message("The movie encoder could not be added.") }
        writer.add(input)
        let description = AVMutableMetadataItem()
        description.identifier = .commonIdentifierDescription
        description.value = "Gate input: \(inputLabel); \(settings.profile.rawValue); silent; target \(settings.fps)fps. Gate Log = log2(1+15x)/4 in Rec.709 primaries." as NSString
        writer.metadata = [description]
        guard writer.startWriting() else { throw writer.error ?? CameraFailure.message("Recording could not start.") }
        writer.startSession(atSourceTime: .zero)
        self.writer = writer; self.input = input; self.adaptor = adaptor
    }

    /// False means back pressure or an out-of-order frame, never an unbounded queue.
    func append(_ image: CIImage, sensorTime: CMTime, processor: RawProcessor) throws -> Bool {
        if writer == nil { try prepare(size: image.extent.size) }
        guard let writer, let input, let adaptor else { return false }
        guard writer.status == .writing else { throw writer.error ?? CameraFailure.message("The encoder stopped.") }
        guard input.isReadyForMoreMediaData else { return false }
        var candidate = timeline
        guard let seconds = candidate.accept(sensorTime.seconds) else { return false }
        guard let pool = adaptor.pixelBufferPool else { throw CameraFailure.message("The encoder buffer pool is unavailable.") }
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool,
            [kCVPixelBufferPoolAllocationThresholdKey: 4] as CFDictionary, &buffer)
        if status == kCVReturnWouldExceedAllocationThreshold { return false }
        guard status == kCVReturnSuccess, let buffer else { throw CameraFailure.message("The movie buffer could not be allocated (\(status)).") }
        processor.context.render(image, to: buffer, bounds: image.extent, colorSpace: processor.linearSpace)
        guard adaptor.append(buffer, withPresentationTime: CMTime(seconds: seconds, preferredTimescale: 600_000)) else {
            throw writer.error ?? CameraFailure.message("A movie frame could not be written.")
        }
        timeline = candidate
        frameCount += 1
        return true
    }

    func finish(diagnostics: [String: Any] = [:], completion: @escaping (Result<URL, Error>) -> Void) {
        guard let writer, frameCount > 0 else {
            writer?.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            completion(.failure(CameraFailure.message("No frames were recorded. Try a lower resolution or frame rate.")))
            return
        }
        guard writer.status == .writing else {
            let error = writer.error ?? CameraFailure.message("The movie encoder failed.")
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            completion(.failure(error)); return
        }
        let duration = (timeline.last! - timeline.origin!) + 1 / Double(settings.fps)
        writer.endSession(atSourceTime: CMTime(seconds: duration, preferredTimescale: 600_000))
        input?.markAsFinished()
        writer.finishWriting {
            if writer.status == .completed {
                let sidecar: [String: Any] = ["profile": self.settings.profile.rawValue,
                    "curve": self.settings.profile == .gateLog ? "log2(1 + 15 * max(0, linear)) / 4" : "Rec.709 OETF",
                    "primaries": "Rec.709", "targetFPS": self.settings.fps,
                    "frames": self.frameCount, "duration": duration,
                    "averageFPS": Double(self.frameCount) / duration, "audio": false,
                    "input": self.inputLabel, "encoderInputBitDepth": 8,
                    "pixelWidth": Int(self.input?.outputSettings?[AVVideoWidthKey] as? Int ?? 0),
                    "pixelHeight": Int(self.input?.outputSettings?[AVVideoHeightKey] as? Int ?? 0),
                    "performance": diagnostics]
                if let data = try? JSONSerialization.data(withJSONObject: sidecar, options: [.prettyPrinted, .sortedKeys]) {
                    try? data.write(to: self.url.deletingPathExtension().appendingPathExtension("json"), options: .atomic)
                }
                completion(.success(self.url))
            } else {
                try? FileManager.default.removeItem(at: self.url)
                completion(.failure(writer.error ?? CameraFailure.message("Finalizing the movie failed.")))
            }
        }
    }
}
