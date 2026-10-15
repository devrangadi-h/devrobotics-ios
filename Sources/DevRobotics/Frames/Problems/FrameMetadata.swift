import Foundation
import ImageIO

/// Reads photo dates with ImageIO (header only, cheap). Results are cached per file path, size and mtime.
enum FrameMetadata {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: Date?] = [:]

    /// "yyyy-MM-dd", the format of the `date` front-matter field.
    static let fieldFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static func exifFormatter() -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return f
    }

    /// DateTimeOriginal / DateTimeDigitized / TIFF DateTime, or nil when the file carries no date.
    static func dateTaken(of url: URL) -> Date? {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let key = "\(url.path)|\((attrs?[.size] as? Int) ?? 0)|\((attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)"
        lock.lock()
        if let hit = cache[key] { lock.unlock(); return hit }
        lock.unlock()
        let value = read(url)
        lock.lock(); cache[key] = .some(value); lock.unlock()
        return value
    }

    /// The file's creation date from the file system (used to start the date sheet), when known.
    static func creationDate(of url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.creationDate] as? Date
    }

    private static func read(_ url: URL) -> Date? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return nil }
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let candidates: [Any?] = [exif?[kCGImagePropertyExifDateTimeOriginal], exif?[kCGImagePropertyExifDateTimeDigitized],
                                  tiff?[kCGImagePropertyTIFFDateTime]]
        let f = exifFormatter()
        for c in candidates {
            if let s = c as? String, let d = f.date(from: s.trimmingCharacters(in: .whitespaces)) { return d }
        }
        return nil
    }
}
