import SwiftUI

/// Card for a clip block: poster/thumbnail, duration badge ("0:08"), a "Trimmed" mark, tap to play inline (muted, looping),
/// tap again to expand. Owned by the "clips + server" agent (implementation); the story editor's BlockViews uses it.
/// Local clips (just added) play from the draft folder; clips already on the Pi stream a small preview via
/// `GET v1/frames/<kind>/<slug>/clip/<name>` (see docs/problems-contract.md).
struct ClipCardView: View {
    let model: DraftEditorModel
    let name: String
    var trimmed = false

    var body: some View {   // STUB
        RoundedRectangle(cornerRadius: DS.Radius.control).fill(.quaternary).frame(height: 180)
            .overlay { Image(systemName: "play.fill").font(.largeTitle) }
    }
}
