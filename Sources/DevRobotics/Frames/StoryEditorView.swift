import SwiftUI
import PhotosUI

struct StoryEditorView: View {
    @Bindable var model: DraftEditorModel
    enum Tab: String, CaseIterable { case details = "Details", body = "Body", preview = "Preview" }
    @State private var tab: Tab = .details
    @State private var coverItem: PhotosPickerItem?

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).padding(.horizontal).padding(.vertical, 8)
            switch tab {
            case .details: details
            case .body: StoryBodyEditor(model: model)
            case .preview: StoryPreview(model: model)
            }
        }
        .alert("Problem", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(model.error ?? "") }
    }

    private var details: some View {
        Form {
            Section("Cover") {
                let cover = model.draft.field("cover")
                if !cover.isEmpty, model.draft.allFiles.contains(cover) {
                    FrameThumb(source: model.source(for: cover)).frame(height: 180).clipShape(RoundedRectangle(cornerRadius: 8))
                    Text(cover).font(.caption).foregroundStyle(.secondary)
                }
                PhotosPicker(selection: $coverItem, matching: .images, preferredItemEncoding: .current, photoLibrary: .shared()) {
                    Label(cover.isEmpty ? "Choose cover photo" : "Replace cover photo", systemImage: "photo.badge.plus")
                }
                if model.busy { ProgressView("Reading original…") }
            }
            Section("Details") {
                TextField("Title (required)", text: model.binding("title", suggestsSlug: true))
                TextField("Place (required)", text: model.binding("place"))
                SlugRow(model: model)
                GPSRow(model: model)
                TextField("Summary (one line)", text: model.binding("summary"), axis: .vertical)
                TextField("Cover alt text", text: model.binding("alt"), axis: .vertical)
                DateRow(model: model)
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
        .onChange(of: coverItem) { _, new in
            guard let new else { return }
            Task {
                model.busy = true
                defer { model.busy = false; coverItem = nil }
                do {
                    let media = try await MediaPicking.load(new)
                    if media.isVideo { try? FileManager.default.removeItem(at: media.url); model.error = "The cover must be a photo."; return }
                    if let n = model.add(media) { model.draft.fields["cover"] = n }
                } catch { model.error = error.localizedDescription }
            }
        }
    }
}

// MARK: body + toolbar

private struct PendingInsert: Identifiable {
    enum Kind { case image, images, clip }
    let id = UUID()
    var kind: Kind
    var names: [String]
}

struct StoryBodyEditor: View {
    @Bindable var model: DraftEditorModel
    @State private var controller = MarkdownController()
    @State private var imageItem: [PhotosPickerItem] = []
    @State private var imagesItems: [PhotosPickerItem] = []
    @State private var clipItem: [PhotosPickerItem] = []
    @State private var pending: PendingInsert?
    @State private var showYouTube = false

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            MarkdownTextView(text: model.bodyBinding, controller: controller)
        }
        .onChange(of: imageItem) { _, v in handle(v, .image) { imageItem = [] } }
        .onChange(of: imagesItems) { _, v in handle(v, .images) { imagesItems = [] } }
        .onChange(of: clipItem) { _, v in handle(v, .clip) { clipItem = [] } }
        .sheet(item: $pending) { p in
            InsertDetailsSheet(pending: p) { block in insert(block) }
        }
        .sheet(isPresented: $showYouTube) {
            YouTubeSheet { url, title in insert(FrameFormat.youtubeMarker(url: url, title: title)) }
        }
    }

    private var toolbar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                fmt("bold", "Bold") { controller.apply { FrameFormat.wrap($0, $1, prefix: "**", suffix: "**", placeholder: "bold") } }
                fmt("italic", "Italic") { controller.apply { FrameFormat.wrap($0, $1, prefix: "*", suffix: "*", placeholder: "italic") } }
                fmt("textformat.size", "Heading") { controller.apply { FrameFormat.linePrefix($0, $1, prefix: "## ") } }
                fmt("list.bullet", "Bullet list") { controller.apply { FrameFormat.linePrefix($0, $1, prefix: "- ") } }
                fmt("text.quote", "Quote") { controller.apply { FrameFormat.linePrefix($0, $1, prefix: "> ") } }
                fmt("link", "Link") { controller.apply { FrameFormat.link($0, $1) } }
                Divider().frame(height: 24)
                PhotosPicker(selection: $imageItem, maxSelectionCount: 1, matching: .images, preferredItemEncoding: .current, photoLibrary: .shared()) {
                    BarLabel(icon: "photo", text: "Image")
                }
                PhotosPicker(selection: $imagesItems, maxSelectionCount: 3, matching: .images, preferredItemEncoding: .current, photoLibrary: .shared()) {
                    BarLabel(icon: "photo.on.rectangle", text: "2–3 side by side")
                }
                PhotosPicker(selection: $clipItem, maxSelectionCount: 1, matching: .videos, preferredItemEncoding: .current, photoLibrary: .shared()) {
                    BarLabel(icon: "film", text: "Clip")
                }
                Button { showYouTube = true } label: { BarLabel(icon: "play.rectangle", text: "YouTube") }
                if model.busy { ProgressView().padding(.horizontal, 8) }
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
        }
    }

    private func fmt(_ icon: String, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: icon).frame(width: 36, height: 32) }
            .accessibilityLabel(label)
    }

    private func insert(_ block: String) {
        if controller.isAttached {
            controller.apply { FrameFormat.insertBlock($0, $1, block: block) }
        } else {
            model.draft.body = FrameFormat.insertBlock(model.draft.body, NSRange(location: (model.draft.body as NSString).length, length: 0), block: block).text
        }
    }

    private func handle(_ items: [PhotosPickerItem], _ kind: PendingInsert.Kind, reset: @escaping () -> Void) {
        guard !items.isEmpty else { return }
        Task {
            model.busy = true
            defer { model.busy = false; reset() }
            var names: [String] = []
            for it in items {
                do {
                    let media = try await MediaPicking.load(it)
                    if media.isVideo != (kind == .clip) {
                        try? FileManager.default.removeItem(at: media.url)
                        model.error = kind == .clip ? "Pick a video for a clip." : "Pick photos, not videos."
                        continue
                    }
                    if let n = model.add(media) { names.append(n) }
                } catch { model.error = error.localizedDescription }
            }
            guard !names.isEmpty else { return }
            if kind == .images, names.count < 2 {
                model.error = "Pick 2 or 3 photos for a side-by-side row. The photo was added to the story's files; use Image to place it."
                return
            }
            pending = PendingInsert(kind: kind, names: names)
        }
    }
}

