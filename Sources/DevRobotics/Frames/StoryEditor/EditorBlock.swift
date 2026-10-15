import Foundation

/// Editor-side block model plus a self-contained Markdown <-> blocks codec.
///
/// INTEGRATION: `StoryBlocks.swift` (another agent) is the intended codec. Until it lands this file carries
/// its own lossless-by-construction codec (anything it can't understand becomes an editable text block).
/// To swap, re-implement `EditorBlocks.parse/serialize/lineRanges` on top of `StoryBlocks`; nothing else
/// in the editor touches the codec.
struct EditorBlock: Identifiable, Equatable {
    enum Media: Equatable { case image, images, clip, youtube }
    enum TextKind: Equatable { case paragraph, heading, bullets, numbered, quote }
    struct Item: Equatable { var name: String; var note: String }

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
        if first.hasPrefix("## ") || first.hasPrefix("# ") { return .heading }
        if first.hasPrefix("> ") { return .quote }
        if first.hasPrefix("- ") || first.hasPrefix("* ") { return .bullets }
        if first.range(of: #"^\d+\. "#, options: .regularExpression) != nil { return .numbered }
        return .paragraph
    }

    var fileNames: [String] { media == .youtube ? [] : items.map(\.name) }

    /// Markdown for this block; "" when it has nothing worth writing.
    var markdown: String {
        switch media {
        case .none:
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.range(of: #"^(#{1,2}|-|>|\d+\.)$"#, options: .regularExpression) != nil { return "" }
            return t
        case .image:
            guard let i = items.first else { return "" }
            return FrameFormat.imageMarker(name: i.name, note: i.note, alt: alt, place: place, full: full)
        case .images:
            guard !items.isEmpty else { return "" }
            return FrameFormat.imagesMarker(items.map { ($0.name, $0.note) }, alt: alt)
        case .clip:
            guard let i = items.first else { return "" }
            return FrameFormat.clipMarker(name: i.name, note: i.note)
        case .youtube:
            return url.isEmpty ? "" : FrameFormat.youtubeMarker(url: url, title: title)
        }
    }
}

enum EditorBlocks {
    static func parse(_ body: String) -> [EditorBlock] {
        var blocks: [EditorBlock] = []
        var para: [String] = []
        func flush() {
            if !para.isEmpty { blocks.append(EditorBlock(text: para.joined(separator: "\n"))); para = [] }
        }
        for line in body.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { flush() }
            else if t.lowercased().hasPrefix("<insert") {
                flush()
                blocks.append(parseMarker(t) ?? EditorBlock(text: t))
            } else { para.append(line) }
        }
        flush()
        return blocks
    }

    static func serialize(_ blocks: [EditorBlock]) -> String {
        let parts = blocks.map(\.markdown).filter { !$0.isEmpty }
        return parts.isEmpty ? "" : parts.joined(separator: "\n\n") + "\n"
    }

    /// 1-based, body-relative inclusive line ranges per block that produced output.
    static func lineRanges(_ blocks: [EditorBlock]) -> [(id: UUID, lines: ClosedRange<Int>)] {
        var out: [(id: UUID, lines: ClosedRange<Int>)] = []
        var cursor = 1
        for b in blocks {
            let md = b.markdown
            if md.isEmpty { continue }
            let n = md.components(separatedBy: "\n").count
            out.append((b.id, cursor...(cursor + n - 1)))
            cursor += n + 1
        }
        return out
    }

    static func wordCount(_ blocks: [EditorBlock]) -> Int {
        blocks.filter { !$0.isMedia }.reduce(0) { total, b in
            total + b.text.components(separatedBy: .whitespacesAndNewlines).filter { tok in
                tok.contains { $0.isLetter || $0.isNumber } && tok.range(of: #"^\d+\.$"#, options: .regularExpression) == nil
            }.count
        }
    }

    /// ceil(words / 200), 0 for an empty story.
    static func readMinutes(words: Int) -> Int { words == 0 ? 0 : max(1, Int((Double(words) / 200).rounded(.up))) }

    // MARK: marker parsing

    private enum Tok { case word(String), quoted(String), kv(String, String) }

    private static func tokenize(_ s: String) -> [Tok]? {
        let c = Array(s)
        var i = 0
        var out: [Tok] = []
        func quote() -> String? {
            guard i < c.count, c[i] == "\"" else { return nil }
            i += 1
            var v = ""
            while i < c.count, c[i] != "\"" { v.append(c[i]); i += 1 }
            guard i < c.count else { return nil }
            i += 1
            return v
        }
        while i < c.count {
            if c[i] == " " { i += 1; continue }
            if c[i] == "\"" {
                guard let q = quote() else { return nil }
                out.append(.quoted(q)); continue
            }
            var w = ""
            while i < c.count, c[i] != " ", c[i] != "=", c[i] != "\"" { w.append(c[i]); i += 1 }
            if i < c.count, c[i] == "=" {
                i += 1
                guard let q = quote() else { return nil }
                out.append(.kv(w.lowercased(), q))
            } else if w.isEmpty { return nil } else { out.append(.word(w)) }
        }
        return out
    }

    private static func parseMarker(_ line: String) -> EditorBlock? {
        guard line.hasSuffix(">"), line.count > 8 else { return nil }
        let inner = String(line.dropFirst("<insert".count).dropLast())
        guard let toks = tokenize(inner), case .word(let kindWord)? = toks.first else { return nil }
        let rest = Array(toks.dropFirst())
        switch kindWord.lowercased() {
        case "image":
            var b = EditorBlock(media: .image)
            var item: EditorBlock.Item?
            for t in rest {
                switch t {
                case .word(let w):
                    if w.lowercased() == "full" { b.full = true }
                    else if item == nil { item = .init(name: w, note: "") } else { return nil }
                case .quoted(let q):
                    guard item != nil else { return nil }
                    item!.note = q
                case .kv(let k, let v):
                    if k == "alt" { b.alt = v } else if k == "place" { b.place = v } else { return nil }
                }
            }
            guard let item else { return nil }
            b.items = [item]
            return b
        case "images":
            var b = EditorBlock(media: .images)
            for t in rest {
                switch t {
                case .word(let w): b.items.append(.init(name: w, note: ""))
                case .quoted(let q):
                    guard !b.items.isEmpty else { return nil }
                    b.items[b.items.count - 1].note = q
                case .kv(let k, let v): if k == "alt" { b.alt = v } else { return nil }
                }
            }
            return b.items.isEmpty ? nil : b
        case "clip":
            var b = EditorBlock(media: .clip)
            for t in rest {
                switch t {
                case .word(let w):
                    guard b.items.isEmpty else { return nil }
                    b.items = [.init(name: w, note: "")]
                case .quoted(let q):
                    guard !b.items.isEmpty else { return nil }
                    b.items[0].note = q
                case .kv: return nil
                }
            }
            return b.items.isEmpty ? nil : b
        case "youtube":
            var b = EditorBlock(media: .youtube)
            for t in rest {
                switch t {
                case .word(let w):
                    guard b.url.isEmpty else { return nil }
                    b.url = w
                case .quoted(let q):
                    guard !b.url.isEmpty else { return nil }
                    b.title = q
                case .kv: return nil
                }
            }
            return b.url.isEmpty ? nil : b
        default: return nil
        }
    }
}
