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
    let issue: EditorIssue
    var body: some View {
        Label(issue.message, systemImage: issue.level == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
            .font(.footnote)
            .foregroundStyle(issue.level == .error ? Color.red : Theme.warn)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background((issue.level == .error ? Color.red : Theme.warn).opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// One block in the document: content + drag handle + menu + issue badges.
struct BlockRow: View {
    let block: EditorBlock
    let model: DraftEditorModel
    let doc: StoryDocument
    let issues: [EditorIssue]
    let isFirst: Bool
    let isLast: Bool
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onSetDate: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            VStack(alignment: .leading, spacing: 6) {
                content
                ForEach(issues) { i in
                    IssueBadge(issue: i)
                    if i.kind == .noDate {
                        Button("Set a date", action: onSetDate).font(.footnote.bold())
                    }
                }
            }
            VStack(spacing: 10) {
                Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary)
                    .frame(width: 28, height: 28)
                    .draggable(block.id.uuidString)
                    .accessibilityLabel("Drag to reorder")
                Menu {
                    if block.isMedia { Button("Edit details", systemImage: "slider.horizontal.3", action: onEdit) }
                    Button("Move up", systemImage: "arrow.up") { doc.move(block.id, by: -1) }.disabled(isFirst)
                    Button("Move down", systemImage: "arrow.down") { doc.move(block.id, by: 1) }.disabled(isLast)
                    Button("Delete", systemImage: "trash", role: .destructive, action: onDelete)
                } label: {
                    Image(systemName: "ellipsis").frame(width: 28, height: 28).foregroundStyle(.secondary)
                }
            }
        }
        .dropDestination(for: String.self) { items, _ in
            guard let s = items.first, let id = UUID(uuidString: s) else { return false }
            doc.move(id, before: block.id)
            return true
        }
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
        VStack(alignment: .leading, spacing: 6) {
            switch block.media {
            case .youtube:
                HStack(spacing: 10) {
                    Image(systemName: "play.rectangle.fill").font(.title).foregroundStyle(.red)
                    VStack(alignment: .leading) {
                        Text(block.title.isEmpty ? "YouTube video" : block.title).font(.callout.bold())
                        Text(block.url).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                }
                .padding(12)
                .background(Theme.surface2, in: RoundedRectangle(cornerRadius: 10))
            default:
                HStack(spacing: 6) {
                    ForEach(Array(block.items.enumerated()), id: \.offset) { _, it in
                        if model.draft.allFiles.contains(it.name) {
                            FrameThumb(source: model.source(for: it.name))
                                .frame(height: block.items.count > 1 ? 130 : 220)
                                .frame(maxWidth: .infinity)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .overlay(alignment: .topLeading) {
                                    if block.media == .clip { Image(systemName: "film").padding(6).foregroundStyle(.white).shadow(radius: 2) }
                                }
                        } else {
                            Label("\(it.name) missing", systemImage: "exclamationmark.triangle")
                                .font(.caption).foregroundStyle(.red)
                                .frame(maxWidth: .infinity, minHeight: 80)
                                .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
                let notes = block.items.map(\.note).filter { !$0.isEmpty }
                if !notes.isEmpty {
                    Text(notes.joined(separator: " · ")).font(.footnote).foregroundStyle(.secondary)
                } else {
                    Text("Tap to add a note").font(.footnote).foregroundStyle(.tertiary)
                }
                if block.full { Label("Full-bleed", systemImage: "arrow.left.and.right").font(.caption2).foregroundStyle(.secondary) }
            }
        }
    }
}
