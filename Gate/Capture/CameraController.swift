import AVFoundation
import Combine
import UIKit

final class RawCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate {
    let processed: (AVCapturePhoto?, Error?) -> Void
    let finished: (Error?) -> Void
    init(processed: @escaping (AVCapturePhoto?, Error?) -> Void, finished: @escaping (Error?) -> Void) {
        self.processed = processed; self.finished = finished
    }
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        processed(photo, error)
    }
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        finished(error)
    }
}

// UI-facing properties are accessed on main; engine state is confined to captureQueue,
// and image/encoder work to processingQueue. Cross-queue work uses value snapshots.
final class CameraController: NSObject, ObservableObject, @unchecked Sendable {
    @Published var settings = CameraSettings()
    @Published private(set) var preview: CGImage?
    @Published private(set) var ready = false
    @Published private(set) var recording = false
    @Published private(set) var finalizing = false
    @Published private(set) var preparingTake = false
    @Published private(set) var systemPreviewAvailable = false
    @Published private(set) var measuredFPS = 0.0
    @Published private(set) var skipped = 0
    @Published private(set) var elapsed = 0.0
    @Published private(set) var status = "INITIALIZING"
    @Published private(set) var demo = false
    @Published private(set) var clips: [Clip] = []
    @Published private(set) var isoRange: ClosedRange<Float> = 25...3200
    @Published private(set) var actualISO: Float = 100
    @Published private(set) var actualShutter = 60.0
    @Published var errorMessage: String?

    // The UI only hosts and sizes this layer. Capture connections belong to captureQueue.
    let systemPreviewLayer = AVCaptureVideoPreviewLayer()
    var usesSystemPreview: Bool {
        systemPreviewAvailable && MonitorRouting.usesSystemPreview(recording: recording, finalizing: finalizing, simulation: demo)
    }

    private let session = AVCaptureSession()
    private let output = AVCapturePhotoOutput()
    private let captureQueue = DispatchQueue(label: "gate.capture", qos: .userInitiated)
    private let processingQueue = DispatchQueue(label: "gate.processing", qos: .userInitiated)
    private var processor: RawProcessor?
    private var device: AVCaptureDevice?
    private var rawFormat: OSType?
    private var timer: DispatchSourceTimer?
    private var configuration = CameraSettings()
    // Restore the buffer bound used by the hardware-tested 0.1.0 capture path.
    private static let maxInFlightFrames = 2
    private var budget = CaptureBudget(limit: CameraController.maxInFlightFrames)
    private struct Request {
        let delegate: RawCaptureDelegate
        let requestedAt: Double
        var processingDone = false
        var processingStarted = false
        var captureDone = false
    }
    private var requests: [Int64: Request] = [:]
    private var recorder: MovieRecorder?
    private var isRecording = false
    private var isStopping = false
    private var pendingTakeStart = false
    private var pendingStartID = UUID()
    private var previewConnection: AVCaptureConnection?
    private var allowSystemPreview = true
    private var needsSessionReset = false
    private var configured = false
    private var active = false
    private var isDemo = false
    private var demoID: Int64 = -1
    private var dropped = 0
    private var rateCount = 0
    private var rateStart = ProcessInfo.processInfo.systemUptime
    private var recordStart = 0.0
    private var stopID = UUID()
    private var lastFrame = ProcessInfo.processInfo.systemUptime
    private var lastClockPublish = 0.0
    private var performance = CapturePerformance()
    private var observers: [NSObjectProtocol] = []

