import SwiftUI

/// File import/export stays in the right panel rather than opening system sheets.
@MainActor
extension AppState {
    func openFile(title: String, onSelect: @escaping (Data, String) throws -> Void) {
        presentPanel(title) {
            FileBrowserPanel(suggestedName: nil, data: nil, onSelect: onSelect).padding(Theme.Space.xxl)
        }
    }
    func saveFile(_ data: Data, suggestedName: String) {
        presentPanel("Save file") {
            FileBrowserPanel(suggestedName: suggestedName, data: data, onSelect: { _, _ in }).padding(Theme.Space.xxl)
        }
    }
}

@MainActor
struct FileBrowserPanel: View {
    @Environment(\.dismissPanel) private var dismiss
    let suggestedName: String?
    let data: Data?
    let onSelect: (Data, String) throws -> Void
    @State private var directory: URL
    @State private var path = ""
    @State private var filename = ""
    @State private var entries: [URL] = []
    @State private var selection: URL?
    @State private var error: String?
    @State private var replaceURL: URL?

    init(suggestedName: String?, data: Data?,
         directory: URL = FileManager.default.homeDirectoryForCurrentUser,
         onSelect: @escaping (Data, String) throws -> Void) {
        self.suggestedName = suggestedName
        self.data = data
        self.onSelect = onSelect
        _directory = State(initialValue: directory)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            Text(data == nil ? "Choose a file to import" : "Choose where to save the file").font(.title2)
            HStack {
                Button("Home") { navigate(FileManager.default.homeDirectoryForCurrentUser) }.buttonStyle(.secondary)
                Button("Up") { navigate(directory.deletingLastPathComponent()) }.buttonStyle(.secondary)
                TextField("Folder path", text: $path).field().onSubmit { go() }
                Button("Go") { go() }.buttonStyle(.secondary)
            }
            List(entries, id: \.self, selection: $selection) { url in
                let isFolder = folder(url)
                HStack {
                    Image(systemName: isFolder ? "folder" : "doc")
                    Text(url.lastPathComponent).lineLimit(1)
                    Spacer()
                    if isFolder { Button("Open folder") { navigate(url) }.buttonStyle(.borderless) }
                }.tag(url)
                    .onTapGesture(count: 2) {
                        if isFolder { navigate(url) } else if data == nil { selection = url; openSelected() }
                    }
            }.frame(height: 330)
            if data != nil {
                TextField("File name", text: $filename).field()
                    .onChange(of: filename) { _, _ in replaceURL = nil }
            }
            if let error { Text(error).foregroundStyle(Theme.negative).textSelection(.enabled) }
            if let target = replaceURL {
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    Text("“\(target.lastPathComponent)” already exists. Replace this file?")
                    HStack {
                        Button("Keep existing file") { replaceURL = nil }.buttonStyle(.secondary)
                        Button("Replace file", role: .destructive) { write(target) }.buttonStyle(.primary)
                    }
                }.padding().background(Theme.surfaceRaised)
            }
            HStack {
                Button("Cancel") { dismiss() }.buttonStyle(.secondary)
                Spacer()
                Button(data == nil ? "Import" : "Save") {
                    if data == nil { openSelected() } else { save() }
                }.buttonStyle(.primary)
                    .disabled(data == nil ? (selection == nil || folder(selection!)) : filename.isEmpty)
            }
        }.onAppear { filename = suggestedName ?? ""; navigate(directory) }
    }

    private func folder(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
    }
    private func go() {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        if folder(url) { navigate(url) }
        else { error = "Enter an existing folder path." }
    }
    private func navigate(_ url: URL) {
        do {
            let items = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
            entries = items.sorted { a, b in
                if folder(a) != folder(b) { return folder(a) }
                return a.lastPathComponent.localizedStandardCompare(b.lastPathComponent) == .orderedAscending
            }
            directory = url; path = url.path; selection = nil; replaceURL = nil; error = nil
        } catch { self.error = error.localizedDescription }
    }
    private func openSelected() {
        guard let url = selection, !folder(url) else { return }
        do { try onSelect(Data(contentsOf: url), url.lastPathComponent); dismiss() }
        catch { self.error = error.userMessage }
    }
    private func save() {
        guard !filename.isEmpty, filename != ".", filename != "..", !filename.contains("/"), !filename.contains("\0") else {
            error = "Enter a file name without folder separators."; return
        }
        let target = directory.appendingPathComponent(filename)
        if folder(target) { error = "A folder already uses that name."; return }
        if FileManager.default.fileExists(atPath: target.path) { replaceURL = target }
        else { write(target) }
    }
    private func write(_ url: URL) {
        do { try data?.write(to: url, options: .atomic); dismiss() }
        catch { self.error = error.localizedDescription }
    }
}
