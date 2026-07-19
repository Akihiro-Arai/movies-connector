import AVFoundation
import Foundation

enum JoinExporterError: Error, LocalizedError, Equatable {
    case emptyInput
    case outputCollidesWithInput
    case incompatible([String])
    case cannotCreateComposition
    case cannotCreateExportSession
    case exportFailed(String)
    case diskFull
    case cancelled

    var errorDescription: String? {
        switch self {
        case .emptyInput:
            return "No input videos were provided."
        case .outputCollidesWithInput:
            return "Output destination must not be the same file as any input."
        case .incompatible(let reasons):
            return "Inputs are incompatible for lossless join: \(reasons.joined(separator: "; "))"
        case .cannotCreateComposition:
            return "Could not build the join composition."
        case .cannotCreateExportSession:
            return "Could not start a passthrough export session."
        case .exportFailed(let detail):
            return "Export failed: \(detail)"
        case .diskFull:
            return "Not enough disk space to finish the export."
        case .cancelled:
            return "Export cancelled."
        }
    }
}

/// Production lossless join engine: security-scoped access, immediate preflight,
/// ordered `AVMutableComposition` insert, passthrough `.mov` export, progress, and cancel cleanup.
enum JoinExporter {
    struct Result: Sendable {
        var outputURL: URL
        var elapsedNanoseconds: UInt64
        var inputCount: Int
        /// Sum of source durations used for composition inserts.
        var expectedDuration: CMTime
        /// Duration of the exported asset after a successful install.
        var outputDuration: CMTime
    }

    // MARK: - Test seams

    /// When set, replaces the AV passthrough export body (writes must land at `tempURL`).
    static var exportBodyForTesting: (@Sendable (URL) async throws -> Void)?
    /// Invoked after staging + duration validation, immediately before final rename/replace.
    static var beforeCommitForTesting: (@Sendable () async throws -> Void)?
    /// When set, replaces the final staging→destination commit step.
    static var installExportForTesting: (@Sendable (_ stagingURL: URL, _ destinationURL: URL) throws -> Void)?
    /// Observes the job-owned system-temp URL once it is allocated.
    static var didCreateTempURLForTesting: (@Sendable (URL) -> Void)?
    /// Invoked after destination existence is sampled and before rename/replace (race tests).
    static var afterDestinationExistenceCheckForTesting: (@Sendable (URL) throws -> Void)?
    /// Invoked immediately before composition track loading (cancellation injection).
    static var beforeBuildTracksLoadForTesting: (@Sendable () async throws -> Void)?

    static func resetForTesting() {
        exportBodyForTesting = nil
        beforeCommitForTesting = nil
        installExportForTesting = nil
        didCreateTempURLForTesting = nil
        afterDestinationExistenceCheckForTesting = nil
        beforeBuildTracksLoadForTesting = nil
    }

