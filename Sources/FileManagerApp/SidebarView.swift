import AppKit
import FileCore
import SwiftUI
import UniformTypeIdentifiers

struct SidebarItem: Identifiable, Hashable {
    let id: String
    let location: Location
    let name: String
    let systemImage: String

    /// The Favorites entry for a stored id ("recents", "screenshots" or a folder path);
    /// `nil` for a folder that doesn't exist (any more).
    static func favorite(id: String) -> SidebarItem? {
        switch id {
        case "recents":
            return SidebarItem(id: id, location: .recents, name: "Recents", systemImage: "clock")
        case "screenshots":
            return SidebarItem(id: id, location: .screenshots, name: "Screenshots", systemImage: "camera.viewfinder")
        default:
            let url = URL(fileURLWithPath: id, isDirectory: true)
            guard FavoritesStore.isFolder(url) else { return nil }
            return folderItem(url, systemImage(forFolder: url))
        }
    }

    /// Finder's icons for the well-known folders, a plain folder for the rest.
    static func systemImage(forFolder url: URL) -> String {
        let fileManager = FileManager.default
        let path = url.standardizedFileURL.path
        func matches(_ directory: FileManager.SearchPathDirectory) -> Bool {
            fileManager.urls(for: directory, in: .userDomainMask).first?.standardizedFileURL.path == path
        }
        if path == fileManager.homeDirectoryForCurrentUser.standardizedFileURL.path { return "house" }
        if path == "/Applications" { return "square.grid.2x2" }
        if matches(.desktopDirectory) { return "menubar.dock.rectangle" }
        if matches(.documentDirectory) { return "doc" }
        if matches(.downloadsDirectory) { return "arrow.down.circle" }
        if matches(.picturesDirectory) { return "photo" }
        if matches(.moviesDirectory) { return "film" }
        if matches(.musicDirectory) { return "music.note" }
        return "folder"
    }

    static var locations: [SidebarItem] {
        var result: [SidebarItem] = []
        let iCloud = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        if FileManager.default.fileExists(atPath: iCloud.path) {
            result.append(SidebarItem(id: iCloud.path, location: .folder(iCloud), name: "iCloud Drive", systemImage: "icloud"))
        }

        let keys: [URLResourceKey] = [.volumeLocalizedNameKey, .volumeIsInternalKey]
        let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        for url in volumes {
            let values = try? url.resourceValues(forKeys: Set(keys))
            let isInternal = values?.volumeIsInternal ?? (url.path == "/")
            result.append(SidebarItem(
                id: url.standardizedFileURL.path,
                location: .folder(url),
                name: values?.volumeLocalizedName ?? url.lastPathComponent,
                systemImage: isInternal ? "internaldrive" : "externaldrive"
            ))
        }
        return result
    }

    private static func folderItem(_ url: URL, _ image: String) -> SidebarItem {
        SidebarItem(
            id: url.standardizedFileURL.path,
            location: .folder(url),
            name: FileManager.default.displayName(atPath: url.path),
            systemImage: image
        )
    }

    /// The sidebar id for a location, used to highlight the matching row.
    static func id(for location: Location) -> String {
        switch location {
        case .folder(let url): return url.standardizedFileURL.path
        case .recents: return "recents"
        case .screenshots: return "screenshots"
        }
    }

    var folderURL: URL? {
        if case .folder(let url) = location { return url }
        return nil
    }

    var isEjectable: Bool { systemImage == "externaldrive" }
}

/// Mounted volumes and iCloud Drive, refreshed when a disk is mounted or ejected.
///
/// An `ObservableObject` rather than `@State`: in newer SDKs `@State` is a macro whose plugin
/// ships only with Xcode, and this project must also build with the Command Line Tools alone.
@MainActor
final class LocationList: ObservableObject {
    @Published private(set) var items = SidebarItem.locations

    func refresh() {
        items = SidebarItem.locations
    }
}

/// The sidebar row files are being dragged over, highlighted as the drop target.
@MainActor
final class SidebarDropTarget: ObservableObject {
    @Published var id: String?
}

struct SidebarView: View {
    let location: Location
    /// Color theme palette (`nil`: Native, system sidebar material).
    let palette: ThemePalette?
    let accent: Color
    @ObservedObject var favorites: FavoritesStore
    let onSelect: (Location) -> Void
    /// Files dropped onto a folder in the sidebar: move or copy them there.
    let onDrop: (_ urls: [URL], _ folder: URL, _ mode: FileClipboard.Mode) -> Void

