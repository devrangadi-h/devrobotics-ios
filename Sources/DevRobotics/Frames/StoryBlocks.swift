import Foundation

/// The story body as an ordered list of blocks. Owned by the "blocks" agent (implementation + round-trip checks).
/// Contract: `serialize(parse(md))` produces Markdown the pipeline (framespipe/inbox.py, md.py) reads identically to `md`
/// (whitespace may be normalised: blocks are separated by exactly one blank line). Anything not recognised is kept
/// verbatim as `.raw` so nothing a user wrote can be lost. The pipeline's Markdown subset: paragraphs, `## ` headings
/// (### is flattened to ## by the site), `- ` and `1. ` lists, `> ` quotes, **bold**, *italic*, [links](url).
struct StoryBlock: Identifiable, Equatable {
    struct Item: Equatable { var name: String; var note: String }
    enum Kind: Equatable {
        case paragraph(String)                       // inline markdown kept as text
        case heading(String)                         // text without the "## "
        case bullets([String])
        case numbered([String])
        case quote(String)
        case image(name: String, note: String, alt: String, place: String, full: Bool)
        case images(items: [Item], alt: String)      // 2-3 side by side
        case clip(name: String, note: String)
        case youtube(url: String, title: String)
        case raw(String)                             // unrecognised, verbatim (may span lines)
    }
    var id = UUID()
    var kind: Kind
}

struct SerializedStory: Equatable {
    var markdown: String
    /// Body-relative, 1-based inclusive line ranges per block (for mapping pipeline issues to blocks).
    var lineRanges: [UUID: ClosedRange<Int>]
}

/// Parsing mirrors the real pipeline: marker lines are lines matching `^\s*<\s*insert\b` (inbox.py); everything else is
/// split into Markdown blocks the way md.py's `render` does. A block only becomes a typed kind when serialising it gives
/// back text the pipeline reads identically; otherwise the original lines are kept verbatim as `.raw`.
/// Render-neutral normalisations: CRLF -> LF, blank-line runs -> one blank line, heading/list/quote lines trimmed,
/// list markers -> "- " / "1. 2. 3.", marker keywords lower-cased with straight quotes.
/// `#` and `###`+ headings are kept as `.paragraph` lines so they round-trip exactly (the site flattens them to `##`).
/// Empty blocks (blank text, no items) are skipped by `serialize` and get no entry in `lineRanges`.
enum StoryBlocks {
    static let wordsPerMinute = 220   // build.py WPM

    // MARK: parse

    static func parse(_ markdown: String) -> [StoryBlock] {
        let text = markdown.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var out: [StoryBlock] = []
        var chunk: [String] = []
        for line in text.components(separatedBy: "\n") {
            if isMarkerStart(line) {
                out += scan(chunk)
                chunk = []
                if let k = parseMarker(line), let s = markerString(k), parseMarker(s) == k {
                    out.append(StoryBlock(kind: k))
                } else {
                    out.append(StoryBlock(kind: .raw(line)))
                }
            } else {
                chunk.append(line)
            }
        }
        out += scan(chunk)
        return out
    }

    // MARK: serialize

    static func serialize(_ blocks: [StoryBlock]) -> SerializedStory {
        var parts: [String] = []
        var ranges: [UUID: ClosedRange<Int>] = [:]
        var line = 1
        for b in blocks {
            guard let t = text(of: b.kind) else { continue }
            let n = t.components(separatedBy: "\n").count
            ranges[b.id] = line...(line + n - 1)
            parts.append(t)
            line += n + 1
        }
        return SerializedStory(markdown: parts.isEmpty ? "" : parts.joined(separator: "\n\n") + "\n", lineRanges: ranges)
    }

