import SwiftUI

/// Horizontal strip of files the story doesn't use. Tap: Insert here / Remove. Drag a thumbnail into the story to place it.
struct UnusedMediaTray: View {
    let model: DraftEditorModel
    let names: [String]
    let onInsert: (String) -> Void
    let onRemove: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Not in the story yet · tap or drag")
                .font(Theme.font(11, weight: .semibold, relativeTo: .caption2))
                .foregroundStyle(.secondary)
                .padding(.horizontal, DS.Space.l)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: DS.Space.s) {
                    ForEach(names, id: \.self) { n in
                        Menu {
                            Button("Insert here", systemImage: "plus.square") { onInsert(n) }
                            Button("Remove", systemImage: "trash", role: .destructive) { onRemove(n) }
                        } label: {
                            FrameThumb(source: model.source(for: n))
                                .frame(width: 56, height: 56)
                                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous))
                                .overlay {
                                    RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous)
                                        .strokeBorder(Theme.warn, lineWidth: 1.5)
                                }
                        }
                        .draggable("file:" + n)
                        .accessibilityLabel("Unused file \(n)")
                    }
                }
                .padding(.horizontal, DS.Space.l).padding(.vertical, 2)
            }
        }
        .padding(.vertical, DS.Space.s)
        .glassEffect(.regular, in: .rect(cornerRadius: DS.Radius.card))
        .padding(.horizontal, DS.Space.l)
    }
}
