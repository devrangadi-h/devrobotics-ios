import SwiftUI

struct EditTarget: Hashable {
    var kind: FrameKind
    var slug: String
    var draft: FrameDraft?

    /// Matches `FrameRow.id`, so the list row can be the zoom-transition source.
    var sourceID: String { draft.map { "d-\($0.id)" } ?? "r-\(kind.rawValue)/\(slug)" }
}

private enum FramesFilter: String, CaseIterable, Identifiable {
    case all = "All", photos = "Photos", stories = "Stories"
    var id: String { rawValue }
    func includes(_ k: FrameKind) -> Bool {
        switch self { case .all: true; case .photos: k == .photo; case .stories: k == .story }
    }
}

/// Consecutive photos are laid out two-up; stories get a full-width card.
private enum FramesBlock: Identifiable {
    case story(FrameRow)
    case photos([FrameRow])
    var id: String {
        switch self { case .story(let r): r.id; case .photos(let rs): "p-" + rs.map(\.id).joined(separator: "|") }
    }
}

struct FramesView: View {
    @Environment(SettingsStore.self) private var settings
    @State private var model = FramesModel()
    @State private var path: [EditTarget] = []
    @State private var showPublish = false
    @State private var toDelete: FrameRow?
    @State private var filter: FramesFilter = .all
    @Namespace private var zoomNS

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                LazyVStack(spacing: DS.Space.l) {
                    if let banner = bannerText { ConnectionBanner(text: banner) }
                    if let s = model.summary {
                        Text(s).font(Theme.font(13, relativeTo: .footnote)).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if !model.rows.isEmpty {
                        Picker("Show", selection: $filter) {
                            ForEach(FramesFilter.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .sensoryFeedback(.selection, trigger: filter)
                    }
                    content
                }
                .padding(.horizontal, DS.Space.l)
                .padding(.top, DS.Space.s)
                .padding(.bottom, DS.Space.xl)
            }
            .dsPage()
            .navigationTitle("Frames")
            .navigationDestination(for: EditTarget.self) { t in
                EditorHost(target: t, model: model)
                    .navigationTransition(.zoom(sourceID: t.sourceID, in: zoomNS))
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showPublish = true } label: { Label("Publish", systemImage: "paperplane") }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("New photo", systemImage: "photo") { newEntry(.photo) }
                        Button("New story", systemImage: "book") { newEntry(.story) }
                    } label: { Image(systemName: "plus") }
                    .accessibilityLabel("New entry")
                }
            }
            .refreshable { model.summary = nil; await model.refresh(settings) }
            .task {
                await model.refresh(settings)
                if DemoMode.isOn, path.isEmpty {   // screenshots only (-demo -screen story|photo|publish)
                    switch DemoMode.screen {
                    case "story": path.append(EditTarget(kind: .story, slug: "pumpkintime", draft: nil))
                    case "photo": path.append(EditTarget(kind: .photo, slug: "rainersky", draft: nil))
                    case "publish": showPublish = true
                    default: break
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if !model.pendingDrafts.isEmpty || model.sending {
                    FramesSendBar(model: model, connected: settings.isConfigured)
                        .padding(.horizontal, DS.Space.l)
                        .padding(.bottom, DS.Space.xs)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .dsAnimation(value: model.pendingDrafts.isEmpty && !model.sending)
            .sensoryFeedback(.success, trigger: model.sending) { old, new in old && !new }
            .sheet(isPresented: $showPublish, onDismiss: { model.summary = nil; Task { await model.refresh(settings) } }) {
                PublishView()
            }
            .confirmationDialog("Delete this entry?", isPresented: Binding(get: { toDelete != nil }, set: { if !$0 { toDelete = nil } }),
                                titleVisibility: .visible, presenting: toDelete) { row in
                Button(row.remote != nil ? "Delete from Polaris" : "Delete draft", role: .destructive) {
                    Task { withAnimation(.dsSpring) { toDelete = nil }; await model.delete(row, settings) }
                }
            } message: { row in
                Text(row.remote != nil ? "\"\(row.title)\" and its files are removed from the Pi inbox." : "The local draft is discarded.")
            }
        }
    }

    // MARK: Content

    private var blocks: [FramesBlock] {
        var out: [FramesBlock] = []
        var run: [FrameRow] = []
        for r in model.rows where filter.includes(r.kind) {
            if r.kind == .photo { run.append(r) }
            else {
                if !run.isEmpty { out.append(.photos(run)); run = [] }
                out.append(.story(r))
            }
        }
        if !run.isEmpty { out.append(.photos(run)) }
        return out
    }

    @ViewBuilder private var content: some View {
        let blocks = blocks
        if blocks.isEmpty && !model.loading {
            emptyState.padding(.top, DS.Space.xl)
        } else {
            ForEach(blocks) { block in
                switch block {
                case .story(let r):
                    tile(r, compact: false)
                case .photos(let rs):
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: DS.Space.m), GridItem(.flexible(), spacing: DS.Space.m)],
                              spacing: DS.Space.m) {
                        ForEach(rs) { tile($0, compact: true) }
                    }
                }
            }
            .transition(.opacity.combined(with: .scale(scale: 0.96)))
        }
    }

    private func tile(_ row: FrameRow, compact: Bool) -> some View {
        let radius = compact ? DS.Radius.control : DS.Radius.card
        return Button { open(row) } label: {
            FramesEntryTile(row: row, model: model, compact: compact)
        }
        .buttonStyle(.pressable)
        .matchedTransitionSource(id: row.id, in: zoomNS) {
            $0.clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        }
        .contextMenu {
            if let d = row.draft, !d.dirty {
                Button("Dismiss draft", systemImage: "xmark.circle") { withAnimation(.dsSpring) { model.discardDraft(d, settings) } }
            }
            Button(row.remote != nil ? "Delete from Polaris" : "Delete draft", systemImage: "trash", role: .destructive) {
                toDelete = row
            }
        }
        .transition(.opacity.combined(with: .scale(scale: 0.94)))
    }

    @ViewBuilder private var emptyState: some View {
        if model.rows.isEmpty {
            ContentUnavailableView {
                Label("No entries yet", systemImage: "photo.on.rectangle.angled")
            } description: {
                Text("Add a photo or write a story. Drafts are saved offline until you send them.")
            } actions: {
                Button("New photo", systemImage: "photo") { newEntry(.photo) }.buttonStyle(.secondaryAction)
                Button("New story", systemImage: "book") { newEntry(.story) }.buttonStyle(.primaryAction)
            }
        } else {
            ContentUnavailableView(filter == .photos ? "No photos" : "No stories",
                                   systemImage: filter == .photos ? "photo" : "book",
                                   description: Text("Nothing here yet."))
        }
    }

    private var bannerText: String? {
        if !settings.isConfigured { return "Not connected. Set the Pi address and token in Settings. Drafts still work offline." }
        if let e = model.loadError { return "\(e) Showing saved data; drafts still work offline." }
        return nil
    }

    private func open(_ row: FrameRow) {
        guard !model.sending else { return }
        path.append(EditTarget(kind: row.kind, slug: row.slug, draft: row.draft))
    }

    private func newEntry(_ kind: FrameKind) {
        path.append(EditTarget(kind: kind, slug: "", draft: FrameDraft(kind: kind, isNew: true)))
    }
}

