import AppKit
import Foundation

@MainActor
final class JoinViewModel: ObservableObject {
    /// Ordered queue including in-flight drops (source of truth for join order — #20).
    @Published private(set) var entries: [JoinQueueEntry] = []
    @Published private(set) var outputURL: URL?
    @Published private(set) var isJoining = false
    @Published private(set) var joinProgress: Double = 0
    @Published private(set) var statusMessage: String?
    /// Most recently written join output; used for “Show in Finder”.
    @Published private(set) var lastJoinedURL: URL?
    /// Selectable / copyable drop + import diagnostics for debugging Finder drops.
    @Published private(set) var debugLog: String = ""

    private let inspector: any AssetInspecting
    private let videoSelector: any VideoFileSelecting
    private let outputSelector: any OutputDestinationSelecting
    private let exporter: any JoinExporting

    /// Per-item inspection generation; stale async completions are ignored.
    private var inspectionGenerations: [UUID: Int] = [:]
    /// Increments each time a join job is armed; selectors use this to ignore stale results.
    private var joinGeneration = 0
    /// ViewModel-owned join task so Cancel can cooperatively cancel the exporter.
    private var joinTask: Task<Void, Never>?
    /// In-flight Finder drop resolve tasks (#21).
    private var dropImportTasks: [UUID: Task<Void, Never>] = [:]
    /// When true, adding videos refreshes the default filename under Movies/Movies Connector.
    private var usesManagedDefaultOutput = false

    init(
        inspector: any AssetInspecting = DefaultAssetInspector(),
        videoSelector: any VideoFileSelecting = SystemVideoFileSelector(),
        outputSelector: any OutputDestinationSelecting = SystemOutputDestinationSelector(),
        exporter: any JoinExporting = DefaultJoinExporter()
    ) {
        self.inspector = inspector
        self.videoSelector = videoSelector
        self.outputSelector = outputSelector
        self.exporter = exporter
    }

    /// Materialized movies in queue order (pending rows skipped).
    var items: [JoinQueueItem] {
        entries.compactMap(\.asItem)
    }

    var pendingDropImports: [PendingDropImport] {
        entries.compactMap(\.asPending)
    }

    var canJoin: Bool {
        guard !isJoining else { return false }
        guard pendingDropImports.isEmpty else { return false }
        guard outputURL != nil else { return false }
        guard !items.isEmpty else { return false }
        return items.allSatisfy {
            if case .compatible = $0.compatibility { return true }
            return false
        }
    }

    var canCancelJoin: Bool {
        isJoining
    }

    /// True while any Finder drop is still resolving.
    var isImportingDrop: Bool {
        !pendingDropImports.isEmpty
    }

    /// Queue mutations stay enabled during drop import so additional videos can be dropped.
    var isMutationEnabled: Bool {
        !isJoining
    }

    var orderedInputURLs: [URL] {
        items.map(\.url)
    }

    /// Compact path for the output row (`~/Movies/...` instead of `/Users/…`).
    var outputDisplayPath: String {
        guard let outputURL else { return L10n.string("ui.output.none") }
        return Self.abbreviatedPath(for: outputURL)
    }

    /// Full filesystem path for tooltips / copy.
    var outputFullPath: String {
        outputURL?.path ?? L10n.string("ui.output.none")
    }

    var canRevealLastJoined: Bool {
        guard let lastJoinedURL else { return false }
        return FileManager.default.fileExists(atPath: lastJoinedURL.path)
    }

