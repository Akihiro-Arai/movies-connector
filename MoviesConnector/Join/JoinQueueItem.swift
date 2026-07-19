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

/// In-flight drag import shown as a queue row while Photos / iCloud materializes the file.
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

    /// Strips the drop-copy UUID prefix (`<uuid>-IMG_3765.MOV` → `IMG_3765.MOV`).
    static func preferredDisplayName(for url: URL) -> String {
        let name = url.lastPathComponent
        let uuidPrefix =
            #"^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}-"#
        guard let range = name.range(of: uuidPrefix, options: .regularExpression) else {
            return name
        }
        let stripped = String(name[range.upperBound...])
        return stripped.isEmpty ? name : stripped
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
