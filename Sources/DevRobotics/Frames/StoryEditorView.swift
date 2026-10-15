import SwiftUI
import PhotosUI

struct TrimRequest: Identifiable {
    let id = UUID()
    let url: URL
    let finish: (URL?) -> Void
}

private enum PendingProblemAction {
    case fix(FrameProblem.Fix)
    case select(FrameProblem)
}

private struct ScrollRequest: Equatable {
    enum Target: Equatable { case top, block(UUID) }
    let target: Target
    let n: Int
}

private struct ProblemsKey: Equatable {
    var body: String
    var fields: [String: String]
    var files: [String]
    var issues: [UUID]
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
    @State private var fileToRemove: String?
    @State private var trimRequest: TrimRequest?
    @State private var keyboardUp = false
    @FocusState private var titleFocused: Bool
    @FocusState private var placeFocused: Bool

    @State private var problems: [FrameProblem] = []
    @State private var showProblems = false
    @State private var pending: PendingProblemAction?
    @State private var showSetDate = false
    @State private var highlightID: UUID?
    @State private var scrollRequest: ScrollRequest?
    @State private var barCollapsed = false
    @State private var downAcc: CGFloat = 0
    @State private var upAcc: CGFloat = 0

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
        .safeAreaInset(edge: .top, spacing: 0) {
            if !problems.isEmpty {
                ProblemsPill(problems: problems) { showProblems = true }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, DS.Space.xs)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !keyboardUp {
                VStack(spacing: DS.Space.xs) {
                    if mode == .write, !unusedFiles.isEmpty {
                        UnusedMediaTray(model: model, names: unusedFiles,
                                        onInsert: { insertFile($0) },
                                        onRemove: { fileToRemove = $0 })
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                    StoryFloatingBar(mode: $mode, onAdd: { add($0, at: doc.blocks.count) },
                                     collapsed: barCollapsed && mode == .write,
                                     onExpand: { barCollapsed = false })
                }
                .dsAnimation(.dsSpring, value: unusedFiles)
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
        .task(id: problemsKey) {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            recomputeProblems()
        }
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
        if DemoMode.isOn, DemoMode.screen == "storyproblems" { bridge?.refresh() }   // screenshots: show fixture issues
    }

    // MARK: problems

    private var problemsKey: ProblemsKey {
        ProblemsKey(body: model.draft.body, fields: model.draft.fields, files: model.draft.allFiles,
                    issues: (bridge?.issues ?? []).map(\.id))
    }

    private var unusedFiles: [String] {
        var seen = Set<String>()
        return problems.filter { $0.kind == .unusedFile }.compactMap(\.fileName).filter { seen.insert($0).inserted }
    }

    private func recomputeProblems() {
        let blocks = doc.blocks.map(\.story)
        let issues = bridge?.issues ?? []
        let local = FrameProblemEngine.local(draft: model.draft, blocks: blocks, localFileURL: { [model] n in
            model.draft.localFiles.contains(n) ? model.mediaURL(n) : nil
        })
        var merged = FrameProblemEngine.merge(local, FrameProblemEngine.fromPipeline(issues, blocks: blocks))
        if merged.isEmpty, DemoMode.isOn { merged = demoProblems(issues) }   // screenshots only, until the engine lands
        if merged != problems { problems = merged }
    }

    /// Demo-only stand-in for the engine so screenshots show badges and the tray.
    private func demoProblems(_ issues: [PreviewIssue]) -> [FrameProblem] {
        issues.map { i in
            let name = i.fileName
            switch i.kind {
            case .noDate:
                return FrameProblem(id: "noDate", severity: .error, kind: .noDate, title: "No date taken for \(name ?? "the cover")",
                                    fileName: name, fixes: [.setDate])
            case .missingFile:
                let bid = doc.blocks.first { b in b.fileNames.contains { $0 == name } }?.id
                return FrameProblem(id: "missing:\(name ?? "")", severity: .error, kind: .missingFile,
                                    title: "\(name ?? "A file") isn't in this story", fileName: name, blockID: bid,
                                    fixes: bid.map { [.removeBlock($0)] } ?? [])
            default:
                return FrameProblem(id: "unused:\(name ?? i.message)", severity: .warning, kind: .unusedFile,
                                    title: "\(name ?? "A file") isn't used in the story", fileName: name,
                                    fixes: name.map { [.insertFile($0), .removeFile($0)] } ?? [])
            }
        }
    }

    /// Problems per block (explicit blockID, else resolved from the body line), plus those about the story as a whole.
    private var problemMap: (byBlock: [UUID: [FrameProblem]], general: [FrameProblem]) {
        var map: [UUID: [FrameProblem]] = [:]
        var rest: [FrameProblem] = []
        let ranges = currentRanges
        for p in problems where p.kind != .unusedFile {
            var target = p.blockID.flatMap { id in doc.blocks.contains { $0.id == id } ? id : nil }
            if target == nil, let l = p.bodyLine { target = ranges.first { $0.lines.contains(l) }?.id }
            if let target { map[target, default: []].append(p) } else { rest.append(p) }
        }
        return (map, rest)
    }

    /// Entry point for inline badges: destructive fixes ask first, like everywhere else.
    private func request(_ fix: FrameProblem.Fix) {
        switch fix {
        case .removeFile(let n): fileToRemove = n
        case .removeBlock(let id): deleteTarget = id
        default: perform(fix)
        }
    }

    private func perform(_ fix: FrameProblem.Fix) {
        switch fix {
        case .setDate:
            showSetDate = true
        case .insertFile(let n):
            insertFile(n)
        case .removeFile(let n):
            model.remove(n)
        case .removeBlock(let id):
            doc.remove(id)
        case .showText(let id):
            if let b = doc.blocks.first(where: { $0.id == id }), b.isMedia,
               let i = doc.index(of: id) {
                let md = EditorBlocks.serialize([b]).trimmingCharacters(in: .whitespacesAndNewlines)
                doc.blocks[i] = EditorBlock(id: id, text: md)
            }
            doc.focusID = id
            requestScroll(.block(id), highlight: id)
        case .openDetails(let field):
            if field == "title" || field == "place" {
                requestScroll(.top, highlight: nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    if field == "title" { titleFocused = true } else { placeFocused = true }
                }
            } else {
                detailsFocusDate = field == "date"
                showDetails = true
            }
        }
    }

    private func select(_ p: FrameProblem) {
        let target = problemMap.byBlock.first { $0.value.contains(p) }?.key
            ?? p.blockID.flatMap { id in doc.blocks.contains { $0.id == id } ? id : nil }
        if let target { requestScroll(.block(target), highlight: target) } else { requestScroll(.top, highlight: nil) }
    }

    private func requestScroll(_ t: ScrollRequest.Target, highlight: UUID?) {
        var delay = 0.05
        if mode != .write { mode = .write; delay = 0.4 }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            scrollRequest = ScrollRequest(target: t, n: (scrollRequest?.n ?? 0) + 1)
            guard let highlight else { return }
            highlightID = highlight
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                if highlightID == highlight { highlightID = nil }
            }
        }
    }