    /// Reveals the last successful join in Finder.
    func revealLastJoinedInFinder() {
        guard let lastJoinedURL, FileManager.default.fileExists(atPath: lastJoinedURL.path) else {
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([lastJoinedURL])
    }

    /// Reveals the current output file (or its folder if not written yet).
    func revealOutputInFinder() {
        guard let outputURL else { return }
        if FileManager.default.fileExists(atPath: outputURL.path) {
            NSWorkspace.shared.activateFileViewerSelecting([outputURL])
        } else {
            let folder = outputURL.deletingLastPathComponent()
            NSWorkspace.shared.open(folder)
        }
    }

    static func abbreviatedPath(for url: URL) -> String {
        let path = url.path
        let home = NSHomeDirectory()
        if path == home { return "~" }
        if path.hasPrefix(home + "/") {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    // MARK: - Default output (Movies / Movies Connector)

    /// First-run Allow dialog + collision-free default file under `~/Movies/Movies Connector/`.
    func prepareDefaultOutputIfNeeded() {
        guard outputURL == nil else { return }
        guard let directory = MoviesOutputAccess.requestDefaultDirectoryIfNeeded() else {
            return
        }
        outputURL = DefaultOutputDirectory.uniqueFileURL(
            in: directory,
            fileName: suggestedOutputName()
        )
        usesManagedDefaultOutput = true
    }

    // MARK: - Mutations

    func addVideos() async {
        guard isMutationEnabled else { return }
        let generationAtStart = joinGeneration
        let urls = await videoSelector.selectVideos()
        guard !isJoining, joinGeneration == generationAtStart else { return }
        addURLs(urls)
    }

    /// Reserves an ordered Loading… row. Call synchronously from `performDrop`.
    @discardableResult
    func beginDropImport(title: String? = nil) -> UUID {
        let pending = PendingDropImport(title: title ?? L10n.string("ui.dropped_video"))
        entries.append(.pending(pending))
        return pending.id
    }

    func updateDropImportTitle(id: UUID, title: String) {
        guard let index = entries.firstIndex(where: { $0.id == id }),
              case .pending(var pending) = entries[index]
        else { return }
        pending.title = title
        entries[index] = .pending(pending)
    }

    /// Binds the async drop-resolve task so Cancel can stop it (#21).
    func attachDropImportTask(id: UUID, task: Task<Void, Never>) {
        dropImportTasks[id] = task
    }

    /// Finishes one in-flight drop in place so join order matches drop order (#20).
    func completeDropImport(id: UUID, outcome: DropLoadOutcome) {
        dropImportTasks[id] = nil
        outcome.diagnostics.log("dropImportID=\(id)")

        guard let index = entries.firstIndex(where: { $0.id == id }),
              case .pending = entries[index]
        else {
            appendDebugLine("completeDropImport skipped id=\(id) (missing pending row)")
            publishDebugLog(from: outcome.diagnostics)
            return
        }

        let accepted = filterDroppedURLs(outcome.urls, diagnostics: outcome.diagnostics)

        if accepted.isEmpty {
            entries.remove(at: index)
            if outcome.timedOut {
                statusMessage = L10n.string("status.drop_timeout")
            }
            publishDebugLog(from: outcome.diagnostics)
            return
        }

        var replacement: [JoinQueueEntry] = []
        for url in accepted {
            let item = JoinQueueItem(url: url)
            inspectionGenerations[item.id] = 0
            replacement.append(.item(item))
            outcome.diagnostics.log("enqueue id=\(item.id) name=\(item.displayName)")
        }
        entries.replaceSubrange(index ... index, with: replacement)
        // Publish once after filter/enqueue so the UI transcript is complete (#23).
        publishDebugLog(from: outcome.diagnostics)
        recomputeCompatibility()
        refreshManagedDefaultOutputNameIfNeeded()
        for entry in replacement {
            if case .item(let item) = entry {
                startInspection(for: item.id)
            }
        }
    }

    /// User-dismissable pending import (#21).
    func cancelDropImport(id: UUID) {
        dropImportTasks[id]?.cancel()
        dropImportTasks[id] = nil
        entries.removeAll { $0.id == id }
        appendDebugLine("cancelDropImport id=\(id)")
    }

    func addDroppedURLs(_ urls: [URL]) {
        let diagnostics = DropDiagnostics()
        let accepted = filterDroppedURLs(urls, diagnostics: diagnostics)
        appendItems(accepted, diagnostics: diagnostics)
        // Publish after filter/enqueue so the transcript is complete (#23).
        publishDebugLog(from: diagnostics)
    }

    func addDroppedURLs(_ outcome: DropLoadOutcome) {
        let accepted = filterDroppedURLs(outcome.urls, diagnostics: outcome.diagnostics)
        appendItems(accepted, diagnostics: outcome.diagnostics)
        publishDebugLog(from: outcome.diagnostics)
    }

    func clearDebugLog() {
        debugLog = ""
    }

    func copyDebugLogToPasteboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(debugLog, forType: .string)
    }

    private func filterDroppedURLs(
        _ urls: [URL],
        diagnostics: DropDiagnostics
    ) -> [URL] {
        diagnostics.section("JoinViewModel.filterDroppedURLs")
        diagnostics.log("received URL count=\(urls.count)")
        for (index, url) in urls.enumerated() {
            diagnostics.log("[\(index)] \(url.path)")
        }

        guard !isJoining else {
            diagnostics.log("ABORT isJoining=true")
            return []
        }
        if urls.isEmpty {
            statusMessage = L10n.string("status.drop_empty")
            diagnostics.log("empty URL list — surfacing statusMessage")
            return []
        }
        let result = SecurityScopedAccess.withAccess(to: urls) {
            DroppedMovieURLFilter.filter(urls, diagnostics: diagnostics)
        }
        if !result.rejected.isEmpty {
            statusMessage = Self.dropRejectionMessage(result.rejected)
            diagnostics.log("statusMessage=\(statusMessage ?? "nil")")
        } else if !result.accepted.isEmpty {
            statusMessage = nil
        }
        return result.accepted
    }

    private func publishDebugLog(from diagnostics: DropDiagnostics) {
        let transcript = diagnostics.transcript
        guard !transcript.isEmpty else { return }
        if debugLog.isEmpty {
            debugLog = transcript
        } else {
            debugLog += "\n\n" + transcript
        }
    }

    private func appendDebugLine(_ message: String) {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let line = "[\(formatter.string(from: Date()))] \(message)"
        if debugLog.isEmpty {
            debugLog = line
        } else {
            debugLog += "\n" + line
        }
        NSLog("[MoviesConnector] %@", message)
    }

    func addURLs(_ urls: [URL]) {
        appendItems(urls, diagnostics: nil)
    }

    private func appendItems(_ urls: [URL], diagnostics: DropDiagnostics?) {
        guard !isJoining else { return }
        guard !urls.isEmpty else { return }
        diagnostics?.section("Enqueue")
        var appended: [JoinQueueItem] = []
        for url in urls {
            let item = JoinQueueItem(url: url)
            diagnostics?.log("enqueue id=\(item.id) name=\(item.displayName)")
            appended.append(item)
            inspectionGenerations[item.id] = 0
            entries.append(.item(item))
        }
        recomputeCompatibility()
        refreshManagedDefaultOutputNameIfNeeded()
        for item in appended {
            startInspection(for: item.id)
        }
    }

    func removeItem(id: UUID) {
        guard isMutationEnabled else { return }
        entries.removeAll { $0.id == id }
        inspectionGenerations[id] = nil
        recomputeCompatibility()
        refreshManagedDefaultOutputNameIfNeeded()
    }

    func moveEntries(from source: IndexSet, to destination: Int) {
        guard isMutationEnabled else { return }
        entries.move(fromOffsets: source, toOffset: destination)
        recomputeCompatibility()
        refreshManagedDefaultOutputNameIfNeeded()
    }

    /// Backward-compatible reorder API used by older tests (items-only queues).
    func moveItems(from source: IndexSet, to destination: Int) {
        guard pendingDropImports.isEmpty else {
            moveEntries(from: source, to: destination)
            return
        }
        var itemEntries = entries
        itemEntries.move(fromOffsets: source, toOffset: destination)
        entries = itemEntries
        recomputeCompatibility()
        refreshManagedDefaultOutputNameIfNeeded()
    }

    func chooseOutputDestination() async {
        guard isMutationEnabled else { return }
        let generationAtStart = joinGeneration
        let suggested = suggestedOutputName()
        if let url = await outputSelector.selectOutputDestination(suggestedName: suggested) {
            guard !isJoining, joinGeneration == generationAtStart else { return }
            outputURL = url
            usesManagedDefaultOutput = DefaultOutputDirectory.isInsideManagedDirectory(url)
            statusMessage = nil
        }
    }

    func setOutputURLForTesting(_ url: URL?) {
        guard !isJoining else { return }
        outputURL = url
        usesManagedDefaultOutput = url.map(DefaultOutputDirectory.isInsideManagedDirectory) ?? false
    }

    private func refreshManagedDefaultOutputNameIfNeeded() {
        guard usesManagedDefaultOutput else { return }
        guard let directory = DefaultOutputDirectory.managedDirectoryURL() else { return }
        outputURL = DefaultOutputDirectory.uniqueFileURL(
            in: directory,
            fileName: suggestedOutputName()
        )
    }

    // MARK: - Join

    func startJoin() {
        guard let job = armJoinJob() else { return }
        joinTask?.cancel()
        joinTask = Task { [weak self] in
            await self?.performJoin(job)
            await MainActor.run { self?.joinTask = nil }
        }
    }

    func cancelJoin() {
        joinTask?.cancel()
    }

    func join() async {
        guard let job = armJoinJob() else { return }
        await performJoin(job)
    }

    // MARK: - Compatibility

    func recomputeCompatibility() {
        let materialized = items
        let reference = materialized.first?.signature
        let firstCompatibility = materialized.first?.compatibility

        for index in entries.indices {
            guard case .item(var item) = entries[index] else { continue }
            guard let signature = item.signature else {
                if case .failed = item.compatibility {
                    continue
                }
                if case .incompatible = item.compatibility {
                    continue
                }
                item.compatibility = .inspecting
                entries[index] = .item(item)
                continue
            }

            guard let reference else {
                if case .failed(let reason) = firstCompatibility {
                    item.compatibility = .failed(
                        reason: L10n.string("status.reference_unusable \(reason)")
                    )
                } else if case .incompatible(let mismatches) = firstCompatibility {
                    let reason = mismatches.map(\.localizedDescription).joined(separator: "; ")
                    item.compatibility = .failed(
                        reason: L10n.string("status.reference_unusable \(reason)")
                    )
                } else {
                    item.compatibility = .inspecting
                }
                entries[index] = .item(item)
                continue
            }

            let mismatches = CompatibilityComparer.mismatches(between: reference, and: signature)
            if mismatches.isEmpty {
                item.compatibility = .compatible
            } else {
                item.compatibility = .incompatible(mismatches: mismatches)
            }
            entries[index] = .item(item)
        }
    }

    // MARK: - Inspection

    private func startInspection(for id: UUID) {
        let generation = (inspectionGenerations[id] ?? 0) + 1
        inspectionGenerations[id] = generation

        guard let url = items.first(where: { $0.id == id })?.url else { return }

        Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await self.inspector.inspect(url: url)
                self.applyInspectionSuccess(id: id, generation: generation, result: result)
            } catch {
                self.applyInspectionFailure(id: id, generation: generation, error: error)
            }
        }
    }

