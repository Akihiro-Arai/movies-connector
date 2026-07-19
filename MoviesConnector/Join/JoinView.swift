import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Single-window join queue: add/drop, reorder, delete, output, Join.
struct JoinView: View {
    @ObservedObject var viewModel: JoinViewModel
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            queueList
            outputRow
            actionsRow

            if let status = viewModel.statusMessage {
                Text(status)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .accessibilityLabel(status)
            }

            debugLogPanel
        }
        .padding(24)
        .frame(minWidth: 720, minHeight: 560)
        .environment(\.locale, settings.effectiveLocale)
        // String identifiers include Photos file-promise pasteboard types that UTType may omit.
        .onDrop(
            of: MovieDropItemLoader.dropAcceptedTypeIdentifiers,
            delegate: JoinDropDelegate(viewModel: viewModel)
        )
        .task {
            viewModel.prepareDefaultOutputIfNeeded()
        }
        .onChange(of: settings.language) { _, _ in
            // Re-localize row reasons stored from the previous language (#22).
            viewModel.recomputeCompatibility()
        }
        .id(settings.language)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("app.name")
                .font(.largeTitle.weight(.semibold))
            Text("ui.subtitle")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private var queueList: some View {
        Group {
            if viewModel.entries.isEmpty {
                emptyDropTarget
            } else {
                List {
                    ForEach(viewModel.entries) { entry in
                        switch entry {
                        case .pending(let pending):
                            PendingDropImportRow(pending: pending) {
                                viewModel.cancelDropImport(id: pending.id)
                            }
                        case .item(let item):
                            JoinQueueRow(
                                item: item,
                                isMutationEnabled: viewModel.isMutationEnabled
                            ) {
                                viewModel.removeItem(id: item.id)
                            }
                        }
                    }
                    .onMove { source, destination in
                        viewModel.moveEntries(from: source, to: destination)
                    }
                }
                .listStyle(.inset)
                .disabled(viewModel.isJoining)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(
                    .quaternary,
                    style: StrokeStyle(
                        lineWidth: 1,
                        dash: viewModel.entries.isEmpty ? [6] : []
                    )
                )
        }
    }

    private var emptyDropTarget: some View {
        VStack(spacing: 8) {
            Image(systemName: "film.stack")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.secondary)
            Text("ui.empty.title")
                .font(.headline)
            Text("ui.empty.hint")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("ui.empty.a11y"))
    }

    private var outputRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("ui.output")
                .font(.headline)
            Text(viewModel.outputDisplayPath)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(viewModel.outputURL == nil ? .secondary : .primary)
                .textSelection(.enabled)
                .help(viewModel.outputDisplayPath)
                .accessibilityLabel(
                    Text("ui.output.a11y \(viewModel.outputDisplayPath)")
                )
            Spacer(minLength: 8)
            Button("ui.choose") {
                Task { await viewModel.chooseOutputDestination() }
            }
            .disabled(!viewModel.isMutationEnabled)
            .accessibilityLabel(Text("ui.choose.a11y"))
        }
    }

    private var actionsRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            if viewModel.isJoining {
                ProgressView(value: viewModel.joinProgress, total: 1)
                    .accessibilityLabel(Text("ui.progress.a11y"))
                    .accessibilityValue(
                        Text(
                            "ui.progress.value \(Int64((viewModel.joinProgress * 100).rounded()))"
                        )
                    )
            }

            HStack {
                Button("ui.add_videos") {
                    Task { await viewModel.addVideos() }
                }
                .keyboardShortcut("o", modifiers: [.command])
                .disabled(!viewModel.isMutationEnabled)

                Spacer()

                if viewModel.canCancelJoin {
                    Button("ui.cancel") {
                        viewModel.cancelJoin()
                    }
                    .accessibilityLabel(Text("ui.cancel.a11y"))
                }

                Button("ui.join") {
                    viewModel.startJoin()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!viewModel.canJoin)
                .accessibilityLabel(Text("ui.join.a11y"))
                .accessibilityHint(
                    Text(viewModel.canJoin ? "ui.join.hint.enabled" : "ui.join.hint.disabled")
                )
            }
        }
    }

    private var debugLogPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("ui.debug.title")
                    .font(.headline)
                Spacer()
                Button("ui.debug.copy") {
                    viewModel.copyDebugLogToPasteboard()
                }
                .disabled(viewModel.debugLog.isEmpty)
                Button("ui.debug.clear") {
                    viewModel.clearDebugLog()
                }
                .disabled(viewModel.debugLog.isEmpty)
            }

            ScrollView {
                Group {
                    if viewModel.debugLog.isEmpty {
                        Text("ui.debug.placeholder")
                    } else {
                        Text(viewModel.debugLog)
                    }
                }
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(viewModel.debugLog.isEmpty ? .secondary : .primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(8)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .frame(minHeight: 140, maxHeight: 220)
        }
    }
}

/// Accepts Finder file URLs and Photos `NSFilePromiseReceiver` drops.
/// Multiple drops can run concurrently — each gets its own pending Loading… row.
private struct JoinDropDelegate: DropDelegate {
    let viewModel: JoinViewModel