    private func runPending() {
        guard let p = pending else { return }
        pending = nil
        switch p {
        case .fix(let f): perform(f)
        case .select(let pr): select(pr)
        }
    }

    private func insertFile(_ name: String, before index: Int? = nil) {
        var b = EditorBlock(media: FrameFormat.isImage(name) ? .image : .clip)
        b.items = [.init(name: name, note: "")]
        doc.insert(b, at: index ?? doc.insertionIndexForTray)
        requestScroll(.block(b.id), highlight: b.id)
    }

    private func collapseBar(old: CGFloat, new: CGFloat) {
        guard mode == .write, new >= 0 else { return }
        let d = new - old
        if d > 0 {
            downAcc += d; upAcc = 0
            if downAcc > 30, new > 60, !barCollapsed { barCollapsed = true }
        } else if d < 0 {
            upAcc += -d; downAcc = 0
            if upAcc > 20, barCollapsed { barCollapsed = false }
        }
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
        .sheet(isPresented: $showProblems, onDismiss: runPending) {
            ProblemsSheet(problems: problems,
                          onFix: { _, fix in
                              switch fix {
                              case .setDate, .openDetails:
                                  pending = .fix(fix); showProblems = false
                              default: perform(fix)
                              }
                          },
                          onSelect: { p in pending = .select(p); showProblems = false })
        }
        .sheet(isPresented: $showSetDate) {
            SetDateSheet(initial: StoryDates.initial(for: model)) { d in
                model.draft.fields["date"] = StoryDates.fmt.string(from: d)
            }
        }
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
        .confirmationDialog("Remove this file?", isPresented: Binding(get: { fileToRemove != nil }, set: { if !$0 { fileToRemove = nil } }),
                            titleVisibility: .visible) {
            Button("Remove file", role: .destructive) {
                if let n = fileToRemove { model.remove(n) }
                fileToRemove = nil
            }
        } message: {
            Text("\(fileToRemove ?? "The file") is removed from this story's files.")
        }
        .alert("Problem", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(model.error ?? "") }
    }

