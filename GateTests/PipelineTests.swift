import XCTest
import AVFoundation
import CoreImage
@testable import Gate

final class PipelineTests: XCTestCase {
    func testGPUCurveDoesNotAddAnotherGamma() throws {
        let processor = try RawProcessor()
        let linear = CIImage(color: try XCTUnwrap(CIColor(red: 0.18, green: 0.18, blue: 0.18, alpha: 1, colorSpace: processor.linearSpace)))
            .cropped(to: CGRect(x: 0, y: 0, width: 2, height: 2))
        let encoded = try processor.encoded(linear, profile: .gateLog)
        var pixel = [Float](repeating: 0, count: 4)
        pixel.withUnsafeMutableBytes {
            processor.context.render(encoded, toBitmap: $0.baseAddress!, rowBytes: 16,
                bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: processor.linearSpace)
        }
        XCTAssertEqual(Double(pixel[0]), GateLog.encode(0.18), accuracy: 0.002)
        XCTAssertEqual(pixel[0], pixel[1], accuracy: 0.002)
    }

    func testFramingKeepsEvenEncoderDimensions() throws {
        let processor = try RawProcessor()
        let image = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 3024, height: 4032))
        var settings = CameraSettings()
        settings.longEdge = 1920
        XCTAssertEqual(processor.frame(image, settings: settings).extent.size, CGSize(width: 1440, height: 1920))
        settings.framing = .widescreen
        XCTAssertEqual(processor.frame(image, settings: settings).extent.size, CGSize(width: 1080, height: 1920))
        settings.framing = .openGate
        settings.longEdge = 4032
        XCTAssertEqual(processor.frame(image, settings: settings).extent.size, CGSize(width: 3024, height: 4032))
    }

    func testHEVCMoviePreservesTimestampGaps() async throws {
        try await verifyMovie(codec: .hevc)
    }

    func testProResMoviePreservesTimestampGapsWhenEncoderAvailable() async throws {
        do { try await verifyMovie(codec: .proRes) }
        catch let error as NSError {
            #if targetEnvironment(simulator)
            if error.domain == AVFoundationErrorDomain && error.code == AVError.encoderNotFound.rawValue {
                throw XCTSkip("ProRes encoding is unavailable in this iOS Simulator. Validate on iPhone.")
            }
            #endif
            throw error
        }
    }

    private func verifyMovie(codec: RecordingCodec) async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let processor = try RawProcessor()
            var settings = CameraSettings()
            settings.codec = codec
            settings.longEdge = 320
            let recorder = try MovieRecorder(settings: settings, folder: folder)
            let gray = CIImage(color: try XCTUnwrap(CIColor(red: 0.18, green: 0.18, blue: 0.18, alpha: 1, colorSpace: processor.linearSpace)))
                .cropped(to: CGRect(x: 0, y: 0, width: 240, height: 320))
            let image = try processor.encoded(gray, profile: .gateLog)
            var accepted = 0
            for time in [100.0, 100.1, 100.5] {
                // Test waits for encoder back pressure rather than dropping its fixture.
                for _ in 0..<100 {
                    if try recorder.append(image, sensorTime: CMTime(seconds: time, preferredTimescale: 600_000), processor: processor) {
                        accepted += 1
                        break
                    }
                    try await Task.sleep(nanoseconds: 10_000_000)
                }
            }
            XCTAssertEqual(accepted, 3, codec.rawValue)
            let url: URL = try await withCheckedThrowingContinuation { continuation in
                recorder.finish { continuation.resume(with: $0) }
            }
            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration)
            XCTAssertEqual(duration.seconds, 0.5 + 1.0 / 30, accuracy: 0.02)
            let tracks = try await asset.loadTracks(withMediaType: .video)
            XCTAssertEqual(tracks.count, 1)
            let size = try await tracks[0].load(.naturalSize)
            XCTAssertEqual(size, CGSize(width: 240, height: 320))
            let sidecar = url.deletingPathExtension().appendingPathExtension("json")
            let metadata = try JSONSerialization.jsonObject(with: Data(contentsOf: sidecar)) as! [String: Any]
            XCTAssertEqual(metadata["frames"] as? Int, 3)
            XCTAssertEqual(metadata["profile"] as? String, "Gate Log")
            XCTAssertEqual(metadata["pixelWidth"] as? Int, 240)
            XCTAssertEqual(metadata["pixelHeight"] as? Int, 320)
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: tracks[0], outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            reader.add(output)
            XCTAssertTrue(reader.startReading())
            var timestamps: [Double] = []
            while let sample = output.copyNextSampleBuffer() {
                timestamps.append(CMSampleBufferGetPresentationTimeStamp(sample).seconds)
                let decoded = try XCTUnwrap(CMSampleBufferGetImageBuffer(sample))
                CVPixelBufferLockBaseAddress(decoded, .readOnly)
                let address = try XCTUnwrap(CVPixelBufferGetBaseAddress(decoded)).assumingMemoryBound(to: UInt8.self)
                let red = Double(address[2]) / 255
                CVPixelBufferUnlockBaseAddress(decoded, .readOnly)
                XCTAssertEqual(red, GateLog.encode(0.18), accuracy: 0.025, "The encoder must preserve the log signal, without a second gamma.")
            }
            XCTAssertEqual(timestamps.count, 3)
            for (actual, expected) in zip(timestamps, [0.0, 0.1, 0.5]) {
                XCTAssertEqual(actual, expected, accuracy: 0.002)
            }
    }

    func testEmptyTakeReportsFailure() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let recorder = try MovieRecorder(settings: CameraSettings(), folder: folder)
        let result: Result<URL, Error> = await withCheckedContinuation { continuation in
            recorder.finish { continuation.resume(returning: $0) }
        }
        if case .success = result { XCTFail("An empty movie must not be reported as saved.") }
    }

    @MainActor
    func testConsecutiveTakesAndBackgroundFinalization() async throws {
        #if targetEnvironment(simulator)
        let controller = CameraController()
        controller.settings.longEdge = 320
        controller.settings.fps = 12
        controller.updateSettings(controller.settings)
        controller.refreshClips()
        let existing = Set(controller.clips.map(\.url))
        controller.start()
        defer {
            controller.suspend()
            for clip in controller.clips where !existing.contains(clip.url) {
                try? FileManager.default.removeItem(at: clip.url)
                try? FileManager.default.removeItem(at: clip.url.deletingPathExtension().appendingPathExtension("json"))
            }
        }
        try await waitUntil { controller.ready && controller.preview != nil }
        controller.refreshClips()
        let before = controller.clips.count
        controller.toggleRecording()
        try await waitUntil { controller.recording && controller.elapsed > 0.3 }
        controller.toggleRecording()
        try await waitUntil { !controller.recording && !controller.finalizing && controller.clips.count == before + 1 }
        XCTAssertNil(controller.errorMessage)
        controller.toggleRecording()
        try await waitUntil { controller.recording && controller.elapsed > 0.3 }
        controller.suspend()
        try await waitUntil { !controller.ready && !controller.recording && !controller.finalizing && controller.clips.count == before + 2 }
        XCTAssertNil(controller.errorMessage)
        let newest = try XCTUnwrap(controller.clips.first)
        let metadata = try JSONSerialization.jsonObject(with: Data(contentsOf: newest.url.deletingPathExtension().appendingPathExtension("json"))) as! [String: Any]
        XCTAssertEqual(metadata["input"] as? String, "Synthetic simulator frames")
        #else
        throw XCTSkip("This lifecycle fixture uses simulator frames; hardware tests are manual.")
        #endif
    }

    @MainActor
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<250 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Camera lifecycle did not reach the expected state within five seconds.")
        throw CameraFailure.message("Test timed out.")
    }
}
