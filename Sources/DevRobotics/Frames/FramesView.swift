import SwiftUI

struct EditTarget: Hashable {
    var kind: FrameKind
    var slug: String
    var draft: FrameDraft?
}

struct FramesView: View {
    @Environment(SettingsStore.self) private var settings
    @State private var model = FramesModel()
    @State private var path: [EditTarget] = []
    @State private var showPublish = false
    @State private var toDelete: FrameRow?

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if let banner = bannerText {
                    SmallBanner(text: banner).listRowInsets(EdgeInsets()).listRowSeparator(.hidden)
                }
                if let s = model.summary {
                    Text(s).font(.footnote).foregroundStyle(.secondary).listRowSeparator(.hidden)
                }
                let rows = model.rows
                if rows.isEmpty && !model.loading {
                    ContentUnavailableView("No entries yet", systemImage: "photo.on.rectangle",
                                           description: Text("Tap + to add a photo or a story."))
                }
                ForEach(rows) { row in
                    Button { open(row) } label: { FrameRowView(row: row, model: model) }
                        .buttonStyle(.plain)
                        .swipeActions {
                            Button("Delete", role: .destructive) { toDelete = row }
                            if let d = row.draft, !d.dirty {
                                Button("Dismiss") { model.discardDraft(d) }.tint(.gray)
                            }
                        }
                }
            }
            .listStyle(.plain)
            .navigationTitle("Frames")
            .navigationDestination(for: EditTarget.self) { t in
                EditorHost(target: t, model: model)
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
                }
            }
            .refreshable { model.summary = nil; await model.refresh(settings) }
            .task { await model.refresh(settings) }
            .safeAreaInset(edge: .bottom) { sendBar }
            .sheet(isPresented: $showPublish, onDismiss: { model.summary = nil; Task { await model.refresh(settings) } }) {
                PublishView()
            }
            .confirmationDialog("Delete this entry?", isPresented: Binding(get: { toDelete != nil }, set: { if !$0 { toDelete = nil } }),
                                titleVisibility: .visible, presenting: toDelete) { row in
                Button(row.remote != nil ? "Delete from Polaris" : "Delete draft", role: .destructive) {
                    Task { await model.delete(row, settings) }
                }
            } message: { row in
                Text(row.remote != nil ? "\"\(row.title)\" and its files are removed from the Pi inbox." : "The local draft is discarded.")
            }
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

    @ViewBuilder private var sendBar: some View {
        let pending = model.pendingDrafts
        if !pending.isEmpty || model.sending {
            VStack(spacing: 6) {
                if model.sending {
                    ProgressView(value: model.progress.values.max() ?? 0).padding(.horizontal)
                }
                Button {
                    Task { await model.sendAll(settings) }
                } label: {
                    Label(model.sending ? "Sending…" : "Send to Polaris (\(pending.count))", systemImage: "arrow.up.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.sending || !settings.isConfigured)
                .padding(.horizontal)
            }
            .padding(.vertical, 8)
            .background(.bar)
        }
    }
}

struct FrameRowView: View {
    let row: FrameRow
    let model: FramesModel

    var body: some View {
        HStack(spacing: 12) {
            FrameThumb(source: model.thumbSource(for: row.draft, remote: row.remote, kind: row.kind, slug: row.slug))
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 3) {
                Text(row.title).font(.headline).lineLimit(1)
                HStack(spacing: 6) {
                    Text(row.kind.label).font(.caption).foregroundStyle(.secondary)
                    if !row.subtitle.isEmpty { Text(row.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                }
                HStack(spacing: 6) {
                    if row.published { badge("Published", .green) }
                    if row.draft?.dirty == true { badge("Unsent draft", .orange) }
                    if row.remote == nil, row.draft != nil { badge("New", .blue) }
                }
                if let d = row.draft {
                    if let s = model.statusText[d.id] {
                        HStack {
                            ProgressView(value: model.progress[d.id] ?? 0)
                            Text(s).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    if let e = d.lastError { Text(e).font(.caption).foregroundStyle(.red).lineLimit(2) }
                    ForEach(d.problems, id: \.self) { Text($0).font(.caption).foregroundStyle(.orange).lineLimit(2) }
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }

    private func badge(_ t: String, _ c: Color) -> some View {
        Text(t).font(.caption2.bold()).padding(.horizontal, 6).padding(.vertical, 2)
            .background(c.opacity(0.18), in: Capsule()).foregroundStyle(c)
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
