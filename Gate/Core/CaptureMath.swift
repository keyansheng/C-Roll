import Foundation

/// Gate Log is a documented custom curve in linear Rec.709 primaries.
/// It is not Apple Log, S-Log, or a camera-matching profile.
enum GateLog {
    static func encode(_ linear: Double) -> Double {
        log2(1 + 15 * max(0, linear)) / 4
    }

    static func decode(_ encoded: Double) -> Double {
        (pow(2, encoded * 4) - 1) / 15
    }
}

/// Keep actual sensor timing. Never turn a slow RAW stream into sped-up video.
struct CaptureTimeline {
    private(set) var origin: Double?
    private(set) var last: Double?

    mutating func accept(_ seconds: Double) -> Double? {
        guard seconds.isFinite, last.map({ seconds > $0 }) ?? true else { return nil }
        if origin == nil { origin = seconds }
        last = seconds
        return seconds - origin!
    }
}

/// A slot covers both the capture callback and downstream GPU/encoder work.
struct CaptureBudget {
    let limit: Int
    private(set) var active: Set<Int64> = []

    mutating func reserve(_ id: Int64) -> Bool {
        guard active.count < limit, !active.contains(id) else { return false }
        active.insert(id)
        return true
    }

    mutating func release(_ id: Int64) { active.remove(id) }
}

enum MonitorRouting {
    static func usesSystemPreview(recording: Bool, finalizing: Bool, simulation: Bool) -> Bool {
        !simulation && (recording || finalizing)
    }

    static func rendersRAWPreview(recording: Bool, finalizing: Bool, recordingFrame: Bool, simulation: Bool) -> Bool {
        simulation || !(recording || finalizing || recordingFrame)
    }
}

struct CapturePerformance {
    private(set) var samples = 0
    private var captureTotal = 0.0
    private var queueTotal = 0.0
    private var renderTotal = 0.0

    mutating func add(capture: Double, queue: Double, render: Double) {
        samples += 1
        captureTotal += capture
        queueTotal += queue
        renderTotal += render
    }

    var meanCaptureMS: Double { samples == 0 ? 0 : captureTotal * 1000 / Double(samples) }
    var meanQueueMS: Double { samples == 0 ? 0 : queueTotal * 1000 / Double(samples) }
    var meanRenderMS: Double { samples == 0 ? 0 : renderTotal * 1000 / Double(samples) }
}
