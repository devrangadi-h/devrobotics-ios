import SwiftUI

enum AddAction: String, CaseIterable, Identifiable {
    case image, images, clip, youtube, text, heading, bullets, numbered, quote
    var id: String { rawValue }
    var label: String {
        switch self {
        case .image: "Image"
        case .images: "2–3 side by side"
        case .clip: "Clip"
        case .youtube: "YouTube"
        case .text: "Text"
        case .heading: "Heading"
        case .bullets: "List"
        case .numbered: "Numbered list"
        case .quote: "Quote"
        }
    }
    var icon: String {
        switch self {
        case .image: "photo"
        case .images: "photo.on.rectangle"
        case .clip: "film"
        case .youtube: "play.rectangle"
        case .text: "text.alignleft"
        case .heading: "textformat.size"
        case .bullets: "list.bullet"
        case .numbered: "list.number"
        case .quote: "text.quote"
        }
    }
}

struct AddMenu<Label: View>: View {
    let onPick: (AddAction) -> Void
    @ViewBuilder var label: () -> Label
    var body: some View {
        Menu {
            Section("Media") {
                ForEach([AddAction.image, .images, .clip, .youtube]) { a in
                    Button { onPick(a) } label: { SwiftUI.Label(a.label, systemImage: a.icon) }
                }
            }
            Section("Text") {
                ForEach([AddAction.text, .heading, .bullets, .numbered, .quote]) { a in
                    Button { onPick(a) } label: { SwiftUI.Label(a.label, systemImage: a.icon) }
                }
            }
        } label: { label() }
    }
}

struct IssueBadge: View {
    let issue: PreviewIssue
    var body: some View {
        let tint = issue.level == .error ? Color.red : Theme.warn
        Label(issue.message, systemImage: issue.level == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
            .font(Theme.font(13, weight: .medium, relativeTo: .footnote))
            .foregroundStyle(tint)
            .padding(.horizontal, DS.Space.m).padding(.vertical, DS.Space.s)
            .glassEffect(.regular.tint(tint.opacity(0.22)), in: .rect(cornerRadius: DS.Radius.chip))
            .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .leading)))
    }
}

/// One block in the document: content + drag handle + menu + issue badges.
struct BlockRow: View {
    let block: EditorBlock
    let model: DraftEditorModel
    let doc: StoryDocument
    let issues: [PreviewIssue]
    let isFirst: Bool
    let isLast: Bool
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onSetDate: () -> Void
    @State private var moved = 0

    var body: some View {
        HStack(alignment: .top, spacing: DS.Space.s) {
            VStack(alignment: .leading, spacing: 6) {
                content
                ForEach(issues) { i in
                    IssueBadge(issue: i)
                    if i.kind == .noDate {
                        Button("Set a date", action: onSetDate).font(.footnote.bold())
                    }
                }
            }
            controls
        }
        .sensoryFeedback(.impact(weight: .medium), trigger: moved)
        .dropDestination(for: String.self) { items, _ in
            guard let s = items.first, let id = UUID(uuidString: s) else { return false }
            doc.move(id, before: block.id)
            moved += 1
            return true
        }
    }

    /// Slim glass capsule: drag handle on top, menu below. 40 pt targets.
    private var controls: some View {
        VStack(spacing: 0) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 36, height: 40)
                .contentShape(Rectangle())
                .draggable(block.id.uuidString)
                .accessibilityLabel("Drag to reorder")
            Menu {
                if block.isMedia { Button("Edit details", systemImage: "slider.horizontal.3", action: onEdit) }
                Button("Move up", systemImage: "arrow.up") { doc.move(block.id, by: -1); moved += 1 }.disabled(isFirst)
                Button("Move down", systemImage: "arrow.down") { doc.move(block.id, by: 1); moved += 1 }.disabled(isLast)
                Button("Delete", systemImage: "trash", role: .destructive, action: onDelete)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 36, height: 40)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Block actions")
        }
        .glassEffect(.regular.interactive(), in: .capsule)
    }

    @ViewBuilder private var content: some View {
        if block.isMedia {
            Button(action: onEdit) { MediaCard(block: block, model: model) }.buttonStyle(.plain)
        } else {
            LiveTextView(text: doc.text(for: block.id),
                         wantsFocus: doc.focusID == block.id,
                         onFocusHandled: { if doc.focusID == block.id { doc.focusID = nil } })
                .overlay(alignment: .topLeading) {
                    if block.text.isEmpty {
                        Text(placeholder).foregroundStyle(.tertiary).padding(.top, 8).allowsHitTesting(false)
                    }
                }
        }
    }

    private var placeholder: String { isFirst && isLast ? "Start writing…" : "Write something…" }
}

struct MediaCard: View {
    let block: EditorBlock
    let model: DraftEditorModel

    var body: some View {
        switch block.media {
        case .youtube:
            HStack(spacing: DS.Space.m) {
                Image(systemName: "play.rectangle.fill").font(.system(size: 30)).foregroundStyle(.red)
                VStack(alignment: .leading, spacing: 2) {
                    Text(block.title.isEmpty ? "YouTube video" : block.title)
                        .font(Theme.font(16, weight: .semibold, relativeTo: .callout))
                    Text(block.url).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(DS.Space.l)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous).strokeBorder(Theme.border) }
        default:
            HStack(spacing: 6) {
                ForEach(Array(block.items.enumerated()), id: \.offset) { _, it in
                    if model.draft.allFiles.contains(it.name) {
                        Color.clear
                            .frame(maxWidth: .infinity)
                            .frame(height: block.items.count > 1 ? 150 : 240)
                            .overlay { FrameThumb(source: model.source(for: it.name)) }
                            .clipped()
                            .overlay(alignment: .topLeading) {
                                if block.media == .clip {
                                    Image(systemName: "play.fill").font(.system(size: 12))
                                        .frame(width: 30, height: 30)
                                        .glassEffect(.regular, in: .circle)
                                        .padding(8)
                                }
                            }
                    } else {
                        Label("\(it.name) missing", systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.red)
                            .frame(maxWidth: .infinity, minHeight: 100)
                            .background(Color.red.opacity(0.1))
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
            .overlay(alignment: .bottomLeading) { caption }
            .overlay(alignment: .topTrailing) {
                if block.full {
                    Image(systemName: "arrow.left.and.right")
                        .font(.system(size: 11, weight: .bold))
                        .frame(width: 28, height: 28)
                        .glassEffect(.regular, in: .circle)
                        .padding(8)
                        .accessibilityLabel("Full-bleed")
                }
            }
        }
    }

    private var caption: some View {
        let notes = block.items.map(\.note).filter { !$0.isEmpty }
        return Group {
            if notes.isEmpty {
                Label("Add a note", systemImage: "text.bubble").foregroundStyle(.secondary)
            } else {
                Text(notes.joined(separator: " · ")).lineLimit(3).multilineTextAlignment(.leading)
            }
        }
        .font(Theme.font(13, weight: .medium, relativeTo: .footnote))
        .padding(.horizontal, DS.Space.m).padding(.vertical, DS.Space.s)
        .glassEffect(.regular, in: .rect(cornerRadius: DS.Radius.chip))
        .padding(DS.Space.s)
    }
}
