import Foundation

/// Pure helpers: slugs, file names, insert markers, Markdown edits. No UI, no I/O (unit-testable).
enum FrameFormat {
    static let imageExts: Set<String> = ["jpg", "jpeg", "heic", "heif"]
    static let clipExts: Set<String> = ["mp4", "mov"]

    static func isValidSlug(_ s: String) -> Bool {
        s.range(of: #"^[a-z0-9]+(-[a-z0-9]+)*$"#, options: .regularExpression) != nil
    }

    /// "Arashiyama, Kyoto, Japan" -> "arashiyama-kyoto-japan"
    static func suggestSlug(from text: String) -> String {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en"))
            .lowercased()
        var out = ""
        var lastDash = true
        for u in folded.unicodeScalars {
            if (u >= "a" && u <= "z") || (u >= "0" && u <= "9") {
                out.unicodeScalars.append(u); lastDash = false
            } else if !lastDash {
                out.append("-"); lastDash = true
            }
        }
        var s = String(out.prefix(60))
        while s.hasSuffix("-") { s.removeLast() }
        return s
    }

    /// Server accepts [A-Za-z0-9._ -]; markers can't contain spaces, so spaces become "_" too.
    static func sanitizeFileName(_ name: String) -> String {
        let base = (name as NSString).lastPathComponent
        var out = ""
        for u in base.unicodeScalars {
            if (u >= "a" && u <= "z") || (u >= "A" && u <= "Z") || (u >= "0" && u <= "9") || u == "." || u == "-" || u == "_" {
                out.unicodeScalars.append(u)
            } else {
                out.append("_")
            }
        }
        while out.hasPrefix(".") { out.removeFirst() }
        return out
    }

    static func isImage(_ name: String) -> Bool { imageExts.contains((name as NSString).pathExtension.lowercased()) }
    static func isClip(_ name: String) -> Bool { clipExts.contains((name as NSString).pathExtension.lowercased()) }

    /// Make `name` unique among `existing` (case-insensitive) by appending -2, -3 ...
    static func uniqueName(_ name: String, among existing: [String]) -> String {
        let lower = Set(existing.map { $0.lowercased() })
        if !lower.contains(name.lowercased()) { return name }
        let ns = name as NSString
        let stem = ns.deletingPathExtension, ext = ns.pathExtension
        var i = 2
        while true {
            let cand = ext.isEmpty ? "\(stem)-\(i)" : "\(stem)-\(i).\(ext)"
            if !lower.contains(cand.lowercased()) { return cand }
            i += 1
        }
    }

    /// "x% y%" from a 0...1 point.
    static func focusString(x: Double, y: Double) -> String {
        "\(Int((min(max(x, 0), 1) * 100).rounded()))% \(Int((min(max(y, 0), 1) * 100).rounded()))%"
    }

    static func parseFocus(_ s: String) -> (x: Double, y: Double)? {
        let nums = s.replacingOccurrences(of: "%", with: " ").replacingOccurrences(of: ",", with: " ")
            .split(separator: " ").compactMap { Double($0) }
        guard nums.count == 2 else { return nil }
        return (min(max(nums[0] / 100, 0), 1), min(max(nums[1] / 100, 0), 1))
    }

    // MARK: markers (always straight quotes)

    static func quoted(_ s: String) -> String {
        let clean = s.replacingOccurrences(of: "\"", with: "'")
            .replacingOccurrences(of: "\u{201C}", with: "'")
            .replacingOccurrences(of: "\u{201D}", with: "'")
            .replacingOccurrences(of: "\u{201E}", with: "'")
            .replacingOccurrences(of: ">", with: ")")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        return "\"\(clean)\""
    }

    private static func attr(_ key: String, _ v: String?) -> String {
        guard let v, !v.trimmingCharacters(in: .whitespaces).isEmpty else { return "" }
        return " \(key)=\(quoted(v))"
    }

    private static func note(_ n: String?) -> String {
        guard let n, !n.trimmingCharacters(in: .whitespaces).isEmpty else { return "" }
        return " " + quoted(n)
    }

    static func imageMarker(name: String, note n: String? = nil, alt: String? = nil, place: String? = nil, full: Bool = false) -> String {
        "<insert image \(name)\(note(n))\(attr("alt", alt))\(attr("place", place))\(full ? " full" : "")>"
    }

    static func imagesMarker(_ items: [(name: String, note: String?)], alt: String? = nil) -> String {
        let parts = items.map { "\($0.name)\(note($0.note))" }.joined(separator: " ")
        return "<insert images \(parts)\(attr("alt", alt))>"
    }

    static func clipMarker(name: String, note n: String? = nil) -> String {
        "<insert clip \(name)\(note(n))>"
    }

    static func youtubeMarker(url: String, title: String? = nil) -> String {
        "<insert youtube \(url.trimmingCharacters(in: .whitespaces))\(note(title))>"
    }

    static func isYouTubeURL(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces)
        let id = "[A-Za-z0-9_-]{11}"
        let pats = ["^https?://(www\\.)?youtu\\.be/\(id)([?&#].*)?$",
                    "^https?://(www\\.|m\\.|music\\.)?youtube\\.com/watch\\?(.*&)?v=\(id)([&#].*)?$",
                    "^https?://(www\\.|m\\.)?youtube\\.com/shorts/\(id)([/?&#].*)?$"]
        return pats.contains { t.range(of: $0, options: .regularExpression) != nil }
    }