    /// Markdown for one block, or nil when the block is empty.
    private static func text(of kind: StoryBlock.Kind) -> String? {
        func nonEmpty(_ s: String) -> String? { trim(s).isEmpty ? nil : s }
        func flat(_ s: String) -> String { trim(s.replacingOccurrences(of: "\n", with: " ")) }
        switch kind {
        case .paragraph(let s), .raw(let s):
            return nonEmpty(s)
        case .heading(let s):
            let t = flat(s)
            return t.isEmpty ? nil : "## " + t
        case .bullets(let items):
            let l = items.map(flat).filter { !$0.isEmpty }
            return l.isEmpty ? nil : l.map { "- " + $0 }.joined(separator: "\n")
        case .numbered(let items):
            let l = items.map(flat).filter { !$0.isEmpty }
            return l.isEmpty ? nil : l.enumerated().map { "\($0.offset + 1). " + $0.element }.joined(separator: "\n")
        case .quote(let s):
            guard nonEmpty(s) != nil else { return nil }
            return s.components(separatedBy: "\n").map { l -> String in
                let t = trim(l)
                return t.isEmpty ? ">" : "> " + t
            }.joined(separator: "\n")
        case .image, .images, .clip, .youtube:
            return markerString(kind)
        }
    }

    private static func markerString(_ kind: StoryBlock.Kind) -> String? {
        switch kind {
        case .image(let name, let note, let alt, let place, let full):
            return FrameFormat.imageMarker(name: name, note: note, alt: alt, place: place, full: full)
        case .images(let items, let alt):
            return FrameFormat.imagesMarker(items.map { (name: $0.name, note: $0.note) }, alt: alt)
        case .clip(let name, let note):
            return FrameFormat.clipMarker(name: name, note: note)
        case .youtube(let url, let title):
            return FrameFormat.youtubeMarker(url: url, title: title)
        default:
            return nil
        }
    }

    // MARK: referenced files / counts

    /// File names as written, in order of first appearance, de-duplicated exactly (case-sensitive, like the pipeline).
    static func referencedFiles(_ blocks: [StoryBlock]) -> [String] {
        var seen = Set<String>(), out: [String] = []
        func add(_ n: String) { if !n.isEmpty, seen.insert(n).inserted { out.append(n) } }
        for b in blocks {
            switch b.kind {
            case .image(let name, _, _, _, _): add(name)
            case .images(let items, _): items.forEach { add($0.name) }
            case .clip(let name, _): add(name)
            case .raw(let s):
                for l in s.components(separatedBy: "\n") where isMarkerStart(l) { FrameFormat.markerFiles(l).forEach(add) }
            default: break
            }
        }
        return out
    }

    /// Same tokenisation as md.py `text_of`: links collapsed, `` `*_[]()#> `` blanked, split on whitespace.
    /// Marker notes/alt text do not count; neither do unparseable marker lines (the pipeline rejects them).
    static func wordCount(_ blocks: [StoryBlock]) -> Int {
        func words(_ s: String) -> Int {
            var t = s.replacingOccurrences(of: #"\]\([^)]*\)"#, with: "]", options: .regularExpression)
            for c in "`*_[]()#>" { t = t.replacingOccurrences(of: String(c), with: " ") }
            return t.split(whereSeparator: { $0.isWhitespace }).count
        }
        func count(_ k: StoryBlock.Kind) -> Int {
            switch k {
            case .paragraph(let s), .heading(let s), .quote(let s): return words(s)
            case .bullets(let l), .numbered(let l): return l.reduce(0) { $0 + words($1) }
            case .raw(let s):
                let md = s.components(separatedBy: "\n").filter { !isMarkerStart($0) }
                return scan(md).reduce(0) { acc, b in
                    guard case .raw(let r) = b.kind else { return acc + count(b.kind) }
                    // list with continuation lines, or a quote/heading kept verbatim: strip list prefixes like md.py does
                    let ls = r.components(separatedBy: "\n").map(trim)
                    let pat: String? = ls.first.map { isNumbered($0) ? numberPat : isBullet($0) ? bulletPat : nil } ?? nil
                    return acc + ls.reduce(0) { a, l in
                        a + words(pat.map { l.replacingOccurrences(of: $0, with: "", options: .regularExpression) } ?? l)
                    }
                }
            default: return 0
            }
        }
        return blocks.reduce(0) { $0 + count($1.kind) }
    }

    /// build.py `read_minutes`: max(1, round(words / 220)), Python rounding (half to even).
    static func readMinutes(_ blocks: [StoryBlock]) -> Int {
        max(1, Int((Double(wordCount(blocks)) / Double(wordsPerMinute)).rounded(.toNearestOrEven)))
    }

    // MARK: Markdown scanning (mirrors md.render block structure)

    private static func trim(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }

    private static func rx(_ pattern: String, _ s: String) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let ns = s as NSString
        guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (0..<m.numberOfRanges).map { m.range(at: $0).location == NSNotFound ? "" : ns.substring(with: m.range(at: $0)) }
    }

