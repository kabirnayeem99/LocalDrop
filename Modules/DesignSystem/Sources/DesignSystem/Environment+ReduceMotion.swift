import SwiftUI

private struct AppReducesMotionKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// App-level "Reduce motion" setting (Settings screen toggle) — combines with the
    /// system's `accessibilityReduceMotion`, which SwiftUI doesn't allow overriding directly.
    public var appReducesMotion: Bool {
        get { self[AppReducesMotionKey.self] }
        set { self[AppReducesMotionKey.self] = newValue }
    }
}
