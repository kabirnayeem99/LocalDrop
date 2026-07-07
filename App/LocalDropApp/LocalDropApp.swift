import SwiftUI
import FeatureTransfer

@main
struct LocalDropApp: App {
    @State private var container = TransferFeatureContainer.live()

    var body: some Scene {
        WindowGroup {
            container.rootView
                .task {
                    await container.startIfNeeded()
                }
        }
        .defaultSize(width: 1120, height: 704)
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unified)

        MenuBarExtra("LocalDrop", systemImage: "paperplane") {
            EmptyView()
        }
    }
}
