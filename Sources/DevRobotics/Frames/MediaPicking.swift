import SwiftUI
import PhotosUI
import AVFoundation
import UniformTypeIdentifiers

/// Original bytes of a picked photo/video, copied to a temp file (no UIImage re-encoding, HEIC preserved).
struct PickedFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            PickedFile(url: try Self.copy(received.file))
        }
        FileRepresentation(importedContentType: .movie) { received in
            PickedFile(url: try Self.copy(received.file))
        }
    }

    private static func copy(_ src: URL) throws -> URL {
        let ext = src.pathExtension
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("pick-\(UUID().uuidString)" + (ext.isEmpty ? "" : ".\(ext)"))
        try FileManager.default.copyItem(at: src, to: dest)
        return dest
    }
}

struct PickedMedia {
    var url: URL
    var name: String
    var isVideo: Bool
    /// Longer than the 10 s limit: the caller must run it through the trimmer before use.
    var needsTrim = false
}

struct MediaError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum MediaPicking {
    static let maxClipSeconds = 10.0

    /// Load one picker item as original bytes with a safe IMG_xxxx name. Live Photos load as the still.
    static func load(_ item: PhotosPickerItem) async throws -> PickedMedia {
        guard let file = try await item.loadTransferable(type: PickedFile.self) else {
            throw MediaError(message: "Could not read the selected item.")
        }
        var ext = file.url.pathExtension.lowercased()
        // Decide from what was actually loaded (a Live Photo lists a movie type too, but we got the still).
        var isVideo = FrameFormat.clipExts.contains(ext)
        if ext.isEmpty {
            isVideo = item.supportedContentTypes.allSatisfy { $0.conforms(to: .movie) }
            if let t = item.supportedContentTypes.first(where: { $0.conforms(to: isVideo ? .movie : .image) }) {
                ext = t.preferredFilenameExtension?.lowercased() ?? ""
            }
        }
        let ok = isVideo ? FrameFormat.clipExts : FrameFormat.imageExts
        guard ok.contains(ext) else {
            try? FileManager.default.removeItem(at: file.url)
            throw MediaError(message: "Unsupported \(isVideo ? "video" : "photo") format \"\(ext.isEmpty ? "unknown" : ext)\". Use \(isVideo ? "MP4/MOV" : "JPEG or HEIC").")
        }
        var needsTrim = false
        if isVideo {
            let secs = await duration(of: file.url)
            needsTrim = secs > maxClipSeconds + 0.05
        }
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyyMMdd_HHmmss"
        let name = "IMG_\(stamp.string(from: Date()))_\(Int.random(in: 100...999)).\(ext)"
        // Keep the file extension intact for the later import step.
        return PickedMedia(url: file.url, name: name, isVideo: isVideo, needsTrim: needsTrim)
    }

    static func duration(of url: URL) async -> Double {
        (try? await AVURLAsset(url: url).load(.duration).seconds) ?? 0
    }

    /// Name for a trimmed file: same base name, the extension of the file the trimmer produced.
    static func renamed(_ name: String, forFileAt url: URL) -> String {
        let base = (name as NSString).deletingPathExtension
        let ext = url.pathExtension.lowercased()
        return ext.isEmpty ? name : "\(base).\(ext)"
    }
}
