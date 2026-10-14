import XCTest
@testable import GateCore

final class CaptureMathTests: XCTestCase {
    func testLogRoundTripAndEndpoints() {
        XCTAssertEqual(GateLog.encode(0), 0)
        XCTAssertEqual(GateLog.encode(1), 1)
        XCTAssertEqual(GateLog.encode(-0.1), 0)
        for value in [0.001, 0.018, 0.18, 0.5, 1, 2, 8] {
            XCTAssertEqual(GateLog.decode(GateLog.encode(value)), value, accuracy: 1e-10)
        }
    }

    func testSlowFramesKeepRealTimeAndRejectOutOfOrder() {
        var timeline = CaptureTimeline()
        XCTAssertEqual(timeline.accept(20), 0)
        XCTAssertEqual(timeline.accept(20.1)!, 0.1, accuracy: 1e-9)
        XCTAssertNil(timeline.accept(20.05))
        XCTAssertNil(timeline.accept(20.1))
        XCTAssertNil(timeline.accept(.nan))
        XCTAssertEqual(timeline.accept(21), 1)
    }

    func testBackPressureAndIdempotentRelease() {
        var budget = CaptureBudget(limit: 2)
        XCTAssertTrue(budget.reserve(1))
        XCTAssertFalse(budget.reserve(1))
        XCTAssertTrue(budget.reserve(2))
        XCTAssertFalse(budget.reserve(3))
        budget.release(1)
        budget.release(1)
        XCTAssertTrue(budget.reserve(3))
        XCTAssertEqual(budget.active, [2, 3])
    }

    func testHardwareTakeSkipsRAWMonitorIncludingDrainAndQueuedIdleFrame() {
        XCTAssertTrue(MonitorRouting.rendersRAWPreview(recording: false, finalizing: false, recordingFrame: false, simulation: false))
        for (recording, finalizing, recordingFrame) in [(true, false, true), (true, false, false), (false, true, true), (false, false, true)] {
            XCTAssertFalse(MonitorRouting.rendersRAWPreview(recording: recording, finalizing: finalizing,
                recordingFrame: recordingFrame, simulation: false))
        }
        XCTAssertTrue(MonitorRouting.usesSystemPreview(recording: true, finalizing: false, simulation: false))
        XCTAssertTrue(MonitorRouting.usesSystemPreview(recording: false, finalizing: true, simulation: false))
        XCTAssertFalse(MonitorRouting.usesSystemPreview(recording: false, finalizing: false, simulation: false))
        XCTAssertFalse(MonitorRouting.usesSystemPreview(recording: true, finalizing: false, simulation: true))
        XCTAssertTrue(MonitorRouting.rendersRAWPreview(recording: true, finalizing: false, recordingFrame: true, simulation: true))
    }

    func testPerformanceSummarySeparatesCaptureQueueAndRenderLatency() {
        var performance = CapturePerformance()
        XCTAssertEqual(performance.meanRenderMS, 0)
        performance.add(capture: 0.030, queue: 0.002, render: 0.010)
        performance.add(capture: 0.050, queue: 0.006, render: 0.020)
        XCTAssertEqual(performance.samples, 2)
        XCTAssertEqual(performance.meanCaptureMS, 40, accuracy: 1e-9)
        XCTAssertEqual(performance.meanQueueMS, 4, accuracy: 1e-9)
        XCTAssertEqual(performance.meanRenderMS, 15, accuracy: 1e-9)
    }

    func testErrorNoticeIncludesStageAndUnderlyingCameraCode() {
        let underlying = NSError(domain: NSOSStatusErrorDomain, code: -12780,
            userInfo: [NSLocalizedDescriptionKey: "Underlying camera failure"])
        let error = NSError(domain: "AVFoundationErrorDomain", code: -11800,
            userInfo: [NSLocalizedDescriptionKey: "The operation could not be completed", NSUnderlyingErrorKey: underlying])
        let text = CaptureErrorReport.describe(error, stage: "RAW photo delivery")
        XCTAssertTrue(text.contains("RAW photo delivery"))
        XCTAssertTrue(text.contains("AVFoundationErrorDomain -11800"))
        XCTAssertTrue(text.contains("NSOSStatusErrorDomain -12780"))
    }
}
