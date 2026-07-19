import AppKit
import Foundation
import UniformTypeIdentifiers

struct DropLoadOutcome: Sendable {
    var urls: [URL]
    var diagnostics: DropDiagnostics
    /// True when a provider callback never finished within `dropLoadTimeout`.
    var timedOut: Bool = false
}

/// Loads Finder file URLs from drag-and-drop (`public.file-url` only).
///
/// Photos / file-promise materialization is intentionally unsupported (#26).
/// `NSItemProvider.loadItem` callbacks can still stall, so loads are wall-clock bounded.
enum MovieDropItemLoader {
    /// Overall wall-clock budget for resolving Finder drop providers.
    static var dropLoadTimeout: TimeInterval = 45
    /// Test seam overriding `dropLoadTimeout`.
    static var dropLoadTimeoutForTesting: TimeInterval?

    /// Types registered with SwiftUI `onDrop` — Finder file URLs only (#26).
    static var dropAcceptedTypes: [UTType] {
        [.fileURL]
    }

    static var dropAcceptedTypeIdentifiers: [String] {
        dropAcceptedTypes.map(\.identifier)
    }

    /// Test seam: `(identifiers, isReadable) -> URL?`
    static var resolveFileURLForTesting: (([String], (URL) -> Bool) -> URL?)?
    /// Test seam that parks the drop load (simulates a provider callback that never fires).
    static var stallDropLoadForTesting: (@Sendable () async -> Void)?

    static func resetForTesting() {
        resolveFileURLForTesting = nil
        dropLoadTimeoutForTesting = nil
        stallDropLoadForTesting = nil
        dropLoadTimeout = 45
    }

    private static var effectiveDropLoadTimeout: TimeInterval {
        dropLoadTimeoutForTesting ?? dropLoadTimeout
    }

    /// Primary entry used by the UI after a drop.
    static func loadURLsFromCurrentDrop(
        providers: [NSItemProvider],
        diagnostics: DropDiagnostics = DropDiagnostics()
    ) async -> DropLoadOutcome {
        let timeout = effectiveDropLoadTimeout
        diagnostics.section("Drop load start")
        diagnostics.log("providers=\(providers.count) timeout=\(Int(timeout))s")
        for (index, provider) in providers.enumerated() {
            diagnostics.log(
                "provider[\(index)] registeredTypeIdentifiers=\(provider.registeredTypeIdentifiers.joined(separator: ", "))"
            )
            diagnostics.log(
                "provider[\(index)] suggestedName=\(provider.suggestedName ?? "nil")"
            )
        }

        let body = await withTimeout(seconds: timeout, diagnostics: diagnostics, label: "loadURLsFromCurrentDrop") {
            await loadURLsFromCurrentDropUnbounded(providers: providers, diagnostics: diagnostics)
        }

        switch body {
        case .value(let outcome):
            return outcome
        case .timedOut:
            diagnostics.log("ABORT drop load timed out — clearing Loading row")
            return DropLoadOutcome(urls: [], diagnostics: diagnostics, timedOut: true)
        }
    }

    private static func loadURLsFromCurrentDropUnbounded(
        providers: [NSItemProvider],
        diagnostics: DropDiagnostics
    ) async -> DropLoadOutcome {
        if Task.isCancelled {
            diagnostics.log("ABORT drop load cancelled")
            return DropLoadOutcome(urls: [], diagnostics: diagnostics)
        }
        if let stallDropLoadForTesting {
            diagnostics.log("test seam stallDropLoad — parking until cancel/timeout")
            await stallDropLoadForTesting()
            if Task.isCancelled {
                diagnostics.log("ABORT drop load cancelled after stall")
                return DropLoadOutcome(urls: [], diagnostics: diagnostics)
            }
        }

        var urls: [URL] = []
        for (index, provider) in providers.enumerated() {
            if Task.isCancelled { break }
            diagnostics.log("loading provider[\(index)]…")
            if let url = await loadURL(from: provider, diagnostics: diagnostics) {
                diagnostics.log("provider[\(index)] → \(url.path)")
                urls.append(url)
            } else {
                diagnostics.log("provider[\(index)] → nil")
            }
        }

        diagnostics.log("final URL count=\(urls.count)")
        return DropLoadOutcome(urls: urls, diagnostics: diagnostics)
    }

