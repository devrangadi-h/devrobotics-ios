import SwiftUI
import PhotosUI

struct TrimRequest: Identifiable {
    let id = UUID()
    let url: URL
    let finish: (URL?) -> Void
}

/// The story editor: one scrolling document (cover, title, blocks) with Write / Preview modes.
/// Pieces live in `StoryEditor/`.
struct StoryEditorView: View {
    @Bindable var model: DraftEditorModel
    enum Mode: String, CaseIterable { case write = "Write", preview = "Preview" }

    @State private var doc: StoryDocument
    @State private var bridge: StoryPreviewBridge?
    @State private var mode: Mode = .write

    @State private var insertIndex = 0
    @State private var showImagePicker = false
    @State private var showImagesPicker = false
    @State private var showClipPicker = false
    @State private var showCoverPicker = false
    @State private var imageItems: [PhotosPickerItem] = []
    @State private var imagesItems: [PhotosPickerItem] = []
    @State private var clipItems: [PhotosPickerItem] = []
    @State private var coverItem: [PhotosPickerItem] = []
    @State private var showYouTube = false
    @State private var editingID: UUID?
    @State private var showDetails = false
    @State private var detailsFocusDate = false
    @State private var showFullScreen = false
    @State private var deleteTarget: UUID?
    @State private var trimRequest: TrimRequest?

    init(model: DraftEditorModel) {
        self.model = model
        _doc = State(initialValue: StoryDocument(body: model.draft.body))
    }

    var body: some View {
        dialogs(sheets(pickers(changes(lifecycle(content)))))
    }

    private var content: some View {
        VStack(spacing: 0) {
            Picker("Mode", selection: $mode) {
                Text("Write").tag(Mode.write)
                Text("Preview").tag(Mode.preview)
            }
            .pickerStyle(.segmented).padding(.horizontal).padding(.vertical, 8)
            if mode == .write { writeView } else { previewView }
        }
    }

    private func lifecycle<V: View>(_ v: V) -> some View {
        v
        .toolbar { editorToolbar }
        .onAppear { setUp() }
        .onChange(of: model.draft.body) { _, new in doc.reload(from: new) }
    }

    private func changes<V: View>(_ v: V) -> some View {
        v
        .onChange(of: model.draft.fields) { _, _ in bridge?.markChanged() }
        .onChange(of: model.draft.allFiles) { _, _ in bridge?.markChanged() }
        .onChange(of: mode) { _, m in modeChanged(m) }
        .onChange(of: imageItems) { _, v in handle(v, .image) { imageItems = [] } }
        .onChange(of: imagesItems) { _, v in handle(v, .images) { imagesItems = [] } }
        .onChange(of: clipItems) { _, v in handle(v, .clip) { clipItems = [] } }
        .onChange(of: coverItem) { _, v in handleCover(v) }
    }

