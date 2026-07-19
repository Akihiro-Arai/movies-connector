import SwiftUI

@main
struct MoviesConnectorApp: App {
    @StateObject private var joinViewModel = JoinViewModel()

    var body: some Scene {
        // Single unique window (not WindowGroup) so users cannot open multiples.
        Window("Movies Connector", id: "main") {
            JoinView(viewModel: joinViewModel)
        }
        .defaultSize(width: 720, height: 480)
        .windowResizability(.contentMinSize)
    }
}