    @StateObject private var locationList = LocationList()
    @StateObject private var dropTarget = SidebarDropTarget()

    var body: some View {
        let favoriteItems = favorites.items
        List(selection: selection) {
            Section("Favorites") {
                ForEach(favoriteItems) { item in
                    row(item)
                        .contextMenu { favoriteMenu(item) }
                }
                .onMove { favorites.move(fromOffsets: $0, toOffset: $1) }
                // Drag a folder between the rows to add it.
                .onInsert(of: [.fileURL]) { index, providers in
                    let position = favoriteIndex(forRow: index)
                    Task { @MainActor in
                        var urls: [URL] = []
                        for provider in providers {
                            if let url = await Self.loadURL(provider) { urls.append(url) }
                        }
                        favorites.add(urls, at: position)
                    }
                }
            }
            Section("Locations") {
                ForEach(locationList.items) { item in
                    row(item)
                        .contextMenu { locationMenu(item) }
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(palette == nil ? .automatic : .hidden)
        .themeBackground(palette?.sidebar)
        .navigationSplitViewColumnWidth(min: 160, ideal: 200, max: 300)
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification)) { _ in
            locationList.refresh()
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification)) { _ in
            locationList.refresh()
        }
    }

    private func row(_ item: SidebarItem) -> some View {
        Label {
            Text(item.name)
                .foregroundStyle(palette.map { Color(nsColor: $0.text) } ?? Color.primary)
        } icon: {
            Image(systemName: item.systemImage)
                .foregroundStyle(accent)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background {
            if dropTarget.id == item.id {
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(accent, lineWidth: 2)
                    .background(accent.opacity(0.15), in: RoundedRectangle(cornerRadius: 5))
                    .padding(.horizontal, -6)
                    .padding(.vertical, -3)
            }
        }
        .tag(item.id)
        // Drop files onto a folder to move them there (copy to another disk; ⌥ copies, ⌘ moves).
        .dropDestination(for: URL.self) { urls, _ in
            dropTarget.id = nil
            return drop(urls, onto: item)
        } isTargeted: { targeted in
            if targeted {
                dropTarget.id = item.id
            } else if dropTarget.id == item.id {
                dropTarget.id = nil
            }
        }
    }

    /// Moves or copies dropped files into the row's folder; false if that isn't possible here.
    @discardableResult
    func drop(_ urls: [URL], onto item: SidebarItem, mask: NSDragOperation = FileListController.currentDropMask()) -> Bool {
        let files = urls.filter(\.isFileURL)
        guard let folder = item.folderURL,
              let mode = FileListController.dropMode(mask: mask, sources: files, destination: folder)
        else { return false }
        onDrop(files, folder, mode)
        return true
    }

    @ViewBuilder
    private func favoriteMenu(_ item: SidebarItem) -> some View {
        if let url = item.folderURL {
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            Divider()
        }
        Button("Remove from Sidebar") { favorites.remove(id: item.id) }
        Button("Restore Default Favorites") { favorites.resetToDefaults() }
    }

    @ViewBuilder
    private func locationMenu(_ item: SidebarItem) -> some View {
        if let url = item.folderURL {
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            if !favorites.contains(url) {
                Button("Add to Favorites") { favorites.add([url]) }
            }
            if item.isEjectable {
                Divider()
                Button("Eject “\(item.name)”") {
                    try? NSWorkspace.shared.unmountAndEjectDevice(at: url)
                }
            }
        }
    }

    /// `onInsert` counts rows on screen; missing folders are hidden, so map to the stored list.
    private func favoriteIndex(forRow row: Int) -> Int {
        let shown = favorites.items
        guard row < shown.count else { return favorites.ids.count }
        return favorites.ids.firstIndex(of: shown[row].id) ?? favorites.ids.count
    }

    private static func loadURL(_ provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in continuation.resume(returning: url) }
        }
    }

    /// Highlights the row matching the current location; selecting a row goes there.
    private var selection: Binding<String?> {
        let all = favorites.items + locationList.items
        return Binding(
            get: {
                let id = SidebarItem.id(for: location)
                return all.contains { $0.id == id } ? id : nil
            },
            set: { id in
                guard let id, let item = all.first(where: { $0.id == id }) else { return }
                onSelect(item.location)
            }
        )
    }
}
