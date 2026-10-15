import SwiftUI
import UIKit

/// Looks-only chrome for the story editor: hero cover, floating mode switch / add control, footer chip.
/// Nothing here touches the text view, parsing or document model.

// MARK: - keyboard visibility (so floating chrome gets out of the keyboard accessory's way)

private struct StoryKeyboardVisibility: ViewModifier {
    @Binding var visible: Bool
    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
                withAnimation(.dsSnappy) { visible = true }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
                withAnimation(.dsSnappy) { visible = false }
            }
    }
}

extension View {
    func storyTracksKeyboard(_ visible: Binding<Bool>) -> some View {
        modifier(StoryKeyboardVisibility(visible: visible))
    }
}

// MARK: - hero cover

struct StoryCoverHero: View {
    @Bindable var model: DraftEditorModel
    @Binding var title: String
    var titleFocus: FocusState<Bool>.Binding
    var placeFocus: FocusState<Bool>.Binding
    let busy: Bool
    let onPickCover: () -> Void

    private var coverName: String? {
        let c = model.draft.field("cover")
        return (!c.isEmpty && model.draft.allFiles.contains(c)) ? c : nil
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Button(action: onPickCover) { backdrop }
                .buttonStyle(.pressable)
                .accessibilityLabel(coverName == nil ? "Add cover photo" : "Replace cover photo")
            plate
        }
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card + 4, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
    }

    @ViewBuilder private var backdrop: some View {
        ZStack(alignment: .topTrailing) {
            if let name = coverName {
                Color.clear
                    .frame(maxWidth: .infinity).frame(height: 320)
                    .overlay { FrameThumb(source: model.source(for: name)) }
                    .clipped()
            } else {
                LinearGradient(colors: [Theme.accent.opacity(0.55), Color(red: 0.38, green: 0.36, blue: 0.95).opacity(0.5)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                    .frame(maxWidth: .infinity, minHeight: 320, maxHeight: 320)
                    .overlay(alignment: .top) {
                        VStack(spacing: DS.Space.s) {
                            Image(systemName: "photo.badge.plus").font(.system(size: 34, weight: .medium))
                                .symbolEffect(.pulse)
                            Text("Add a cover photo").font(Theme.font(15, weight: .medium, relativeTo: .callout))
                        }
                        .foregroundStyle(.white.opacity(0.9))
                        .padding(.top, 48)
                    }
            }
            LinearGradient(colors: [.clear, .clear, .black.opacity(0.6)], startPoint: .top, endPoint: .bottom)
                .allowsHitTesting(false)
            if coverName != nil {
                Label(busy ? "Reading…" : "Replace", systemImage: busy ? "hourglass" : "photo.badge.plus")
                    .font(Theme.font(12, weight: .semibold, relativeTo: .caption))
                    .padding(.horizontal, DS.Space.m).padding(.vertical, 8)
                    .glassEffect(.regular, in: .capsule)
                    .padding(DS.Space.m)
            }
        }
    }

    private var plate: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            TextField("", text: $title, axis: .vertical)
                .focused(titleFocus)
                .lineLimit(1...6)
                .font(Theme.font(28, weight: .bold, relativeTo: .largeTitle))
                .textInputAutocapitalization(.sentences)
                .submitLabel(.done)
                .fixedSize(horizontal: false, vertical: true)
                .overlay(alignment: .topLeading) {
                    if title.isEmpty {
                        Text("Add a title").font(Theme.font(28, weight: .bold, relativeTo: .largeTitle))
                            .foregroundStyle(.tertiary).allowsHitTesting(false)
                    }
                }
            HStack(spacing: DS.Space.xs) {
                Image(systemName: "mappin.and.ellipse").foregroundStyle(.secondary)
                TextField("Add a place", text: model.binding("place"))
                    .focused(placeFocus)
                    .submitLabel(.done)
                    .onSubmit { placeFocus.wrappedValue = false }
                    .textInputAutocapitalization(.words)
                    .font(Theme.font(14, weight: .medium, relativeTo: .subheadline))
            }
            .frame(minHeight: 28)
        }
        .padding(DS.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: DS.Radius.card))
        .padding(DS.Space.m)
    }
}

