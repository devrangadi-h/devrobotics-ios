import SwiftUI
import PhotosUI

struct PhotoEditorView: View {
    @Bindable var model: DraftEditorModel
    @State private var item: PhotosPickerItem?
    @State private var pickedCount = 0
    @State private var showProblems = false
    @State private var showDate = false

    private func fix(_ f: FrameProblem.Fix) {
        switch f {
        case .setDate:
            showProblems = false
            Task { try? await Task.sleep(for: .milliseconds(350)); showDate = true }
        case .openDetails: showProblems = false      // Details fields are on this screen
        default: break
        }
    }

    var body: some View {
        Form {
            Section {
                VStack(spacing: DS.Space.m) {
                    if let name = model.draft.thumbName {
                        PhotoFocusPicker(source: model.source(for: name), focus: model.binding("focus"))
                            .transition(.scale(scale: 0.96).combined(with: .opacity))
                        Label("Tap or drag to choose the centre of the square crop.", systemImage: "scope")
                            .font(Theme.font(12, relativeTo: .caption)).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    PhotosPicker(selection: $item, matching: .images, preferredItemEncoding: .current, photoLibrary: .shared()) {
                        Label(model.draft.thumbName == nil ? "Choose photo" : "Replace photo",
                              systemImage: "photo.badge.plus")
                    }
                    .buttonStyle(PhotoPickButtonStyle(secondary: model.draft.thumbName != nil))
                    if model.busy {
                        HStack { ProgressView(); Text("Reading original…").font(.footnote).foregroundStyle(.secondary) }
                    }
                    if let n = model.draft.thumbName {
                        Text("\(n) · original, unmodified")
                            .font(Theme.font(11, mono: true, relativeTo: .caption2)).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
                .listRowInsets(EdgeInsets(top: DS.Space.m, leading: DS.Space.l, bottom: DS.Space.m, trailing: DS.Space.l))
                .listRowBackground(Color.clear)
            }
            Section("Details") {
                TextField("Place (required)", text: model.binding("place", suggestsSlug: true))
                SlugRow(model: model)
                TextField("Alt text (describe the photo)", text: model.binding("alt"), axis: .vertical)
            }
            Section("Options") {
                GPSRow(model: model)
                DateSourceRow(model: model, showSheet: $showDate)
            }
            Section("Note") {
                TextEditor(text: model.bodyBinding)
                    .frame(minHeight: 120)
                    .autocorrectionDisabled(false)
            }
            if !model.draft.dirty && model.problems().isEmpty {
                // Opened from the Pi and not edited yet: nothing is queued for sending.
                Section {
                    Label("No changes to send", systemImage: "equal.circle").foregroundStyle(.secondary)
                }
            }
        }
        .dsPage()
        .dsAnimation(value: model.draft.thumbName)
        .safeAreaInset(edge: .top, spacing: 0) {
            let problems = model.problems()
            if !problems.isEmpty {
                ProblemsPill(problems: problems) { showProblems = true }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, DS.Space.xs)
            }
        }
        .sheet(isPresented: $showProblems) {
            ProblemsSheet(problems: model.problems(), onFix: { _, f in fix(f) }, onSelect: { _ in })
        }
        .sheet(isPresented: $showDate) {
            SetDateSheet(initial: model.dateSheetInitial) { model.setDate($0) }
        }
        .sensoryFeedback(.success, trigger: pickedCount)
        .onChange(of: item) { _, new in
            guard let new else { return }
            Task { await pick(new) }
        }
        .alert("Problem", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(model.error ?? "") }
    }

    private func pick(_ it: PhotosPickerItem) async {
        model.busy = true
        defer { model.busy = false; item = nil }
        do {
            let media = try await MediaPicking.load(it)
            if media.isVideo { try? FileManager.default.removeItem(at: media.url); model.error = "Pick a photo, not a video."; return }
            model.add(media)
            model.draft.fields["focus"] = nil
            pickedCount += 1
        } catch {
            model.error = error.localizedDescription
        }
    }
}

/// Pick button (tinted primary, or plain glass once a photo exists), local to the photo editor.
private struct PhotoPickButtonStyle: ButtonStyle {
    var secondary = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.font(15, weight: .semibold, relativeTo: .body))
            .foregroundStyle(secondary ? Theme.accent : Theme.accentContrast)
            .padding(.vertical, DS.Space.m)
            .frame(maxWidth: .infinity)
            .glassEffect(secondary ? .regular.interactive() : .regular.tint(Theme.accent).interactive(),
                         in: .rect(cornerRadius: DS.Radius.control))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.dsSnappy, value: configuration.isPressed)
    }
}
