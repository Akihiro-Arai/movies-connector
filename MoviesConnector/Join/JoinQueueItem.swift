import Foundation

enum JoinCompatibilityState: Equatable, Sendable {
    case inspecting
    case compatible
    /// Semantic mismatches — localize at presentation time (#22).
    case incompatible(mismatches: [CompatibilityMismatch])
    /// Inspection / I/O failure (system-provided text).
    case failed(reason: String)

    /// English diagnostic text (tests, exporter-facing summaries).
    var reasonText: String? {
        switch self {
        case .inspecting, .compatible:
            return nil
        case .incompatible(let mismatches):
            return mismatches.map(\.description).joined(separator: "; ")
        case .failed(let reason):
            return reason
        }
    }

    /// Locale-aware text for UI rows.
    var localizedReasonText: String? {
        switch self {
        case .inspecting, .compatible:
            return nil
        case .incompatible(let mismatches):
            return mismatches.map(\.localizedDescription).joined(separator: "; ")
        case .failed(let reason):
            return reason
        }
    }
}

/// In-flight Finder drop shown as a queue row while the file URL resolves.
struct PendingDropImport: Identifiable, Equatable, Sendable {
    let id: UUID
    var title: String

    init(id: UUID = UUID(), title: String) {
        self.id = id
        self.title = title
    }
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
        self.displayName = displayName ?? Self.preferredDisplayName(for: url)
        self.duration = duration
        self.compatibility = compatibility
        self.signature = signature
    }

    static func preferredDisplayName(for url: URL) -> String {
        url.lastPathComponent
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
