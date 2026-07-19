import SwiftUI

@main
struct MoviesConnectorApp: App {
    var body: some Scene {
        WindowGroup {
            JoinView()
        }
        .defaultSize(width: 720, height: 480)
        .windowResizability(.contentMinSize)
    }
}
