import AppKit
import SwiftUI

struct SidebarLocation: Identifiable, Hashable {
    let url: URL
    let name: String
    let systemImage: String

    var id: String { url.standardizedFileURL.path }

    static var favorites: [SidebarLocation] {
        let fileManager = FileManager.default
        func folder(_ directory: FileManager.SearchPathDirectory) -> URL? {
            fileManager.urls(for: directory, in: .userDomainMask).first
        }
        let candidates: [(URL?, String)] = [
            (fileManager.homeDirectoryForCurrentUser, "house"),
            (folder(.desktopDirectory), "menubar.dock.rectangle"),
            (folder(.documentDirectory), "doc"),
            (folder(.downloadsDirectory), "arrow.down.circle"),
            (URL(fileURLWithPath: "/Applications", isDirectory: true), "square.grid.2x2"),
        ]
        return candidates.compactMap { url, image in
            guard let url else { return nil }
            return SidebarLocation(url: url, name: fileManager.displayName(atPath: url.path), systemImage: image)
        }
    }

    static var volumes: [SidebarLocation] {
        let keys: [URLResourceKey] = [.volumeLocalizedNameKey, .volumeIsInternalKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return urls.map { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            let isInternal = values?.volumeIsInternal ?? (url.path == "/")
            return SidebarLocation(
                url: url,
                name: values?.volumeLocalizedName ?? url.lastPathComponent,
                systemImage: isInternal ? "internaldrive" : "externaldrive"
            )
        }
    }
}

/// Mounted volumes, refreshed when a disk is mounted or ejected.
///
/// An `ObservableObject` rather than `@State`: in newer SDKs `@State` is a macro whose plugin
/// ships only with Xcode, and this project must also build with the Command Line Tools alone.
@MainActor
final class VolumeList: ObservableObject {
    @Published private(set) var volumes = SidebarLocation.volumes

    func refresh() {
        volumes = SidebarLocation.volumes
    }
}

struct SidebarView: View {
    let currentURL: URL
    let onSelect: (URL) -> Void

    private let favorites = SidebarLocation.favorites
    @StateObject private var volumeList = VolumeList()

    private var volumes: [SidebarLocation] { volumeList.volumes }

    var body: some View {
        List(selection: selection) {
            Section("Favorites") {
                ForEach(favorites) { row($0) }
            }
            Section("Locations") {
                ForEach(volumes) { row($0) }
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 150, ideal: 190, max: 300)
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification)) { _ in
            volumeList.refresh()
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification)) { _ in
            volumeList.refresh()
        }
    }

    private func row(_ location: SidebarLocation) -> some View {
        Label(location.name, systemImage: location.systemImage)
            .tag(location.id)
    }

    /// Highlights the sidebar row matching the current folder; selecting a row navigates there.
    private var selection: Binding<String?> {
        Binding(
            get: {
                let path = currentURL.standardizedFileURL.path
                return (favorites + volumes).first { $0.id == path }?.id
            },
            set: { id in
                guard let id, let location = (favorites + volumes).first(where: { $0.id == id }) else { return }
                onSelect(location.url)
            }
        )
    }
}
