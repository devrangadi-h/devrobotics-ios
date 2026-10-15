import SwiftUI

/// Add / edit / remove a link. Presented by the live text view's coordinator via a hosting controller.
struct LinkSheet: View {
    let isEditing: Bool
    let initialText: String
    let initialURL: String
    let onSave: (_ text: String, _ url: String) -> Void
    let onRemove: () -> Void
    let onCancel: () -> Void

    @State private var text = ""
    @State private var url = ""
    @State private var touched = false

    private var result: MarkdownSpans.URLResult { MarkdownSpans.normalizeURL(url) }
    private var error: String? {
        if case .error(let m) = result, touched || !url.isEmpty { return m }
        return nil
    }
    private var canSave: Bool {
        if case .ok = result { return !MarkdownSpans.sanitizeLabel(text).isEmpty }
        return false
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Text") {
                    TextField("Link text", text: $text)
                }
                Section("Address") {
                    TextField("https://…", text: $url)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                        .onChange(of: url) { _, _ in touched = true }
                    if let error { Text(error).font(.caption).foregroundStyle(Theme.danger) }
                }
                if isEditing {
                    Section {
                        Button("Remove link", role: .destructive) { onRemove() }
                    }
                }
            }
            .navigationTitle(isEditing ? "Edit link" : "Link")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { onCancel() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isEditing ? "Save" : "Add") {
                        if case .ok(let u) = result { onSave(text, u) }
                    }.disabled(!canSave)
                }
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .onAppear { text = initialText; url = initialURL; touched = false }
    }
}
