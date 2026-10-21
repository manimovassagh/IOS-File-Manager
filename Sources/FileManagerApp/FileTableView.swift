import AppKit
import FileCore
import SwiftUI

/// List view: one table showing the current folder with Name / Date / Size / Kind columns.
struct FileTableView: NSViewRepresentable {
    @ObservedObject var model: BrowserModel
    @ObservedObject var settings: ThemeSettings
    /// Paths of items on the clipboard in cut mode; shown dimmed.
    let cutPaths: Set<String>

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    func makeNSView(context: Context) -> NSScrollView {
        context.coordinator.list.scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.update(settings: settings, cutPaths: cutPaths)
    }

    @MainActor
    final class Coordinator {
        let list: FileListController
        private let model: BrowserModel
        private var folderPath: String?

        init(model: BrowserModel) {
            self.model = model
            list = FileListController(style: .list, model: model, folder: model.currentURL)
            list.onSelectionChange = { [weak model] list in
                model?.selection = list.selectedURLs
            }
            list.onOpen = { [weak model] _, items in
                model?.open(items)
            }
        }

        func update(settings: ThemeSettings, cutPaths: Set<String>) {
            list.apply(settings)
            list.folder = model.currentURL
            list.acceptsNewItems = model.acceptsNewItems
            list.showSort(model.effectiveSort)
            list.display(model.items, selectedPaths: Set(model.selection.map(\.path)), cutPaths: cutPaths)
            list.handleRenameRequest(model.renameRequest)

            let path = model.currentURL.standardizedFileURL.path + "|\(model.navigationID)"
            if path != folderPath {
                folderPath = path
                if model.selection.isEmpty {
                    list.scrollToTop()
                }
                // Keep keyboard focus on the file list (e.g. after clicking the sidebar).
                DispatchQueue.main.async { [list] in list.focus() }
            }
        }
    }
}
