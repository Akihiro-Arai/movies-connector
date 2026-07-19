import AppKit
import Foundation
import UniformTypeIdentifiers

struct DropLoadOutcome: Sendable {
    var urls: [URL]
    var diagnostics: DropDiagnostics
}

/// Loads durable movie file URLs from drag-and-drop.
///
/// - Finder: usually `public.file-url`
/// - Photos: typically `NSFilePromiseReceiver` on the drag pasteboard
enum MovieDropItemLoader {
    /// Types registered with SwiftUI `onDrop` so the drop is accepted.
    static var dropAcceptedTypes: [UTType] {
        var types: [UTType] = [.fileURL, .audiovisualContent, .url]
        for type in MovieContentTypes.importTypes where !types.contains(type) {
            types.append(type)
        }
        for raw in NSFilePromiseReceiver.readableDraggedTypes {
            if let type = UTType(raw), !types.contains(type) {
                types.append(type)
            }
        }
        return types
    }

    /// Raw type identifiers for APIs that still use strings (includes file promises).
    static var dropAcceptedTypeIdentifiers: [String] {
        var identifiers = Set(dropAcceptedTypes.map(\.identifier))
        for raw in NSFilePromiseReceiver.readableDraggedTypes {
            identifiers.insert(raw)
        }
        return Array(identifiers).sorted()
    }

    /// Movie type identifiers tried with `loadFileRepresentation`.
    static var representationTypeIdentifiers: [String] {
        var identifiers: [String] = [UTType.audiovisualContent.identifier, UTType.movie.identifier]
        for type in MovieContentTypes.importTypes {
            if !identifiers.contains(type.identifier) {
                identifiers.append(type.identifier)
            }
        }
        return identifiers
    }

    /// Test seam: `(identifiers, isReadable) -> URL?`
    static var resolveFileURLForTesting: (([String], (URL) -> Bool) -> URL?)?
    /// Test seam: `(typeIdentifiers) -> URL?` already-persisted representation.
    static var resolveRepresentationForTesting: (([String]) -> URL?)?
    /// Test seam replacing drag-pasteboard file promises.
    static var resolveFilePromisesForTesting: (() -> [URL])?

    static func resetForTesting() {
        resolveFileURLForTesting = nil
        resolveRepresentationForTesting = nil
        resolveFilePromisesForTesting = nil
    }

    /// Call from `performDrop` **synchronously** before returning.
    static func snapshotFilePromiseReceiversFromDragPasteboard(
        diagnostics: DropDiagnostics
    ) -> [NSFilePromiseReceiver] {
        if resolveFilePromisesForTesting != nil {
            diagnostics.log("snapshotFilePromiseReceivers: using test seam (skip pasteboard read)")
            return []
        }
        let pasteboard = NSPasteboard(name: .drag)
        let types = pasteboard.types?.map(\.rawValue) ?? []
        diagnostics.log("drag pasteboard types (\(types.count)): \(types.joined(separator: ", "))")
        diagnostics.log(
            "NSFilePromiseReceiver.readableDraggedTypes: \(NSFilePromiseReceiver.readableDraggedTypes.joined(separator: ", "))"
        )
        let receivers = (pasteboard.readObjects(
            forClasses: [NSFilePromiseReceiver.self],
            options: nil
        ) as? [NSFilePromiseReceiver]) ?? []
        diagnostics.log("readObjects NSFilePromiseReceiver count=\(receivers.count)")
        for (index, receiver) in receivers.enumerated() {
            diagnostics.log("promise[\(index)] fileNames=\(receiver.fileNames)")
        }
        return receivers
    }

    /// Non-consuming check for `validateDrop`.
    static func dragPasteboardHasFilePromises() -> Bool {
        if resolveFilePromisesForTesting != nil {
            return true
        }
        let pasteboard = NSPasteboard(name: .drag)
        let readable = Set(NSFilePromiseReceiver.readableDraggedTypes)
        return pasteboard.types?.contains(where: { readable.contains($0.rawValue) }) == true
    }

    static func describeDragPasteboardForValidation(diagnostics: DropDiagnostics) {
        let pasteboard = NSPasteboard(name: .drag)
        let types = pasteboard.types?.map(\.rawValue) ?? []
        diagnostics.log("validateDrop pasteboard types: \(types.joined(separator: ", "))")
        diagnostics.log("validateDrop hasFilePromiseType=\(dragPasteboardHasFilePromises())")
    }

