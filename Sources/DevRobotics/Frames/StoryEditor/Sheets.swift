import SwiftUI

/// Edit a media block: notes, alt, place, full-bleed, YouTube link.
struct BlockDetailsSheet: View {
    @Binding var block: EditorBlock
    let model: DraftEditorModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                if block.media == .youtube {
                    Section("YouTube link") {
                        TextField("https://youtu.be/…", text: $block.url)
                            .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                        if !block.url.isEmpty && !FrameFormat.isYouTubeURL(block.url) {
                            Text("Use a youtu.be, youtube.com/watch or shorts link.").font(.caption).foregroundStyle(.red)
                        }
                    }
                    Section("Title (optional)") { TextField("Title", text: $block.title) }
                } else {
                    ForEach(block.items.indices, id: \.self) { i in
                        Section(block.items[i].name) {
                            TextField("Note (shown under it)", text: $block.items[i].note, axis: .vertical)
                            if block.media == .images {
                                TextField("Alt text", text: $block.items[i].alt, axis: .vertical)
                            }
                            if FrameFormat.isImage(block.items[i].name), block.items[i].name != model.draft.field("cover") {
                                Button("Use as cover photo") { model.draft.fields["cover"] = block.items[i].name }
                            }
                        }
                    }
                    if block.media == .image {
                        Section {
                            TextField("Alt text", text: $block.alt, axis: .vertical)
                            TextField("Place (if different from the story)", text: $block.place)
                            Toggle("Full-bleed (edge to edge)", isOn: $block.full)
                        }
                    }
                }
            }
            .navigationTitle("Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

struct YouTubeSheet: View {
    let onInsert: (String, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var url = ""
    @State private var title = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("YouTube link") {
                    TextField("https://youtu.be/…", text: $url)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    if !url.isEmpty && !FrameFormat.isYouTubeURL(url) {
                        Text("Use a youtu.be, youtube.com/watch or shorts link.").font(.caption).foregroundStyle(.red)
                    }
                }
                Section("Title (optional)") { TextField("Title", text: $title) }
            }
            .navigationTitle("YouTube")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Insert") { onInsert(url.trimmingCharacters(in: .whitespaces), title); dismiss() }
                        .disabled(!FrameFormat.isYouTubeURL(url))
                }
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }
}

/// All the metadata that isn't the cover/title/body, in one sheet.
struct StoryDetailsSheet: View {
    @Bindable var model: DraftEditorModel
    var focusDate = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                Form {
                    Section {
                        DateRow(model: model).id("date")
                        GPSRow(model: model)
                    } header: {
                        Label("When and where", systemImage: "calendar")
                    } footer: { Text("Edit the title and place on the cover.") }
                    Section {
                        TextField("Summary (one line)", text: model.binding("summary"), axis: .vertical)
                        TextField("Cover alt text", text: model.binding("alt"), axis: .vertical)
                    } header: {
                        Label("Description", systemImage: "text.alignleft")
                    }
                    Section {
                        SlugRow(model: model)
                    } header: {
                        Label("Link", systemImage: "link")
                    }
                    FilesSection(model: model)
                    if model.draft.lastError != nil || !model.draft.problems.isEmpty {
                        Section("Problems") { ProblemsView(draft: model.draft) }
                    }
                    let v = model.draft.validation
                    if !v.isEmpty {
                        Section("Before sending") { ForEach(v, id: \.self) { Label($0, systemImage: "info.circle").font(.callout) } }
                    }
                }
                .onAppear {
                    if focusDate { DispatchQueue.main.async { withAnimation { proxy.scrollTo("date", anchor: .top) } } }
                }
            }
            .scrollContentBackground(.hidden)
            .background { AppBackground() }
            .navigationTitle("Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
    }
}

/// Distraction-free: just the text blocks, with the formatting toolbar.
struct FullScreenWriter: View {
    let doc: StoryDocument
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: DS.Space.xs) {
                    ForEach(doc.blocks.filter { !$0.isMedia }) { b in
                        LiveTextView(text: doc.text(for: b.id))
                    }
                }
                .padding(.horizontal, DS.Space.l).padding(.vertical, DS.Space.m)
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Writing")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
    }
}
