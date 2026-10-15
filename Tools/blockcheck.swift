// Round-trip check for StoryBlocks. Build and run on the Mac (from a directory outside Sources/):
//   swiftc -o /tmp/blockcheck Sources/DevRobotics/Frames/FrameFormat.swift Sources/DevRobotics/Frames/StoryBlocks.swift Tools/blockcheck.swift
//   /tmp/blockcheck story.md [more.md ...]
// Each file may have "---" front matter (stripped) or be a bare body. --write DIR writes DIR/<basename> (front matter + round-tripped body)
// for feeding the real pipeline.
import Foundation

@main
struct BlockCheck {
    static func body(of text: String) -> String { split(text).body }

    /// (front matter lines including both "---" fences, body)
    static func split(_ text: String) -> (head: String, body: String) {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        guard let first = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
              lines[first].trimmingCharacters(in: .whitespaces) == "---",
              let end = lines[(first + 1)...].firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" })
        else { return ("", text) }
        return (lines[...end].joined(separator: "\n") + "\n", lines[(end + 1)...].joined(separator: "\n"))
    }

    /// Whitespace-normalised view: LF, trailing spaces trimmed, blank runs collapsed, edges trimmed.
    static func norm(_ s: String) -> String {
        var out: [String] = []
        for l in s.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let t = l.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { if out.last != "" { out.append("") } } else { out.append(t) }
        }
        while out.first == "" { out.removeFirst() }
        while out.last == "" { out.removeLast() }
        return out.joined(separator: "\n")
    }

    /// Blank lines only separate blocks, so the text diff ignores them.
    static func noBlank(_ s: String) -> String { s.components(separatedBy: "\n").filter { !$0.isEmpty }.joined(separator: "\n") }

    static func label(_ k: StoryBlock.Kind) -> String {
        switch k {
        case .paragraph(let s): return "paragraph(\(s.components(separatedBy: "\n").count)L)"
        case .heading: return "heading"
        case .bullets(let l): return "bullets(\(l.count))"
        case .numbered(let l): return "numbered(\(l.count))"
        case .quote: return "quote"
        case .image(_, _, _, _, let full): return full ? "image-full" : "image"
        case .images(let i): return "images(\(i.count))"
        case .clip: return "clip"
        case .youtube: return "youtube"
        case .raw: return "RAW"
        }
    }

    static func main() {
        var args = Array(CommandLine.arguments.dropFirst())
        var writeDir: String?
        if let i = args.firstIndex(of: "--write"), i + 1 < args.count { writeDir = args[i + 1]; args.removeSubrange(i...(i + 1)) }
        var failures = 0
        for path in args {
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { print("!! cannot read \(path)"); failures += 1; continue }
            let md = body(of: text)
            let a = StoryBlocks.parse(md)
            let s1 = StoryBlocks.serialize(a)
            let b = StoryBlocks.parse(s1.markdown)
            let s2 = StoryBlocks.serialize(b)
            print("== \(path)")
            print("   blocks: " + a.map { label($0.kind) }.joined(separator: ", "))
            print("   words=\(StoryBlocks.wordCount(a)) readMinutes=\(StoryBlocks.readMinutes(a)) files=\(StoryBlocks.referencedFiles(a))")
            var ok = true
            if a.map(\.kind) != b.map(\.kind) { print("   FAIL parse(serialize(parse)) != parse"); ok = false }
            if s1.markdown != s2.markdown { print("   FAIL serialize not idempotent"); ok = false }
            // line ranges must slice the serialized markdown back to each block's text
            let lines = s1.markdown.components(separatedBy: "\n")
            for blk in a { if let r = s1.lineRanges[blk.id], r.upperBound > lines.count { print("   FAIL range out of bounds"); ok = false } }
            let n0 = noBlank(norm(md)), n1 = noBlank(norm(s1.markdown))
            if n0 == n1 { print("   normalised text: identical") } else {
                print("   normalised text differs (expected only for marker/list canonicalisation):")
                let l0 = n0.components(separatedBy: "\n"), l1 = n1.components(separatedBy: "\n")
                for i in 0..<max(l0.count, l1.count) {
                    let x = i < l0.count ? l0[i] : "<none>", y = i < l1.count ? l1[i] : "<none>"
                    if x != y { print("     - \(x)\n     + \(y)") }
                }
            }
            if let dir = writeDir {
                let name = (path as NSString).lastPathComponent
                try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                try? (split(text).head + "\n" + s1.markdown).write(toFile: dir + "/" + name, atomically: true, encoding: .utf8)
            }
            print(ok ? "   OK" : "   FAILED")
            if !ok { failures += 1 }
        }
        exit(failures == 0 ? 0 : 1)
    }
}
