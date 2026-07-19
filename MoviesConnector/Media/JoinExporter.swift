import AVFoundation
import Foundation

enum JoinExporterError: Error, LocalizedError, Equatable {
    case emptyInput
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

    /// Joins `inputURLs` in exact caller order to `outputURL` using passthrough export.
    ///
    /// - Acquires inputs + output through `UserSelectedURLAccess.withPreparedAccess`
    /// - Re-runs batch compatibility preflight before composition; refuses on failure
    /// - Writes to a job-owned temp file, then replaces/moves into `outputURL` only on success
    /// - On cancel/failure, removes only this job's partial temp output (never inputs / untouched destinations)
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

        return try await UserSelectedURLAccess.withPreparedAccess(to: scoped) {
            try await joinWithPreparedAccess(
                inputURLs: inputURLs,
                outputURL: outputURL,
                progress: progress
            )
        }
    }

    /// Immediate preflight before export — reuses `AssetInspector` row-addressable results.
    static func preflightCompatibility(inputURLs: [URL]) async throws {
        let report = await AssetInspector.preflight(urls: inputURLs)
        guard report.canExport else {
            throw JoinExporterError.incompatible(report.formattedReasons)
        }
    }

    // MARK: - Prepared-access body

    private static func joinWithPreparedAccess(
        inputURLs: [URL],
        outputURL: URL,
        progress: (@Sendable (Double) -> Void)?
    ) async throws -> Result {
        reportProgress(0, to: progress, last: nil)

        try Task.checkCancellation()
        try await preflightCompatibility(inputURLs: inputURLs)
        var lastProgress = reportProgress(0.02, to: progress, last: 0)

        try Task.checkCancellation()
        let built = try await buildComposition(inputURLs: inputURLs)
        lastProgress = reportProgress(0.05, to: progress, last: lastProgress)

        guard
            let exportSession = AVAssetExportSession(
                asset: built.composition,
                presetName: AVAssetExportPresetPassthrough
            )
        else {
            throw JoinExporterError.cannotCreateExportSession
        }

        exportSession.shouldOptimizeForNetworkUse = false

        let jobID = UUID().uuidString
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("movies-connector-job-\(jobID).mov")
        // Only this job's temp output is eligible for cleanup — never inputs or an unmanaged destination.
        defer { removeJobOutputIfPresent(tempURL) }

        let started = DispatchTime.now().uptimeNanoseconds
        do {
            try await exportPassthrough(
                session: exportSession,
                to: tempURL,
                progress: progress,
                lastReported: lastProgress
            )
        } catch is CancellationError {
            throw JoinExporterError.cancelled
        } catch let error as JoinExporterError {
            throw error
        } catch {
            throw mapExportError(error)
        }

        try Task.checkCancellation()
        try installExport(from: tempURL, to: outputURL)

        let outputDuration = try await AVURLAsset(url: outputURL).load(.duration)
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
            let tracks: [AVAssetTrack]
            do {
                tracks = try await asset.load(.tracks)
            } catch {
                throw JoinExporterError.incompatible([
                    "file unreadable (\(url.lastPathComponent)): \(error.localizedDescription)",
                ])
            }

            let videoTrack = try firstTrack(in: tracks, mediaType: .video)
            let duration = try await asset.load(.duration)
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

    /// Atomically replace an existing destination, or move into place when absent.
    /// A pre-existing destination is untouched until this successful install step.
    private static func installExport(from tempURL: URL, to outputURL: URL) throws {
        let fm = FileManager.default
        do {
            if fm.fileExists(atPath: outputURL.path) {
                _ = try fm.replaceItemAt(outputURL, withItemAt: tempURL)
            } else {
                let parent = outputURL.deletingLastPathComponent()
                try fm.createDirectory(at: parent, withIntermediateDirectories: true)
                try fm.moveItem(at: tempURL, to: outputURL)
            }
        } catch {
            throw mapExportError(error)
        }
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