// MARK: - floating mode switch + add

struct StoryFloatingBar: View {
    @Binding var mode: StoryEditorView.Mode
    let onAdd: (AddAction) -> Void
    var collapsed = false
    var onExpand: () -> Void = {}
    @Namespace private var ns

    var body: some View {
        Group {
            if collapsed {
                Button(action: onExpand) {
                    Image(systemName: mode == .write ? "square.and.pencil" : "eye")
                        .font(.system(size: 17, weight: .semibold))
                        .frame(width: 48, height: 48)
                        .glassEffect(.regular.interactive(), in: .circle)
                        .padding(DS.Space.xs)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Show Write, Preview and add")
                .frame(maxWidth: .infinity, alignment: .trailing)
                .transition(.scale(scale: 0.8, anchor: .trailing).combined(with: .opacity))
            } else {
                expanded.transition(.scale(scale: 0.9, anchor: .trailing).combined(with: .opacity))
            }
        }
        .padding(.horizontal, DS.Space.l)
        .padding(.bottom, DS.Space.s)
        .frame(height: StoryFloatingBar.height, alignment: .bottom)
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)   // fixed-height floating chrome: cap so labels never truncate
        .dsAnimation(.dsSpring, value: collapsed)
    }

    /// Fixed so collapsing never changes the bottom inset (no scroll feedback loop).
    static let height: CGFloat = 76

    private var expanded: some View {
        GlassEffectContainer(spacing: DS.Space.m) {
            HStack(spacing: DS.Space.s) {
                ForEach(StoryEditorView.Mode.allCases, id: \.self) { m in
                    segment(m)
                }
                if mode == .write {
                    AddMenu(onPick: onAdd) {
                        Image(systemName: "plus")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(Theme.accentContrast)
                            .frame(width: 48, height: 48)
                            .glassEffect(.regular.tint(Theme.accent).interactive(), in: .circle)
                            .glassEffectID("add", in: ns)
                            .padding(DS.Space.xs)
                    }
                    .accessibilityLabel("Add block")
                }
            }
        }
        .sensoryFeedback(.selection, trigger: mode)
    }

    private func segment(_ m: StoryEditorView.Mode) -> some View {
        let on = mode == m
        return Button {
            withAnimation(.dsSpring) { mode = m }
        } label: {
            Label(m.rawValue, systemImage: m == .write ? "square.and.pencil" : "eye")
                .font(Theme.font(15, weight: .semibold, relativeTo: .callout))
                .symbolEffect(.bounce, value: on)
                .foregroundStyle(on ? Theme.accentContrast : Color.primary)
                .padding(.horizontal, DS.Space.l)
                .frame(height: 48)
                .glassEffect(on ? Glass.regular.tint(Theme.accent).interactive() : Glass.regular.interactive(), in: .capsule)
                .glassEffectID(m.rawValue, in: ns)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

// MARK: - footer chip

struct StoryFooterChip: View {
    let words: Int
    let minutes: Int
    let savedAt: Date

    var body: some View {
        HStack(spacing: DS.Space.m) {
            Label("\(words) words" + (minutes > 0 ? " · \(minutes) min" : ""), systemImage: "text.word.spacing")
                .contentTransition(.numericText())
            Label("Saved \(savedAt.formatted(date: .omitted, time: .shortened))", systemImage: "checkmark.circle")
                .symbolEffect(.bounce, value: savedAt)
        }
        .font(Theme.font(12, weight: .medium, relativeTo: .caption))
        .foregroundStyle(.secondary)
        .padding(.horizontal, DS.Space.l).padding(.vertical, DS.Space.s)
        .glassEffect(.regular, in: .capsule)
        .frame(maxWidth: .infinity)
        .dsAnimation(value: words)
        .accessibilityElement(children: .combine)
    }
}
