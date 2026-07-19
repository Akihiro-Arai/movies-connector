import SwiftUI

@main
struct MoviesConnectorApp: App {
    var body: some Scene {
        // Single unique window (not WindowGroup) so users cannot open multiples.
        Window("Movies Connector", id: "main") {
            JoinView()
        }
        .defaultSize(width: 720, height: 480)
        .windowResizability(.contentMinSize)
    }
}
