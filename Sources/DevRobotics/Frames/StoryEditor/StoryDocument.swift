import SwiftUI
import Observation

/// Editing state for the block body. `blocks` is the source of truth while editing; every change is
/// serialized to the draft's Markdown body (`onBody`). Blocks keep stable ids so cursors survive edits.
@MainActor @Observable
final class StoryDocument {
    var blocks: [EditorBlock] {
        didSet { sync() }
    }
    var focusID: UUID?
    @ObservationIgnored var onBody: ((String) -> Void)?
    @ObservationIgnored private(set) var lastBody: String

    @ObservationIgnored private var loading = false
    @ObservationIgnored private(set) var loaded = false

    /// Cheap on purpose: SwiftUI may build this struct many times; the real parse happens in `load`.
    init() {
        blocks = [EditorBlock()]
        lastBody = ""
    }

    /// Parse the draft body once. `lastBody` stays the body exactly as stored, so merely viewing a story never
    /// rewrites (or dirties) it; the first edit writes the normalised Markdown.
    func load(_ body: String) {
        loaded = true
        read(body)
    }

    /// Re-read from Markdown if it changed behind our back.
    func reload(from body: String) {
        guard loaded, body != lastBody else { return }
        read(body)
    }

    private func read(_ body: String) {
        loading = true
        var b = EditorBlocks.parse(body)
        if b.isEmpty { b = [EditorBlock()] }
        blocks = b
        lastBody = body
        loading = false
    }

    private func sync() {
        guard !loading, loaded else { return }
        let md = EditorBlocks.serialize(blocks)
        guard md != lastBody else { return }
        lastBody = md
        onBody?(md)
    }

    func index(of id: UUID) -> Int? { blocks.firstIndex { $0.id == id } }

    func text(for id: UUID) -> Binding<String> {
        Binding(get: { self.blocks.first { $0.id == id }?.text ?? "" },
                set: { new in
                    if let i = self.index(of: id), self.blocks[i].text != new { self.blocks[i].text = new }
                })
    }

    func block(_ id: UUID) -> Binding<EditorBlock> {
        Binding(get: { self.blocks.first { $0.id == id } ?? EditorBlock(id: id) },
                set: { new in if let i = self.index(of: id), self.blocks[i] != new { self.blocks[i] = new } })
    }

    func insert(_ b: EditorBlock, at index: Int) {
        blocks.insert(b, at: min(max(index, 0), blocks.count))
    }

    func remove(_ id: UUID) {
        blocks.removeAll { $0.id == id }
        if blocks.isEmpty { blocks = [EditorBlock()] }
    }

    func move(_ id: UUID, by delta: Int) {
        guard let i = index(of: id), blocks.indices.contains(i + delta) else { return }
        blocks.swapAt(i, i + delta)
    }

    /// Drag-and-drop: put `id` immediately before `target`.
    func move(_ id: UUID, before target: UUID) {
        guard id != target, let from = index(of: id), let to = index(of: target) else { return }
        let b = blocks.remove(at: from)
        blocks.insert(b, at: to > from ? to - 1 : to)
    }

    /// Whether another block (not `id`) references `name`.
    func isFileUsed(_ name: String, excluding id: UUID) -> Bool {
        blocks.contains { $0.id != id && $0.fileNames.contains { $0.caseInsensitiveCompare(name) == .orderedSame } }
    }

}
