import Foundation

/// Packs list items so every grid row is full: photos pair up, stories span the row, and a photo that would be left
/// alone becomes a wide tile. Pure and index-based so it can be checked without UI (Tools/problemcheck.swift).
enum FramesLayoutPacker {
    enum Slot: Equatable {
        case story(Int)
        case pair(Int, Int)
        case wide(Int)
    }

    /// `isPhoto[i]` per item in display order. `pullForward`: when a story would follow a single unpaired photo,
    /// take the next photo from later in the list to pair with it (Tidy). Without it (Chronological / Recently edited)
    /// order is kept exactly and the lone photo becomes wide.
    static func pack(isPhoto: [Bool], pullForward: Bool) -> [Slot] {
        var out: [Slot] = []
        var consumed = Set<Int>()
        var pending: Int?
        for i in isPhoto.indices where !consumed.contains(i) {
            if isPhoto[i] {
                if let p = pending { out.append(.pair(p, i)); pending = nil } else { pending = i }
            } else {
                if let p = pending {
                    if pullForward, let j = ((i + 1)..<isPhoto.count).first(where: { isPhoto[$0] && !consumed.contains($0) }) {
                        out.append(.pair(p, j)); consumed.insert(j)
                    } else {
                        out.append(.wide(p))
                    }
                    pending = nil
                }
                out.append(.story(i))
            }
        }
        if let p = pending { out.append(.wide(p)) }
        return out
    }
}