    private func applyInspectionSuccess(id: UUID, generation: Int, result: JoinInspectionResult) {
        guard inspectionGenerations[id] == generation else { return }
        guard let index = entries.firstIndex(where: { $0.id == id }),
              case .item(var item) = entries[index]
        else { return }
        item.duration = result.duration
        item.signature = result.signature
        entries[index] = .item(item)
        appendDebugLine(
            "inspect OK id=\(id) duration=\(result.duration)"
        )
        recomputeCompatibility()
    }

    private func applyInspectionFailure(id: UUID, generation: Int, error: Error) {
        guard inspectionGenerations[id] == generation else { return }
        guard let index = entries.firstIndex(where: { $0.id == id }),
              case .item(var item) = entries[index]
        else { return }
        item.duration = nil
        item.signature = nil
        item.compatibility = .failed(reason: error.localizedDescription)
        entries[index] = .item(item)
        appendDebugLine("inspect FAIL id=\(id): \(error.localizedDescription)")
        recomputeCompatibility()
    }

    private func armJoinJob() -> JoinJobSnapshot? {
        // #18: never arm a join that would replace an existing managed default without bumping.
        if usesManagedDefaultOutput,
           let outputURL,
           FileManager.default.fileExists(atPath: outputURL.path),
           let directory = DefaultOutputDirectory.managedDirectoryURL()
        {
            self.outputURL = DefaultOutputDirectory.uniqueFileURL(
                in: directory,
                fileName: suggestedOutputName()
            )
        }

        guard canJoin, let outputURL else { return nil }
        let snapshot = JoinJobSnapshot(
            inputs: orderedInputURLs,
            inputCount: items.count,
            outputURL: outputURL,
            generation: joinGeneration &+ 1
        )
        joinGeneration = snapshot.generation
        isJoining = true
        joinProgress = 0
        statusMessage = nil
        lastJoinedURL = nil
        return snapshot
    }

