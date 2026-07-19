import SwiftUI

@main
struct MoviesConnectorApp: App {
    @StateObject private var joinViewModel = JoinViewModel()
    @ObservedObject private var settings = AppSettings.shared

    var body: some Scene {
        // Single unique window (not WindowGroup) so users cannot open multiples.
        Window("Movies Connector", id: "main") {
            JoinView(viewModel: joinViewModel)
                .environmentObject(settings)
                .environment(\.locale, settings.effectiveLocale)
        }
        .defaultSize(width: 720, height: 560)
        .windowResizability(.contentMinSize)

        Settings {
            SettingsView()
                .environmentObject(settings)
                .environment(\.locale, settings.effectiveLocale)
        }
    }
}
