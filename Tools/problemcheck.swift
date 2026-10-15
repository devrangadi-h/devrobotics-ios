// Checks FrameProblemEngine (local checks + pipeline rewriting). Build and run on the Mac from outside Sources/:
//   swiftc -parse-as-library -o /tmp/problemcheck Sources/DevRobotics/Frames/{FrameFormat,StoryBlocks,FrameModels,FrameProblems}.swift \
//     Sources/DevRobotics/Frames/Problems/FrameMetadata.swift Tools/problemcheck.swift && /tmp/problemcheck
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct PreviewIssue: Identifiable, Equatable {   // same shape as the app's (DraftPreviewController.swift)
    enum Level { case error, warning }
    enum Kind { case noDate, missingFile, marker, other }
    let id = UUID()
    var level: Level
    var kind: Kind
    var bodyLine: Int?
    var message: String
    var fileName: String?
}

@main
struct ProblemCheck {
    static var failures = 0
    static func check(_ ok: Bool, _ what: String) {
        print((ok ? "ok   " : "FAIL ") + what)
        if !ok { failures += 1 }
    }

    static func writeJPEG(_ url: URL, date: String?) {
        let ctx = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let img = ctx.makeImage()!
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        var props: [CFString: Any] = [:]
        if let date { props[kCGImagePropertyExifDictionary] = [kCGImagePropertyExifDateTimeOriginal: date] }
        CGImageDestinationAddImage(dest, img, props as CFDictionary)
        CGImageDestinationFinalize(dest)
    }

