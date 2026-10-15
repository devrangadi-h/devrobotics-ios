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
        if isVideo {
            let asset = AVURLAsset(url: file.url)
            let secs = (try? await asset.load(.duration).seconds) ?? 0
            if secs > maxClipSeconds + 0.05 {
                try? FileManager.default.removeItem(at: file.url)
                throw MediaError(message: String(format: "That clip is %.0f s; clips must be 10 s or shorter. Trim it in Photos first.", secs))
            }
        }
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyyMMdd_HHmmss"
        let name = "IMG_\(stamp.string(from: Date()))_\(Int.random(in: 100...999)).\(ext)"
        // Keep the file extension intact for the later import step.
        return PickedMedia(url: file.url, name: name, isVideo: isVideo)
    }
}
