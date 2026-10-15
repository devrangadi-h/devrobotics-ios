import SwiftUI
import UIKit

/// Launch animation overlay: the mark flies in with a spring and a soft glow, holds a beat, then fades out.
/// Sits above `RootView`, so the real UI loads underneath. Tap to skip. Reduce Motion = plain fade.
struct SplashView: View {
    /// Called once the splash is fully gone (so the host can remove it).
    var onFinish: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme
    @State private var landed = false
    @State private var fadingOut = false
    @State private var landTick = 0
    @State private var finished = false

    static let hold = ProcessInfo.processInfo.arguments.contains("-splashhold")
    /// Skipped by `-nosplash` and in demo mode (screenshots), unless `-splashhold` asks for it.
    static var enabled: Bool {
        if ProcessInfo.processInfo.arguments.contains("-nosplash") { return false }
        if hold { return true }
        return !DemoMode.isOn
    }

    private static let mark: UIImage? = {
        guard let url = Bundle.module.url(forResource: "LaunchMark", withExtension: "png") else { return nil }
        return UIImage(contentsOfFile: url.path)
    }()

    var body: some View {
        ZStack {
            LinearGradient(
                colors: scheme == .dark
                    ? [Color(red: 0.02, green: 0.10, blue: 0.16), Color.black]
                    : [Color(red: 0.0, green: 0.55, blue: 0.75), Color(red: 0.0, green: 0.40, blue: 0.62)],
                startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            ZStack {
                Circle()
                    .fill(Color.white.opacity(scheme == .dark ? 0.28 : 0.40))
                    .frame(width: 220, height: 220)
                    .blur(radius: 50)
                    .opacity(landed ? 1 : 0)
                    .scaleEffect(landed ? 1.1 : 0.5)
                Group {
                    if let m = Self.mark {
                        Image(uiImage: m).resizable().scaledToFit()
                    } else {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .resizable().scaledToFit().padding(40).foregroundStyle(.white)
                    }
                }
                .frame(width: 148, height: 148)
                .clipShape(.rect(cornerRadius: 33, style: .continuous))
                .shadow(color: .black.opacity(0.25), radius: 18, y: 8)
                .scaleEffect(landed ? 1 : (reduceMotion ? 1 : 0.6))
                .offset(y: landed || reduceMotion ? 0 : 70)
                .opacity(landed ? 1 : 0)
            }
            .accessibilityHidden(true)
        }
        .opacity(fadingOut ? 0 : 1)
        .contentShape(Rectangle())
        .onTapGesture { if !Self.hold { dismiss() } }
        .sensoryFeedback(.impact(weight: .light), trigger: landTick)
        .task {
            withAnimation(reduceMotion ? .easeOut(duration: 0.3) : .spring(duration: 0.6, bounce: 0.3)) { landed = true }
            try? await Task.sleep(for: .milliseconds(reduceMotion ? 250 : 350))
            landTick += 1
            if Self.hold { return }
            try? await Task.sleep(for: .milliseconds(reduceMotion ? 500 : 450))
            dismiss()
        }
    }

    private func dismiss() {
        guard !finished else { return }
        finished = true
        withAnimation(.easeInOut(duration: 0.3)) { fadingOut = true }
        Task {
            try? await Task.sleep(for: .milliseconds(320))
            onFinish()
        }
    }
}