    static func loadURLs(from providers: [NSItemProvider]) async -> [URL] {
        let outcome = await loadURLsFromCurrentDrop(providers: providers)
        return outcome.urls
    }

    static func loadURL(
        from provider: NSItemProvider,
        diagnostics: DropDiagnostics = DropDiagnostics()
    ) async -> URL? {
        let identifiers = provider.registeredTypeIdentifiers

        if let resolveFileURLForTesting {
            if let url = resolveFileURLForTesting(identifiers, isReadableFile),
               shouldUseDirectFileURL(url)
            {
                diagnostics.log("test seam direct fileURL \(url.path)")
                return url
            }
            diagnostics.log("test seam fileURL rejected or nil (photos library / unreadable)")
            return nil
        }

        guard provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else {
            diagnostics.log("provider does not conform to public.file-url")
            return nil
        }

        diagnostics.log("trying loadItem public.file-url")
        guard let url = await loadFileURLItem(from: provider, diagnostics: diagnostics) else {
            return nil
        }
        diagnostics.log(
            "fileURL item path=\(url.path) isPhotosLibrary=\(isPhotosLibraryURL(url)) readable=\(isReadableFile(url))"
        )
        if shouldUseDirectFileURL(url) {
            return url
        }
        diagnostics.log("rejecting fileURL (photos library or unreadable) — no materialization fallback")
        return nil
    }

    /// Defense-in-depth: never open files inside a Photos Library package (#26).
    static func isPhotosLibraryURL(_ url: URL) -> Bool {
        let path = url.path
        return path.contains(".photoslibrary/")
            || path.contains("/Photos Library.photoslibrary")
            || path.contains("/Photos Library/")
    }

    static func shouldUseDirectFileURL(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        if isPhotosLibraryURL(url) { return false }
        return isReadableFile(url)
    }

    // MARK: - Item provider helpers

    private static func isReadableFile(_ url: URL) -> Bool {
        FileManager.default.isReadableFile(atPath: url.path)
    }

    private static func loadFileURLItem(
        from provider: NSItemProvider,
        diagnostics: DropDiagnostics
    ) async -> URL? {
        await withCheckedContinuation { continuation in
            let once = OnceResume(continuation)
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
                if let error {
                    diagnostics.logError("loadItem(public.file-url)", error)
                }
                if let data = item as? Data,
                   let url = URL(dataRepresentation: data, relativeTo: nil)
                {
                    diagnostics.log("file-url Data → \(url.absoluteString)")
                    once.resume(returning: url)
                } else if let url = item as? URL {
                    diagnostics.log("file-url URL → \(url.absoluteString)")
                    once.resume(returning: url)
                } else if let path = item as? String {
                    diagnostics.log("file-url String → \(path)")
                    once.resume(returning: URL(fileURLWithPath: path))
                } else {
                    diagnostics.log(
                        "file-url unexpected item type=\(String(describing: type(of: item))) value=\(String(describing: item))"
                    )
                    once.resume(returning: nil)
                }
            }
        }
    }

    // MARK: - Timeout / resume safety

    private enum TimeoutBox<T: Sendable>: Sendable {
        case value(T)
        case timedOut
    }

    /// Resumes a checked continuation at most once (timeout vs late callback).
    private final class OnceResume<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T, Never>?
        private var didResume = false

        init(_ continuation: CheckedContinuation<T, Never>) {
            self.continuation = continuation
        }

        func resume(returning value: T) {
            lock.lock()
            defer { lock.unlock() }
            guard !didResume, let continuation else { return }
            didResume = true
            self.continuation = nil
            continuation.resume(returning: value)
        }
    }

    private static func withTimeout<T: Sendable>(
        seconds: TimeInterval,
        diagnostics: DropDiagnostics,
        label: String,
        operation: @escaping @Sendable () async -> T
    ) async -> TimeoutBox<T> {
        await withTaskGroup(of: TimeoutBox<T>.self) { group in
            group.addTask {
                .value(await operation())
            }
            group.addTask {
                let ns = UInt64(max(seconds, 0.1) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: ns)
                return .timedOut
            }
            let first = await group.next() ?? .timedOut
            group.cancelAll()
            if case .timedOut = first {
                diagnostics.log("TIMEOUT \(label) after \(Int(seconds))s")
            }
            return first
        }
    }
}