    func validateDrop(info: DropInfo) -> Bool {
        guard !viewModel.isJoining else { return false }
        if MovieDropItemLoader.dragPasteboardHasFilePromises() {
            return true
        }
        let providers = info.itemProviders(for: MovieDropItemLoader.dropAcceptedTypeIdentifiers)
        return !providers.isEmpty
    }

    func performDrop(info: DropInfo) -> Bool {
        let diagnostics = DropDiagnostics()
        diagnostics.section("JoinDropDelegate.performDrop")
        diagnostics.log(
            "isJoining=\(viewModel.isJoining) pendingImports=\(viewModel.pendingDropImports.count)"
        )

        guard !viewModel.isJoining else {
            diagnostics.log("ABORT drop while joining")
            return false
        }

        // Placeholder row immediately so the next video can be dropped while this one loads.
        let importID = viewModel.beginDropImport()

        // Must snapshot promises before this function returns — drag pasteboard clears after.
        let promiseReceivers = MovieDropItemLoader.snapshotFilePromiseReceiversFromDragPasteboard(
            diagnostics: diagnostics
        )
        let providers = info.itemProviders(for: MovieDropItemLoader.dropAcceptedTypeIdentifiers)
        diagnostics.log("itemProviders count=\(providers.count)")
        diagnostics.log(
            "acceptedTypeIdentifiers=\(MovieDropItemLoader.dropAcceptedTypeIdentifiers.joined(separator: ", "))"
        )

        if let suggested = promiseReceivers.lazy
            .compactMap({ $0.fileNames.first })
            .first(where: { !$0.isEmpty })
        {
            viewModel.updateDropImportTitle(id: importID, title: suggested)
        }

        guard !promiseReceivers.isEmpty || !providers.isEmpty else {
            diagnostics.log("ABORT no promise receivers and no providers")
            viewModel.completeDropImport(
                id: importID,
                outcome: DropLoadOutcome(urls: [], diagnostics: diagnostics)
            )
            return false
        }

        let task = Task {
            let outcome = await MovieDropItemLoader.loadURLsFromCurrentDrop(
                providers: providers,
                promiseReceivers: promiseReceivers,
                diagnostics: diagnostics
            )
            await MainActor.run {
                viewModel.completeDropImport(id: importID, outcome: outcome)
            }
        }
        viewModel.attachDropImportTask(id: importID, task: task)
        return true
    }
}

private struct PendingDropImportRow: View {
    let pending: PendingDropImport
    let onCancel: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(pending.title)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("ui.loading")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(pending.title), \(L10n.string("ui.loading"))")

            Spacer(minLength: 8)

            Text("—")
                .font(.body.monospacedDigit())
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            Button(role: .destructive, action: onCancel) {
                Image(systemName: "xmark.circle")
            }
            .buttonStyle(.borderless)
            .help(Text("ui.drop.cancel.help"))
            .accessibilityLabel(Text("ui.drop.cancel.a11y \(pending.title)"))
        }
        .padding(.vertical, 2)
    }
}

private struct JoinQueueRow: View {
    let item: JoinQueueItem
    var isMutationEnabled: Bool = true
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayName)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                    .help(item.url.path)
                Text(compatibilityLabel)
                    .font(.caption)
                    .foregroundStyle(compatibilityColor)
                    .lineLimit(2)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilitySummary)

            Spacer(minLength: 8)

            Text(DurationFormatting.string(from: item.duration))
                .font(.body.monospacedDigit())
                .foregroundStyle(.secondary)

            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .disabled(!isMutationEnabled)
            .help(Text("ui.remove.help"))
            .accessibilityLabel(Text("ui.remove.a11y \(item.displayName)"))
        }
        .padding(.vertical, 2)
    }

    private var compatibilityLabel: String {
        switch item.compatibility {
        case .inspecting:
            return L10n.string("ui.status.inspecting")
        case .compatible:
            return L10n.string("ui.status.compatible")
        case .incompatible, .failed:
            let reason = item.compatibility.localizedReasonText ?? ""
            return L10n.string("ui.status.incompatible \(reason)")
        }
    }

    private var compatibilityColor: Color {
        switch item.compatibility {
        case .inspecting:
            return .secondary
        case .compatible:
            return .green
        case .incompatible, .failed:
            return .red
        }
    }

    private var accessibilitySummary: String {
        let duration = DurationFormatting.string(from: item.duration)
        switch item.compatibility {
        case .inspecting:
            return "\(item.displayName), \(duration), \(L10n.string("ui.status.inspecting"))"
        case .compatible:
            return "\(item.displayName), \(duration), \(L10n.string("ui.status.compatible"))"
        case .incompatible, .failed:
            let reason = item.compatibility.localizedReasonText ?? ""
            return "\(item.displayName), \(duration), \(L10n.string("ui.status.incompatible \(reason)"))"
        }
    }
}

#Preview {
    JoinView(viewModel: JoinViewModel())
        .environmentObject(AppSettings.shared)
}