    /// Joins `inputURLs` in exact caller order to `outputURL` using passthrough export.
    ///
    /// - Acquires inputs + output through `UserSelectedURLAccess.withPreparedAccess`
    /// - Rejects output colliding with any input before preflight/write
    /// - Re-runs batch compatibility preflight before composition; refuses on failure
    /// - Writes to a job-owned temp, stages beside the destination, validates there, then rename/replace
    /// - After a successful commit, never throws or awaits (cancel cannot unwind a finished write)
    /// - On cancel/failure, removes only staging / explicit backup — never the final URL by existence alone
    /// - Reports monotonic progress in `0...1` via `progress`
    @discardableResult
    static func join(
        inputURLs: [URL],
        outputURL: URL,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> Result {
        guard !inputURLs.isEmpty else { throw JoinExporterError.emptyInput }

        var scoped = inputURLs
        scoped.append(outputURL)

        // Access-layer typed errors (e.g. security-scope denial) propagate unchanged.
        // CancellationError from the entire prepared-access lifetime becomes `.cancelled`.
        do {
            return try await UserSelectedURLAccess.withPreparedAccess(to: scoped) {
                do {
                    return try await joinWithPreparedAccess(
                        inputURLs: inputURLs,
                        outputURL: outputURL,
                        progress: progress
                    )
                } catch let error as JoinExporterError {
                    throw error
                } catch is CancellationError {
                    throw JoinExporterError.cancelled
                } catch {
                    throw mapExportError(error)
                }
            }
        } catch is CancellationError {
            throw JoinExporterError.cancelled
        }
    }

    /// Immediate preflight before export — reuses `AssetInspector` row-addressable results.
    static func preflightCompatibility(inputURLs: [URL]) async throws {
        let report = try await AssetInspector.preflight(urls: inputURLs)
        try Task.checkCancellation()
        guard report.canExport else {
            throw JoinExporterError.incompatible(report.formattedReasons)
        }
    }

    /// Maps arbitrary errors (including nested AVFoundation / POSIX / Cocoa) to typed outcomes.
    /// Exposed for unit tests that inject raw AVError / ENOSPC / cancellation.
    static func mapErrorForTesting(_ error: Error) -> JoinExporterError {
        mapExportError(error)
    }

    // MARK: - Prepared-access body

    private static func joinWithPreparedAccess(
        inputURLs: [URL],
        outputURL: URL,
        progress: (@Sendable (Double) -> Void)?
    ) async throws -> Result {
        reportProgress(0, to: progress, last: nil)

        try Task.checkCancellation()
        try rejectCollidingOutput(outputURL: outputURL, inputURLs: inputURLs)

        try Task.checkCancellation()
        try await preflightCompatibility(inputURLs: inputURLs)
        var lastProgress = reportProgress(0.02, to: progress, last: 0)

        try Task.checkCancellation()
        let built = try await buildComposition(inputURLs: inputURLs)
        lastProgress = reportProgress(0.05, to: progress, last: lastProgress)

        let jobID = UUID().uuidString
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("movies-connector-job-\(jobID).mov")
        didCreateTempURLForTesting?(tempURL)
        // System-temp is always job-owned; staging is cleaned unless successfully committed.
        defer { removeJobOutputIfPresent(tempURL) }

        let started = DispatchTime.now().uptimeNanoseconds
        do {
            if let exportBodyForTesting {
                try await exportBodyForTesting(tempURL)
                lastProgress = reportProgress(0.95, to: progress, last: lastProgress)
            } else {
                guard
                    let exportSession = AVAssetExportSession(
                        asset: built.composition,
                        presetName: AVAssetExportPresetPassthrough
                    )
                else {
                    throw JoinExporterError.cannotCreateExportSession
                }
                exportSession.shouldOptimizeForNetworkUse = false
                try await exportPassthrough(
                    session: exportSession,
                    to: tempURL,
                    progress: progress,
                    lastReported: lastProgress
                )
            }
        } catch is CancellationError {
            throw JoinExporterError.cancelled
        } catch let error as JoinExporterError {
            throw error
        } catch {
            throw mapExportError(error)
        }

        // Stage beside the destination (same volume), validate there, then rename/replace to commit.
        try Task.checkCancellation()
        let stagingURL = try moveToDestinationStaging(from: tempURL, destination: outputURL, jobID: jobID)
        var stagingCommitted = false
        defer {
            if !stagingCommitted {
                removeJobOutputIfPresent(stagingURL)
            }
        }

        let outputDuration: CMTime
        do {
            outputDuration = try await AVURLAsset(url: stagingURL).load(.duration)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw mapExportError(error)
        }

        try Task.checkCancellation()
        if let beforeCommitForTesting {
            try await beforeCommitForTesting()
            try Task.checkCancellation()
        }

        // Final cancellation check, then commit. No throw/await after a successful install.
        try Task.checkCancellation()
        try commitStaging(from: stagingURL, to: outputURL)
        stagingCommitted = true

        reportProgress(1, to: progress, last: lastProgress)
        let elapsed = DispatchTime.now().uptimeNanoseconds - started
        return Result(
            outputURL: outputURL,
            elapsedNanoseconds: elapsed,
            inputCount: inputURLs.count,
            expectedDuration: built.expectedDuration,
            outputDuration: outputDuration
        )
    }

    private struct BuiltComposition {
        var composition: AVMutableComposition
        var expectedDuration: CMTime
    }

    private static func buildComposition(inputURLs: [URL]) async throws -> BuiltComposition {
        let composition = AVMutableComposition()
        guard
            let compositionVideo = composition.addMutableTrack(
                withMediaType: .video,
                preferredTrackID: kCMPersistentTrackID_Invalid
            )
        else {
            throw JoinExporterError.cannotCreateComposition
        }

        var compositionAudio: AVMutableCompositionTrack?
        var cursor = CMTime.zero

        for url in inputURLs {
            try Task.checkCancellation()

            let asset = AVURLAsset(url: url)
            if let beforeBuildTracksLoadForTesting {
                try await beforeBuildTracksLoadForTesting()
            }
            let tracks: [AVAssetTrack]
            do {
                tracks = try await asset.load(.tracks)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw JoinExporterError.incompatible([
                    "file unreadable (\(url.lastPathComponent)): \(error.localizedDescription)",
                ])
            }

            try Task.checkCancellation()
            let videoTrack = try firstTrack(in: tracks, mediaType: .video)
            let duration: CMTime
            do {
                duration = try await asset.load(.duration)
            } catch is CancellationError {
                throw CancellationError()
            }
            let timeRange = CMTimeRange(start: .zero, duration: duration)

            do {
                try compositionVideo.insertTimeRange(timeRange, of: videoTrack, at: cursor)
            } catch {
                throw JoinExporterError.cannotCreateComposition
            }

            if let preferredTransform = try? await videoTrack.load(.preferredTransform) {
                compositionVideo.preferredTransform = preferredTransform
            }

            if let audioTrack = optionalTrack(in: tracks, mediaType: .audio) {
                if compositionAudio == nil {
                    compositionAudio = composition.addMutableTrack(
                        withMediaType: .audio,
                        preferredTrackID: kCMPersistentTrackID_Invalid
                    )
                }
                do {
                    try compositionAudio?.insertTimeRange(timeRange, of: audioTrack, at: cursor)
                } catch {
                    throw JoinExporterError.cannotCreateComposition
                }
            }

            cursor = CMTimeAdd(cursor, duration)
        }

        return BuiltComposition(composition: composition, expectedDuration: cursor)
    }

    private static func exportPassthrough(
        session: AVAssetExportSession,
        to tempURL: URL,
        progress: (@Sendable (Double) -> Void)?,
        lastReported: Double
    ) async throws {
        let progressTask = Task<Void, Never> {
            await monitorExportProgress(
                session: session,
                progress: progress,
                lastReported: lastReported
            )
        }

        do {
            try await session.export(to: tempURL, as: .mov)
            progressTask.cancel()
            _ = await progressTask.value
            reportProgress(1, to: progress, last: lastReported)
        } catch {
            progressTask.cancel()
            _ = await progressTask.value
            throw error
        }
    }

    /// Monitors passthrough export progress without moving backward.
    /// Uses `states(updateInterval:)` on macOS 15+; polls session progress on macOS 14.
    private static func monitorExportProgress(
        session: AVAssetExportSession,
        progress: (@Sendable (Double) -> Void)?,
        lastReported: Double
    ) async {
        if #available(macOS 15.0, *) {
            await monitorExportProgressWithStates(
                session: session,
                progress: progress,
                lastReported: lastReported
            )
        } else {
            await monitorExportProgressByPolling(
                session: session,
                progress: progress,
                lastReported: lastReported
            )
        }
    }

