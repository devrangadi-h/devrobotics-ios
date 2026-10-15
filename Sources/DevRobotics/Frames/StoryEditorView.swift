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
    @Environment(SettingsStore.self) private var settings
    @State private var counts = (words: 0, minutes: 0)

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
    @State private var keyboardUp = false
    @FocusState private var titleFocused: Bool

    init(model: DraftEditorModel) {
        self.model = model
        _doc = State(initialValue: StoryDocument())
    }

    var body: some View {
        dialogs(sheets(pickers(changes(lifecycle(content)))))
    }

    private var content: some View {
        Group {
            if mode == .write { writeView } else { previewView }
        }
        .background { AppBackground() }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !keyboardUp {
                StoryFloatingBar(mode: $mode) { add($0, at: doc.blocks.count) }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .storyTracksKeyboard($keyboardUp)
        .toolbarVisibility(.hidden, for: .tabBar)
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
        if !doc.loaded { doc.load(model.draft.body) }
        if bridge == nil { bridge = StoryPreviewBridge(model: model, settings: settings) }
    }

    private func modeChanged(_ m: Mode) {}

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

    private var issueMap: (byBlock: [UUID: [PreviewIssue]], unmapped: [PreviewIssue]) {
        guard let issues = bridge?.issues, !issues.isEmpty else { return ([:], []) }
        let ranges = currentRanges
        var map: [UUID: [PreviewIssue]] = [:]
        var rest: [PreviewIssue] = []
        for i in issues {
            var target: UUID?
            if i.kind == .missingFile, let n = i.fileName {
                target = doc.blocks.first { $0.fileNames.contains { $0.caseInsensitiveCompare(n) == .orderedSame } }?.id
            }
            if target == nil { target = i.bodyLine.flatMap { l in ranges.first { $0.lines.contains(l) }?.id } }
            if let target { map[target, default: []].append(i) } else { rest.append(i) }
        }
        return (map, rest)
    }

    /// Block line ranges in the body the server will build from: the normalised serialization once edited,
    /// the stored body (zipped by index) for an untouched draft; empty when they can't be trusted.
    private var currentRanges: [(id: UUID, lines: ClosedRange<Int>)] {
        if model.draft.body == EditorBlocks.serialize(doc.blocks) { return EditorBlocks.lineRanges(doc.blocks) }
        return EditorBlocks.rawRanges(body: model.draft.body, blocks: doc.blocks) ?? []
    }

    private var writeView: some View {
        let issues = issueMap
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    issueBanner(proxy: proxy)
                    cover
                        .padding(.bottom, DS.Space.s)
                    ForEach(Array(doc.blocks.enumerated()), id: \.element.id) { idx, b in
                        addRow(at: idx)
                        BlockRow(block: b, model: model, doc: doc, issues: issues.byBlock[b.id] ?? [],
                                 isFirst: idx == 0, isLast: idx == doc.blocks.count - 1,
                                 onEdit: { editingID = b.id },
                                 onDelete: { requestDelete(b) },
                                 onSetDate: { detailsFocusDate = true; showDetails = true })
                            .id(b.id)
                            .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    }
                    footer
                }
                .dsAnimation(.dsSpring, value: doc.blocks.map(\.id))
                .padding(.horizontal, DS.Space.l).padding(.bottom, 24)
            }
            .scrollDismissesKeyboard(.interactively)
        }
    }

    @ViewBuilder private var cover: some View {
        StoryCoverHero(model: model, title: titleBinding, titleFocus: $titleFocused,
                       busy: model.busy,
                       onPickCover: { showCoverPicker = true },
                       onPlace: { detailsFocusDate = false; showDetails = true })
    }

    /// Wrapping title: Return ends editing instead of inserting a newline (titles are single-line in the file).
    private var titleBinding: Binding<String> {
        let base = model.binding("title", suggestsSlug: true)
        return Binding(get: { base.wrappedValue },
                       set: { new in
                           if new.contains("\n") {
                               titleFocused = false
                               base.wrappedValue = new.replacingOccurrences(of: "\n", with: " ")
                                   .trimmingCharacters(in: .whitespaces)
                           } else { base.wrappedValue = new }
                       })
    }

    @ViewBuilder private func addRow(at index: Int) -> some View {
        AddMenu(onPick: { add($0, at: index) }) {
            HStack(spacing: DS.Space.s) {
                Capsule().fill(Theme.border).frame(height: 1)
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .background(.thinMaterial, in: .circle)
                Capsule().fill(Theme.border).frame(height: 1)
            }
            .frame(height: 28).contentShape(Rectangle())
        }
        .accessibilityLabel("Add block here")
    }

    private var footer: some View {
        StoryFooterChip(words: counts.words, minutes: counts.minutes, savedAt: model.draft.updatedAt)
            .task(id: model.draft.body) {
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled else { return }
                let blocks = doc.blocks
                counts = (EditorBlocks.wordCount(blocks), EditorBlocks.readMinutes(blocks))
            }
            .padding(.top, DS.Space.l)
    }

    @ViewBuilder private func issueBanner(proxy: ScrollViewProxy) -> some View {
        if let issues = bridge?.issues, !issues.isEmpty {
            let hasErr = issues.contains { $0.level == .error }
            Button {
                let ranges = currentRanges
                let first = issues.min { ($0.bodyLine ?? 0) < ($1.bodyLine ?? 0) }
                if let first, let l = first.bodyLine, let t = ranges.first(where: { $0.lines.contains(l) })?.id {
                    withAnimation { proxy.scrollTo(t, anchor: .center) }
                } else if first?.kind == .noDate {
                    detailsFocusDate = true; showDetails = true
                }
            } label: {
                Label("\(issues.count) \(issues.count == 1 ? "problem" : "problems")", systemImage: "exclamationmark.triangle.fill")
                    .font(Theme.font(13, weight: .semibold, relativeTo: .footnote))
                    .foregroundStyle(hasErr ? Color.red : Theme.warn)
                    .padding(.horizontal, DS.Space.l).padding(.vertical, DS.Space.m)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .glassEffect(.regular.tint((hasErr ? Color.red : Theme.warn).opacity(0.25)).interactive(),
                                 in: .rect(cornerRadius: DS.Radius.control))
            }
            .buttonStyle(.plain)
            .padding(.bottom, DS.Space.xs)
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
                    .padding(.horizontal, DS.Space.l).padding(.vertical, DS.Space.m)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .glassEffect(.regular.tint(Theme.warn.opacity(0.2)), in: .rect(cornerRadius: DS.Radius.control))
                    .padding(.horizontal, DS.Space.l)
                    .onTapGesture { withAnimation(.dsSpring) { mode = .write } }
            }
            if let b = bridge, b.unavailableReason == nil {
                b.makePreviewView()
            } else {
                SmallBanner(text: "Approximate preview. " + (bridge?.unavailableReason ?? "The real page preview isn't available."))
                if let b = bridge {
                    Button("Try the real preview") { b.refresh() }.font(.footnote.bold()).padding(.vertical, 6)
                }
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
        b.fileNames.filter { $0 != model.draft.field("cover") && !doc.isFileUsed($0, excluding: b.id) && model.draft.allFiles.contains($0) }
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