    /// Primary entry used by the UI after a drop.
    static func loadURLsFromCurrentDrop(
        providers: [NSItemProvider],
        promiseReceivers: [NSFilePromiseReceiver] = [],
        diagnostics: DropDiagnostics = DropDiagnostics()
    ) async -> DropLoadOutcome {
        diagnostics.section("Drop load start")
        diagnostics.log("providers=\(providers.count) promiseReceivers=\(promiseReceivers.count)")
        for (index, provider) in providers.enumerated() {
            diagnostics.log(
                "provider[\(index)] registeredTypeIdentifiers=\(provider.registeredTypeIdentifiers.joined(separator: ", "))"
            )
            diagnostics.log(
                "provider[\(index)] suggestedName=\(provider.suggestedName ?? "nil")"
            )
        }

        if let resolveFilePromisesForTesting {
            let urls = resolveFilePromisesForTesting()
            diagnostics.log("test seam filePromises urls=\(urls.map(\.path))")
            if !urls.isEmpty {
                return DropLoadOutcome(urls: urls, diagnostics: diagnostics)
            }
        }

        let sessionDirectory: URL
        do {
            sessionDirectory = try makeDropSessionDirectory()
            diagnostics.log("drop session directory=\(sessionDirectory.path)")
        } catch {
            diagnostics.logError("makeDropSessionDirectory", error)
            return DropLoadOutcome(urls: [], diagnostics: diagnostics)
        }

        var urls: [URL] = []
        for (index, receiver) in promiseReceivers.enumerated() {
            diagnostics.section("File promise [\(index)]")
            let promised = await receivePromisedMovies(
                from: receiver,
                sessionDirectory: sessionDirectory,
                diagnostics: diagnostics
            )
            if promised.isEmpty {
                diagnostics.log("promise[\(index)] FAILED to materialize")
            } else {
                for url in promised {
                    diagnostics.log("promise[\(index)] persisted → \(url.path)")
                }
                urls.append(contentsOf: promised)
            }
        }
        if !urls.isEmpty {
            diagnostics.log("using \(urls.count) URL(s) from file promises")
            return DropLoadOutcome(urls: urls, diagnostics: diagnostics)
        }

        diagnostics.section("Item provider fallback")
        for (index, provider) in providers.enumerated() {
            diagnostics.log("loading provider[\(index)]…")
            let loaded = await loadURLs(
                from: provider,
                sessionDirectory: sessionDirectory,
                diagnostics: diagnostics
            )
            if loaded.isEmpty {
                diagnostics.log("provider[\(index)] → nil")
            } else {
                for url in loaded {
                    diagnostics.log("provider[\(index)] → \(url.path)")
                }
                urls.append(contentsOf: loaded)
            }
        }

        if urls.isEmpty {
            try? FileManager.default.removeItem(at: sessionDirectory)
            diagnostics.log("removed empty drop session directory")
        }

        diagnostics.log("final URL count=\(urls.count)")
        return DropLoadOutcome(urls: urls, diagnostics: diagnostics)
    }

    static func loadURLs(from providers: [NSItemProvider]) async -> [URL] {
        let outcome = await loadURLsFromCurrentDrop(providers: providers, promiseReceivers: [])
        return outcome.urls
    }

    static func loadURL(
        from provider: NSItemProvider,
        sessionDirectory: URL? = nil,
        diagnostics: DropDiagnostics = DropDiagnostics()
    ) async -> URL? {
        await loadURLs(
            from: provider,
            sessionDirectory: sessionDirectory,
            diagnostics: diagnostics
        ).first
    }

    /// Loads every URL a provider can materialize (multi-file promises included — #19).
    static func loadURLs(
        from provider: NSItemProvider,
        sessionDirectory: URL? = nil,
        diagnostics: DropDiagnostics = DropDiagnostics()
    ) async -> [URL] {
        let identifiers = provider.registeredTypeIdentifiers
        let directory: URL
        do {
            directory = try sessionDirectory ?? makeDropSessionDirectory()
        } catch {
            diagnostics.logError("makeDropSessionDirectory", error)
            return []
        }

        if let resolveFileURLForTesting {
            if let url = resolveFileURLForTesting(identifiers, isReadableFile),
               shouldUseDirectFileURL(url)
            {
                diagnostics.log("test seam direct fileURL \(url.path)")
                return [url]
            }
            diagnostics.log("test seam fileURL rejected or nil (photos library / unreadable)")
        } else if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            diagnostics.log("trying loadItem public.file-url")
            if let url = await loadFileURLItem(from: provider, diagnostics: diagnostics) {
                diagnostics.log(
                    "fileURL item path=\(url.path) isPhotosLibrary=\(isPhotosLibraryURL(url)) readable=\(isReadableFile(url))"
                )
                if shouldUseDirectFileURL(url) {
                    return [url]
                }
                diagnostics.log("skipping direct fileURL (photos library or unreadable)")
            }
        } else {
            diagnostics.log("provider does not conform to public.file-url")
        }

