import SwiftUI
import FeatureTransfer

@main
struct LocalDropApp: App {
    var body: some Scene {
        WindowGroup {
            EmptyView()
        }

        MenuBarExtra("LocalDrop", systemImage: "paperplane") {
            EmptyView()
        }
    }
}