    private func performJoin(_ job: JoinJobSnapshot) async {
        defer {
            if joinGeneration == job.generation {
                isJoining = false
            }
        }

        do {
            let writtenURL = try await exporter.join(
                inputURLs: job.inputs,
                outputURL: job.outputURL,
                replaceExistingDestination: !usesManagedDefaultOutput
            ) { [weak self] value in
                Task { @MainActor in
                    guard let self, self.joinGeneration == job.generation else { return }
                    if value >= self.joinProgress {
                        self.joinProgress = value
                    }
                }
            }
            guard joinGeneration == job.generation else { return }
            joinProgress = 1
            lastJoinedURL = writtenURL
            if usesManagedDefaultOutput {
                outputURL = writtenURL
            }
            statusMessage = L10n.string(
                "status.joined \(Int64(job.inputCount)) \(writtenURL.lastPathComponent)"
            )
            // Next join must not overwrite the file we just wrote (#18).
            refreshManagedDefaultOutputNameIfNeeded()
        } catch is CancellationError {
            guard joinGeneration == job.generation else { return }
            lastJoinedURL = nil
            statusMessage = JoinExporterError.cancelled.errorDescription
        } catch let error as JoinExporterError where error == .cancelled {
            guard joinGeneration == job.generation else { return }
            lastJoinedURL = nil
            statusMessage = error.errorDescription
        } catch {
            guard joinGeneration == job.generation else { return }
            lastJoinedURL = nil
            statusMessage = error.localizedDescription
        }
    }

    private struct JoinJobSnapshot {
        var inputs: [URL]
        var inputCount: Int
        var outputURL: URL
        var generation: Int
    }

    private func suggestedOutputName() -> String {
        if let first = items.first?.displayName {
            let base = (first as NSString).deletingPathExtension
            return "\(base)-joined.mov"
        }
        return "joined.mov"
    }

    private static func dropRejectionMessage(
        _ rejected: [DroppedMovieURLFilter.Rejection]
    ) -> String {
        let parts = rejected.map { rejection in
            let name = rejection.url.isFileURL
                ? rejection.url.lastPathComponent
                : rejection.url.absoluteString
            let reason = rejection.reason.errorDescription ?? L10n.string("status.rejected")
            return "\(name): \(reason)"
        }
        if parts.count == 1 {
            return L10n.string("status.skip_one \(parts[0])")
        }
        return L10n.string(
            "status.skip_many \(Int64(parts.count)) \(parts.joined(separator: "; "))"
        )
    }
}
