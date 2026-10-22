import AppKit
import Foundation

/// The sidebar's Favorites: which places are listed and in what order. The user can add folders
/// (drag one into the sidebar, or "Add to Sidebar"), remove any entry and reorder them; the list
/// is saved in UserDefaults.
///
/// Entries are stored as ids: "recents", "screenshots", or a folder's path.
@MainActor
final class FavoritesStore: ObservableObject {
    static let shared = FavoritesStore()

    @Published private(set) var ids: [String]

    private let defaults: UserDefaults
    private static let key = "sidebarFavorites"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        ids = defaults.stringArray(forKey: Self.key) ?? Self.defaultIDs
    }

    /// Finder's usual favorites plus Recents and Screenshots.
    static var defaultIDs: [String] {
        let fileManager = FileManager.default
        func path(_ directory: FileManager.SearchPathDirectory) -> String? {
            fileManager.urls(for: directory, in: .userDomainMask).first?.standardizedFileURL.path
        }
        let ids: [String?] = [
            "recents",
            fileManager.homeDirectoryForCurrentUser.standardizedFileURL.path,
            path(.desktopDirectory),
            "screenshots",
            path(.documentDirectory),
            path(.downloadsDirectory),
            path(.picturesDirectory),
            "/Applications",
        ]
        return ids.compactMap { $0 }
    }

    /// The entries to show; folders that no longer exist are skipped (and come back if they reappear).
    var items: [SidebarItem] {
        ids.compactMap(SidebarItem.favorite(id:))
    }

    func contains(_ url: URL) -> Bool {
        ids.contains(url.standardizedFileURL.path)
    }

    /// Adds folders that aren't listed yet, at `index` (the end by default). Files are ignored.
    func add(_ urls: [URL], at index: Int? = nil) {
        var position = min(index ?? ids.count, ids.count)
        for url in urls where Self.isFolder(url) && !contains(url) {
            ids.insert(url.standardizedFileURL.path, at: position)
            position += 1
        }
        save()
    }

    func remove(id: String) {
        ids.removeAll { $0 == id }
        save()
    }

    /// Moves entries as `List.onMove` reports it (offsets into `items`, which may skip missing folders).
    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        let shown = items.map(\.id)
        var reordered = shown
        reordered.move(fromOffsets: source, toOffset: destination)
        // Hidden (missing) entries stay where they were; the shown ones fill their slots in the new order.
        let hidden = Set(ids).subtracting(shown)
        var next = reordered.makeIterator()
        ids = ids.map { hidden.contains($0) ? $0 : (next.next() ?? $0) }
        save()
    }

    func resetToDefaults() {
        ids = Self.defaultIDs
        defaults.removeObject(forKey: Self.key)
    }

    private func save() {
        defaults.set(ids, forKey: Self.key)
    }

    nonisolated static func isFolder(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        return values?.isDirectory == true && values?.isPackage != true
    }
}