    static func main() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("problemcheck-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        writeJPEG(dir.appendingPathComponent("dated.jpg"), date: "2026:10:14 09:30:00")
        writeJPEG(dir.appendingPathComponent("undated.jpg"), date: nil)
        let url: (String) -> URL? = { n in
            let u = dir.appendingPathComponent(n)
            return FileManager.default.fileExists(atPath: u.path) ? u : nil
        }

        // Metadata
        check(FrameMetadata.dateTaken(of: dir.appendingPathComponent("dated.jpg")) != nil, "reads DateTimeOriginal")
        check(FrameMetadata.dateTaken(of: dir.appendingPathComponent("undated.jpg")) == nil, "no EXIF date -> nil")

        // Empty story: required fields
        var d = FrameDraft(kind: .story, slug: "", isNew: true)
        var p = FrameProblemEngine.local(draft: d, blocks: [], localFileURL: url)
        let ids = Set(p.map(\.id))
        check(ids.isSuperset(of: ["missingField:place", "missingField:title", "missingField:cover", "missingField:slug"]),
              "required fields flagged: \(ids.sorted())")
        check(p.allSatisfy { $0.severity == .error }, "required fields are errors")

        // Real story: undated cover, unused file, marker -> missing file
        d.slug = "trip"; d.fields["place"] = "Seattle"; d.fields["title"] = "Trip"; d.fields["cover"] = "undated.jpg"
        d.localFiles = ["undated.jpg", "dated.jpg"]
        d.body = "Hello\n\n<insert image ghost.jpg>\n"
        let blocks = StoryBlocks.parse(d.body)
        p = FrameProblemEngine.local(draft: d, blocks: blocks, localFileURL: url)
        let byID = Dictionary(uniqueKeysWithValues: p.map { ($0.id, $0) })
        check(byID["noDate:undated.jpg"]?.title == "The cover photo undated.jpg has no date. Set a date for this story.", "cover noDate title")
        check(byID["noDate:undated.jpg"]?.fixes == [.setDate], "noDate fix")
        check(byID["unusedFile:dated.jpg"]?.severity == .warning, "unused file warning")
        check(byID["unusedFile:dated.jpg"]?.fixes == [.insertFile("dated.jpg"), .removeFile("dated.jpg")], "unused fixes")
        let missing = byID["missingFile:ghost.jpg"]
        check(missing?.severity == .error && missing?.title == "ghost.jpg is missing from this story.", "missing marker file")
        check(missing?.blockID == blocks.last?.id && missing?.fixes == [.removeBlock(blocks.last!.id)], "missing -> block id + removeBlock")
        check(p.first?.severity == .error && p.last?.severity == .warning, "errors first")
        print("summary:", p.summaryText)

        // Date set by hand clears noDate
        d.fields["date"] = "2026-10-14"
        p = FrameProblemEngine.local(draft: d, blocks: blocks, localFileURL: url)
        check(!p.contains { $0.kind == .noDate }, "manual date clears noDate")

        // Remote files skipped
        d.fields["date"] = ""; d.localFiles = []; d.remoteFiles = ["undated.jpg"]
        p = FrameProblemEngine.local(draft: d, blocks: [], localFileURL: { _ in nil })
        check(!p.contains { $0.kind == .noDate }, "remote files skipped for date")

        // Pipeline rewriting
        let mb = blocks
        let issues: [PreviewIssue] = [
            .init(level: .error, kind: .noDate, bodyLine: nil, message: "the cover IMG_0100.HEIC has no date taken; add \"date: YYYY-MM-DD\" to the header", fileName: "IMG_0100.HEIC"),
            .init(level: .error, kind: .missingFile, bodyLine: 3, message: "MISSING_0042.HEIC is not in this story folder", fileName: "MISSING_0042.HEIC"),
            .init(level: .warning, kind: .other, bodyLine: nil, message: "not used by any insert marker or cover (it will not be published)", fileName: "IMG_0200.HEIC"),
            .init(level: .error, kind: .marker, bodyLine: 3, message: "bad insert marker syntax", fileName: nil),
            .init(level: .warning, kind: .other, bodyLine: nil, message: "something brand new", fileName: nil),
        ]
        let q = FrameProblemEngine.fromPipeline(issues, blocks: mb)
        for x in q { print("  ", x.severity, x.kind, x.id, "|", x.title, x.fixes) }
        check(q.first { $0.id == "noDate:IMG_0100.HEIC" }?.title == "The cover photo IMG_0100.HEIC has no date. Set a date for this story.", "pipeline cover noDate")
        check(q.first { $0.id == "missingFile:MISSING_0042.HEIC" }?.title == "MISSING_0042.HEIC is missing from this story.", "pipeline missing file")
        check(q.first { $0.id == "unusedFile:IMG_0200.HEIC" }?.title == "IMG_0200.HEIC isn't used anywhere in the story, so it won't be published.", "pipeline unused")
        check(q.first { $0.kind == .invalidMarker }?.title == "This block's insert line isn't valid.", "pipeline marker")
        check(q.first { $0.kind == .invalidMarker }?.fixes == [.showText(mb.last!.id)], "marker -> showText(block by line)")
        check(q.first { $0.kind == .other }?.title == "something brand new", "unknown stays raw")
        check(q.first { $0.kind == .unusedFile }?.severity == .warning, "level -> severity")

        // Frames list packing (FramesLayoutPacker). P = photo, S = story.
        func pk(_ s: String, _ pull: Bool) -> [FramesLayoutPacker.Slot] {
            FramesLayoutPacker.pack(isPhoto: s.map { $0 == "P" }, pullForward: pull)
        }
        check(pk("PSPPS", true) == [.pair(0, 2), .story(1), .wide(3), .story(4)], "tidy pulls next photo forward: \(pk("PSPPS", true))")
        check(pk("PSPPS", false) == [.wide(0), .story(1), .pair(2, 3), .story(4)], "chronological: lone photo wide")
        check(pk("PPP", true) == [.pair(0, 1), .wide(2)], "trailing lone photo wide")
        check(pk("PS", true) == [.wide(0), .story(1)], "no later photo -> wide")
        check(pk("SS", false) == [.story(0), .story(1)], "stories only")
        check(pk("", true).isEmpty, "empty")
        for s in ["PSPSPSP", "PPSPPSP", "SPSPPPS"] {
            for pull in [true, false] {
                let slots = pk(s, pull)
                var seen: [Int] = []
                for sl in slots { switch sl { case .story(let i), .wide(let i): seen.append(i); case .pair(let a, let b): seen += [a, b] } }
                check(seen.sorted() == Array(0..<s.count), "\(s) pull=\(pull) uses every item once")
            }
        }

        try? FileManager.default.removeItem(at: dir)
        print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }
}
