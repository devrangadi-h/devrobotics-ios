import SwiftUI

/// One entry in the Frames list: a photo tile (square) or a story card (wide). Thumbnail with a legibility
/// gradient, glass status pills and an inline progress bar while sending.
struct FramesEntryTile: View {
    let row: FrameRow
    let model: FramesModel
    var compact: Bool

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: compact ? DS.Radius.control : DS.Radius.card, style: .continuous)
    }

    var body: some View {
        Color.clear
            .aspectRatio(compact ? 1 : 1.8, contentMode: .fit)
            .overlay {
                FrameThumb(source: model.thumbSource(for: row.draft, remote: row.remote, kind: row.kind, slug: row.slug))
            }
            .overlay(alignment: .bottom) {
                LinearGradient(colors: [.clear, .black.opacity(0.65)], startPoint: .center, endPoint: .bottom)
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .topLeading) { pills.padding(DS.Space.s) }
            .overlay(alignment: .bottomLeading) { caption.padding(compact ? DS.Space.m : DS.Space.l) }
            .clipShape(shape)
            .overlay { shape.strokeBorder(.white.opacity(0.14), lineWidth: 0.5) }
            .contentShape(shape)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityText)
    }

    private struct Badge: Hashable { var text: String; var icon: String; var red = false; var orange = false; var green = false }

    private var statusBadges: [Badge] {
        var out: [Badge] = []
        if let d = row.draft {
            if d.lastError != nil {
                out.append(Badge(text: "Failed", icon: "exclamationmark.triangle.fill", red: true))
            } else if !d.problems.isEmpty {
                out.append(Badge(text: "\(d.problems.count) problem\(d.problems.count == 1 ? "" : "s")",
                                 icon: "exclamationmark.triangle.fill", red: true))
            } else if d.dirty {
                out.append(row.remote == nil ? Badge(text: "Draft", icon: "pencil.line", orange: true)
                                             : Badge(text: "Edited", icon: "pencil", orange: true))
            }
        }
        if row.published, row.draft?.dirty != true { out.append(Badge(text: "Published", icon: "checkmark.circle.fill", green: true)) }
        return out
    }

    private func tint(_ b: Badge) -> Color? {
        b.red ? .red.opacity(0.6) : b.orange ? .orange.opacity(0.55) : b.green ? .green.opacity(0.5) : nil
    }

    private var pills: some View {
        GlassEffectContainer(spacing: 6) {
            HStack(spacing: 6) {
                ForEach(statusBadges, id: \.self) { b in
                    GlassPill(text: b.text, systemImage: b.icon, tint: tint(b))
                        .transition(.scale(scale: 0.8).combined(with: .opacity))
                }
                if row.kind == .story {
                    GlassPill(text: "Story", systemImage: "book.fill")
                }
            }
        }
        .dsAnimation(value: statusBadges)
    }

    private var caption: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(row.title)
                .font(Theme.font(compact ? 15 : 20, weight: .semibold, relativeTo: .headline))
                .foregroundStyle(.white)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            if !row.subtitle.isEmpty {
                Label(row.subtitle, systemImage: row.kind == .story ? "mappin.and.ellipse" : "link")
                    .font(Theme.font(12, weight: .medium, relativeTo: .caption))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
            }
            if let d = row.draft, let status = model.statusText[d.id] {
                VStack(alignment: .leading, spacing: 3) {
                    ProgressView(value: model.progress[d.id] ?? 0).tint(.white)
                    Text(status).font(Theme.font(11, relativeTo: .caption2)).foregroundStyle(.white.opacity(0.85)).lineLimit(1)
                }
                .padding(.top, 2)
                .transition(.opacity)
            }
        }
        .shadow(color: .black.opacity(0.35), radius: 4, y: 1)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var accessibilityText: String {
        var parts = [row.kind.label, row.title]
        if !row.subtitle.isEmpty { parts.append(row.subtitle) }
        parts += statusBadges.map(\.text)
        return parts.joined(separator: ", ")
    }
}