    static var clipsFolder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Clips", isDirectory: true)
    }

    override init() {
        super.init()
        observers.append(NotificationCenter.default.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: nil) { [weak self] _ in
            self?.captureQueue.async { self?.interrupted("Camera interrupted. Recording has stopped.") }
        })
        observers.append(NotificationCenter.default.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil) { [weak self] note in
            let error = (note.userInfo?[AVCaptureSessionErrorKey] as? Error) ?? CameraFailure.message("Camera session failed.")
            self?.captureQueue.async { self?.reportCaptureFailure(error, stage: "Camera session") }
        })
        observers.append(NotificationCenter.default.addObserver(forName: AVCaptureSession.interruptionEndedNotification, object: session, queue: nil) { [weak self] _ in
            self?.captureQueue.async {
                guard let self, self.active else { return }
                if !self.session.isRunning { self.session.startRunning() }
                self.publish { $0.ready = self.rawFormat != nil; $0.status = "BAYER RAW" }
                self.startTimer()
            }
        })
    }

    deinit {
        timer?.cancel()
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    private func publish(_ update: @escaping (CameraController) -> Void) {
        DispatchQueue.main.async { [weak self] in if let self { update(self) } }
    }

    func start() {
        refreshClips()
        #if targetEnvironment(simulator)
        captureQueue.async { self.activateDemo() }
        #else
        Task {
            let allowed: Bool
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized: allowed = true
            case .notDetermined: allowed = await AVCaptureDevice.requestAccess(for: .video)
            default: allowed = false
            }
            if allowed {
                captureQueue.async { self.activateCamera() }
            } else {
                publish { $0.status = "CAMERA ACCESS NEEDED"; $0.errorMessage = "Allow camera access in Settings to capture RAW video." }
            }
        }
        #endif
    }

    private func activateCamera(retryDeadline: Double? = nil) {
        guard !active else { return }
        // A Retry must not reuse a failed graph or tear down retained RAW photos.
        if isStopping || !budget.active.isEmpty {
            let deadline = retryDeadline ?? ProcessInfo.processInfo.systemUptime + 6
            if ProcessInfo.processInfo.systemUptime < deadline {
                captureQueue.asyncAfter(deadline: .now() + 0.1) { self.activateCamera(retryDeadline: deadline) }
            } else {
                publish { $0.errorMessage = "Camera restart is waiting for unfinished RAW captures. Close and reopen Gate." }
            }
            return
        }
        do {
            if needsSessionReset {
                if session.isRunning { session.stopRunning() }
                session.beginConfiguration()
                if let connection = previewConnection { session.removeConnection(connection) }
                systemPreviewLayer.session = nil
                previewConnection = nil
                session.outputs.forEach { session.removeOutput($0) }
                session.inputs.forEach { session.removeInput($0) }
                session.commitConfiguration()
                rawFormat = nil
                configured = false
                needsSessionReset = false
                publish { $0.systemPreviewAvailable = false }
            }
            if !configured {
                processor = try RawProcessor()
                try configureSession()
                configured = true
            }
            active = true
            session.startRunning()
            guard let format = output.availableRawPhotoPixelFormatTypes.first(where: AVCapturePhotoOutput.isBayerRAWPixelFormat) else {
                throw CameraFailure.message("Bayer RAW is unavailable on this camera configuration. No processed-video fallback is used.")
            }
            rawFormat = format
            output.setPreparedPhotoSettingsArray([photoSettings(format: format)], completionHandler: nil)
            try applyDeviceSettings()
            publish { $0.ready = true; $0.status = "BAYER RAW" }
            startTimer()
        } catch {
            active = false
            if session.isRunning { session.stopRunning() }
            let detail = CaptureErrorReport.describe(error, stage: "Camera setup")
            publish { $0.ready = false; $0.status = "CAMERA UNAVAILABLE"; $0.errorMessage = detail }
        }
    }

    private func configureSession() throws {
        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            throw CameraFailure.message("A rear wide camera is required.")
        }
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .photo
        let input = try AVCaptureDeviceInput(device: camera)
        guard session.canAddInput(input), session.canAddOutput(output) else {
            throw CameraFailure.message("The RAW capture session could not be configured.")
        }
        session.addInput(input)
        session.addOutput(output)
        device = camera
        try camera.lockForConfiguration()
        camera.videoZoomFactor = 1 // Bayer RAW requires physical camera at 1x.
        camera.unlockForConfiguration()
        output.maxPhotoQualityPrioritization = .speed
        if output.isAppleProRAWEnabled { output.isAppleProRAWEnabled = false }
        output.isLivePhotoCaptureEnabled = false
        if output.isZeroShutterLagSupported { output.isZeroShutterLagEnabled = false }
        if output.isResponsiveCaptureSupported { output.isResponsiveCaptureEnabled = true }
        if output.isFastCapturePrioritizationSupported { output.isFastCapturePrioritizationEnabled = true }
        if let dimensions = camera.activeFormat.supportedMaxPhotoDimensions.min(by: {
            Int64($0.width) * Int64($0.height) < Int64($1.width) * Int64($1.height)
        }) { output.maxPhotoDimensions = dimensions }
        publish { $0.isoRange = camera.activeFormat.minISO...camera.activeFormat.maxISO }
    }

    private func photoSettings(format: OSType) -> AVCapturePhotoSettings {
        let settings = AVCapturePhotoSettings(rawPixelFormatType: format)
        settings.photoQualityPrioritization = .speed
        settings.flashMode = .off
        settings.maxPhotoDimensions = output.maxPhotoDimensions
        settings.isShutterSoundSuppressionEnabled = output.isShutterSoundSuppressionSupported
        return settings
    }

    private func activateDemo() {
        guard !active else { return }
        do {
            if processor == nil { processor = try RawProcessor() }
            configured = true; active = true; isDemo = true
            publish { $0.demo = true; $0.ready = true; $0.status = "SIMULATOR · SYNTHETIC" }
            startTimer()
        } catch { publish { $0.errorMessage = error.localizedDescription } }
    }

    func suspend() {
        captureQueue.async {
            self.pendingTakeStart = false
            self.active = false
            self.timer?.cancel(); self.timer = nil
            if self.isRecording { self.stopRecording() }
            if self.session.isRunning { self.session.stopRunning() }
            self.publish { $0.ready = false; $0.preparingTake = false; $0.status = "PAUSED" }
        }
    }

    func updateSettings(_ settings: CameraSettings) {
        captureQueue.async {
            var next = settings
            if self.isRecording || self.isStopping {
                next.fps = self.configuration.fps
                next.codec = self.configuration.codec
                next.profile = self.configuration.profile
                next.framing = self.configuration.framing
                next.longEdge = self.configuration.longEdge
                next.bitrateMbps = self.configuration.bitrateMbps
                next.focus = self.configuration.focus
                next.autoFocus = self.configuration.autoFocus
            }
            let previous = self.configuration
            self.configuration = next
            let hardwareChanged = previous.autoExposure != next.autoExposure || previous.iso != next.iso ||
                previous.shutterDenominator != next.shutterDenominator || previous.ev != next.ev ||
                previous.whiteBalance != next.whiteBalance || previous.autoFocus != next.autoFocus ||
                previous.focus != next.focus || previous.fps != next.fps
            do { if hardwareChanged { try self.applyDeviceSettings() } }
            catch { self.publish { $0.errorMessage = error.localizedDescription } }
        }
    }

    private func applyDeviceSettings() throws {
        guard let device else { return }
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        // Leave photo-session sensor cadence under AVFoundation control. Forcing
        // video frame durations here is not a guarantee of RAW delivery cadence.
        if configuration.autoExposure {
            if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
            device.setExposureTargetBias(min(device.maxExposureTargetBias, max(device.minExposureTargetBias, configuration.ev)))
        } else if device.isExposureModeSupported(.custom) {
            let duration = min(device.activeFormat.maxExposureDuration.seconds,
                               max(device.activeFormat.minExposureDuration.seconds,
                                   min(1 / configuration.shutterDenominator, 1 / Double(configuration.fps))))
            device.setExposureModeCustom(duration: CMTime(seconds: duration, preferredTimescale: 1_000_000),
                                         iso: min(device.activeFormat.maxISO, max(device.activeFormat.minISO, configuration.iso)))
        }
        if !isRecording && !isStopping {
            if configuration.autoFocus, device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            } else if device.isLockingFocusWithCustomLensPositionSupported {
                device.setFocusModeLocked(lensPosition: configuration.focus)
            }
        }
        // Hold sensor white balance; the RAW developer applies the user's Kelvin.
        if device.isWhiteBalanceModeSupported(.locked) {
            let values = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(temperature: configuration.whiteBalance, tint: 0)
            var gains = device.deviceWhiteBalanceGains(for: values)
            gains.redGain = min(device.maxWhiteBalanceGain, max(1, gains.redGain))
            gains.greenGain = min(device.maxWhiteBalanceGain, max(1, gains.greenGain))
            gains.blueGain = min(device.maxWhiteBalanceGain, max(1, gains.blueGain))
            device.setWhiteBalanceModeLocked(with: gains)
        }
    }

    private func startTimer() {
        timer?.cancel()
        guard active, !isStopping else { return }
        let timer = DispatchSource.makeTimerSource(queue: captureQueue)
        // Idle monitor is intentionally capped to limit heat from RAW development.
        let fps = isRecording ? configuration.fps : 6
        timer.schedule(deadline: .now(), repeating: 1 / Double(fps), leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in self?.tick() }
        self.timer = timer
        timer.resume()
    }

    private func tick() {
        guard active, !isStopping else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if isRecording && (ProcessInfo.processInfo.thermalState == .critical || now - lastFrame > 8) {
            interrupted(ProcessInfo.processInfo.thermalState == .critical ? "The phone is too hot. Recording stopped." : "RAW frames stopped arriving. Recording stopped.")
            return
        }
        if isRecording && now - lastClockPublish >= 0.25 {
            lastClockPublish = now
            let elapsed = now - recordStart
            publish { $0.elapsed = elapsed }
        }
        guard budget.active.count < budget.limit else { if isRecording { dropped += 1 }; return }
        if isDemo { captureDemo(now: now); return }
        guard session.isRunning, let rawFormat else { return }
        let settings = photoSettings(format: rawFormat)
        let id = settings.uniqueID
        guard budget.reserve(id) else { return }
        let snapshot = configuration
        let take = recorder
        let delegate = RawCaptureDelegate(processed: { [weak self] photo, error in
            self?.captureQueue.async { self?.received(photo, error: error, id: id, settings: snapshot, recorder: take) }
        }, finished: { [weak self] error in
            self?.captureQueue.async {
                guard let self, self.requests[id] != nil else { return }
                self.requests[id]?.captureDone = true
                if let error {
                    if self.requests[id]?.processingStarted == false { self.requests[id]?.processingDone = true }
                    self.reportCaptureFailure(error, stage: "RAW capture completion")
                }
                self.releaseIfFinished(id)
            }
        })
        requests[id] = Request(delegate: delegate, requestedAt: now)
        output.capturePhoto(with: settings, delegate: delegate)
    }

    private func received(_ photo: AVCapturePhoto?, error: Error?, id: Int64, settings: CameraSettings, recorder: MovieRecorder?) {
        guard let request = requests[id] else { return }
        guard error == nil, let photo else {
            requests[id]?.processingDone = true
            if let error { reportCaptureFailure(error, stage: "RAW photo delivery") }
            releaseIfFinished(id)
            return
        }
        // Retain the photo through rendering: its RAW buffer is an inner pointer.
        requests[id]?.processingStarted = true
        let enqueuedAt = ProcessInfo.processInfo.systemUptime
        let captureLatency = enqueuedAt - request.requestedAt
        let renderPreview = previewConnection == nil || MonitorRouting.rendersRAWPreview(recording: isRecording, finalizing: isStopping,
            recordingFrame: recorder != nil, simulation: false)
        processingQueue.async {
            autoreleasepool {
                do {
                    let beganAt = ProcessInfo.processInfo.systemUptime
                    guard let processor = self.processor else { throw CameraFailure.message("RAW processor unavailable.") }
                    let linear = try processor.develop(photo, settings: settings)
                    let wrote = try recorder.map { try $0.append(processor.encoded(linear, profile: settings.profile), sensorTime: photo.timestamp, processor: processor) } ?? true
                    // During a take, do not evaluate the RAW graph a second time for monitoring.
                    let preview = renderPreview ? try processor.preview(linear, settings: settings) : nil
                    self.completeFrame(id: id, preview: preview, wrote: wrote, recordingFrame: recorder != nil,
                        captureLatency: captureLatency, queueWait: beganAt - enqueuedAt,
                        renderTime: ProcessInfo.processInfo.systemUptime - beganAt)
                } catch { self.failedFrame(id: id, error: error) }
            }
        }
    }

    private func captureDemo(now: Double) {
        demoID -= 1
        let id = demoID
        guard budget.reserve(id) else { return }
        let settings = configuration
        let take = recorder
        processingQueue.async {
            autoreleasepool {
                do {
                    guard let processor = self.processor else { return }
                    let image = processor.demoImage(time: now, settings: settings)
                    let wrote = try take.map { try $0.append(processor.encoded(image, profile: settings.profile), sensorTime: CMTime(seconds: now, preferredTimescale: 600_000), processor: processor) } ?? true
                    self.completeFrame(id: id, preview: try processor.preview(image, settings: settings), wrote: wrote, recordingFrame: take != nil)
                } catch { self.failedFrame(id: id, error: error) }
            }
        }
    }

    private func completeFrame(id: Int64, preview: CGImage?, wrote: Bool, recordingFrame: Bool,
                               captureLatency: Double = 0, queueWait: Double = 0, renderTime: Double = 0) {
        if let preview {
            publish { if !$0.usesSystemPreview { $0.preview = preview } }
        }
        captureQueue.async {
            self.lastFrame = ProcessInfo.processInfo.systemUptime
            // In-flight idle frames must not inflate the recording FPS counter.
            if recordingFrame {
                if wrote {
                    self.rateCount += 1
                    self.performance.add(capture: captureLatency, queue: queueWait, render: renderTime)
                } else { self.dropped += 1 }
            } else if !self.isRecording && !self.isStopping { self.rateCount += 1 }
            if self.lastFrame - self.rateStart >= 1 {
                let rate = Double(self.rateCount) / (self.lastFrame - self.rateStart)
                let dropped = self.dropped
                let iso = self.device?.iso ?? self.configuration.iso
                let shutter = self.device.map { 1 / max(0.000001, $0.exposureDuration.seconds) } ?? self.configuration.shutterDenominator
                self.publish { $0.measuredFPS = rate; $0.skipped = dropped; $0.actualISO = iso; $0.actualShutter = shutter }
                self.rateStart = self.lastFrame; self.rateCount = 0
            }
            if self.isDemo { self.budget.release(id); self.finishIfDrained(); self.startTakeIfDrained() }
            else { self.requests[id]?.processingDone = true; self.releaseIfFinished(id) }
        }
    }

    private func failedFrame(id: Int64, error: Error) {
        captureQueue.async {
            self.reportCaptureFailure(error, stage: "RAW development / movie encoding")
            if self.isDemo { self.budget.release(id) }
            else { self.requests[id]?.processingDone = true; self.releaseIfFinished(id) }
            self.finishIfDrained()
        }
    }

    private func releaseIfFinished(_ id: Int64) {
        guard let request = requests[id], request.processingDone && request.captureDone else { return }
        requests[id] = nil
        budget.release(id)
        finishIfDrained()
        startTakeIfDrained()
    }

    func toggleRecording() {
        captureQueue.async {
            if self.isRecording { self.stopRecording(); return }
            guard self.active, !self.isStopping, !self.pendingTakeStart, self.isDemo || self.rawFormat != nil else { return }
            self.pendingTakeStart = true
            let attempt = UUID()
            self.pendingStartID = attempt
            self.timer?.cancel(); self.timer = nil
            self.publish { $0.preparingTake = true }
            self.startTakeIfDrained()
            self.captureQueue.asyncAfter(deadline: .now() + 3) {
                guard self.pendingTakeStart, self.pendingStartID == attempt else { return }
                self.pendingTakeStart = false
                self.reportCaptureFailure(CameraFailure.message("An idle RAW capture did not finish before take start."), stage: "Preparing recording")
            }
        }
    }

    /// Add the optional video connection only after all idle RAW captures finish.
    /// No UI lifecycle callback may attach, detach, or rotate a capture connection.
    private func attachSystemPreviewIfPossible() {
        guard !isDemo, allowSystemPreview, previewConnection == nil,
              let input = session.inputs.compactMap({ $0 as? AVCaptureDeviceInput }).first,
              let port = input.ports.first(where: { $0.mediaType == .video }) else { return }
        session.beginConfiguration()
        systemPreviewLayer.setSessionWithNoConnection(session)
        let connection = AVCaptureConnection(inputPort: port, videoPreviewLayer: systemPreviewLayer)
        if session.canAddConnection(connection) {
            session.addConnection(connection)
            if connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle = 90 }
            previewConnection = connection
        } else {
            systemPreviewLayer.session = nil
        }
        session.commitConfiguration()
        let available = previewConnection != nil
        publish { $0.systemPreviewAvailable = available }
    }

    private func startTakeIfDrained() {
        guard pendingTakeStart, active, !isStopping, budget.active.isEmpty else { return }
        pendingTakeStart = false
            do {
                attachSystemPreviewIfPossible()
                self.recorder = try MovieRecorder(settings: self.configuration, folder: Self.clipsFolder,
                    inputLabel: self.isDemo ? "Synthetic simulator frames" : "Bayer RAW")
                // Freeze focus at take start to avoid RAW lens movement between frames.
                if let device = self.device, device.isFocusModeSupported(.locked) {
                    try device.lockForConfiguration()
                    device.focusMode = .locked
                    device.unlockForConfiguration()
                }
                self.isRecording = true
                self.recordStart = ProcessInfo.processInfo.systemUptime
                self.lastFrame = self.recordStart
                self.rateStart = self.recordStart; self.rateCount = 0; self.dropped = 0
                self.lastClockPublish = self.recordStart
                self.performance = CapturePerformance()
                self.publish { $0.preparingTake = false; $0.recording = true; $0.elapsed = 0; $0.skipped = 0 }
                self.startTimer()
            } catch {
                self.recorder = nil
                let detail = CaptureErrorReport.describe(error, stage: "Starting recording")
                self.publish { $0.preparingTake = false; $0.errorMessage = detail }
                self.startTimer()
            }
    }

    private func stopRecording() {
        guard isRecording else { return }
        isRecording = false; isStopping = true
        let currentStop = UUID()
        stopID = currentStop
        timer?.cancel(); timer = nil
        publish { $0.recording = false; $0.finalizing = true }
        finishIfDrained()
        // A cancelled AVFoundation request must not leave the UI stuck forever.
        captureQueue.asyncAfter(deadline: .now() + 5) {
            guard self.isStopping, self.stopID == currentStop else { return }
            self.requests.removeAll()
            self.budget = CaptureBudget(limit: Self.maxInFlightFrames)
            self.finishIfDrained()
        }
    }

    private func finishIfDrained() {
        guard isStopping, budget.active.isEmpty, let take = recorder else { return }
        recorder = nil
        let diagnostics: [String: Any] = [
            "previewSource": isDemo ? "synthetic" : previewConnection != nil ? "system video preview layer" : "RAW preview fallback",
            "rawPreviewEnabledForRecordingFrames": isDemo || previewConnection == nil,
            "maxInFlightFrames": Self.maxInFlightFrames,
            "measuredFrames": performance.samples,
            "meanCaptureCallbackMS": performance.meanCaptureMS,
            "meanProcessingQueueWaitMS": performance.meanQueueMS,
            "meanRawRenderAndAppendMS": performance.meanRenderMS,
            "skippedCaptureOrEncoderOpportunities": dropped
        ]
        processingQueue.async {
            take.finish(diagnostics: diagnostics) { result in
                self.captureQueue.async {
                    self.isStopping = false
                    try? self.applyDeviceSettings()
                    self.publish {
                        $0.finalizing = false
                        if case let .failure(error) = result, $0.errorMessage == nil {
                            $0.errorMessage = CaptureErrorReport.describe(error, stage: "Finalizing recording")
                        }
                        $0.refreshClips()
                    }
                    self.startTimer()
                }
            }
        }
    }

    private func interrupted(_ message: String) {
        pendingTakeStart = false
        timer?.cancel(); timer = nil
        if isRecording { stopRecording() }
        active = false
        publish { $0.ready = false; $0.preparingTake = false; $0.status = "CAPTURE STOPPED"; $0.errorMessage = message }
    }

    private func reportCaptureFailure(_ error: Error, stage: String) {
        guard active || isRecording || pendingTakeStart else { return }
        needsSessionReset = !isDemo
        // If the optional preview graph fails, a Retry returns to the previously
        // working RAW-only session instead of repeating the same connection failure.
        if previewConnection != nil { allowSystemPreview = false }
        interrupted(CaptureErrorReport.describe(error, stage: stage))
    }

    func refreshClips() {
        let urls = (try? FileManager.default.contentsOfDirectory(at: Self.clipsFolder, includingPropertiesForKeys: [.creationDateKey, .fileSizeKey])) ?? []
        clips = urls.filter { $0.pathExtension == "mov" }.compactMap { url in
            // The library only exposes finalized movies with a sidecar.
            guard FileManager.default.fileExists(atPath: url.deletingPathExtension().appendingPathExtension("json").path),
                  let values = try? url.resourceValues(forKeys: [.creationDateKey, .fileSizeKey]) else { return nil }
            return Clip(url: url, date: values.creationDate ?? .distantPast, bytes: Int64(values.fileSize ?? 0))
        }.sorted { $0.date > $1.date }
    }
}
