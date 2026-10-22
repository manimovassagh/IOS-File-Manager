import AppKit
import FileCore
import SwiftUI

/// Saved Move To… / Copy To… destinations.
@MainActor
final class DestinationHistoryStore {
    static let shared = DestinationHistoryStore()

    private let defaults: UserDefaults
    private static let key = "destinationHistory"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var history: DestinationHistory {
        get {
            defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode(DestinationHistory.self, from: $0) }
                ?? DestinationHistory()
        }
        set {
            defaults.set(try? JSONEncoder().encode(newValue), forKey: Self.key)
        }
    }

    func record(_ folder: URL) {
        history.record(folder)
    }
}

/// A request to move or copy items to a folder picked in the destination picker.
struct DestinationRequest: Identifiable {
    let id = UUID()
    let urls: [URL]
    let mode: FileClipboard.Mode
    /// The folder being shown; its subfolders are offered too.
    let currentFolder: URL

    var verb: String { mode == .cut ? "Move" : "Copy" }

    var title: String {
        let what = urls.count == 1 ? "“\(urls[0].lastPathComponent)”" : "\(urls.count) items"
        return "\(verb) \(what) to…"
    }
}

/// The picker's search: recent destinations first, then favorites, folders whose name matches
/// what's typed, or the folders inside a typed path (`/`, `~`).
@MainActor
final class DestinationPickerModel: ObservableObject {
    struct Candidate: Identifiable, Equatable {
        let url: URL
        let isRecent: Bool
        var id: String { url.path }
        var name: String { FileManager.default.displayName(atPath: url.path) }
        var parentPath: String {
            (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
        }
    }

    let request: DestinationRequest
    @Published var query = "" {
        didSet { update() }
    }
    @Published private(set) var results: [Candidate] = []
    @Published var highlighted = 0

    private var recents: [URL] = []
    private var favorites: [URL] = []
    /// Folders inside the favorites and the current folder, searched by name.
    private var pool: [URL] = []

    static let maxResults = 60

    init(request: DestinationRequest, history: DestinationHistory, favorites: [URL]) {
        self.request = request
        recents = history.ranked().map { URL(fileURLWithPath: $0, isDirectory: true) }
            .filter(FavoritesStore.isFolder)
        self.favorites = favorites
        var seen = Set<String>()
        var pool: [URL] = []
        for folder in recents + favorites + [request.currentFolder] + Self.subfolders(of: [request.currentFolder] + favorites) {
            if seen.insert(folder.standardizedFileURL.path).inserted { pool.append(folder) }
        }
        self.pool = pool
        update()
    }

    /// Non-hidden folders directly inside `folders`.
    static func subfolders(of folders: [URL]) -> [URL] {
        folders.flatMap { folder in
            let contents = (try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey], options: [.skipsHiddenFiles]
            )) ?? []
            return contents.filter(FavoritesStore.isFolder).sorted { $0.lastPathComponent < $1.lastPathComponent }
        }
    }

    /// Whether the items can go into `folder` (not into themselves, not a move to where they are).
    func accepts(_ folder: URL) -> Bool {
        FileListController.dropMode(
            mask: request.mode == .cut ? .move : .copy, sources: request.urls, destination: folder
        ) != nil
    }

    private func update() {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        var candidates: [Candidate]
        if trimmed.hasPrefix("/") || trimmed.hasPrefix("~") {
            candidates = pathCompletions(for: trimmed).map { Candidate(url: $0, isRecent: false) }
        } else if trimmed.isEmpty {
            let recentPaths = Set(recents.map(\.path))
            candidates = recents.map { Candidate(url: $0, isRecent: true) }
                + favorites.filter { !recentPaths.contains($0.path) }.map { Candidate(url: $0, isRecent: false) }
        } else {
            let recentRank = Dictionary(recents.enumerated().map { ($1.path, $0) }, uniquingKeysWith: { a, _ in a })
            candidates = pool
                .compactMap { url -> (URL, Int)? in
                    FuzzyMatch.score(trimmed, in: url.lastPathComponent).map { (url, $0) }
                }
                .sorted { lhs, rhs in
                    // Better matches first; among equal ones, recently used destinations.
                    if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
                    return (recentRank[lhs.0.path] ?? .max) < (recentRank[rhs.0.path] ?? .max)
                }
                .map { Candidate(url: $0.0, isRecent: recentRank[$0.0.path] != nil) }
        }
        results = Array(candidates.filter { accepts($0.url) }.prefix(Self.maxResults))
        highlighted = 0
    }

    /// For "~/Doc": the folders in ~ matching "Doc". For "~/Documents/": everything in it.
    private func pathCompletions(for typed: String) -> [URL] {
        let expanded = (typed as NSString).expandingTildeInPath
        let endsWithSlash = typed.hasSuffix("/")
        let parent = endsWithSlash ? expanded : (expanded as NSString).deletingLastPathComponent
        let fragment = endsWithSlash ? "" : (expanded as NSString).lastPathComponent
        let parentURL = URL(fileURLWithPath: parent.isEmpty ? "/" : parent, isDirectory: true)

        var result: [URL] = []
        if !endsWithSlash, FavoritesStore.isFolder(URL(fileURLWithPath: expanded)) {
            result.append(URL(fileURLWithPath: expanded, isDirectory: true))
        } else if endsWithSlash, FavoritesStore.isFolder(parentURL) {
            result.append(parentURL)
        }
        let matches = Self.subfolders(of: [parentURL])
            .compactMap { url in FuzzyMatch.score(fragment, in: url.lastPathComponent).map { (url, $0) } }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
        result += matches.filter { $0.standardizedFileURL.path != result.first?.standardizedFileURL.path }
        return result
    }

    func moveHighlight(by offset: Int) {
        guard !results.isEmpty else { return }
        highlighted = min(max(highlighted + offset, 0), results.count - 1)
    }

    var highlightedFolder: URL? {
        results.indices.contains(highlighted) ? results[highlighted].url : nil
    }
}

