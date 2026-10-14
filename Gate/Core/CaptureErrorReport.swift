import Foundation

enum CaptureErrorReport {
    static func describe(_ error: Error, stage: String) -> String {
        var lines = [stage]
        var current: NSError? = error as NSError
        // Underlying camera errors often contain the useful OSStatus code.
        for _ in 0..<4 {
            guard let value = current else { break }
            lines.append("\(value.localizedDescription) [\(value.domain) \(value.code)]")
            if let reason = value.localizedFailureReason, reason != value.localizedDescription {
                lines.append(reason)
            }
            current = value.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return lines.joined(separator: "\n")
    }
}