    /// File names referenced by markers in `body` (lowercased).
    static func referencedFiles(in body: String) -> Set<String> {
        var out = Set<String>()
        for line in body.split(separator: "\n") where line.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("<insert") {
            out.formUnion(markerFiles(String(line)).map { $0.lowercased() })
        }
        return out
    }

    static func markerFiles(_ line: String) -> [String] {
        let stripped = line.replacingOccurrences(of: "\"[^\"]*\"", with: " ", options: .regularExpression)
        guard let re = try? NSRegularExpression(pattern: "[A-Za-z0-9._-]+\\.(jpg|jpeg|heic|heif|mp4|mov)\\b", options: .caseInsensitive) else { return [] }
        let ns = stripped as NSString
        return re.matches(in: stripped, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) }
    }

    // MARK: Markdown edits on (text, selection)

    typealias Edit = (text: String, selection: NSRange)

    static func wrap(_ text: String, _ sel: NSRange, prefix: String, suffix: String, placeholder: String) -> Edit {
        let ns = text as NSString
        let sel = clamp(sel, ns.length)
        let inner = sel.length > 0 ? ns.substring(with: sel) : placeholder
        let new = ns.replacingCharacters(in: sel, with: prefix + inner + suffix)
        return (new, NSRange(location: sel.location + (prefix as NSString).length, length: (inner as NSString).length))
    }

    static func linePrefix(_ text: String, _ sel: NSRange, prefix: String) -> Edit {
        let ns = text as NSString
        let sel = clamp(sel, ns.length)
        let line = ns.lineRange(for: NSRange(location: sel.location, length: 0))
        let new = ns.replacingCharacters(in: NSRange(location: line.location, length: 0), with: prefix)
        return (new, NSRange(location: sel.location + (prefix as NSString).length, length: sel.length))
    }

    static func link(_ text: String, _ sel: NSRange) -> Edit {
        let ns = text as NSString
        let sel = clamp(sel, ns.length)
        let label = sel.length > 0 ? ns.substring(with: sel) : "text"
        let ins = "[\(label)](https://)"
        let new = ns.replacingCharacters(in: sel, with: ins)
        return (new, NSRange(location: sel.location + (ins as NSString).length - 1, length: 0))
    }

    /// Insert `block` on its own line, separated from neighbours by blank lines.
    static func insertBlock(_ text: String, _ sel: NSRange, block: String) -> Edit {
        let ns = text as NSString
        var sel = clamp(sel, ns.length)
        sel = NSRange(location: sel.location + sel.length, length: 0)  // never replace the selection
        let before = ns.substring(to: sel.location)
        let after = ns.substring(from: sel.location + sel.length)
        let pre: String = before.isEmpty ? "" : before.hasSuffix("\n\n") ? "" : before.hasSuffix("\n") ? "\n" : "\n\n"
        let post: String = after.isEmpty ? "\n" : after.hasPrefix("\n\n") ? "" : after.hasPrefix("\n") ? "\n" : "\n\n"
        let ins = pre + block + post
        let new = before + ins + after
        return (new, NSRange(location: (before as NSString).length + (ins as NSString).length, length: 0))
    }

    private static func clamp(_ r: NSRange, _ len: Int) -> NSRange {
        let loc = min(max(r.location, 0), len)
        return NSRange(location: loc, length: min(max(r.length, 0), len - loc))
    }
}
