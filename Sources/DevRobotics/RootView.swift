import SwiftUI

struct RootView: View {
    enum AppTab: Hashable { case status, lights, frames, settings }
    @State private var tab: AppTab = RootView.initialTab
    @State private var demoDateSheet = DemoMode.screen == "setdate"   // screenshots only

    /// `-screen <name>` (demo/screenshots) can start on any tab.
    private static var initialTab: AppTab {
        switch DemoMode.screen {
        case "lights": return .lights
        case "frames", "story", "photo", "publish", "storyproblems": return .frames
        case "settings", "about": return .settings
        default: return SettingsStore.storedLaunchTab
        }
    }

    var body: some View {
        TabView(selection: $tab) {
            Tab("Status", systemImage: "waveform.path.ecg", value: .status) { StatusView() }
            Tab("Lights", systemImage: "lightbulb", value: .lights) { LightsView() }
            Tab("Frames", systemImage: "photo.on.rectangle", value: .frames) { FramesView() }
            Tab("Settings", systemImage: "gearshape", value: .settings) { SettingsView() }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .sensoryFeedback(.selection, trigger: tab)
        .scrollDismissesKeyboard(.interactively)
        .sheet(isPresented: $demoDateSheet) { SetDateSheet(initial: Date()) { _ in } }
    }
}
