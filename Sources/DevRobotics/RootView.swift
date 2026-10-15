import SwiftUI

struct RootView: View {
    var body: some View {
        TabView {
            StatusView().tabItem { Label("Status", systemImage: "waveform.path.ecg") }
            LightsView().tabItem { Label("Lights", systemImage: "lightbulb") }
            FramesView().tabItem { Label("Frames", systemImage: "photo.on.rectangle") }
            SettingsView().tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .scrollDismissesKeyboard(.interactively)   // drag a list/form down to hide the keyboard too
    }
}