        let promised = await loadFilePromiseReceiver(
            from: provider,
            sessionDirectory: directory,
            diagnostics: diagnostics
        )
        if !promised.isEmpty {
            return promised
        }

        if let resolveRepresentationForTesting {
            let url = resolveRepresentationForTesting(identifiers)
            diagnostics.log("test seam representation → \(url?.path ?? "nil")")
            return url.map { [$0] } ?? []
        }

        for typeIdentifier in representationTypeIdentifiers {
            guard provider.hasItemConformingToTypeIdentifier(typeIdentifier) else {
                continue
            }
            diagnostics.log("trying loadFileRepresentation \(typeIdentifier)")
            if let url = await loadPersistedFileRepresentation(
                from: provider,
                typeIdentifier: typeIdentifier,
                sessionDirectory: directory,
                diagnostics: diagnostics
            ) {
                return [url]
            }
        }
        diagnostics.log("no representation type produced a URL")
        return []
    }

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

    /// Root for all drop materializations (`tmp/MoviesConnectorDrops`).
    static func dropsRootDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MoviesConnectorDrops", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Unique directory for one drop / load session (#19).
    static func makeDropSessionDirectory() throws -> URL {
        let session = try dropsRootDirectory()
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        return session
    }

    /// True when `url` lives under the app-owned drops root (safe to delete with the queue row).
    static func isOwnedDropCopy(_ url: URL) -> Bool {
        guard let root = try? dropsRootDirectory() else { return false }
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        return path == rootPath || path.hasPrefix(rootPath + "/")
    }

    /// Removes orphaned drop session folders left after crashes / cancelled imports (#24).
    static func cleanupAbandonedDropSessions(
        olderThan age: TimeInterval = 60 * 60,
        fileManager: FileManager = .default
    ) {
        guard let root = try? dropsRootDirectory() else { return }
        let cutoff = Date().addingTimeInterval(-age)
        guard let contents = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for url in contents {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey])
            guard values?.isDirectory == true else {
                try? fileManager.removeItem(at: url)
                continue
            }
            if let modified = values?.contentModificationDate, modified > cutoff {
                continue
            }
            try? fileManager.removeItem(at: url)
        }
    }

    static func persistDropCopy(
        of sourceURL: URL,
        in directory: URL? = nil,
        diagnostics: DropDiagnostics? = nil
    ) throws -> URL {
        let directory = try directory ?? makeDropSessionDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let originalName = sourceURL.lastPathComponent
        let fileName: String
        if originalName.isEmpty || originalName == "/" {
            fileName = "\(UUID().uuidString).\(MovieContentTypes.exportPathExtension)"
        } else {
            // Keep Photos / Finder names (e.g. IMG_3765.MOV) while staying unique.
            fileName = "\(UUID().uuidString)-\(originalName)"
        }
        let destination = directory.appendingPathComponent(fileName)
        try FileManager.default.copyItem(at: sourceURL, to: destination)
        diagnostics?.log("persistDropCopy \(sourceURL.path) → \(destination.path)")
        return destination
    }

    // MARK: - File promises

    private static func loadFilePromiseReceiver(
        from provider: NSItemProvider,
        sessionDirectory: URL,
        diagnostics: DropDiagnostics
    ) async -> [URL] {
        let promiseTypes = NSFilePromiseReceiver.readableDraggedTypes
        for rawType in promiseTypes {
            guard provider.hasItemConformingToTypeIdentifier(rawType) else { continue }
            diagnostics.log("provider conforms to promise type \(rawType); loadItem…")
            if let receiver = await loadPromiseReceiverItem(
                from: provider,
                typeIdentifier: rawType,
                diagnostics: diagnostics
            ) {
                return await receivePromisedMovies(
                    from: receiver,
                    sessionDirectory: sessionDirectory,
                    diagnostics: diagnostics
                )
            }
        }
        return []
    }

    private static func loadPromiseReceiverItem(
        from provider: NSItemProvider,
        typeIdentifier: String,
        diagnostics: DropDiagnostics
    ) async -> NSFilePromiseReceiver? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: typeIdentifier, options: nil) { item, error in
                if let error {
                    diagnostics.logError("loadItem(\(typeIdentifier))", error)
                }
                let receiver = item as? NSFilePromiseReceiver
                diagnostics.log(
                    "loadItem(\(typeIdentifier)) → \(receiver == nil ? "nil/\(String(describing: type(of: item)))" : "NSFilePromiseReceiver fileNames=\(receiver!.fileNames)")"
                )
                continuation.resume(returning: receiver)
            }
        }
    }

    /// Collects **every** promised-file callback for one receiver (#19).
    private static func receivePromisedMovies(
        from receiver: NSFilePromiseReceiver,
        sessionDirectory: URL,
        diagnostics: DropDiagnostics
    ) async -> [URL] {
        diagnostics.log("receivePromisedFiles destinationDir=\(sessionDirectory.path)")
        diagnostics.log("promise fileNames=\(receiver.fileNames)")

        return await withCheckedContinuation { continuation in
            let queue = OperationQueue()
            queue.name = "MoviesConnector.FilePromise.\(UUID().uuidString)"
            queue.maxConcurrentOperationCount = 1

            let lock = NSLock()
            var collected: [URL] = []
            var partials: [URL] = []

            receiver.receivePromisedFiles(
                atDestination: sessionDirectory,
                options: [:],
                operationQueue: queue
            ) { url, error in
                if let error {
                    diagnostics.logError("receivePromisedFiles", error)
                    try? FileManager.default.removeItem(at: url)
                    return
                }
                diagnostics.log("receivePromisedFiles wrote \(url.path)")
                lock.lock()
                partials.append(url)
                lock.unlock()
                do {
                    let values = try url.resourceValues(forKeys: [
                        .fileSizeKey,
                        .contentTypeKey,
                        .typeIdentifierKey,
                        .isReadableKey,
                    ])
                    diagnostics.log(
                        "promised file size=\(values.fileSize.map(String.init) ?? "?") type=\(values.contentType?.identifier ?? values.typeIdentifier ?? "?") readable=\(values.isReadable.map(String.init(describing:)) ?? "?")"
                    )
                } catch {
                    diagnostics.logError("promised file resourceValues", error)
                }
                do {
                    let persisted = try persistDropCopy(
                        of: url,
                        in: sessionDirectory,
                        diagnostics: diagnostics
                    )
                    try? FileManager.default.removeItem(at: url)
                    lock.lock()
                    collected.append(persisted)
                    lock.unlock()
                } catch {
                    diagnostics.logError("persistDropCopy after promise", error)
                    lock.lock()
                    collected.append(url)
                    lock.unlock()
                }
            }

            DispatchQueue.global(qos: .userInitiated).async {
                queue.waitUntilAllOperationsAreFinished()
                lock.lock()
                let urls = collected
                let leftoverPartials = partials.filter { partial in
                    !urls.contains(where: { $0.path == partial.path })
                }
                lock.unlock()
                for partial in leftoverPartials {
                    // Failed mid-flight promised files should not linger (#19).
                    if !urls.contains(where: { $0.standardizedFileURL == partial.standardizedFileURL }) {
                        try? FileManager.default.removeItem(at: partial)
                    }
                }
                continuation.resume(returning: urls)
            }
        }
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
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
                if let error {
                    diagnostics.logError("loadItem(public.file-url)", error)
                }
                if let data = item as? Data,
                   let url = URL(dataRepresentation: data, relativeTo: nil)
                {
                    diagnostics.log("file-url Data → \(url.absoluteString)")
                    continuation.resume(returning: url)
                } else if let url = item as? URL {
                    diagnostics.log("file-url URL → \(url.absoluteString)")
                    continuation.resume(returning: url)
                } else if let path = item as? String {
                    diagnostics.log("file-url String → \(path)")
                    continuation.resume(returning: URL(fileURLWithPath: path))
                } else {
                    diagnostics.log(
                        "file-url unexpected item type=\(String(describing: type(of: item))) value=\(String(describing: item))"
                    )
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    private static func loadPersistedFileRepresentation(
        from provider: NSItemProvider,
        typeIdentifier: String,
        sessionDirectory: URL,
        diagnostics: DropDiagnostics
    ) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { url, error in
                if let error {
                    diagnostics.logError("loadFileRepresentation(\(typeIdentifier))", error)
                    continuation.resume(returning: nil)
                    return
                }
                guard let url else {
                    diagnostics.log("loadFileRepresentation(\(typeIdentifier)) → nil url")
                    continuation.resume(returning: nil)
                    return
                }
                diagnostics.log("loadFileRepresentation(\(typeIdentifier)) temp=\(url.path)")
                do {
                    let persisted = try persistDropCopy(
                        of: url,
                        in: sessionDirectory,
                        diagnostics: diagnostics
                    )
                    continuation.resume(returning: persisted)
                } catch {
                    diagnostics.logError("persistDropCopy after representation", error)
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}
