import SwiftUI

// Shared problem UI. Owned by the "problems core" agent (implementations); used by the story editor, the photo editor and
// the Frames list. Keep these public signatures stable (other agents code against them).

/// Compact pinned chip: "1 error · 1 warning". Red when any error, amber when only warnings; hidden when empty.
struct ProblemsPill: View {
    let problems: [FrameProblem]
    var action: () -> Void

    var body: some View {
        let hasError = !problems.errors.isEmpty
        Group {
            if !problems.isEmpty {
                Button(action: action) {
                    HStack(spacing: DS.Space.xs) {
                        Image(systemName: hasError ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                            .imageScale(.small)
                            .contentTransition(.symbolEffect(.replace))
                        Text(problems.summaryText).contentTransition(.numericText())
                        Image(systemName: "chevron.up").imageScale(.small).opacity(0.7)
                    }
                    .font(Theme.font(13, weight: .semibold, relativeTo: .footnote))
                    .padding(.horizontal, DS.Space.m)
                    .padding(.vertical, 7)
                    .glassEffect(.regular.tint((hasError ? Color.red : Theme.warn).opacity(0.5)).interactive(), in: .capsule)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Problems: \(problems.summaryText)")
                .accessibilityHint("Shows what needs fixing")
                .transition(.scale(scale: 0.8, anchor: .top).combined(with: .opacity))
            }
        }
        .dsAnimation(value: problems.map(\.id))
    }
}

/// Compact bottom-sheet list. `onFix` performs a fix action; `onSelect` scrolls to / highlights the problem's block.
struct ProblemsSheet: View {
    let problems: [FrameProblem]
    var onFix: (FrameProblem, FrameProblem.Fix) -> Void
    var onSelect: (FrameProblem) -> Void

    var body: some View {
        NavigationStack {
            Group {
                if problems.isEmpty {
                    ContentUnavailableView("No problems", systemImage: "checkmark.circle",
                                           description: Text("Everything looks ready to send."))
                } else {
                    ScrollView {
                        LazyVStack(spacing: DS.Space.m) {
                            ForEach(problems) { p in row(p).transition(.opacity.combined(with: .scale(scale: 0.96))) }
                        }
                        .padding(.horizontal, DS.Space.l)
                        .padding(.vertical, DS.Space.s)
                    }
                }
            }
            .navigationTitle(problems.isEmpty ? "Problems" : problems.summaryText)
            .navigationBarTitleDisplayMode(.inline)
            .dsAnimation(value: problems.map(\.id))
        }
        .presentationDetents([.fraction(0.4), .large])
        .presentationDragIndicator(.visible)
    }

    private func row(_ p: FrameProblem) -> some View {
        let isError = p.severity == .error
        return VStack(alignment: .leading, spacing: DS.Space.s) {
            Button { onSelect(p) } label: {
                HStack(alignment: .top, spacing: DS.Space.m) {
                    Image(systemName: isError ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(isError ? Color.red : Theme.warn)
                        .font(.system(size: 18))
                        .accessibilityLabel(isError ? "Error" : "Warning")
                    VStack(alignment: .leading, spacing: 2) {
                        Text(p.title).font(Theme.font(15, weight: .semibold, relativeTo: .subheadline))
                            .foregroundStyle(.primary).multilineTextAlignment(.leading)
                        if let d = p.detail {
                            Text(d).font(Theme.font(13, relativeTo: .footnote)).foregroundStyle(.secondary)
                                .multilineTextAlignment(.leading)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if !p.fixes.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: DS.Space.s) {
                        ForEach(Array(p.fixes.enumerated()), id: \.offset) { _, fix in
                            Button(label(for: fix, file: p.fileName)) { onFix(p, fix) }
                                .buttonStyle(.glass)
                                .font(Theme.font(13, weight: .semibold, relativeTo: .footnote))
                        }
                    }
                }
                .padding(.leading, 30)
            }
        }
        .padding(DS.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: DS.Radius.control))
        .accessibilityElement(children: .contain)
    }

    private func label(for fix: FrameProblem.Fix, file: String?) -> String {
        switch fix {
        case .setDate: "Set a date"
        case .insertFile(let n): FrameFormat.isClip(n) ? "Insert as clip" : "Insert as photo"
        case .removeFile: "Remove file"
        case .removeBlock: "Remove block"
        case .showText: "Show text"
        case .openDetails: "Fix in Details"
        }
    }
}

/// "Set a date": graphical calendar, one Save button. `initial` = file creation date if known, else today.
struct SetDateSheet: View {
    let initial: Date
    var onSave: (Date) -> Void
    @State private var date: Date
    @Environment(\.dismiss) private var dismiss

    init(initial: Date, onSave: @escaping (Date) -> Void) {
        self.initial = initial
        self.onSave = onSave
        _date = State(initialValue: initial)
    }

    var body: some View {
        VStack(spacing: DS.Space.l) {
            Text("Set a date").font(Theme.font(20, weight: .semibold, relativeTo: .title3))
            DatePicker("Date", selection: $date, in: ...Date.distantFuture, displayedComponents: .date)
                .datePickerStyle(.graphical)
                .labelsHidden()
            Button {
                onSave(date)
                dismiss()
            } label: {
                Text("Save")
            }
            .buttonStyle(.primaryAction)
        }
        .padding(DS.Space.l)
        .presentationDetents([.height(560), .large])
        .presentationDragIndicator(.visible)
    }
}
