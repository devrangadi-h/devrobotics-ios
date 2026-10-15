import SwiftUI

/// Floating glass "Send to Polaris" bar. Shows per-draft progress while sending.
struct FramesSendBar: View {
    let model: FramesModel
    let connected: Bool
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        let pending = model.pendingDrafts
        VStack(spacing: DS.Space.s) {
            if model.sending {
                VStack(spacing: DS.Space.s) {
                    ForEach(pending.prefix(3)) { d in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(d.displayTitle).lineLimit(1)
                                Spacer(minLength: 8)
                                Text(model.statusText[d.id] ?? "Queued").foregroundStyle(.secondary).lineLimit(1)
                            }
                            .font(Theme.font(12, weight: .medium, relativeTo: .caption))
                            ProgressView(value: model.progress[d.id] ?? 0)
                        }
                    }
                }
                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .bottom)))
            }
            Button {
                Task { await model.sendAll(settings) }
            } label: {
                HStack(spacing: DS.Space.s) {
                    Image(systemName: model.sending ? "arrow.triangle.2.circlepath" : "arrow.up.circle.fill")
                        .symbolEffect(.pulse, isActive: model.sending)
                        .contentTransition(.symbolEffect(.replace))
                    Text(model.sending ? "Sending…" : "Send to Polaris")
                    if !model.sending {
                        Text("\(pending.count)")
                            .font(Theme.font(13, weight: .bold, mono: true, relativeTo: .footnote))
                            .contentTransition(.numericText())
                            .padding(.horizontal, 8).padding(.vertical, 2)
                            .background(.white.opacity(0.25), in: Capsule())
                    }
                }
            }
            .buttonStyle(.primaryAction)
            .disabled(model.sending || !connected)
            .opacity(connected ? 1 : 0.6)
            if !connected {
                Text("Connect to Polaris in Settings to send.")
                    .font(Theme.font(11, relativeTo: .caption2)).foregroundStyle(.secondary)
            }
        }
        .padding(DS.Space.s)
        .glassEffect(.regular, in: .rect(cornerRadius: DS.Radius.card))
        .dsAnimation(value: model.sending)
        .dsAnimation(value: pending.count)
    }
}
