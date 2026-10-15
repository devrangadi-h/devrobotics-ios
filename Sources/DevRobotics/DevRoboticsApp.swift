import SwiftUI

@main
struct DevRoboticsApp: App {
    @State private var settings = SettingsStore()
    /// Fresh launch only: scene state, so returning from background never replays it.
    @State private var showSplash = SplashView.enabled

    init() {
        Theme.registerFonts()
        KeyboardDone.install()
        DemoMode.installIfNeeded()
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                RootView()
                    .environment(settings)
                    .tint(Theme.accent)
                if showSplash {
                    SplashView { showSplash = false }
                        .transition(.identity)
                        .zIndex(1)
                }
            }
        }
    }
}