    @available(macOS 15.0, *)
    private static func monitorExportProgressWithStates(
        session: AVAssetExportSession,
        progress: (@Sendable (Double) -> Void)?,
        lastReported: Double
    ) async {
        var last = lastReported
        for await state in session.states(updateInterval: 0.05) {
            if Task.isCancelled { break }
            switch state {
            case .pending, .waiting:
                continue
            case .exporting(let exportProgress):
                let mapped = 0.05 + (max(0, min(1, exportProgress.fractionCompleted)) * 0.95)
                last = reportProgress(mapped, to: progress, last: last)
            @unknown default:
                continue
            }
        }
    }

    private static func monitorExportProgressByPolling(
        session: AVAssetExportSession,
        progress: (@Sendable (Double) -> Void)?,
        lastReported: Double
    ) async {
        var last = lastReported
        while !Task.isCancelled {
            let fraction = Double(session.progress)
            let mapped = 0.05 + (max(0, min(1, fraction)) * 0.95)
            last = reportProgress(mapped, to: progress, last: last)
            if fraction >= 1 { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    /// Moves the system-temp export into a job-specific staging URL beside the destination.
    private static func moveToDestinationStaging(
        from tempURL: URL,
        destination outputURL: URL,
        jobID: String
    ) throws -> URL {
        let fm = FileManager.default
        let parent = outputURL.deletingLastPathComponent()
        do {
            try fm.createDirectory(at: parent, withIntermediateDirectories: true)
            let stagingURL = parent.appendingPathComponent(
                ".movies-connector-staging-\(jobID).mov"
            )
            if fm.fileExists(atPath: stagingURL.path) {
                try fm.removeItem(at: stagingURL)
            }
            try fm.moveItem(at: tempURL, to: stagingURL)
            return stagingURL
        } catch {
            throw mapExportError(error)
        }
    }

    /// Commits a validated staging file to `outputURL` via same-volume rename/replace.
    ///
    /// Failure cleans only staging / an explicit backup created by this commit — never deletes
    /// `outputURL` merely because it exists (another process may own it).
    private static func commitStaging(from stagingURL: URL, to outputURL: URL) throws {
        let fm = FileManager.default
        let destinationExisted = fm.fileExists(atPath: outputURL.path)
        var backupURL: URL?

        do {
            if let afterDestinationExistenceCheckForTesting {
                try afterDestinationExistenceCheckForTesting(outputURL)
            }

            if let installExportForTesting {
                try installExportForTesting(stagingURL, outputURL)
                // Test hook owns the commit; drop leftover staging so only the destination remains.
                removeJobOutputIfPresent(stagingURL)
                return
            }

            if destinationExisted {
                let backupName = ".movies-connector-backup-\(UUID().uuidString)"
                let createdBackup = try fm.replaceItemAt(
                    outputURL,
                    withItemAt: stagingURL,
                    backupItemName: backupName,
                    options: []
                )
                backupURL = createdBackup
                if let createdBackup {
                    try? fm.removeItem(at: createdBackup)
                    backupURL = nil
                }
            } else {
                try fm.moveItem(at: stagingURL, to: outputURL)
            }
        } catch {
            // Own only staging + explicit backup. Never delete the final URL by existence alone.
            removeJobOutputIfPresent(stagingURL)
            if let backupURL, fm.fileExists(atPath: backupURL.path) {
                // Best-effort restore if replace left the original aside and failed afterward.
                if !fm.fileExists(atPath: outputURL.path) {
                    try? fm.moveItem(at: backupURL, to: outputURL)
                } else {
                    try? fm.removeItem(at: backupURL)
                }
            }
            throw mapExportError(error)
        }
    }

    private static func rejectCollidingOutput(outputURL: URL, inputURLs: [URL]) throws {
        for inputURL in inputURLs {
            if urlsReferToSameItem(outputURL, inputURL) {
                throw JoinExporterError.outputCollidesWithInput
            }
        }
    }

    /// Compares standardized paths, symlink-resolved paths, and file resource identifiers.
    private static func urlsReferToSameItem(_ lhs: URL, _ rhs: URL) -> Bool {
        let leftStandard = lhs.standardizedFileURL
        let rightStandard = rhs.standardizedFileURL
        if leftStandard.path == rightStandard.path {
            return true
        }

        let leftResolved = leftStandard.resolvingSymlinksInPath()
        let rightResolved = rightStandard.resolvingSymlinksInPath()
        if leftResolved.path == rightResolved.path {
            return true
        }

        let leftValues = try? leftStandard.resourceValues(forKeys: [.fileResourceIdentifierKey])
        let rightValues = try? rightStandard.resourceValues(forKeys: [.fileResourceIdentifierKey])
        if let leftID = leftValues?.fileResourceIdentifier,
           let rightID = rightValues?.fileResourceIdentifier,
           leftID.isEqual(rightID)
        {
            return true
        }

        // Also compare identifiers on symlink-resolved URLs when the unresolved pair missed.
        let leftResolvedValues = try? leftResolved.resourceValues(forKeys: [.fileResourceIdentifierKey])
        let rightResolvedValues = try? rightResolved.resourceValues(forKeys: [.fileResourceIdentifierKey])
        if let leftID = leftResolvedValues?.fileResourceIdentifier,
           let rightID = rightResolvedValues?.fileResourceIdentifier,
           leftID.isEqual(rightID)
        {
            return true
        }

        return false
    }

    private static func removeJobOutputIfPresent(_ url: URL) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return }
        try? fm.removeItem(at: url)
    }

    @discardableResult
    private static func reportProgress(
        _ value: Double,
        to handler: (@Sendable (Double) -> Void)?,
        last: Double?
    ) -> Double {
        let clamped = max(0, min(1, value))
        let next = max(last ?? 0, clamped)
        if last == nil || next > (last ?? 0) || next == 1 {
            handler?(next)
        }
        return next
    }

    private static func mapExportError(_ error: Error) -> JoinExporterError {
        if error is CancellationError {
            return .cancelled
        }
        if let joinError = error as? JoinExporterError {
            return joinError
        }
        if isDiskFull(error) {
            return .diskFull
        }
        return .exportFailed(error.localizedDescription)
    }

    private static func isDiskFull(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == AVFoundationErrorDomain,
           nsError.code == AVError.Code.diskFull.rawValue
        {
            return true
        }
        if nsError.domain == NSPOSIXErrorDomain, nsError.code == Int(ENOSPC) {
            return true
        }
        if nsError.domain == NSCocoaErrorDomain, nsError.code == NSFileWriteOutOfSpaceError {
            return true
        }
        for code in [NSUnderlyingErrorKey, NSMultipleUnderlyingErrorsKey] {
            if code == NSUnderlyingErrorKey, let underlying = nsError.userInfo[code] as? Error {
                if isDiskFull(underlying) { return true }
            }
            if code == NSMultipleUnderlyingErrorsKey,
               let underlyingErrors = nsError.userInfo[code] as? [Error]
            {
                if underlyingErrors.contains(where: isDiskFull) { return true }
            }
        }
        return false
    }

    private static func firstTrack(in tracks: [AVAssetTrack], mediaType: AVMediaType) throws -> AVAssetTrack {
        if let track = tracks.first(where: { $0.mediaType == mediaType }) {
            return track
        }
        throw JoinExporterError.exportFailed("Missing \(mediaType.rawValue) track")
    }

    private static func optionalTrack(in tracks: [AVAssetTrack], mediaType: AVMediaType) -> AVAssetTrack? {
        tracks.first(where: { $0.mediaType == mediaType })
    }
}
