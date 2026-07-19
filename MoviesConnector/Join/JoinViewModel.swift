import Foundation

@MainActor
final class JoinViewModel: ObservableObject {
    @Published private(set) var items: [JoinQueueItem] = []
    @Published private(set) var outputURL: URL?
    @Published private(set) var isJoining = false
    @Published private(set) var statusMessage: String?

    private let inspector: any AssetInspecting
    private let videoSelector: any VideoFileSelecting
    private let outputSelector: any OutputDestinationSelecting
    private let exporter: any JoinExporting

    /// Per-item inspection generation; stale async completions are ignored.
    private var inspectionGenerations: [UUID: Int] = [:]

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

    var canJoin: Bool {
        guard !isJoining else { return false }
        guard outputURL != nil else { return false }
        guard !items.isEmpty else { return false }
        return items.allSatisfy { $0.compatibility == .compatible }
    }

    var orderedInputURLs: [URL] {
        items.map(\.url)
    }

    var outputDisplayPath: String {
        outputURL?.path ?? "No output selected"
    }

    // MARK: - Mutations

    func addVideos() async {
        let urls = await videoSelector.selectVideos()
        addURLs(urls)
    }

    func addURLs(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        var appended: [JoinQueueItem] = []
        for url in urls {
            let item = JoinQueueItem(url: url)
            appended.append(item)
            inspectionGenerations[item.id] = 0
        }
        items.append(contentsOf: appended)
        recomputeCompatibility()
        for item in appended {
            startInspection(for: item.id)
        }
    }

    func removeItem(id: UUID) {
        items.removeAll { $0.id == id }
        inspectionGenerations[id] = nil
        recomputeCompatibility()
    }

    func moveItems(from source: IndexSet, to destination: Int) {
        items.move(fromOffsets: source, toOffset: destination)
        recomputeCompatibility()
    }

    func chooseOutputDestination() async {
        let suggested = suggestedOutputName()
        if let url = await outputSelector.selectOutputDestination(suggestedName: suggested) {
            outputURL = url
            statusMessage = nil
        }
    }

    func setOutputURLForTesting(_ url: URL?) {
        outputURL = url
    }

    func join() async {
        guard canJoin, let outputURL else { return }
        isJoining = true
        statusMessage = nil
        defer { isJoining = false }

        do {
            try await exporter.join(inputURLs: orderedInputURLs, outputURL: outputURL)
            statusMessage = "Joined \(items.count) video(s) → \(outputURL.lastPathComponent)"
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    // MARK: - Compatibility

    /// Recomputes per-row compatibility from cached signatures after reorder/delete/add.
    /// Items still awaiting inspection stay `.inspecting`. Inspection failures keep their reason.
    func recomputeCompatibility() {
        let reference = items.first?.signature
        let firstCompatibility = items.first?.compatibility

        for index in items.indices {
            guard let signature = items[index].signature else {
                if case .incompatible = items[index].compatibility {
                    continue
                }
                items[index].compatibility = .inspecting
                continue
            }

            guard let reference else {
                if case .incompatible(let reason) = firstCompatibility {
                    items[index].compatibility = .incompatible(
                        reason: "Reference item unusable: \(reason)"
                    )
                } else {
                    items[index].compatibility = .inspecting
                }
                continue
            }

            let mismatches = CompatibilityComparer.mismatches(between: reference, and: signature)
            if mismatches.isEmpty {
                items[index].compatibility = .compatible
            } else {
                items[index].compatibility = .incompatible(
                    reason: mismatches.map(\.description).joined(separator: "; ")
                )
            }
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
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].duration = result.duration
        items[index].signature = result.signature
        recomputeCompatibility()
    }

    private func applyInspectionFailure(id: UUID, generation: Int, error: Error) {
        guard inspectionGenerations[id] == generation else { return }
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].duration = nil
        items[index].signature = nil
        items[index].compatibility = .incompatible(reason: error.localizedDescription)
        recomputeCompatibility()
    }

    private func suggestedOutputName() -> String {
        if let first = items.first?.displayName {
            let base = (first as NSString).deletingPathExtension
            return "\(base)-joined.mov"
        }
        return "joined.mov"
    }
}
