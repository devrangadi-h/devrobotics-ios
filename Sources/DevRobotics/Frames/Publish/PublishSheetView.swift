import SwiftUI

/// Preview -> changes list -> Approve & publish. Presented from FramesView in a sheet.
struct PublishView: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @State private var model = PublishModel()
    @State private var openTarget: PreviewTarget?
    @State private var confirming = false
    @State private var focusConsumed = false
    private let focus: PreviewTarget?

    init(focus: PreviewTarget? = nil) { self.focus = focus }

    private struct TargetID: Identifiable { let target: PreviewTarget; var id: PreviewTarget { target } }

    /// Coarse phase identity: animate between states, not on every log line.
    private var phaseKey: String {
        switch model.phase {
        case .idle: return "idle"
        case .building: return "building"
        case .review: return "review"
        case .publishing: return "publishing"
        case .published: return "published"
        case .failed: return "failed"
        case .busy: return "busy"
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackground()
                content
                    .id(phaseKey)
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
            }
            .dsAnimation(.dsSmooth, value: phaseKey)
            .navigationTitle("Publish")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { model.cancelWatching(); dismiss() }
                }
            }
        }
        .fullScreenCover(item: Binding(get: { openTarget.map(TargetID.init) },
                                       set: { openTarget = $0?.target })) { PreviewPage(target: $0.target) }
        .onAppear {
            model.begin(settings: settings)
            let demoAuto = DemoMode.isOn && DemoMode.screen == "publish"
            if (focus != nil || demoAuto), settings.isConfigured, case .idle = model.phase {
                model.start("preview", settings: settings)
            }
        }
        .onDisappear { model.cancelWatching() }
        .onChange(of: model.phase) { _, p in
            if case .review = p, let focus, !focusConsumed { focusConsumed = true; openTarget = focus }
        }
        .sensoryFeedback(.success, trigger: phaseKey) { _, new in new == "published" }
        .sensoryFeedback(.error, trigger: phaseKey) { _, new in new == "failed" }
        .sensoryFeedback(.selection, trigger: phaseKey) { _, new in new == "review" }
        .confirmationDialog("Publish everything?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Publish to devrobotics.dev") { model.start("publish", settings: settings) }
        } message: {
            Text("This publishes the whole inbox to devrobotics.dev, not just one item.")
        }
    }

    // MARK: States

    @ViewBuilder private var content: some View {
        if !settings.isConfigured {
            PublishStateScreen(icon: "gearshape", tint: .secondary, title: "Not configured",
                               detail: "Set the Pi address and token in Settings first.")
        } else {
            switch model.phase {
            case .idle: idle
            case .building(let log): working("Building preview", "Rendering everything in your inbox.", log, icon: "hammer.fill")
            case .publishing(let log): working("Publishing", "Committing and pushing to the live site.", log, icon: "paperplane.fill")
            case .busy:
                PublishStateScreen(icon: "hourglass", tint: Theme.warn, title: "Polaris is busy",
                                   detail: "Another build or publish is running. Try again in a minute.", pulse: true) {
                    Button("Retry") { model.start("preview", settings: settings) }.buttonStyle(.secondaryAction)
                }
            case .review(let changes, _): review(changes)
            case .published(let pushed, let changes): published(pushed: pushed, changes)
            case .failed(let msg, let log): failed(msg, log)
            }
        }
    }

    private var idle: some View {
        PublishStateScreen(icon: "eye.fill", tint: Theme.accent, title: "Build a preview",
                           detail: "See everything in your inbox exactly as it will appear. Nothing goes live until you approve.") {
            VStack(spacing: DS.Space.m) {
                Button { model.start("preview", settings: settings) } label: {
                    Label("Build preview", systemImage: "hammer.fill")
                }
                .buttonStyle(.primaryAction)
                Text("Requires Tailscale to be connected.")
                    .font(Theme.font(12, relativeTo: .caption)).foregroundStyle(.secondary)
            }
        }
    }

    private func working(_ title: String, _ detail: String, _ log: [String], icon: String) -> some View {
        VStack(spacing: DS.Space.xl) {
            Spacer(minLength: 0)
            PublishWorkingMark(icon: icon)
            VStack(spacing: DS.Space.s) {
                Text(title).font(Theme.font(22, weight: .semibold, relativeTo: .title2))
                Text(detail).font(Theme.font(15, relativeTo: .subheadline)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            PublishLogTail(lines: log)
            Spacer(minLength: 0)
        }
        .padding(DS.Space.l)
    }

    private func review(_ changes: [FrameChange]) -> some View {
        List {
            Section {
                PublishWarningCard(count: changes.count)
            }
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)

            if changes.isEmpty {
                Section {
                    Label("No changes: the preview matches what is already live.", systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(FrameChange.Kind.allCases, id: \.self) { kind in
                let rows = changes.filter { $0.change == kind }
                if !rows.isEmpty {
                    Section {
                        ForEach(rows) { c in changeRow(c) }
                    } header: {
                        HStack(spacing: DS.Space.xs) {
                            Image(systemName: Self.icon(kind)).foregroundStyle(Self.tint(kind))
                            Text("\(kind.title) (\(rows.count))")
                        }
                    }
                }
            }
        }
        .font(Theme.font(16))
        .dsPage()
        .safeAreaInset(edge: .bottom) {
            GlassEffectContainer(spacing: DS.Space.m) {
                VStack(spacing: DS.Space.s) {
                    Button { confirming = true } label: {
                        Label("Approve & publish", systemImage: "paperplane.fill")
                    }
                    .buttonStyle(.primaryAction)
                    .disabled(changes.isEmpty)
                    .opacity(changes.isEmpty ? 0.5 : 1)
                    Button("Rebuild preview") { model.start("preview", settings: settings) }
                        .buttonStyle(.secondaryAction)
                }
            }
            .padding(.horizontal, DS.Space.l)
            .padding(.vertical, DS.Space.s)
        }
    }

    private func changeRow(_ c: FrameChange) -> some View {
        let tappable = c.change != .removed && PreviewTarget(change: c) != nil
        return Button {
            if c.change != .removed, let t = PreviewTarget(change: c) { openTarget = t }
        } label: {
            HStack(spacing: DS.Space.m) {
                Image(systemName: c.kind == "photo" ? "photo.fill" : "text.book.closed.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(Self.tint(c.change))
                    .frame(width: 34, height: 34)
                    .background(Self.tint(c.change).opacity(0.14), in: .rect(cornerRadius: DS.Radius.chip))
                VStack(alignment: .leading, spacing: 2) {
                    Text(c.slug).font(Theme.font(16, weight: .medium)).lineLimit(1).truncationMode(.middle)
                    Text(c.kind == "photo" ? "Photo" : "Story")
                        .font(Theme.font(12, relativeTo: .caption)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if tappable {
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .disabled(!tappable)
        .accessibilityHint(tappable ? "Opens a preview" : "")
    }

    private func published(pushed: Bool, _ changes: [FrameChange]) -> some View {
        VStack(spacing: DS.Space.xl) {
            Spacer(minLength: 0)
            PublishSuccessMark(tint: pushed ? Theme.ok : Theme.warn)
            VStack(spacing: DS.Space.s) {
                Text(pushed ? "Published" : "Committed, not pushed")
                    .font(Theme.font(24, weight: .semibold, relativeTo: .title))
                Text(pushed ? "\(changes.count) change\(changes.count == 1 ? "" : "s") are live on devrobotics.dev."
                            : "Committed on the Pi, but it was not pushed.")
                    .font(Theme.font(15, relativeTo: .subheadline)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Spacer(minLength: 0)
            Button("Done") { model.reset(); dismiss() }.buttonStyle(.primaryAction)
        }
        .padding(DS.Space.l)
    }

    private func failed(_ msg: String, _ log: [String]) -> some View {
        ScrollView {
            VStack(spacing: DS.Space.l) {
                PublishStateMark(icon: "xmark.octagon.fill", tint: Theme.danger, wiggle: true)
                    .padding(.top, DS.Space.xl)
                Text("Something went wrong").font(Theme.font(22, weight: .semibold, relativeTo: .title2))
                Text(msg).font(Theme.font(15, relativeTo: .subheadline)).multilineTextAlignment(.center)
                Text("Nothing was left half-published.")
                    .font(Theme.font(13, relativeTo: .footnote)).foregroundStyle(.secondary)
                if !log.isEmpty {
                    GlassCard {
                        Text(log.joined(separator: "\n"))
                            .font(Theme.font(11, mono: true, relativeTo: .caption2))
                            .textSelection(.enabled)
                    }
                }
                Button("Start over") { model.reset() }.buttonStyle(.secondaryAction)
            }
            .padding(DS.Space.l)
        }
    }

    private static func tint(_ k: FrameChange.Kind) -> Color {
        switch k { case .new: return Theme.ok; case .changed: return Theme.accent; case .removed: return Theme.danger }
    }
    private static func icon(_ k: FrameChange.Kind) -> String {
        switch k { case .new: return "plus.circle.fill"; case .changed: return "pencil.circle.fill"; case .removed: return "minus.circle.fill" }
    }
}

// MARK: - Pieces (private to the publish sheet)

/// Big symbol in a soft tinted disc.
private struct PublishStateMark: View {
    var icon: String
    var tint: Color
    var pulse = false
    var wiggle = false
    @State private var tick = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Image(systemName: icon)
            .font(.system(size: 42, weight: .semibold))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(tint)
            .symbolEffect(.pulse, options: .repeating, isActive: pulse && !reduceMotion)
            .symbolEffect(.wiggle, value: tick)
            .frame(width: 96, height: 96)
            .glassEffect(.regular.tint(tint.opacity(0.18)), in: .circle)
            .onAppear { if wiggle { tick += 1 } }
            .accessibilityHidden(true)
    }
}

/// Full-screen centred state with optional action area.
private struct PublishStateScreen<Actions: View>: View {
    var icon: String
    var tint: Color
    var title: String
    var detail: String
    var pulse = false
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        VStack(spacing: DS.Space.xl) {
            Spacer(minLength: 0)
            PublishStateMark(icon: icon, tint: tint, pulse: pulse)
            VStack(spacing: DS.Space.s) {
                Text(title).font(Theme.font(24, weight: .semibold, relativeTo: .title))
                Text(detail).font(Theme.font(15, relativeTo: .subheadline)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            actions()
        }
        .padding(DS.Space.l)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension PublishStateScreen where Actions == EmptyView {
    init(icon: String, tint: Color, title: String, detail: String, pulse: Bool = false) {
        self.init(icon: icon, tint: tint, title: title, detail: detail, pulse: pulse) { EmptyView() }
    }
}

/// Spinner ring with the job's symbol inside.
private struct PublishWorkingMark: View {
    var icon: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            ProgressView().controlSize(.extraLarge).tint(Theme.accent).scaleEffect(1.5)
                .frame(width: 96, height: 96)
            Image(systemName: icon)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .symbolEffect(.pulse, options: .repeating, isActive: !reduceMotion)
        }
        .frame(width: 112, height: 112)
        .glassEffect(.regular, in: .circle)
        .accessibilityLabel("Working")
    }
}

/// Last few log lines, newest at the bottom, in a glass card.
private struct PublishLogTail: View {
    var lines: [String]

    var body: some View {
        let tail = Array(lines.suffix(6))
        GlassCard(padding: DS.Space.m) {
            VStack(alignment: .leading, spacing: 4) {
                if tail.isEmpty {
                    Text("Waiting for Polaris…")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(tail.enumerated()), id: \.offset) { i, line in
                        Text(line)
                            .lineLimit(1).truncationMode(.middle)
                            .foregroundStyle(i == tail.count - 1 ? Color.primary : Color.secondary)
                    }
                }
            }
            .font(Theme.font(11, mono: true, relativeTo: .caption2))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: 120, alignment: .top)
        .dsAnimation(.dsSnappy, value: lines.count)
    }
}

/// Warning that publishing sends the whole inbox.
private struct PublishWarningCard: View {
    var count: Int
    var body: some View {
        // Content, not floating chrome: flat tint instead of glass (glass in a list row showed a halo).
        Group {
            HStack(alignment: .top, spacing: DS.Space.m) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warn)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Publishes the whole inbox").font(Theme.font(15, weight: .semibold, relativeTo: .subheadline))
                    Text("Everything listed below goes live on devrobotics.dev, not just one item. Tap a row to preview it first.")
                        .font(Theme.font(13, relativeTo: .footnote)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(DS.Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.warn.opacity(0.16), in: RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous).strokeBorder(Theme.warn.opacity(0.4)))
        }
        .padding(.horizontal, DS.Space.l)
    }
}

/// Circle that fills in and a checkmark that draws itself, then bounces.
private struct PublishSuccessMark: View {
    var tint: Color
    @State private var drawn = false
    @State private var bounce = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle().fill(tint.opacity(0.16))
            Circle().stroke(tint.opacity(0.35), lineWidth: 2)
            PublishCheckShape()
                .trim(from: 0, to: drawn ? 1 : 0)
                .stroke(tint, style: StrokeStyle(lineWidth: 8, lineCap: .round, lineJoin: .round))
                .padding(32)
        }
        .frame(width: 112, height: 112)
        .glassEffect(.regular.tint(tint.opacity(0.2)), in: .circle)
        .scaleEffect(bounce ? 1 : 0.7)
        .onAppear {
            if reduceMotion { drawn = true; bounce = true; return }
            withAnimation(.dsSpring) { bounce = true }
            withAnimation(.easeOut(duration: 0.5).delay(0.15)) { drawn = true }
        }
        .accessibilityLabel("Success")
    }
}

private struct PublishCheckShape: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.midY + r.height * 0.05))
        p.addLine(to: CGPoint(x: r.minX + r.width * 0.36, y: r.maxY - r.height * 0.1))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY + r.height * 0.1))
        return p
    }
}
