import SwiftUI
import UniformTypeIdentifiers

/// Single-window join queue: add/drop, reorder, delete, output, Join.
struct JoinView: View {
    @ObservedObject var viewModel: JoinViewModel

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
        }
        .padding(24)
        .frame(minWidth: 640, minHeight: 420)
        .onDrop(of: [UTType.fileURL], isTargeted: nil, perform: handleDrop(providers:))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Movies Connector")
                .font(.largeTitle.weight(.semibold))
            Text("Drop videos here or add them below. Order in the list is the join order.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private var queueList: some View {
        Group {
            if viewModel.items.isEmpty {
                emptyDropTarget
            } else {
                List {
                    ForEach(viewModel.items) { item in
                        JoinQueueRow(item: item) {
                            viewModel.removeItem(id: item.id)
                        }
                    }
                    .onMove(perform: viewModel.moveItems)
                }
                .listStyle(.inset)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(
                    .quaternary,
                    style: StrokeStyle(lineWidth: 1, dash: viewModel.items.isEmpty ? [6] : [])
                )
        }
    }

    private var emptyDropTarget: some View {
        VStack(spacing: 8) {
            Image(systemName: "film.stack")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.secondary)
            Text("Drop videos from Finder")
                .font(.headline)
            Text("or use Add Videos")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Drop videos from Finder or use Add Videos")
    }

    private var outputRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("Output")
                .font(.headline)
            Text(viewModel.outputDisplayPath)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(viewModel.outputURL == nil ? .secondary : .primary)
                .textSelection(.enabled)
                .help(viewModel.outputDisplayPath)
                .accessibilityLabel("Output destination: \(viewModel.outputDisplayPath)")
            Spacer(minLength: 8)
            Button("Choose…") {
                Task { await viewModel.chooseOutputDestination() }
            }
            .accessibilityLabel("Choose output destination")
        }
    }

    private var actionsRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            if viewModel.isJoining {
                ProgressView(value: viewModel.joinProgress, total: 1)
                    .accessibilityLabel("Join progress")
                    .accessibilityValue("\(Int((viewModel.joinProgress * 100).rounded())) percent")
            }

            HStack {
                Button("Add Videos") {
                    Task { await viewModel.addVideos() }
                }
                .keyboardShortcut("o", modifiers: [.command])
                .disabled(viewModel.isJoining)

                Spacer()

                if viewModel.canCancelJoin {
                    Button("Cancel") {
                        viewModel.cancelJoin()
                    }
                    .accessibilityLabel("Cancel join")
                }

                Button("Join") {
                    viewModel.startJoin()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!viewModel.canJoin)
                .accessibilityLabel("Join videos")
                .accessibilityHint(
                    viewModel.canJoin
                        ? "Starts lossless passthrough join"
                        : "Disabled until the queue is ready"
                )
            }
        }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        Task {
            var collected: [URL] = []
            for provider in providers {
                if let url = await Self.loadFileURL(from: provider) {
                    collected.append(url)
                }
            }
            await MainActor.run {
                viewModel.addDroppedURLs(collected)
            }
        }
        return true
    }

    private static func loadFileURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                if let data = item as? Data,
                   let url = URL(dataRepresentation: data, relativeTo: nil)
                {
                    continuation.resume(returning: url)
                } else if let url = item as? URL {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}

private struct JoinQueueRow: View {
    let item: JoinQueueItem
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
                .accessibilityLabel("Duration \(DurationFormatting.string(from: item.duration))")

            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Remove from queue")
            .accessibilityLabel("Remove \(item.displayName)")
        }
        .padding(.vertical, 2)
    }

    private var compatibilityLabel: String {
        switch item.compatibility {
        case .inspecting:
            return "Inspecting…"
        case .compatible:
            return "Compatible"
        case .incompatible(let reason):
            return "Incompatible — \(reason)"
        }
    }

    private var compatibilityColor: Color {
        switch item.compatibility {
        case .inspecting:
            return .secondary
        case .compatible:
            return .green
        case .incompatible:
            return .red
        }
    }

    private var accessibilitySummary: String {
        let duration = DurationFormatting.string(from: item.duration)
        switch item.compatibility {
        case .inspecting:
            return "\(item.displayName), duration \(duration), inspecting"
        case .compatible:
            return "\(item.displayName), duration \(duration), compatible"
        case .incompatible(let reason):
            return "\(item.displayName), duration \(duration), incompatible: \(reason)"
        }
    }
}

#Preview {
    JoinView(viewModel: JoinViewModel())
}
