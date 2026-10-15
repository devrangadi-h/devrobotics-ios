import SwiftUI

/// Shared bits for the photo and story editors.

struct SlugRow: View {
    @Bindable var model: DraftEditorModel
    var body: some View {
        if model.draft.isNew {
            VStack(alignment: .leading, spacing: 4) {
                TextField("slug", text: Binding(get: { model.draft.slug },
                                                set: { model.draft.slug = $0.lowercased().replacingOccurrences(of: " ", with: "-") }))
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .font(.system(.body, design: .monospaced))
                if !model.draft.slug.isEmpty && !FrameFormat.isValidSlug(model.draft.slug) {
                    Text("Lowercase letters, digits and single hyphens only.").font(.caption).foregroundStyle(.red)
                } else {
                    Text("Becomes the link. Can't be changed after publishing.").font(.caption).foregroundStyle(.secondary)
                }
            }
        } else {
            LabeledContent("Slug", value: model.draft.slug).font(.system(.body, design: .monospaced))
        }
    }
}

struct GPSRow: View {
    @Bindable var model: DraftEditorModel
    var body: some View {
        Toggle("Show GPS location", isOn: Binding(get: { model.draft.field("gps") != "hide" },
                                                 set: { model.draft.fields["gps"] = $0 ? "show" : "hide" }))
    }
}

struct DateRow: View {
    @Bindable var model: DraftEditorModel
    private static let fmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    var body: some View {
        let has = !model.draft.field("date").isEmpty
        Toggle("Override date", isOn: Binding(get: { has }, set: { on in
            model.draft.fields["date"] = on ? Self.fmt.string(from: Date()) : ""
        }))
        if has {
            DatePicker("Date", selection: Binding(
                get: { Self.fmt.date(from: model.draft.field("date")) ?? Date() },
                set: { model.draft.fields["date"] = Self.fmt.string(from: $0) }), displayedComponents: .date)
        }
    }
}

struct ProblemsView: View {
    let draft: FrameDraft
    var body: some View {
        if let e = draft.lastError {
            Label(e, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.callout)
        }
        ForEach(draft.problems, id: \.self) { p in
            Label(p, systemImage: "exclamationmark.circle").foregroundStyle(.orange).font(.callout)
        }
    }
}

/// Large image; tap sets the crop focus point (stored as "x% y%").
struct FocusImage: View {
    let source: ThumbSource?
    @Binding var focus: String
    @Environment(SettingsStore.self) private var settings
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
                    .overlay {
                        GeometryReader { g in
                            let f = FrameFormat.parseFocus(focus) ?? (0.5, 0.5)
                            ZStack {
                                Circle().stroke(.white, lineWidth: 3).frame(width: 30, height: 30)
                                Circle().stroke(Theme.accent, lineWidth: 1.5).frame(width: 36, height: 36)
                            }
                            .shadow(radius: 2)
                            .position(x: f.x * g.size.width, y: f.y * g.size.height)
                            .allowsHitTesting(false)
                            Color.clear.contentShape(Rectangle())
                                .onTapGesture(coordinateSpace: .local) { p in
                                    focus = FrameFormat.focusString(x: p.x / max(g.size.width, 1), y: p.y / max(g.size.height, 1))
                                }
                        }
                    }
            } else {
                ZStack { Color(.secondarySystemBackground); ProgressView() }.frame(height: 240)
            }
        }
        .task(id: source) {
            guard let source else { return }
            image = await ThumbLoading.image(source, settings: settings, width: 1000)
        }
    }
}

struct FilesSection: View {
    @Bindable var model: DraftEditorModel
    var body: some View {
        Section("Files in this story") {
            if model.draft.allFiles.isEmpty { Text("No files yet.").foregroundStyle(.secondary) }
            ForEach(model.draft.allFiles, id: \.self) { n in
                HStack {
                    FrameThumb(source: model.source(for: n)).frame(width: 48, height: 48).clipShape(RoundedRectangle(cornerRadius: 6))
                    VStack(alignment: .leading) {
                        Text(n).font(.callout).lineLimit(1)
                        Text(model.draft.localFiles.contains(n) ? "Not sent yet" : "On Polaris")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if model.draft.field("cover") == n { Text("Cover").font(.caption.bold()).foregroundStyle(Theme.accent) }
                    else if FrameFormat.isImage(n) {
                        Button("Set cover") { model.draft.fields["cover"] = n }.font(.caption).buttonStyle(.borderless)
                    }
                }
                .swipeActions { Button("Remove", role: .destructive) { model.remove(n) } }
            }
        }
    }
}

struct SmallBanner: View {
    let text: String
    var tint: Color = .orange
    var body: some View {
        Label(text, systemImage: "wifi.exclamationmark")
            .font(.footnote)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(tint.opacity(0.15))
    }
}
