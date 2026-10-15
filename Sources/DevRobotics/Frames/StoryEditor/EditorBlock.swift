import Foundation

/// Editor-side block model. Text blocks hold the Markdown source of the block (so live formatting can show
/// the syntax); media blocks hold parsed fields. `EditorBlocks` converts to/from `StoryBlocks`, the shared codec.
struct EditorBlock: Identifiable, Equatable {
    enum Media: Equatable { case image, images, clip, youtube }
    enum TextKind: Equatable { case paragraph, heading, bullets, numbered, quote }
    struct Item: Equatable { var name: String; var note: String; var alt = "" }

    let id: UUID
    /// nil = text block (the Markdown source of the block lives in `text`).
    var media: Media?
    var text = ""
    var items: [Item] = []
    var alt = ""
    var place = ""
    var full = false
    var url = ""
    var title = ""

    init(id: UUID = UUID(), text: String = "") { self.id = id; self.text = text }
    init(id: UUID = UUID(), media: Media) { self.id = id; self.media = media }

    var isMedia: Bool { media != nil }

    var textKind: TextKind {
        let first = text.components(separatedBy: "\n").first ?? ""
        if first.hasPrefix("## ") { return .heading }
        if first.hasPrefix("> ") { return .quote }
        if first.hasPrefix("- ") { return .bullets }
        if first.range(of: #"^\d+\. "#, options: .regularExpression) != nil { return .numbered }
        return .paragraph
    }

    var fileNames: [String] { media == .youtube ? [] : items.map(\.name) }

    /// Codec block for this editor block. Text goes in as a paragraph (kept verbatim by the codec).
    var story: StoryBlock {
        switch media {
        case .none:
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            // a bare list/heading/quote prefix with nothing after it is not content
            if t.range(of: #"^(#{1,2}|-|>|\d+\.)$"#, options: .regularExpression) != nil {
                return StoryBlock(id: id, kind: .paragraph(""))
            }
            return StoryBlock(id: id, kind: .paragraph(t))
        case .image:
            let i = items.first ?? Item(name: "", note: "")
            return StoryBlock(id: id, kind: .image(name: i.name, note: i.note, alt: alt, place: place, full: full))
        case .images:
            return StoryBlock(id: id, kind: .images(items: items.map { StoryBlock.Item(name: $0.name, note: $0.note, alt: $0.alt) }))
        case .clip:
            let i = items.first ?? Item(name: "", note: "")
            return StoryBlock(id: id, kind: .clip(name: i.name, note: i.note))
        case .youtube:
            return StoryBlock(id: id, kind: .youtube(url: url, title: title))
        }
    }

    init(_ s: StoryBlock) {
        id = s.id
        switch s.kind {
        case .paragraph(let t), .raw(let t):
            text = t
        case .heading(let t):
            text = "## " + t
        case .bullets(let l):
            text = l.map { "- " + $0 }.joined(separator: "\n")
        case .numbered(let l):
            text = l.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        case .quote(let t):
            text = t.components(separatedBy: "\n").map { $0.isEmpty ? ">" : "> " + $0 }.joined(separator: "\n")
        case .image(let n, let note, let alt, let place, let full):
            media = .image
            items = [Item(name: n, note: note)]
            self.alt = alt; self.place = place; self.full = full
        case .images(let its):
            media = .images
            items = its.map { Item(name: $0.name, note: $0.note, alt: $0.alt) }
        case .clip(let n, let note):
            media = .clip
            items = [Item(name: n, note: note)]
        case .youtube(let u, let t):
            media = .youtube
            url = u; title = t
        }
    }
}

enum EditorBlocks {
    static func parse(_ body: String) -> [EditorBlock] {
        StoryBlocks.parse(body).map(EditorBlock.init)
    }

    static func serialize(_ blocks: [EditorBlock]) -> String {
        StoryBlocks.serialize(blocks.map(\.story)).markdown
    }

    /// 1-based, body-relative inclusive line ranges per block that produced output, in document order.
    static func lineRanges(_ blocks: [EditorBlock]) -> [(id: UUID, lines: ClosedRange<Int>)] {
        StoryBlocks.serialize(blocks.map(\.story)).lineRanges
            .map { (id: $0.key, lines: $0.value) }
            .sorted { $0.lines.lowerBound < $1.lines.lowerBound }
    }

    /// Ranges against the draft body exactly as stored (the server builds from it) for a draft that hasn't been
    /// re-serialized yet. Splits on blank lines and marker lines; nil when that disagrees with the block count.
    static func rawRanges(body: String, blocks: [EditorBlock]) -> [(id: UUID, lines: ClosedRange<Int>)]? {
        var ranges: [ClosedRange<Int>] = []
        var start: Int?
        let lines = body.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        for (i, l) in lines.enumerated() {
            let t = l.trimmingCharacters(in: .whitespaces)
            let n = i + 1
            if t.isEmpty {
                if let s = start { ranges.append(s...(n - 1)); start = nil }
            } else if t.lowercased().hasPrefix("<insert") {
                if let s = start { ranges.append(s...(n - 1)) }
                ranges.append(n...n)
                start = nil
            } else if start == nil { start = n }
        }
        if let s = start { ranges.append(s...lines.count) }
        let ids = blocks.filter { !StoryBlocks.serialize([$0.story]).markdown.isEmpty }.map(\.id)
        guard ids.count == ranges.count else { return nil }
        return zip(ids, ranges).map { (id: $0, lines: $1) }
    }

    static func wordCount(_ blocks: [EditorBlock]) -> Int { StoryBlocks.wordCount(blocks.map(\.story)) }
    static func readMinutes(_ blocks: [EditorBlock]) -> Int { StoryBlocks.readMinutes(blocks.map(\.story)) }
}
