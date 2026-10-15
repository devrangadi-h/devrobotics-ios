import SwiftUI

@main
struct DevRoboticsApp: App {
    @State private var settings = SettingsStore()

    init() { Theme.registerFonts() }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(settings)
                .tint(Theme.accent)
        }
    }
}
