import AppKit
import FileCore

/// A place the browser can show: a real folder, or a smart location.
enum Location: Hashable {
    case folder(URL)
    /// Files opened recently (from Spotlight), like Finder's Recents.
    case recents
    /// Screenshots in the folder macOS saves them to.
    case screenshots

    enum Kind: Hashable {
        case folder, recents, screenshots

        /// Folders sort by name; smart locations show the newest first.
        var defaultSort: FileSort {
            switch self {
            case .folder: return FileSort()
            case .recents, .screenshots: return FileSort(key: .dateModified, ascending: false)
            }
        }
    }

    var kind: Kind {
        switch self {
        case .folder: return .folder
        case .recents: return .recents
        case .screenshots: return .screenshots
        }
    }

    /// The folder this location lives in; Recents has none, so it uses Home.
    var baseURL: URL {
        switch self {
        case .folder(let url): return url
        case .recents: return FileManager.default.homeDirectoryForCurrentUser
        case .screenshots: return Screenshots.folder
        }
    }

    /// Whether files can be pasted, dropped or created here. Not in smart locations: Recents isn't
    /// a folder, and Screenshots only shows screenshots, so anything else put there would vanish.
    var acceptsNewItems: Bool { kind == .folder }

    private static let lastUsedKey = "lastLocation"

    /// Where the previous session left off (Home the first time).
    static var lastUsed: Location {
        let home = Location.folder(FileManager.default.homeDirectoryForCurrentUser)
        guard let saved = UserDefaults.standard.string(forKey: lastUsedKey) else { return home }
        switch saved {
        case "recents": return .recents
        case "screenshots": return .screenshots
        default:
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: saved, isDirectory: &isDirectory), isDirectory.boolValue else { return home }
            return .folder(URL(fileURLWithPath: saved, isDirectory: true))
        }
    }

    func remember() {
        let value: String
        switch self {
        case .folder(let url): value = url.path
        case .recents: value = "recents"
        case .screenshots: value = "screenshots"
        }
        UserDefaults.standard.set(value, forKey: Self.lastUsedKey)
    }

    var smartTitle: String? {
        switch self {
        case .folder: return nil
        case .recents: return "Recents"
        case .screenshots: return "Screenshots"
        }
    }

    var smartSystemImage: String? {
        switch self {
        case .folder: return nil
        case .recents: return "clock"
        case .screenshots: return "camera.viewfinder"
        }
    }
}

/// What a file list loads its items from.
enum ItemSource: Equatable {
    case folder(URL)
    case screenshots(URL)
    case recents
}

enum ItemLoader {
    @MainActor
    static func load(_ source: ItemSource, includeHidden: Bool) async throws -> [FileItem] {
        switch source {
        case .folder(let url):
            return try await Task.detached(priority: .userInitiated) {
                try DirectoryLister.contents(of: url, includeHidden: includeHidden)
            }.value
        case .screenshots(let url):
            return try await Task.detached(priority: .userInitiated) {
                try Screenshots.contents(of: url)
            }.value
        case .recents:
            let urls = await RecentFilesQuery.fetch()
            return await Task.detached(priority: .userInitiated) {
                let items = urls.isEmpty ? recentFilesFallback() : urls.compactMap { try? FileItem(url: $0) }
                return items.filter { !$0.isDirectory && !$0.url.path.contains("/Library/") }
            }.value
        }
    }

    /// Used when Spotlight returns nothing (e.g. indexing is off): files changed in the last
    /// week directly inside Desktop, Documents and Downloads.
    private static func recentFilesFallback() -> [FileItem] {
        let fileManager = FileManager.default
        let folders: [FileManager.SearchPathDirectory] = [.desktopDirectory, .documentDirectory, .downloadsDirectory]
        let cutoff = Date().addingTimeInterval(-7 * 24 * 60 * 60)
        return folders
            .compactMap { fileManager.urls(for: $0, in: .userDomainMask).first }
            .flatMap { (try? DirectoryLister.contents(of: $0, includeHidden: false)) ?? [] }
            .filter { ($0.dateModified ?? .distantPast) > cutoff }
    }
}

/// Runs one Spotlight query for files used in the last 30 days, newest first.
@MainActor
final class RecentFilesQuery: NSObject {
    private let query = NSMetadataQuery()
    private let limit: Int
    private var continuation: CheckedContinuation<[URL], Never>?

    private init(limit: Int) {
        self.limit = limit
    }

    static func fetch(limit: Int = 300) async -> [URL] {
        await RecentFilesQuery(limit: limit).run()
    }

    private func run() async -> [URL] {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            let since = Date().addingTimeInterval(-30 * 24 * 60 * 60)
            query.searchScopes = [NSMetadataQueryUserHomeScope]
            query.predicate = NSPredicate(format: "%K >= %@", "kMDItemLastUsedDate", since as NSDate)
            query.sortDescriptors = [NSSortDescriptor(key: "kMDItemLastUsedDate", ascending: false)]
            NotificationCenter.default.addObserver(
                self, selector: #selector(didFinishGathering(_:)),
                name: .NSMetadataQueryDidFinishGathering, object: query
            )
            if !query.start() {
                finish([])
            }
        }
    }

    @objc private func didFinishGathering(_ notification: Notification) {
        query.disableUpdates()
        query.stop()
        var urls: [URL] = []
        for index in 0..<min(query.resultCount, limit) {
            if let item = query.result(at: index) as? NSMetadataItem,
               let path = item.value(forAttribute: NSMetadataItemPathKey) as? String {
                urls.append(URL(fileURLWithPath: path))
            }
        }
        finish(urls)
    }

    private func finish(_ urls: [URL]) {
        NotificationCenter.default.removeObserver(self)
        continuation?.resume(returning: urls)
        continuation = nil
    }
}