    private static let bulletPat = #"^[-*+]\s+"#
    private static let numberPat = #"^\d+[.)]\s+"#

    private static func isMarkerStart(_ line: String) -> Bool { rx(#"^\s*<\s*insert\b"#, line) != nil }
    private static func isBullet(_ s: String) -> Bool { rx(bulletPat, s) != nil }
    private static func isNumbered(_ s: String) -> Bool { rx(numberPat, s) != nil }

    /// Splits marker-free lines into blocks the way md.py does (blank lines separate; lists/quotes/headings per its rules).
    private static func scan(_ chunk: [String]) -> [StoryBlock] {
        var out: [StoryBlock] = []
        var i = 0
        let n = chunk.count
        func add(_ k: StoryBlock.Kind) { out.append(StoryBlock(kind: k)) }
        while i < n {
            let s = trim(chunk[i])
            if s.isEmpty { i += 1; continue }
            if let g = rx(#"^(#{1,6})\s+(.*?)\s*#*\s*$"#, s) {
                let text = g[2]
                if g[1].count == 2 {
                    add(!text.isEmpty && "## " + text == s ? .heading(text) : .raw(chunk[i]))
                } else {
                    add(.paragraph(chunk[i]))
                }
                i += 1
                continue
            }
            if isBullet(s) || isNumbered(s) {
                let ordered = isNumbered(s)
                var items: [String] = [], lines: [String] = []
                var cont = false
                while i < n, !trim(chunk[i]).isEmpty {
                    let s2 = trim(chunk[i])
                    lines.append(chunk[i])
                    if ordered ? isNumbered(s2) : isBullet(s2) {
                        items.append(s2.replacingOccurrences(of: ordered ? numberPat : bulletPat, with: "", options: .regularExpression))
                    } else {
                        cont = true
                    }
                    i += 1
                }
                if cont || items.contains(where: { $0.isEmpty }) {
                    add(.raw(lines.joined(separator: "\n")))
                } else {
                    add(ordered ? .numbered(items) : .bullets(items))
                }
                continue
            }
            if s.hasPrefix(">") {
                var lines: [String] = [], inner: [String] = []
                while i < n, trim(chunk[i]).hasPrefix(">") {
                    let t = trim(chunk[i])
                    lines.append(chunk[i])
                    inner.append(t.replacingOccurrences(of: #"^>\s?"#, with: "", options: .regularExpression))
                    i += 1
                }
                let k = StoryBlock.Kind.quote(inner.joined(separator: "\n"))
                let canon = text(of: k)
                add(canon != nil && canon == lines.map(trim).joined(separator: "\n") ? k : .raw(lines.joined(separator: "\n")))
                continue
            }
            var para: [String] = []
            while i < n, !trim(chunk[i]).isEmpty {
                let s2 = trim(chunk[i])
                if !para.isEmpty, rx(#"^(#{1,6})\s"#, s2) != nil || isBullet(s2) || s2.hasPrefix(">") { break }
                para.append(chunk[i])
                i += 1
            }
            add(.paragraph(para.joined(separator: "\n")))
        }
        return out
    }

    // MARK: marker grammar (inbox.py tokenize_marker / parse_marker)

    private enum Tok: Equatable { case word(String), quoted(String), alt(String), place(String) }

    private static let quoteChars: Set<Character> = ["\"", "\u{201C}", "\u{201D}", "\u{201E}"]

    private static func tokenize(_ str: String) -> [Tok]? {
        let s = Array(str)
        let n = s.count
        var toks: [Tok] = []
        var i = 0
        func closeQuote(_ from: Int) -> Int? {
            var j = from
            while j < n { if s[j] == "\"" || s[j] == "\u{201D}" { return j }; j += 1 }
            return nil
        }
        func inner(_ a: Int, _ b: Int) -> String { trim(String(s[a..<b])) }
        outer: while i < n {
            if s[i].isWhitespace { i += 1; continue }
            for key in ["alt", "place"] {
                let kc = Array(key)
                guard i + kc.count <= n,
                      zip(s[i..<(i + kc.count)], kc).allSatisfy({ String($0).lowercased() == String($1) }) else { continue }
                var j = i + kc.count
                while j < n, s[j].isWhitespace { j += 1 }
                guard j < n, s[j] == "=" else { continue }
                j += 1
                while j < n, s[j].isWhitespace { j += 1 }
                guard j < n, quoteChars.contains(s[j]) else { continue }
                guard let k = closeQuote(j + 1) else { return nil }
                toks.append(key == "alt" ? .alt(inner(j + 1, k)) : .place(inner(j + 1, k)))
                i = k + 1
                continue outer
            }
            if quoteChars.contains(s[i]) {
                guard let k = closeQuote(i + 1) else { return nil }
                toks.append(.quoted(inner(i + 1, k)))
                i = k + 1
                continue
            }
            var j = i
            while j < n, !s[j].isWhitespace, !quoteChars.contains(s[j]) { j += 1 }
            toks.append(.word(String(s[i..<j])))
            i = j
        }
        return toks
    }

    /// nil = the pipeline rejects it, or it carries something the block model cannot hold (kept as `.raw`).
    private static func parseMarker(_ line: String) -> StoryBlock.Kind? {
        guard let g = rx(#"^<\s*insert\s+([\s\S]*?)\s*>$"#, trim(line)),
              let toks = tokenize(g[1]), case .word(let rawKind)? = toks.first else { return nil }
        let rest = Array(toks.dropFirst())
        var words: [String] = [], quoted: [String] = [], alts: [String] = [], places: [String] = []
        for t in rest {
            switch t {
            case .word(let v): words.append(v)
            case .quoted(let v): quoted.append(v)
            case .alt(let v): alts.append(v)
            case .place(let v): places.append(v)
            }
        }
        switch rawKind.lowercased() {
        case "image":
            let files = words.filter { $0.lowercased() != "full" }
            let flags = words.filter { $0.lowercased() == "full" }
            guard files.count == 1, quoted.count <= 1, alts.count <= 1, flags.count <= 1, places.count <= 1,
                  rest.first == .word(files[0]), alts.first != "", places.first != "" else { return nil }
            return .image(name: files[0], note: quoted.first ?? "", alt: alts.first ?? "", place: places.first ?? "", full: !flags.isEmpty)
        case "images":
            // The model holds one alt for the whole marker; FrameFormat writes it after the last file, so it must belong to it.
            guard !words.contains(where: { $0.lowercased() == "full" }), places.isEmpty,
                  case .word? = rest.first, alts.count <= 1, alts.first != "" else { return nil }
            var items: [StoryBlock.Item] = []
            for t in rest {
                switch t {
                case .word(let v): items.append(StoryBlock.Item(name: v, note: ""))
                case .quoted(let v):
                    if !items[items.count - 1].note.isEmpty { return nil }
                    items[items.count - 1].note = v
                case .alt:
                    if items.count < words.count { return nil }   // alt before the last file belongs to an earlier item
                case .place: return nil
                }
            }
            guard (2...3).contains(items.count) else { return nil }
            return .images(items: items, alt: alts.first ?? "")
        case "clip":
            guard alts.isEmpty, places.isEmpty, words.count == 1, quoted.count <= 1 else { return nil }
            return .clip(name: words[0], note: quoted.first ?? "")
        case "youtube":
            guard alts.isEmpty, places.isEmpty, words.count == 1, quoted.count <= 1,
                  FrameFormat.isYouTubeURL(words[0]) else { return nil }
            return .youtube(url: words[0], title: quoted.first ?? "")
        default:
            return nil
        }
    }
}

private extension StoryBlock {
    /// The text of a `.raw` block (empty for other kinds).
    var rawText: String { if case .raw(let s) = kind { return s } else { return "" } }
}
