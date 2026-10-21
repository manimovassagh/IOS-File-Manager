import AppKit
import FileCore
import SwiftUI

/// The file list. Uses AppKit's `NSTableView` because it stays fast with very large folders.
struct FileTableView: NSViewRepresentable {
    @ObservedObject var model: BrowserModel
    /// Paths of items on the clipboard in cut mode; shown dimmed.
    let cutPaths: Set<String>

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let coordinator = context.coordinator
        let tableView = FileTable()
        tableView.style = .fullWidth
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = true
        tableView.allowsEmptySelection = true
        tableView.allowsColumnReordering = true
        tableView.allowsColumnResizing = true
        tableView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle

        for column in FileColumn.allCases {
            let tableColumn = NSTableColumn(identifier: column.identifier)
            tableColumn.title = column.title
            tableColumn.width = column.width
            tableColumn.minWidth = 60
            tableColumn.sortDescriptorPrototype = NSSortDescriptor(key: column.sortKey.rawValue, ascending: true)
            if column == .size {
                tableColumn.headerCell.alignment = .right
            }
            tableView.addTableColumn(tableColumn)
        }
        // Set before the delegate so this doesn't feed back into the model.
        tableView.sortDescriptors = [NSSortDescriptor(key: model.sort.key.rawValue, ascending: model.sort.ascending)]

        tableView.dataSource = coordinator
        tableView.delegate = coordinator
        tableView.actions = coordinator
        tableView.target = coordinator
        tableView.doubleAction = #selector(Coordinator.doubleClicked(_:))

        tableView.registerForDraggedTypes([.fileURL])
        tableView.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
        tableView.setDraggingSourceOperationMask([.copy, .move], forLocal: false)

        let menu = NSMenu()
        menu.delegate = coordinator
        menu.autoenablesItems = false
        tableView.menu = menu

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        coordinator.tableView = tableView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.model = model
        context.coordinator.update(
            folder: model.currentURL,
            items: model.items,
            selection: model.selection,
            cutPaths: cutPaths
        )
        context.coordinator.handleRenameRequest(model.renameRequest)
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate, NSTextFieldDelegate, FileTableActions {
        var model: BrowserModel
        weak var tableView: FileTable?

        private var items: [FileItem] = []
        private var cutPaths: Set<String> = []
        private var folder: URL?
        /// True while we change the table ourselves, so delegate callbacks don't write back into the model.
        private var isUpdating = false
        /// The item whose name is being edited, if any.
        private var renamingItem: FileItem?
        private var scheduledRename: URL?

        private static let byteFormatter: ByteCountFormatter = {
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            return formatter
        }()

        init(model: BrowserModel) {
            self.model = model
        }

        func update(folder newFolder: URL, items newItems: [FileItem], selection: Set<URL>, cutPaths newCutPaths: Set<String>) {
            guard let tableView else { return }
            isUpdating = true
            defer { isUpdating = false }

            let folderChanged = newFolder != folder
            folder = newFolder

            if (newItems != items || newCutPaths != cutPaths) && renamingItem == nil {
                items = newItems
                cutPaths = newCutPaths
                tableView.reloadData()
            }

            let rows = IndexSet(items.indices.filter { selection.contains(items[$0].url) })
            if rows != tableView.selectedRowIndexes {
                tableView.selectRowIndexes(rows, byExtendingSelection: false)
                if let first = rows.first {
                    tableView.scrollRowToVisible(first)
                }
            }

            if folderChanged {
                if rows.isEmpty {
                    tableView.scrollRowToVisible(0)
                }
                // Keep keyboard focus on the file list (e.g. after clicking the sidebar).
                DispatchQueue.main.async { [weak tableView] in
                    guard let tableView, let window = tableView.window else { return }
                    window.makeFirstResponder(tableView)
                }
            }
        }

        // MARK: Data source & delegate

        func numberOfRows(in tableView: NSTableView) -> Int {
            items.count
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let identifier = tableColumn?.identifier,
                  let column = FileColumn(rawValue: identifier.rawValue),
                  items.indices.contains(row)
            else { return nil }

            let item = items[row]
            let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? FileCellView
                ?? FileCellView(column: column)

            switch column {
            case .name:
                cell.textField?.stringValue = item.name
                cell.textField?.isEditable = false
                cell.textField?.delegate = self
                cell.imageView?.image = NSWorkspace.shared.icon(forFile: item.url.path)
            case .dateModified:
                cell.textField?.stringValue = item.dateModified?.formatted(date: .abbreviated, time: .shortened) ?? "--"
            case .size:
                cell.textField?.stringValue = item.size.map { Self.byteFormatter.string(fromByteCount: $0) } ?? "--"
            case .kind:
                cell.textField?.stringValue = item.kind
            }

            if cutPaths.contains(item.url.path) {
                cell.alphaValue = 0.4
            } else if item.isHidden {
                cell.alphaValue = 0.6
            } else {
                cell.alphaValue = 1
            }
            return cell
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !isUpdating, let tableView else { return }
            model.selection = Set(tableView.selectedRowIndexes.compactMap { items.indices.contains($0) ? items[$0].url : nil })
        }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard !isUpdating,
                  let descriptor = tableView.sortDescriptors.first,
                  let key = FileSort.Key(rawValue: descriptor.key ?? "")
            else { return }
            model.sort.key = key
            model.sort.ascending = descriptor.ascending
        }

