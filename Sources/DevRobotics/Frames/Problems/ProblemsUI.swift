import SwiftUI

// Shared problem UI. Owned by the "problems core" agent (implementations); used by the story editor, the photo editor and
// the Frames list. STUBS: keep these public signatures stable (other agents code against them).

/// Compact pinned chip: "1 error · 1 warning". Red when any error, amber when only warnings; hidden when empty.
struct ProblemsPill: View {
    let problems: [FrameProblem]
    var action: () -> Void
    var body: some View { EmptyView() }   // STUB
}

/// Compact bottom-sheet list. `onFix` performs a fix action; `onSelect` scrolls to / highlights the problem's block.
struct ProblemsSheet: View {
    let problems: [FrameProblem]
    var onFix: (FrameProblem, FrameProblem.Fix) -> Void
    var onSelect: (FrameProblem) -> Void
    var body: some View { EmptyView() }   // STUB
}

/// "Set a date": graphical calendar, one Save button. `initial` = file creation date if known, else today.
struct SetDateSheet: View {
    let initial: Date
    var onSave: (Date) -> Void
    var body: some View { EmptyView() }   // STUB
}