private struct InsertDetailsSheet: View {
    let pending: PendingInsert
    let onInsert: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var notes: [String]
    @State private var alt = ""
    @State private var place = ""
    @State private var full = false

    init(pending: PendingInsert, onInsert: @escaping (String) -> Void) {
        self.pending = pending
        self.onInsert = onInsert
        _notes = State(initialValue: Array(repeating: "", count: pending.names.count))
    }

    var body: some View {
        NavigationStack {
            Form {
                ForEach(Array(pending.names.enumerated()), id: \.offset) { i, n in
                    Section(n) { TextField("Note (shown under it)", text: $notes[i], axis: .vertical) }
                }
                if pending.kind != .clip {
                    Section {
                        TextField("Alt text", text: $alt, axis: .vertical)
                        if pending.kind == .image {
                            TextField("Place (if different from the story)", text: $place)
                            Toggle("Full-bleed (edge to edge)", isOn: $full)
                        }
                    }
                }
            }
            .navigationTitle("Insert")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Insert") { onInsert(marker()); dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func marker() -> String {
        switch pending.kind {
        case .image:
            return FrameFormat.imageMarker(name: pending.names[0], note: notes[0], alt: alt, place: place, full: full)
        case .images:
            return FrameFormat.imagesMarker(zip(pending.names, notes).map { ($0, $1) }, alt: alt)
        case .clip:
            return FrameFormat.clipMarker(name: pending.names[0], note: notes[0])
        }
    }
}

private struct YouTubeSheet: View {
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
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Insert") { onInsert(url, title); dismiss() }.disabled(!FrameFormat.isYouTubeURL(url))
                }
            }
        }
        .presentationDetents([.medium])
    }
}

// MARK: preview

struct StoryPreview: View {
    @Bindable var model: DraftEditorModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                let cover = model.draft.field("cover")
                if !cover.isEmpty, model.draft.allFiles.contains(cover) {
                    FrameThumb(source: model.source(for: cover)).frame(height: 220)
                }
                Text(model.draft.field("title")).font(.largeTitle.bold())
                Text(model.draft.field("place")).font(.subheadline).foregroundStyle(.secondary)
                ForEach(Array(model.draft.body.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                    lineView(line)
                }
            }
            .padding()
        }
    }

    @ViewBuilder private func lineView(_ raw: String) -> some View {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if line.isEmpty {
            EmptyView()
        } else if line.lowercased().hasPrefix("<insert") {
            let files = FrameFormat.markerFiles(line)
            if line.lowercased().hasPrefix("<insert youtube") {
                Label(line, systemImage: "play.rectangle").font(.footnote).foregroundStyle(.secondary)
            } else {
                HStack(spacing: 6) {
                    ForEach(files, id: \.self) { n in
                        if model.draft.allFiles.contains(n) {
                            FrameThumb(source: model.source(for: n)).frame(height: 160).clipShape(RoundedRectangle(cornerRadius: 4))
                        } else {
                            Label("\(n) missing", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.red)
                        }
                    }
                }
            }
        } else if line.hasPrefix("## ") {
            Text(String(line.dropFirst(3))).font(.title2.bold())
        } else if line.hasPrefix("> ") {
            md(String(line.dropFirst(2))).italic().padding(.leading, 10)
                .overlay(alignment: .leading) { Rectangle().fill(Theme.accent).frame(width: 3) }
        } else if line.hasPrefix("- ") {
            HStack(alignment: .top) { Text("•"); md(String(line.dropFirst(2))) }
        } else {
            md(line)
        }
    }

    private func md(_ s: String) -> Text {
        if let a = try? AttributedString(markdown: s) { return Text(a) }
        return Text(s)
    }
}

private struct BarLabel: View {
    let icon: String
    let text: String
    var body: some View {
        Label(text, systemImage: icon).font(.footnote).padding(.horizontal, 8).padding(.vertical, 6)
            .background(Color(.secondarySystemBackground), in: Capsule())
    }
}
