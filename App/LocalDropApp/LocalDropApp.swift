import SwiftUI
import FeatureTransfer

@main
struct LocalDropApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .defaultSize(width: 1120, height: 704)
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unified)

        MenuBarExtra("LocalDrop", systemImage: "paperplane") {
            EmptyView()
        }
    }
}