    // MARK: write

    /// Block line ranges in the body the server will build from: the normalised serialization once edited,
    /// the stored body (zipped by index) for an untouched draft; empty when they can't be trusted.
    private var currentRanges: [(id: UUID, lines: ClosedRange<Int>)] {
        if model.draft.body == EditorBlocks.serialize(doc.blocks) { return EditorBlocks.lineRanges(doc.blocks) }
        return EditorBlocks.rawRanges(body: model.draft.body, blocks: doc.blocks) ?? []
    }

    private var writeView: some View {
        let pm = problemMap
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    cover
                        .id("cover-top")
                        .padding(.bottom, DS.Space.s)
                    ForEach(pm.general) { ProblemBadge(problem: $0, onFix: { request($0) }) }
                    ForEach(Array(doc.blocks.enumerated()), id: \.element.id) { idx, b in
                        addRow(at: idx)
                        BlockRow(block: b, model: model, doc: doc, problems: pm.byBlock[b.id] ?? [],
                                 highlighted: highlightID == b.id,
                                 isFirst: idx == 0, isLast: idx == doc.blocks.count - 1,
                                 onEdit: { editingID = b.id },
                                 onDelete: { requestDelete(b) },
                                 onFix: { request($0) },
                                 onDropFile: { insertFile($0, before: idx) })
                            .id(b.id)
                            .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    }
                    footer
                        .dropDestination(for: String.self) { items, _ in
                            guard let s = items.first, s.hasPrefix("file:") else { return false }
                            insertFile(String(s.dropFirst(5)), before: doc.blocks.count)
                            return true
                        }
                }
                .dsAnimation(.dsSpring, value: doc.blocks.map(\.id))
                .padding(.horizontal, DS.Space.l).padding(.bottom, 24)
            }
            .scrollDismissesKeyboard(.interactively)
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y + $0.contentInsets.top } action: { old, new in
                collapseBar(old: old, new: new)
            }
            .onChange(of: scrollRequest) { _, r in
                guard let r else { return }
                withAnimation(.dsSpring) {
                    switch r.target {
                    case .top: proxy.scrollTo("cover-top", anchor: .top)
                    case .block(let id): proxy.scrollTo(id, anchor: .center)
                    }
                }
            }
        }
    }

    @ViewBuilder private var cover: some View {
        StoryCoverHero(model: model, title: titleBinding, titleFocus: $titleFocused,
                       placeFocus: $placeFocused,
                       busy: model.busy,
                       onPickCover: { showCoverPicker = true })
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

    // MARK: preview

    @ViewBuilder private var previewView: some View {
        VStack(spacing: 0) {
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
                            FrameThumb(source: model.source(for: n)).frame(height: 160).clipShape(RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous))
                        } else {
                            Label("\(n) missing", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(Theme.danger)
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

