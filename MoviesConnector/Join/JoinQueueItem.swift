import Foundation

enum JoinCompatibilityState: Equatable, Sendable {
    case inspecting
    case compatible
    case incompatible(reason: String)
}

/// One queue row. Identity is a stable UUID so the same URL can appear more than once.
struct JoinQueueItem: Identifiable, Equatable, Sendable {
    let id: UUID
    var url: URL
    var displayName: String
    var duration: TimeInterval?
    var compatibility: JoinCompatibilityState
    /// Cached signature used to recompute compatibility after reorder/delete without re-reading media.
    var signature: CompatibilitySignature?

    init(
        id: UUID = UUID(),
        url: URL,
        displayName: String? = nil,
        duration: TimeInterval? = nil,
        compatibility: JoinCompatibilityState = .inspecting,
        signature: CompatibilitySignature? = nil
    ) {
        self.id = id
        self.url = url
        self.displayName = displayName ?? url.lastPathComponent
        self.duration = duration
        self.compatibility = compatibility
        self.signature = signature
    }
}

enum DurationFormatting {
    static func string(from duration: TimeInterval?) -> String {
        guard let duration, duration.isFinite, duration >= 0 else { return "—" }
        let totalSeconds = Int(duration.rounded())
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }
}
