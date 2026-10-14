import Foundation
import AVFoundation

enum RecordingCodec: String, CaseIterable, Identifiable {
    case hevc = "HEVC · 8-bit"
    case proRes = "ProRes 422"
    var id: String { rawValue }
    var avCodec: AVVideoCodecType { self == .hevc ? .hevc : .proRes422 }
    var shortName: String { self == .hevc ? "HEVC" : "PRORES" }
}

enum ColorProfile: String, CaseIterable, Identifiable {
    case gateLog = "Gate Log"
    case rec709 = "Rec.709"
    var id: String { rawValue }
}

enum Framing: String, CaseIterable, Identifiable {
    case openGate = "Open gate · 4:3"
    case widescreen = "Cinema · 16:9"
    var id: String { rawValue }
    // The MVP holds portrait orientation; ratios are width / height.
    var portraitRatio: Double { self == .openGate ? 3.0 / 4.0 : 9.0 / 16.0 }
    var shortName: String { self == .openGate ? "OPEN GATE" : "16:9" }
}

enum ExposureAssist: String, CaseIterable, Identifiable {
    case off = "Off"
    case zebras = "Zebras"
    case falseColor = "False color"
    var id: String { rawValue }
}

struct CameraSettings: Equatable {
    var fps = 30
    var codec: RecordingCodec = .hevc
    var profile: ColorProfile = .gateLog
    var framing: Framing = .openGate
    var longEdge = 1920
    var bitrateMbps = 60
    var autoExposure = true
    var iso: Float = 100
    var shutterDenominator: Double = 60
    var ev: Float = 0
    var whiteBalance: Float = 5600
    var autoFocus = true
    var focus: Float = 0.5
    var noiseReduction: Float = 0
    var lensCorrection = false
    var gammaAssist = true
    var assist: ExposureAssist = .off
    var grid = true
}

struct Clip: Identifiable {
    let url: URL
    var id: String { url.lastPathComponent }
    let date: Date
    let bytes: Int64
    var size: String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
}
