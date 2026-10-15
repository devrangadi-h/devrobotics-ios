import SwiftUI
import ImageIO

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
                    Text("Lowercase letters, digits and single hyphens only.").font(.caption).foregroundStyle(Theme.danger)
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

/// Date helpers shared by the Date row and the set-date flow.
enum StoryDates {
    static let fmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// Date taken from EXIF/TIFF metadata (not the file's import time); nil when unreadable.
    static func taken(at url: URL) -> Date? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return nil }
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let raw = (exif?[kCGImagePropertyExifDateTimeOriginal] as? String) ?? (tiff?[kCGImagePropertyTIFFDateTime] as? String)
        guard let raw else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return f.date(from: raw)
    }

    /// Where the set-date calendar starts: the stored date, else the cover's (or first file's) date taken, else today.
    @MainActor static func initial(for model: DraftEditorModel) -> Date {
        if let d = fmt.date(from: model.draft.field("date")) { return d }
        let cover = model.draft.field("cover")
        let names = ([cover] + model.draft.localFiles).filter { !$0.isEmpty && model.draft.localFiles.contains($0) }
        for n in names { if let d = taken(at: model.mediaURL(n)) { return d } }
        return Date()
    }
}

/// "Date: From the photo" / "Set manually: 14 Oct 2026"; tapping opens the set-date sheet.
struct DateRow: View {
    @Bindable var model: DraftEditorModel
    @State private var showSheet = false

    var body: some View {
        let stored = model.draft.field("date")
        let manual = StoryDates.fmt.date(from: stored)
        Button { showSheet = true } label: {
            LabeledContent("Date") {
                Text(manual.map { "Set manually: " + $0.formatted(.dateTime.day().month(.abbreviated).year()) } ?? "From the photo")
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showSheet) {
            SetDateSheet(initial: StoryDates.initial(for: model)) { d in
                model.draft.fields["date"] = StoryDates.fmt.string(from: d)
            }
        }
        if manual != nil {
            Button("Use the photo's date") { model.draft.fields["date"] = "" }.font(.footnote)
        }
    }
}

struct ProblemsView: View {
    let draft: FrameDraft
    var body: some View {
        if let e = draft.lastError {
            Label(e, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.danger).font(.callout)
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
    @State private var fileToRemove: String?
    var body: some View {
        Section("Files in this story") {
            if model.draft.allFiles.isEmpty { Text("No files yet.").foregroundStyle(.secondary) }
            ForEach(model.draft.allFiles, id: \.self) { n in
                HStack {
                    FrameThumb(source: model.source(for: n)).frame(width: 52, height: 52).clipShape(RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous))
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
                .swipeActions { Button("Remove", role: .destructive) { fileToRemove = n } }
            }
        }
        .confirmationDialog("Remove this file?", isPresented: Binding(get: { fileToRemove != nil }, set: { if !$0 { fileToRemove = nil } }),
                            titleVisibility: .visible) {
            Button("Remove file", role: .destructive) {
                if let n = fileToRemove { model.remove(n) }
                fileToRemove = nil
            }
        } message: {
            Text("\(fileToRemove ?? "The file") is removed from this story's files.")
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
            .padding(DS.Space.m)
            .glassEffect(.regular.tint(tint.opacity(0.2)), in: .rect(cornerRadius: DS.Radius.control))
            .padding(.horizontal, DS.Space.l)
    }
}