    @ToolbarContentBuilder private var editorToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button { showFullScreen = true } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                .accessibilityLabel("Full-screen writing")
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button { detailsFocusDate = false; showDetails = true } label: { Image(systemName: "info.circle") }
                .accessibilityLabel("Details")
        }
    }

    private func setUp() {
        doc.onBody = { [weak model] md in
            model?.draft.body = md
            bridge?.markChanged()
        }
        if bridge == nil { bridge = StoryPreviewBridges.make(for: model) }
    }

    private func modeChanged(_ m: Mode) {
        if m == .preview, let b = bridge, b.isStale { b.refresh() }
    }

    private func pickers<V: View>(_ v: V) -> some View {
        v
        .photosPicker(isPresented: $showImagePicker, selection: $imageItems, maxSelectionCount: 1, matching: .images, preferredItemEncoding: .current)
        .photosPicker(isPresented: $showImagesPicker, selection: $imagesItems, maxSelectionCount: 3, matching: .images, preferredItemEncoding: .current)
        .photosPicker(isPresented: $showClipPicker, selection: $clipItems, maxSelectionCount: 1, matching: .videos, preferredItemEncoding: .current)
        .photosPicker(isPresented: $showCoverPicker, selection: $coverItem, maxSelectionCount: 1, matching: .images, preferredItemEncoding: .current)
    }

    private func sheets<V: View>(_ v: V) -> some View {
        v
        .sheet(isPresented: $showYouTube) {
            YouTubeSheet { url, title in
                var b = EditorBlock(media: .youtube)
                b.url = url; b.title = title
                doc.insert(b, at: insertIndex)
            }
        }
        .sheet(isPresented: Binding(get: { editingID != nil && doc.index(of: editingID!) != nil },
                                    set: { if !$0 { editingID = nil } })) {
            if let id = editingID { BlockDetailsSheet(block: doc.block(id), model: model) }
        }
        .sheet(isPresented: $showDetails) { StoryDetailsSheet(model: model, focusDate: detailsFocusDate) }
        .fullScreenCover(isPresented: $showFullScreen) { FullScreenWriter(doc: doc) }
        .fullScreenCover(item: $trimRequest) { req in
            VideoTrimmer(url: req.url) { out in
                trimRequest = nil
                req.finish(out)
            }
            .ignoresSafeArea()
        }
    }

    private func dialogs<V: View>(_ v: V) -> some View {
        v
        .confirmationDialog("Delete this block?", isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }),
                            titleVisibility: .visible) {
            if let id = deleteTarget, let b = doc.blocks.first(where: { $0.id == id }) {
                let exclusive = exclusiveFiles(b)
                Button("Delete block", role: .destructive) { doc.remove(id) }
                if !exclusive.isEmpty {
                    Button("Delete block and remove \(exclusive.count == 1 ? "file" : "\(exclusive.count) files")", role: .destructive) {
                        doc.remove(id)
                        exclusive.forEach { model.remove($0) }
                    }
                }
            }
        } message: {
            Text("The file stays in the story's files unless you remove it too.")
        }
        .alert("Problem", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(model.error ?? "") }
    }

    // MARK: write

    private var issueMap: (byBlock: [UUID: [EditorIssue]], unmapped: [EditorIssue]) {
        guard let issues = bridge?.issues, !issues.isEmpty else { return ([:], []) }
        let ranges = EditorBlocks.lineRanges(doc.blocks)
        var map: [UUID: [EditorIssue]] = [:]
        var rest: [EditorIssue] = []
        for i in issues {
            var target: UUID?
            if i.kind == .missingFile, let n = i.name {
                target = doc.blocks.first { $0.fileNames.contains { $0.caseInsensitiveCompare(n) == .orderedSame } }?.id
            }
            if target == nil { target = ranges.first { $0.lines.contains(i.line) }?.id }
            if let target { map[target, default: []].append(i) } else { rest.append(i) }
        }
        return (map, rest)
    }

    private var writeView: some View {
        let issues = issueMap
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    issueBanner(proxy: proxy)
                    cover
                    TextField("Title", text: model.binding("title", suggestsSlug: true), axis: .vertical)
                        .font(.largeTitle.bold())
                        .textInputAutocapitalization(.sentences)
                        .padding(.top, 8)
                    Text(model.draft.field("place").isEmpty ? "Add a place in Details" : model.draft.field("place"))
                        .font(.subheadline).foregroundStyle(.secondary)
                        .onTapGesture { detailsFocusDate = false; showDetails = true }
                        .padding(.bottom, 8)
                    ForEach(Array(doc.blocks.enumerated()), id: \.element.id) { idx, b in
                        addRow(at: idx)
                        BlockRow(block: b, model: model, doc: doc, issues: issues.byBlock[b.id] ?? [],
                                 isFirst: idx == 0, isLast: idx == doc.blocks.count - 1,
                                 onEdit: { editingID = b.id },
                                 onDelete: { requestDelete(b) },
                                 onSetDate: { detailsFocusDate = true; showDetails = true })
                            .id(b.id)
                    }
                    addRow(at: doc.blocks.count, prominent: true)
                    footer
                }
                .padding(.horizontal, 16).padding(.bottom, 40)
            }
            .scrollDismissesKeyboard(.interactively)
        }
    }

    @ViewBuilder private var cover: some View {
        let c = model.draft.field("cover")
        Button { showCoverPicker = true } label: {
            if !c.isEmpty, model.draft.allFiles.contains(c) {
                FrameThumb(source: model.source(for: c)).frame(height: 220).frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(alignment: .bottomTrailing) {
                        Label("Replace", systemImage: "photo.badge.plus").font(.caption.bold())
                            .padding(8).background(.ultraThinMaterial, in: Capsule()).padding(8)
                    }
            } else {
                RoundedRectangle(cornerRadius: 12).strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6]))
                    .foregroundStyle(.secondary).frame(height: 140)
                    .overlay { Label("Add cover photo", systemImage: "photo.badge.plus").foregroundStyle(.secondary) }
            }
        }
        .buttonStyle(.plain)
        if model.busy { ProgressView("Reading original…").font(.footnote) }
    }

    private func addRow(at index: Int, prominent: Bool = false) -> some View {
        AddMenu(onPick: { add($0, at: index) }) {
            if prominent {
                Label("Add", systemImage: "plus.circle.fill").font(.callout.bold())
                    .frame(maxWidth: .infinity).padding(.vertical, 10)
                    .background(Theme.surface2, in: RoundedRectangle(cornerRadius: 10))
            } else {
                HStack(spacing: 8) {
                    Rectangle().fill(Theme.border).frame(height: 1)
                    Image(systemName: "plus.circle").foregroundStyle(.tertiary)
                    Rectangle().fill(Theme.border).frame(height: 1)
                }
                .frame(height: 22).contentShape(Rectangle())
            }
        }
        .padding(.top, prominent ? 12 : 0)
    }

    private var footer: some View {
        let w = doc.wordCount
        let m = EditorBlocks.readMinutes(words: w)
        return VStack(alignment: .leading, spacing: 2) {
            Text("\(w) words" + (m > 0 ? " · \(m) min read" : ""))
            Text("Saved on this phone · \(model.draft.updatedAt.formatted(date: .omitted, time: .shortened))")
        }
        .font(.caption).foregroundStyle(.secondary).padding(.top, 16)
    }

    @ViewBuilder private func issueBanner(proxy: ScrollViewProxy) -> some View {
        if let issues = bridge?.issues, !issues.isEmpty {
            let hasErr = issues.contains { $0.level == .error }
            Button {
                let ranges = EditorBlocks.lineRanges(doc.blocks)
                let first = issues.sorted { $0.line < $1.line }.first
                if let first, let t = ranges.first(where: { $0.lines.contains(first.line) })?.id {
                    withAnimation { proxy.scrollTo(t, anchor: .center) }
                } else if first?.kind == .noDate {
                    detailsFocusDate = true; showDetails = true
                }
            } label: {
                Label("\(issues.count) \(issues.count == 1 ? "problem" : "problems")", systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote.bold()).frame(maxWidth: .infinity, alignment: .leading).padding(10)
                    .foregroundStyle(hasErr ? Color.red : Theme.warn)
                    .background((hasErr ? Color.red : Theme.warn).opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            ForEach(issueMap.unmapped) { IssueBadge(issue: $0) }
            if issues.contains(where: { $0.kind == .noDate }) {
                Button("Set a date") { detailsFocusDate = true; showDetails = true }.font(.footnote.bold())
            }
        }
    }

    // MARK: preview

    @ViewBuilder private var previewView: some View {
        VStack(spacing: 0) {
            if let b = bridge, !b.issues.isEmpty {
                Label("\(b.issues.count) \(b.issues.count == 1 ? "problem" : "problems") - fix them in Write",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote.bold()).foregroundStyle(Theme.warn)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                    .background(Theme.warn.opacity(0.12))
                    .onTapGesture { mode = .write }
            }
            if let b = bridge, b.unavailableReason == nil {
                HStack {
                    Text(b.isBuilding ? "Building…" : b.isStale ? "Out of date" : "Up to date")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Refresh") { b.refresh() }.font(.footnote.bold()).disabled(b.isBuilding)
                }
                .padding(.horizontal).padding(.vertical, 6)
                b.makePreviewView()
            } else {
                SmallBanner(text: bridge?.unavailableReason ?? "Approximate preview. The real page preview isn't available.")
                StoryPreview(model: model)
            }
        }
    }

    // MARK: actions

    private func add(_ a: AddAction, at index: Int) {
        insertIndex = index
        switch a {
        case .image: showImagePicker = true
        case .images: showImagesPicker = true
        case .clip: showClipPicker = true
        case .youtube: showYouTube = true
        case .text, .heading, .bullets, .numbered, .quote:
            let prefix: String
            switch a {
            case .heading: prefix = "## "
            case .bullets: prefix = "- "
            case .numbered: prefix = "1. "
            case .quote: prefix = "> "
            default: prefix = ""
            }
            let b = EditorBlock(text: prefix)
            doc.insert(b, at: index)
            doc.focusID = b.id
        }
    }

    private func exclusiveFiles(_ b: EditorBlock) -> [String] {
        b.fileNames.filter { !doc.isFileUsed($0, excluding: b.id) && model.draft.allFiles.contains($0) }
    }

    private func requestDelete(_ b: EditorBlock) {
        if exclusiveFiles(b).isEmpty { doc.remove(b.id) } else { deleteTarget = b.id }
    }

    private func handleCover(_ items: [PhotosPickerItem]) {
        guard let it = items.first else { return }
        Task {
            model.busy = true
            defer { model.busy = false; coverItem = [] }
            do {
                let media = try await MediaPicking.load(it)
                if media.isVideo { try? FileManager.default.removeItem(at: media.url); model.error = "The cover must be a photo."; return }
                if let n = model.add(media) { model.draft.fields["cover"] = n }
            } catch { model.error = error.localizedDescription }
        }
    }

    /// Present the system trimmer and wait for it. nil = cancelled or failed.
    private func trim(_ url: URL) async -> URL? {
        await withCheckedContinuation { cont in
            trimRequest = TrimRequest(url: url) { cont.resume(returning: $0) }
        }
    }

    private func handle(_ items: [PhotosPickerItem], _ kind: AddAction, reset: @escaping () -> Void) {
        guard !items.isEmpty else { return }
        let at = insertIndex
        Task {
            model.busy = true
            defer { model.busy = false; reset() }
            var names: [String] = []
            for it in items {
                do {
                    var media = try await MediaPicking.load(it)
                    if media.needsTrim, kind == .clip {
                        let original = media.url
                        guard let trimmed = await trim(original) else {
                            try? FileManager.default.removeItem(at: original)
                            model.error = "Trim cancelled, so the clip wasn't added."
                            continue
                        }
                        try? FileManager.default.removeItem(at: original)
                        let secs = await MediaPicking.duration(of: trimmed)
                        guard secs <= MediaPicking.maxClipSeconds + 0.05 else {
                            try? FileManager.default.removeItem(at: trimmed)
                            model.error = String(format: "The trimmed clip is still %.0f s; clips must be 10 s or shorter.", secs)
                            continue
                        }
                        media = PickedMedia(url: trimmed, name: MediaPicking.renamed(media.name, forFileAt: trimmed), isVideo: true)
                    }
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
            var b = EditorBlock(media: kind == .images ? .images : kind == .clip ? .clip : .image)
            b.items = names.map { .init(name: $0, note: "") }
            doc.insert(b, at: at)
            editingID = b.id
        }
    }
}

// MARK: local (approximate) preview

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

