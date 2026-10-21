import AppKit
import SwiftUI

struct SidebarItem: Identifiable, Hashable {
    let id: String
    let location: Location
    let name: String
    let systemImage: String

    static var favorites: [SidebarItem] {
        let fileManager = FileManager.default
        func folder(_ directory: FileManager.SearchPathDirectory, _ image: String) -> SidebarItem? {
            guard let url = fileManager.urls(for: directory, in: .userDomainMask).first else { return nil }
            return folderItem(url, image)
        }
        let items: [SidebarItem?] = [
            SidebarItem(id: "recents", location: .recents, name: "Recents", systemImage: "clock"),
            folderItem(fileManager.homeDirectoryForCurrentUser, "house"),
            folder(.desktopDirectory, "menubar.dock.rectangle"),
            SidebarItem(id: "screenshots", location: .screenshots, name: "Screenshots", systemImage: "camera.viewfinder"),
            folder(.documentDirectory, "doc"),
            folder(.downloadsDirectory, "arrow.down.circle"),
            folder(.picturesDirectory, "photo"),
            folderItem(URL(fileURLWithPath: "/Applications", isDirectory: true), "square.grid.2x2"),
        ]
        return items.compactMap { $0 }
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

struct SidebarView: View {
    let location: Location
    let onSelect: (Location) -> Void

    private let favorites = SidebarItem.favorites
    @StateObject private var locationList = LocationList()

    var body: some View {
        List(selection: selection) {
            Section("Favorites") {
                ForEach(favorites) { row($0) }
            }
            Section("Locations") {
                ForEach(locationList.items) { row($0) }
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 160, ideal: 200, max: 300)
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification)) { _ in
            locationList.refresh()
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification)) { _ in
            locationList.refresh()
        }
    }

    private func row(_ item: SidebarItem) -> some View {
        Label(item.name, systemImage: item.systemImage)
            .tag(item.id)
    }

    /// Highlights the row matching the current location; selecting a row goes there.
    private var selection: Binding<String?> {
        Binding(
            get: {
                let id = SidebarItem.id(for: location)
                return (favorites + locationList.items).contains { $0.id == id } ? id : nil
            },
            set: { id in
                guard let id, let item = (favorites + locationList.items).first(where: { $0.id == id }) else { return }
                onSelect(item.location)
            }
        )
    }
}
