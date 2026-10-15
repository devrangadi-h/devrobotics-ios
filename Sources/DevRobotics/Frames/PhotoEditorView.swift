import SwiftUI
import PhotosUI

struct PhotoEditorView: View {
    @Bindable var model: DraftEditorModel
    @State private var item: PhotosPickerItem?

    var body: some View {
        Form {
            Section {
                if let name = model.draft.thumbName {
                    FocusImage(source: model.source(for: name), focus: model.binding("focus"))
                        .listRowInsets(EdgeInsets())
                    Text("Tap the photo to set where the square crop is centred.").font(.caption).foregroundStyle(.secondary)
                }
                PhotosPicker(selection: $item, matching: .images, photoLibrary: .shared()) {
                    Label(model.draft.thumbName == nil ? "Choose photo" : "Replace photo", systemImage: "photo.badge.plus")
                }
                if model.busy { ProgressView("Reading original…") }
                if let n = model.draft.thumbName {
                    Text("\(n) • original, unmodified").font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Details") {
                TextField("Place (required)", text: model.binding("place", suggestsSlug: true))
                SlugRow(model: model)
                GPSRow(model: model)
                TextField("Alt text (describe the photo)", text: model.binding("alt"), axis: .vertical)
                DateRow(model: model)
            }
            Section("Note") {
                TextEditor(text: model.bodyBinding)
                    .frame(minHeight: 120)
                    .autocorrectionDisabled(false)
            }
            let problems = model.draft.lastError != nil || !model.draft.problems.isEmpty
            if problems { Section("Problems") { ProblemsView(draft: model.draft) } }
            let v = model.draft.validation
            if !v.isEmpty {
                Section("Before sending") { ForEach(v, id: \.self) { Label($0, systemImage: "info.circle").font(.callout) } }
            }
        }
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
        } catch {
            model.error = error.localizedDescription
        }
    }
}