/// Raycast-style sheet for Move To… (⇧⌘M) and Copy To… (⌥⌘C): type to find a folder, Return to send.
struct DestinationPicker: View {
    @StateObject private var model: DestinationPickerModel
    let accent: Color
    let onChoose: (URL) -> Void
    let onCancel: () -> Void

    @MainActor
    init(
        request: DestinationRequest,
        history: DestinationHistory = DestinationHistoryStore.shared.history,
        favorites: [URL] = FavoritesStore.shared.items.compactMap(\.folderURL),
        accent: Color,
        onChoose: @escaping (URL) -> Void,
        onCancel: @escaping () -> Void
    ) {
        _model = StateObject(wrappedValue: DestinationPickerModel(request: request, history: history, favorites: favorites))
        self.accent = accent
        self.onChoose = onChoose
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: model.request.mode == .cut ? "arrow.right.doc.on.clipboard" : "doc.on.doc")
                    .font(.title2)
                    .foregroundStyle(accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.request.title)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    TextField("Search folders, or type a path like ~/Documents/", text: $model.query)
                        .textFieldStyle(.plain)
                        .font(.title3)
                        .onSubmit(choose)
                        .onKeyPress(.upArrow) { model.moveHighlight(by: -1); return .handled }
                        .onKeyPress(.downArrow) { model.moveHighlight(by: 1); return .handled }
                }
            }
            .padding(14)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        if model.results.isEmpty {
                            Text(model.query.isEmpty ? "No recent destinations yet — type to search" : "No matching folders")
                                .foregroundStyle(.secondary)
                                .padding(.top, 40)
                        }
                        ForEach(Array(model.results.enumerated()), id: \.element.id) { index, candidate in
                            row(candidate, isHighlighted: index == model.highlighted)
                                .id(candidate.id)
                                .onTapGesture(count: 2) { onChoose(candidate.url) }
                                .onTapGesture { model.highlighted = index }
                        }
                    }
                    .padding(6)
                }
                .onChange(of: model.highlighted) { _, index in
                    if model.results.indices.contains(index) { proxy.scrollTo(model.results[index].id) }
                }
            }

            Divider()

            HStack {
                Button("Choose Folder…", action: chooseWithPanel)
                Spacer()
                Text("↑↓ select   ↩ \(model.request.verb.lowercased())   esc cancel")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(model.request.verb, action: choose)
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.highlightedFolder == nil)
            }
            .padding(10)
        }
        .frame(width: 600, height: 440)
    }

    private func row(_ candidate: DestinationPickerModel.Candidate, isHighlighted: Bool) -> some View {
        HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: candidate.url.path))
                .resizable()
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(candidate.name)
                    .lineLimit(1)
                Text(candidate.parentPath)
                    .font(.caption)
                    .foregroundStyle(isHighlighted ? Color.white.opacity(0.8) : Color.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer()
            if candidate.isRecent {
                Image(systemName: "clock.arrow.circlepath")
                    .foregroundStyle(isHighlighted ? Color.white.opacity(0.8) : Color.secondary)
                    .help("Recently used")
            }
        }
        .foregroundStyle(isHighlighted ? Color.white : Color.primary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(isHighlighted ? accent : Color.clear, in: RoundedRectangle(cornerRadius: 7))
        .contentShape(Rectangle())
    }

    private func choose() {
        if let folder = model.highlightedFolder { onChoose(folder) }
    }

    private func chooseWithPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = model.request.verb
        panel.directoryURL = model.request.currentFolder
        if panel.runModal() == .OK, let url = panel.url, model.accepts(url) {
            onChoose(url)
        }
    }
}
