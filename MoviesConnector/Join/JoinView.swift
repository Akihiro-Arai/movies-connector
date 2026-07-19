import SwiftUI

/// Minimal single-window shell for v1. Feature UI lands in later issues.
struct JoinView: View {
    @StateObject private var viewModel = JoinViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Movies Connector")
                .font(.largeTitle.weight(.semibold))

            Text("Lossless passthrough join via AVFoundation. Add/reorder/export UI arrives in follow-up issues.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text(viewModel.statusText)
                .font(.body.monospaced())
                .textSelection(.enabled)

            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(minWidth: 560, minHeight: 360)
        .onAppear {
            viewModel.refreshStatus()
        }
    }
}

#Preview {
    JoinView()
}
