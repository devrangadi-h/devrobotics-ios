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

enum StoryBlocks {
    static func parse(_ markdown: String) -> [StoryBlock] { [StoryBlock(kind: .raw(markdown))] }   // STUB
    static func serialize(_ blocks: [StoryBlock]) -> SerializedStory {                          // STUB
        SerializedStory(markdown: blocks.map { if case .raw(let s) = $0.kind { return s } else { return "" } }.joined(separator: "\n\n"), lineRanges: [:])
    }
    /// Names of media files the blocks reference (for "unused file" cleanup).
    static func referencedFiles(_ blocks: [StoryBlock]) -> [String] { [] }                     // STUB
    /// Words in text-like blocks, and the site's read-time rule (see Pi render.py read_minutes).
    static func wordCount(_ blocks: [StoryBlock]) -> Int { 0 }                                 // STUB
}
