import Foundation

@MainActor
final class JoinViewModel: ObservableObject {
    @Published private(set) var statusText: String = "Loading…"

    func refreshStatus() {
        statusText = """
        Spike ready.
        Engine: AVMutableComposition + AVAssetExportSession
        Preset: AVAssetExportPresetPassthrough
        Output: QuickTime Movie (.mov)
        Sandbox: user-selected read/write only
        """
    }
}
