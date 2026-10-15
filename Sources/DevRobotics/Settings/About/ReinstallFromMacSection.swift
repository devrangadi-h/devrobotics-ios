import SwiftUI

/// About screen: ask the Mac (devrobotics-helper over Tailscale) to rebuild and reinstall this app.
/// Glass hero only for the status; grouped rows for everything else.
struct ReinstallFromMacSection: View {
    @Environment(SettingsStore.self) private var settings
    @State private var model = ReinstallFromMacModel()
    @State private var confirm = false

    var body: some View {
        @Bindable var s = settings
        Group {
            Section { hero }
                .listRowBackground(Color.clear).listRowInsets(EdgeInsets())
                .id("Reinstall")

            Section {
                LabeledContent {
                    TextField("100.x.y.z", text: $s.macHost)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                        .multilineTextAlignment(.trailing)
                        .font(Theme.font(14, mono: true, relativeTo: .subheadline))
                        .onSubmit { Task { await model.refresh(settings) } }
                } label: { Label("Mac address", systemImage: "desktopcomputer") }

                Button { confirm = true } label: {
                    HStack(spacing: DS.Space.s) {
                        if model.isRunning { ProgressView().tint(Theme.accentContrast) }
                        Text(model.isRunning ? "Installing…" : "Reinstall now")
                    }
                }
                .buttonStyle(.primaryAction)
                .disabled(!model.canInstall)
                .opacity(model.canInstall || model.isRunning ? 1 : 0.5)
                .listRowBackground(Color.clear).listRowInsets(EdgeInsets())
                .sensoryFeedback(.impact, trigger: model.startTick)
                .sensoryFeedback(.success, trigger: model.finishTick)
                .sensoryFeedback(.error, trigger: model.failTick)

                if let p = model.problem {
                    Label(p.text, systemImage: "exclamationmark.triangle.fill")
                        .font(Theme.font(13, relativeTo: .footnote)).foregroundStyle(Theme.warn)
                        .symbolEffect(.bounce, value: model.failTick)
                }
                if let tail = model.job?.logTail, !tail.isEmpty {
                    VStack(alignment: .leading, spacing: DS.Space.hair) {
                        ForEach(Array(tail.suffix(6).enumerated()), id: \.offset) { _, l in
                            Text(l).font(Theme.font(11, mono: true, relativeTo: .caption2))
                                .foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel("Install log: \(tail.suffix(3).joined(separator: ". "))")
                }
            } header: {
                Text("Reinstall from my Mac")
            } footer: {
                Text("Works while this app still opens. Your Mac must be awake with the iPhone plugged in, unlocked and trusted. The app closes and reopens when the install finishes.")
            }
        }
        .confirmationDialog("Reinstall from your Mac?", isPresented: $confirm, titleVisibility: .visible) {
            Button("Reinstall now") { Task { await model.start(settings) } }
        } message: {
            Text("The app will close and reopen when the install finishes.")
        }
        .task(id: settings.macHost) {
            while !Task.isCancelled {
                await model.refresh(settings)
                try? await Task.sleep(for: .seconds(model.isRunning ? 1.5 : 5))
            }
        }
    }

    private var statusTint: Color {
        if model.isRunning { return Theme.accent }
        guard model.reachable else { return Theme.danger }
        return model.status?.phoneConnected == true ? Theme.ok : Theme.warn
    }

    private var statusTitle: String {
        if model.isRunning { return "Installing on your iPhone" }
        guard let st = model.status else { return model.checking ? "Checking the Mac…" : "Mac not reachable" }
        return st.phoneConnected ? "Mac reachable · iPhone connected" : "Mac reachable · iPhone not plugged in"
    }

    private var statusDetail: String? {
        if let b = model.status?.lastInstall?.build { return "Last install: build \(b)" + (model.status?.lastInstall?.commit.map { " · \($0)" } ?? "") }
        return model.status?.hostname
    }

    private var hero: some View {
        GlassCard {
            HStack(spacing: DS.Space.m) {
                Circle().fill(statusTint).frame(width: 12, height: 12)
                    .overlay(Circle().stroke(statusTint.opacity(0.35), lineWidth: 6))
                    .symbolEffect(.pulse, isActive: model.isRunning)
                VStack(alignment: .leading, spacing: DS.Space.hair) {
                    Text(statusTitle).font(Theme.font(16, weight: .semibold, relativeTo: .headline))
                        .contentTransition(.opacity)
                    if let d = statusDetail {
                        Text(d).font(Theme.font(12, mono: true, relativeTo: .caption)).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "desktopcomputer").font(.title3).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, DS.Space.xs)
        .dsAnimation(.dsSmooth, value: statusTitle)
        .accessibilityElement(children: .combine)
    }
}
