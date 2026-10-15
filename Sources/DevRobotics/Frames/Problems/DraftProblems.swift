import SwiftUI

extension DraftEditorModel {
    /// Instant problems for this draft (local checks) plus unrecognised messages from the last send as warnings.
    /// Stories: pass the editor's current `blocks` (defaults to parsing the saved body).
    func problems(blocks: [StoryBlock]? = nil) -> [FrameProblem] {
        let b = draft.kind == .story ? (blocks ?? StoryBlocks.parse(draft.body)) : []
        let local = FrameProblemEngine.local(draft: draft, blocks: b, localFileURL: { n in
            draft.localFiles.contains(n) ? mediaURL(n) : nil
        })
        return FrameProblemEngine.merge(local, FrameProblems.lastSend(of: draft, blocks: b))
    }

    /// Date sheet start: the manual date, else the date taken / creation date of the entry's first local photo, else today.
    var dateSheetInitial: Date {
        if let d = FrameMetadata.fieldFormatter.date(from: draft.field("date")) { return d }
        let names = ([draft.field("cover")] + draft.allFiles).filter { !$0.isEmpty && FrameFormat.isImage($0) && draft.localFiles.contains($0) }
        for n in names {
            let u = mediaURL(n)
            if let d = FrameMetadata.dateTaken(of: u) ?? FrameMetadata.creationDate(of: u) { return d }
        }
        return Date()
    }

    func setDate(_ date: Date) { draft.fields["date"] = FrameMetadata.fieldFormatter.string(from: date) }
    func clearDate() { draft.fields["date"] = "" }
}

enum FrameProblems {
    /// Server messages from the last failed send. Only messages the engine can't explain are kept: the rest are
    /// covered (and kept fresh) by the local checks. They're warnings so a stale message can never block sending.
    static func lastSend(of draft: FrameDraft, blocks: [StoryBlock]) -> [FrameProblem] {
        var msgs = draft.problems
        if let e = draft.lastError, draft.validation.isEmpty, !msgs.contains(e) { msgs.append(e) }
        let issues = msgs.map { PreviewIssue(level: .warning, kind: .other, bodyLine: nil, message: $0, fileName: nil) }
        return FrameProblemEngine.fromPipeline(issues, blocks: blocks).filter { $0.kind == .other }
    }
}

/// "Date" row: "From the photo" / "Set manually: 14 Oct 2026". Tap opens the Set a date sheet.
/// Present with `.sheet(isPresented: $showDate) { SetDateSheet(initial: model.dateSheetInitial) { model.setDate($0) } }`.
struct DateSourceRow: View {
    let model: DraftEditorModel
    @Binding var showSheet: Bool

    private var manual: Date? { FrameMetadata.fieldFormatter.date(from: model.draft.field("date")) }

    var body: some View {
        Button { showSheet = true } label: {
            HStack {
                Label("Date", systemImage: "calendar")
                Spacer(minLength: DS.Space.m)
                Text(manual.map { "Set manually: \($0.formatted(.dateTime.day().month(.abbreviated).year()))" } ?? "From the photo")
                    .foregroundStyle(.secondary)
                    .contentTransition(.opacity)
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .dsAnimation(.dsSnappy, value: model.draft.field("date"))
        if manual != nil {
            Button("Use the photo's date") { withAnimation(.dsSnappy) { model.clearDate() } }
        }
    }
}