        @objc func doubleClicked(_ sender: NSTableView) {
            let row = sender.clickedRow
            guard items.indices.contains(row) else { return }
            model.open([items[row]])
        }

        // MARK: FileTableActions

        var hasSelection: Bool { !model.selection.isEmpty }

        var canPaste: Bool {
            model.clipboard.refreshFromPasteboard()
            return model.canPaste
        }

        func openSelection() { model.open(model.selectedItems) }
        func renameSelection() { model.renameSelection() }
        func copySelection() { model.copySelection() }
        func cutSelection() { model.cutSelection() }
        func pasteHere() { model.paste(undoManager: tableView?.undoManager) }
        func trashSelection() { model.trashSelection(undoManager: tableView?.undoManager) }

        // MARK: Rename

        /// Starts editing once the requested item is in the list (a new folder may still be loading).
        func handleRenameRequest(_ url: URL?) {
            guard let url, scheduledRename != url,
                  items.contains(where: { $0.url.path == url.path })
            else { return }
            scheduledRename = url
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.scheduledRename = nil
                self.model.renameRequest = nil
                self.beginRename(url)
            }
        }

        private func beginRename(_ url: URL) {
            guard let tableView,
                  let row = items.firstIndex(where: { $0.url.path == url.path })
            else { return }
            let column = tableView.column(withIdentifier: FileColumn.name.identifier)
            guard column >= 0 else { return }

            tableView.selectRowIndexes([row], byExtendingSelection: false)
            tableView.scrollRowToVisible(row)
            guard let cell = tableView.view(atColumn: column, row: row, makeIfNecessary: true) as? NSTableCellView,
                  let field = cell.textField
            else { return }

            let item = items[row]
            renamingItem = item
            field.isEditable = true
            field.delegate = self
            tableView.window?.makeFirstResponder(field)
            // Select the name without its extension, like Finder.
            let base = item.isBrowsable ? item.name : (item.name as NSString).deletingPathExtension
            field.currentEditor()?.selectedRange = NSRange(location: 0, length: (base as NSString).length)
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard let field = notification.object as? NSTextField, let item = renamingItem else { return }
            renamingItem = nil
            field.isEditable = false
            let newName = field.stringValue
            // Show the old name until the rename succeeds and the list reloads.
            field.stringValue = item.name
            model.rename(item.url, to: newName, undoManager: tableView?.undoManager)
            if let tableView {
                tableView.window?.makeFirstResponder(tableView)
            }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            // Escape cancels the rename.
            guard commandSelector == #selector(NSResponder.cancelOperation(_:)),
                  let field = control as? NSTextField, let item = renamingItem
            else { return false }
            renamingItem = nil
            field.abortEditing()
            field.stringValue = item.name
            field.isEditable = false
            if let tableView {
                tableView.window?.makeFirstResponder(tableView)
            }
            return true
        }

        // MARK: Drag & drop

        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
            guard items.indices.contains(row) else { return nil }
            return items[row].url as NSURL
        }

        func tableView(
            _ tableView: NSTableView,
            validateDrop info: NSDraggingInfo,
            proposedRow row: Int,
            proposedDropOperation dropOperation: NSTableView.DropOperation
        ) -> NSDragOperation {
            let urls = Self.fileURLs(from: info)
            guard !urls.isEmpty else { return [] }

            let destination: URL
            if let folder = dropFolder(row: row, operation: dropOperation) {
                destination = folder
            } else {
                // Not onto a folder: drop into the folder being shown.
                tableView.setDropRow(-1, dropOperation: .on)
                destination = model.currentURL
            }
            guard let mode = Self.dropMode(for: info, sources: urls, destination: destination) else { return [] }
            return mode == .cut ? .move : .copy
        }

        func tableView(
            _ tableView: NSTableView,
            acceptDrop info: NSDraggingInfo,
            row: Int,
            dropOperation: NSTableView.DropOperation
        ) -> Bool {
            let urls = Self.fileURLs(from: info)
            let destination = dropFolder(row: row, operation: dropOperation) ?? model.currentURL
            guard let mode = Self.dropMode(for: info, sources: urls, destination: destination) else { return false }
            model.drop(urls, into: destination, mode: mode, undoManager: tableView.undoManager)
            return true
        }

        private func dropFolder(row: Int, operation: NSTableView.DropOperation) -> URL? {
            guard operation == .on, items.indices.contains(row), items[row].isBrowsable else { return nil }
            return items[row].browseURL
        }

        private static func fileURLs(from info: NSDraggingInfo) -> [URL] {
            info.draggingPasteboard.readObjects(
                forClasses: [NSURL.self],
                options: [.urlReadingFileURLsOnly: true]
            ) as? [URL] ?? []
        }

        /// Like Finder: move within the same disk, copy to another disk. Hold ⌥ to force a copy, ⌘ to force a move.
        private static func dropMode(for info: NSDraggingInfo, sources: [URL], destination: URL) -> FileClipboard.Mode? {
            let destinationPath = destination.standardizedFileURL.pathComponents
            for source in sources {
                let sourcePath = source.standardizedFileURL.pathComponents
                // Can't drop a folder into itself or one of its subfolders.
                if destinationPath.starts(with: sourcePath) { return nil }
            }

            let mask = info.draggingSourceOperationMask
            let mode: FileClipboard.Mode
            if mask == .copy {
                mode = .copy
            } else if mask == .move {
                mode = .cut
            } else if mask.contains(.move) || mask.contains(.generic) {
                mode = sources.allSatisfy { FileOperations.isOnSameVolume($0, destination) } ? .cut : .copy
            } else if mask.contains(.copy) {
                mode = .copy
            } else {
                return nil
            }

            // Moving items into the folder they're already in does nothing.
            let alreadyThere = sources.allSatisfy {
                $0.deletingLastPathComponent().standardizedFileURL.path == destination.standardizedFileURL.path
            }
            if mode == .cut && alreadyThere { return nil }
            return mode
        }

        // MARK: Context menu

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let tableView else { return }

            let clickedRow = tableView.clickedRow
            if clickedRow < 0 {
                tableView.deselectAll(nil)
            } else if !tableView.selectedRowIndexes.contains(clickedRow) {
                tableView.selectRowIndexes([clickedRow], byExtendingSelection: false)
            }
            let selected = model.selectedItems

            if selected.isEmpty {
                menu.addItem(item("New Folder", #selector(menuNewFolder)))
                menu.addItem(.separator())
                let paste = item("Paste", #selector(menuPaste))
                paste.isEnabled = canPaste
                menu.addItem(paste)
                menu.addItem(.separator())
                menu.addItem(item("Open in Terminal", #selector(menuTerminal)))
                return
            }

            menu.addItem(item("Open", #selector(menuOpen)))
            if let openWith = openWithMenu(for: selected) {
                let openWithItem = NSMenuItem(title: "Open With", action: nil, keyEquivalent: "")
                openWithItem.submenu = openWith
                menu.addItem(openWithItem)
            }
            menu.addItem(.separator())
            menu.addItem(item("Copy", #selector(menuCopy)))
            menu.addItem(item("Cut", #selector(menuCut)))
            let paste = item("Paste", #selector(menuPaste))
            paste.isEnabled = canPaste
            menu.addItem(paste)
            menu.addItem(item("Duplicate", #selector(menuDuplicate)))
            menu.addItem(.separator())
            let rename = item("Rename", #selector(menuRename))
            rename.isEnabled = selected.count == 1
            menu.addItem(rename)
            menu.addItem(item("Move to Trash", #selector(menuTrash)))
            menu.addItem(item("Delete Immediately…", #selector(menuDelete)))
            menu.addItem(.separator())
            menu.addItem(item("Copy Path", #selector(menuCopyPath)))
            menu.addItem(item("Show in Finder", #selector(menuReveal)))
            if selected.count == 1, selected[0].isBrowsable {
                menu.addItem(item("Open in Terminal", #selector(menuTerminal)))
            }
        }

        /// Apps that can open every selected file, default app first.
        private func openWithMenu(for selected: [FileItem]) -> NSMenu? {
            guard !selected.contains(where: \.isBrowsable), let first = selected.first else { return nil }
            let workspace = NSWorkspace.shared
            var apps = workspace.urlsForApplications(toOpen: first.url)
            for item in selected.dropFirst() {
                let paths = Set(workspace.urlsForApplications(toOpen: item.url).map(\.path))
                apps = apps.filter { paths.contains($0.path) }
            }
            guard !apps.isEmpty else { return nil }

            let defaultApp = workspace.urlForApplication(toOpen: first.url)
            func name(_ url: URL) -> String { FileManager.default.displayName(atPath: url.path) }
            apps.sort { lhs, rhs in
                if lhs.path == defaultApp?.path { return true }
                if rhs.path == defaultApp?.path { return false }
                return name(lhs).localizedStandardCompare(name(rhs)) == .orderedAscending
            }

            let menu = NSMenu()
            for app in apps {
                let title = app.path == defaultApp?.path ? "\(name(app)) (default)" : name(app)
                let menuItem = item(title, #selector(menuOpenWith(_:)))
                menuItem.representedObject = app
                let icon = workspace.icon(forFile: app.path)
                icon.size = NSSize(width: 16, height: 16)
                menuItem.image = icon
                menu.addItem(menuItem)
            }
            return menu
        }

        private func item(_ title: String, _ action: Selector) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            return item
        }

        @objc private func menuOpen() { openSelection() }
        @objc private func menuOpenWith(_ sender: NSMenuItem) {
            guard let app = sender.representedObject as? URL else { return }
            model.open(model.selectedItems, withApplicationAt: app)
        }
        @objc private func menuNewFolder() { model.newFolder(undoManager: tableView?.undoManager) }
        @objc private func menuDuplicate() { model.duplicateSelection(undoManager: tableView?.undoManager) }
        @objc private func menuRename() { renameSelection() }
        @objc private func menuDelete() { model.deleteSelectionImmediately() }
        @objc private func menuTerminal() {
            let folder = model.selectedItems.first.flatMap { $0.isBrowsable ? $0.browseURL : nil }
            model.openTerminal(at: folder)
        }
        @objc private func menuCopy() { copySelection() }
        @objc private func menuCut() { cutSelection() }
        @objc private func menuPaste() { pasteHere() }
        @objc private func menuTrash() { trashSelection() }
        @objc private func menuCopyPath() { model.copyPathsOfSelection() }
        @objc private func menuReveal() { model.revealSelectionInFinder() }
    }
}

// MARK: - Columns

enum FileColumn: String, CaseIterable {
    case name, dateModified, size, kind

    var identifier: NSUserInterfaceItemIdentifier { NSUserInterfaceItemIdentifier(rawValue) }

    var title: String {
        switch self {
        case .name: return "Name"
        case .dateModified: return "Date Modified"
        case .size: return "Size"
        case .kind: return "Kind"
        }
    }

    var width: CGFloat {
        switch self {
        case .name: return 300
        case .dateModified: return 170
        case .size: return 80
        case .kind: return 140
        }
    }

    var sortKey: FileSort.Key {
        switch self {
        case .name: return .name
        case .dateModified: return .dateModified
        case .size: return .size
        case .kind: return .kind
        }
    }
}

// MARK: - Table subclass

@MainActor
protocol FileTableActions: AnyObject {
    var hasSelection: Bool { get }
    var canPaste: Bool { get }
    func openSelection()
    func renameSelection()
    func copySelection()
    func cutSelection()
    func pasteHere()
    func trashSelection()
}

/// Hooks the standard Edit menu (⌘C / ⌘X / ⌘V) and Finder-style keys into the file list.
final class FileTable: NSTableView {
    weak var actions: FileTableActions?

    @objc func copy(_ sender: Any?) { actions?.copySelection() }
    @objc func cut(_ sender: Any?) { actions?.cutSelection() }
    @objc func paste(_ sender: Any?) { actions?.pasteHere() }

    /// Edit menu items are enabled only when this returns true for their action.
    nonisolated override func responds(to aSelector: Selector!) -> Bool {
        guard Thread.isMainThread else { return super.responds(to: aSelector) }
        if aSelector == #selector(copy(_:)) || aSelector == #selector(cut(_:)) {
            return MainActor.assumeIsolated { actions?.hasSelection ?? false }
        }
        if aSelector == #selector(paste(_:)) {
            return MainActor.assumeIsolated { actions?.canPaste ?? false }
        }
        return super.responds(to: aSelector)
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let isReturn = event.keyCode == 36 || event.keyCode == 76 // Return, keypad Enter
        if isReturn && modifiers.isEmpty {
            actions?.openSelection()
        } else if event.keyCode == 125 && modifiers == .command { // ⌘↓
            actions?.openSelection()
        } else if event.keyCode == 120 && modifiers.isEmpty { // F2
            actions?.renameSelection()
        } else {
            super.keyDown(with: event)
        }
    }
}

// MARK: - Cells

final class FileCellView: NSTableCellView {
    init(column: FileColumn) {
        super.init(frame: .zero)
        identifier = column.identifier

        let label = NSTextField(labelWithString: "")
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = column == .name ? .byTruncatingMiddle : .byTruncatingTail
        label.alignment = column == .size ? .right : .left
        if column != .name {
            label.textColor = .secondaryLabelColor
        }
        addSubview(label)
        textField = label

        if column == .name {
            let icon = NSImageView()
            icon.translatesAutoresizingMaskIntoConstraints = false
            icon.imageScaling = .scaleProportionallyUpOrDown
            addSubview(icon)
            imageView = icon
            NSLayoutConstraint.activate([
                icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
                icon.centerYAnchor.constraint(equalTo: centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: 16),
                icon.heightAnchor.constraint(equalToConstant: 16),
                label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            ])
        } else {
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4).isActive = true
        }
        NSLayoutConstraint.activate([
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}