/// Resolves the draft (from local state or by downloading the .md fields/body) then shows the right editor.
struct EditorHost: View {
    let target: EditTarget
    let model: FramesModel
    @Environment(SettingsStore.self) private var settings
    @State private var editor: DraftEditorModel?
    @State private var error: String?

    var body: some View {
        Group {
            if let editor {
                Group {
                    if editor.draft.kind == .photo { PhotoEditorView(model: editor) } else { StoryEditorView(model: editor) }
                }
                .navigationTitle(editor.draft.isNew ? "New \(editor.draft.kind.label.lowercased())" : editor.draft.displayTitle)
                .navigationBarTitleDisplayMode(.inline)
            } else if let error {
                ContentUnavailableView("Can't load entry", systemImage: "wifi.exclamationmark", description: Text(error))
            } else {
                ProgressView("Loading…")
            }
        }
        .task {
            guard editor == nil else { return }
            if let d = target.draft { editor = DraftEditorModel(draft: d, store: model.store); return }
            do {
                let e = try await model.fetchEntry(target.kind, target.slug, settings)
                editor = DraftEditorModel(draft: FrameDraft(entry: e), store: model.store)
            } catch {
                self.error = "\(FramesModel.describe(error)) Connect to Polaris to edit an entry that has no local draft."
            }
        }
    }
}
