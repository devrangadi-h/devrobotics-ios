import Foundation

/// Pure (Foundation-only) Markdown helpers for the live editor: span detection, word under caret,
/// inline toggles, block detection and link URL normalisation. All ranges are UTF-16 (NSRange).
enum MDSpanKind { case bold, italic, link }

struct MDSpan: Equatable {
    var kind: MDSpanKind
    var full: NSRange
    var open: NSRange      // leading syntax: `**`, `*`, `[`
    var content: NSRange   // visible text
    var close: NSRange     // trailing syntax: `**`, `*`, `](url)`
    var url: String?
}

enum MDBlockKind: Equatable { case none, heading, bullet, numbered, quote }

struct MDBlockInfo: Equatable {
    var kind: MDBlockKind
    var prefixLength: Int   // UTF-16 units of the syntax prefix ("## ", "- ", "1. ", "> ")
}

enum MarkdownSpans {
    private static let tripleRE = try! NSRegularExpression(pattern: #"\*\*\*([^*\s][^*\n]*?)(?<=[^*\s])\*\*\*"#)
    private static let boldRE = try! NSRegularExpression(pattern: #"\*\*(?![\s*])((?:[^*\n]|\*(?!\*))+?)(?<![\s*])\*\*"#)
    private static let italicRE = try! NSRegularExpression(pattern: #"(?<!\*)\*(?![\s*])((?:[^*\n]|\*\*[^*\n]+?\*\*)+?)(?<![\s*])\*(?!\*)"#)
    private static let linkRE = try! NSRegularExpression(pattern: #"\[([^\]\n]+)\]\(([^)\n]*)\)"#)
    private static let numRE = try! NSRegularExpression(pattern: #"^\d+\. "#)

    static func spans(in text: String) -> [MDSpan] {
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        var out: [MDSpan] = []
        var masked = text
        tripleRE.enumerateMatches(in: text, range: full) { m, _, _ in
            guard let m else { return }
            let c = m.range(at: 1), r = m.range
            out.append(MDSpan(kind: .bold, full: r, open: NSRange(location: r.location, length: 2), content: NSRange(location: r.location + 2, length: c.length + 2),
                              close: NSRange(location: NSMaxRange(c) + 1, length: 2), url: nil))
            out.append(MDSpan(kind: .italic, full: NSRange(location: r.location + 2, length: c.length + 2),
                              open: NSRange(location: r.location + 2, length: 1), content: c,
                              close: NSRange(location: NSMaxRange(c), length: 1), url: nil))
            masked = (masked as NSString).replacingCharacters(in: r, with: String(repeating: "\u{1}", count: r.length))
        }
        let text = masked
        boldRE.enumerateMatches(in: text, range: full) { m, _, _ in
            guard let m else { return }
            let c = m.range(at: 1)
            out.append(MDSpan(kind: .bold, full: m.range, open: NSRange(location: m.range.location, length: 2),
                              content: c, close: NSRange(location: NSMaxRange(c), length: 2), url: nil))
        }
        italicRE.enumerateMatches(in: text, range: full) { m, _, _ in
            guard let m else { return }
            let c = m.range(at: 1)
            out.append(MDSpan(kind: .italic, full: m.range, open: NSRange(location: m.range.location, length: 1),
                              content: c, close: NSRange(location: NSMaxRange(c), length: 1), url: nil))
        }
        linkRE.enumerateMatches(in: text, range: full) { m, _, _ in
            guard let m else { return }
            let c = m.range(at: 1)
            let closeStart = NSMaxRange(c)
            out.append(MDSpan(kind: .link, full: m.range, open: NSRange(location: m.range.location, length: 1),
                              content: c, close: NSRange(location: closeStart, length: NSMaxRange(m.range) - closeStart),
                              url: ns.substring(with: m.range(at: 2))))
        }
        return out.sorted { $0.full.location < $1.full.location }
    }

    /// Span of `kind` that contains the whole selection (caret may touch either edge).
    static func span(_ kind: MDSpanKind, containing sel: NSRange, in spans: [MDSpan]) -> MDSpan? {
        spans.first { $0.kind == kind && sel.location >= $0.full.location && NSMaxRange(sel) <= NSMaxRange($0.full) }
    }

    /// Spans whose syntax should be shown: those touched by the caret / selection.
    static func revealed(_ spans: [MDSpan], selection sel: NSRange) -> [MDSpan] {
        spans.filter { sel.location <= NSMaxRange($0.full) && NSMaxRange(sel) >= $0.full.location }
    }

    // MARK: words

    private static func isWordScalar(_ s: Unicode.Scalar) -> Bool {
        CharacterSet.letters.contains(s) || CharacterSet.decimalDigits.contains(s) || CharacterSet.nonBaseCharacters.contains(s)
            || s.properties.isEmoji && s.value > 0x238C || s.value == 0x200D || (0xFE00...0xFE0F).contains(s.value)
    }

    /// Word range under (or touching) the caret; nil when there is none.
    static func wordRange(in text: String, at caret: Int) -> NSRange? {
        let ns = text as NSString
        let n = ns.length
        guard n > 0 else { return nil }
        let caret = min(max(caret, 0), n)
        func isWordChar(at i: Int) -> Bool {
            guard i >= 0, i < n else { return false }
            let r = ns.rangeOfComposedCharacterSequence(at: i)
            let str = ns.substring(with: r)
            if str.unicodeScalars.allSatisfy({ isWordScalar($0) }) { return true }
            // apostrophe / hyphen inside a word
            if str == "'" || str == "\u{2019}" || str == "-" {
                guard r.location > 0, NSMaxRange(r) < n else { return false }
                let prev = ns.rangeOfComposedCharacterSequence(at: r.location - 1)
                let next = ns.rangeOfComposedCharacterSequence(at: NSMaxRange(r))
                return ns.substring(with: prev).unicodeScalars.allSatisfy(isWordScalar)
                    && ns.substring(with: next).unicodeScalars.allSatisfy(isWordScalar)
            }
            return false
        }
        func prevStart(_ i: Int) -> Int { ns.rangeOfComposedCharacterSequence(at: i - 1).location }
        var start = caret, end = caret
        if caret < n, isWordChar(at: caret) { end = NSMaxRange(ns.rangeOfComposedCharacterSequence(at: caret)) }
        else if caret > 0, isWordChar(at: prevStart(caret)) { start = prevStart(caret) }
        else { return nil }
        // grow both ways
        while start > 0, isWordChar(at: prevStart(start)) { start = prevStart(start) }
        while end < n, isWordChar(at: end) { end = NSMaxRange(ns.rangeOfComposedCharacterSequence(at: end)) }
        return end > start ? NSRange(location: start, length: end - start) : nil
    }

    // MARK: inline toggle

    typealias Edit = (text: String, selection: NSRange)

    /// Toggle bold (`**`) or italic (`*`) on the selection / word under caret.
    static func toggleInline(_ text: String, _ selIn: NSRange, kind: MDSpanKind) -> Edit {
        precondition(kind != .link)
        let marker = kind == .bold ? "**" : "*"
        let m = marker.utf16.count
        let ns = text as NSString
        let loc = min(max(selIn.location, 0), ns.length)
        var sel = NSRange(location: loc, length: min(max(selIn.length, 0), ns.length - loc))
        let all = spans(in: text)

        // 1. already formatted -> remove
        if let s = span(kind, containing: sel, in: all) {
            var t = ns.replacingCharacters(in: s.close, with: "") as NSString
            t = t.replacingCharacters(in: s.open, with: "") as NSString
            let newLoc = max(s.full.location, min(sel.location - m, s.full.location + s.content.length))
            let end = max(newLoc, min(NSMaxRange(sel) - m, s.full.location + s.content.length))
            return (t as String, NSRange(location: newLoc, length: end - newLoc))
        }
        // 2. nothing selected -> word, else placeholder
        if sel.length == 0 {
            if let w = wordRange(in: text, at: sel.location) { sel = w }
            else {
                let ins = marker + "text" + marker
                return (ns.replacingCharacters(in: sel, with: ins), NSRange(location: sel.location + m, length: 4))
            }
        }
        // 3. wrap, absorbing overlapping same-kind spans so markers never nest
        var lo = sel.location, hi = NSMaxRange(sel)
        for s in all where s.kind == kind && s.full.location < hi && NSMaxRange(s.full) > lo {
            lo = min(lo, s.full.location); hi = max(hi, NSMaxRange(s.full))
        }
        var region = ns.substring(with: NSRange(location: lo, length: hi - lo))
        for s in all.filter({ $0.kind == kind && NSRange(location: lo, length: hi - lo).intersection($0.full) != nil })
            .sorted(by: { $0.full.location > $1.full.location }) {
            // strip inner markers of absorbed spans (close first so offsets stay valid)
            var r = region as NSString
            r = r.replacingCharacters(in: NSRange(location: s.close.location - lo, length: s.close.length), with: "") as NSString
            r = r.replacingCharacters(in: NSRange(location: s.open.location - lo, length: s.open.length), with: "") as NSString
            region = r as String
        }
        var out = ""
        var firstInner = NSRange(location: 0, length: 0)
        let lines = region.components(separatedBy: "\n")
        for (i, line) in lines.enumerated() {
            if i > 0 { out += "\n" }
            let lead = line.prefix { $0 == " " || $0 == "\t" }
            let rest = line.dropFirst(lead.count)
            let trailCount = rest.reversed().prefix { $0 == " " || $0 == "\t" }.count
            let core = rest.dropLast(trailCount)
            if core.isEmpty { out += line; continue }
            if i == 0 || lines.count == 1 {
                firstInner = NSRange(location: lo + (out as NSString).length + (String(lead) as NSString).length + m,
                                     length: (String(core) as NSString).length)
            }
            out += String(lead) + marker + core + marker + String(rest.suffix(trailCount))
        }
        let t = ns.replacingCharacters(in: NSRange(location: lo, length: hi - lo), with: out)
        if lines.count == 1 { return (t, firstInner) }
        return (t, NSRange(location: lo, length: (out as NSString).length))
    }

    // MARK: blocks

    static func block(ofLine line: String) -> MDBlockInfo {
        if line.hasPrefix("## ") { return MDBlockInfo(kind: .heading, prefixLength: 3) }
        if line.hasPrefix("# ") { return MDBlockInfo(kind: .heading, prefixLength: 2) }
        if line.hasPrefix("> ") { return MDBlockInfo(kind: .quote, prefixLength: 2) }
        if line.hasPrefix("- ") || line.hasPrefix("* ") { return MDBlockInfo(kind: .bullet, prefixLength: 2) }
        let ns = line as NSString
        if let m = numRE.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) {
            return MDBlockInfo(kind: .numbered, prefixLength: m.range.length)
        }
        return MDBlockInfo(kind: .none, prefixLength: 0)
    }

    /// Block kind shared by every non-empty line touched by the selection (`.none` when mixed).
    static func blockKind(_ text: String, _ sel: NSRange) -> MDBlockKind {
        let ns = text as NSString
        let loc = min(max(sel.location, 0), ns.length)
        let s = NSRange(location: loc, length: min(max(sel.length, 0), ns.length - loc))
        var body = ns.substring(with: ns.lineRange(for: s))
        if body.hasSuffix("\n") { body.removeLast() }
        let kinds = body.components(separatedBy: "\n").filter { !$0.isEmpty }.map { block(ofLine: $0).kind }
        guard let first = kinds.first, kinds.allSatisfy({ $0 == first }) else { return .none }
        return first
    }

    // MARK: links

    static let safeURL = try! NSRegularExpression(pattern: #"^(https?://[^\s<>"]+|mailto:[^\s<>"]+|/[^\s<>"]*|#[^\s<>"]*)$"#, options: .caseInsensitive)

    enum URLResult: Equatable { case ok(String), error(String) }

    static func normalizeURL(_ raw: String) -> URLResult {
        var u = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if u.isEmpty { return .error("Enter a web address.") }
        if u.rangeOfCharacter(from: .whitespacesAndNewlines) != nil { return .error("The address can't contain spaces.") }
        func safe(_ s: String) -> Bool { safeURL.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) != nil }
        if !safe(u) {
            let hasScheme = u.range(of: #"^[A-Za-z][A-Za-z0-9+.-]*:"#, options: .regularExpression) != nil
            let looksEmail = u.range(of: #"^[^@/:\s]+@[^@/:\s]+\.[A-Za-z]{2,}$"#, options: .regularExpression) != nil
            if looksEmail { u = "mailto:" + u }
            else if !hasScheme, !u.hasPrefix("//"), u.range(of: #"^[^/?#\s]+\.[A-Za-z]{2,}([/?#].*)?$"#, options: .regularExpression) != nil {
                u = "https://" + u
            } else if u.range(of: #"^localhost(:\d+)?([/?#].*)?$"#, options: .regularExpression) != nil {
                u = "https://" + u
            } else {
                return .error("Use a web address (https://…), an email (mailto:), a /page or a #section.")
            }
            if !safe(u) { return .error("That address doesn't look right.") }
        }
        // parentheses would end the Markdown link early
        u = u.replacingOccurrences(of: "(", with: "%28").replacingOccurrences(of: ")", with: "%29")
        return .ok(u)
    }

    static func sanitizeLabel(_ s: String) -> String {
        s.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "[", with: "")
            .replacingOccurrences(of: "]", with: "").trimmingCharacters(in: .whitespaces)
    }

    /// Build the edit for the Link sheet. `editing` replaces an existing link; otherwise `replace` is replaced.
    static func applyLink(_ text: String, replace: NSRange, label: String, url: String) -> Edit {
        let ns = text as NSString
        let r = NSRange(location: min(max(replace.location, 0), ns.length),
                        length: min(max(replace.length, 0), ns.length - min(max(replace.location, 0), ns.length)))
        let md = "[\(sanitizeLabel(label))](\(url))"
        return (ns.replacingCharacters(in: r, with: md), NSRange(location: r.location + (md as NSString).length, length: 0))
    }

    static func removeLink(_ text: String, span s: MDSpan) -> Edit {
        let ns = text as NSString
        let label = ns.substring(with: s.content)
        return (ns.replacingCharacters(in: s.full, with: label), NSRange(location: s.full.location, length: (label as NSString).length))
    }
}
