import AppKit
import FileCore
import Quartz

/// Drives one file table: the list view, or one column of the column view.
///
/// Uses AppKit's `NSTableView` because it stays fast with very large folders. All file operations
/// go through `BrowserModel`; this class handles display, selection, rename, drag & drop and menus.
@MainActor
final class FileListController: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate,
    NSTextFieldDelegate, FileTableActions {

    enum Style {
        /// Name, Date Modified, Size and Kind columns with sortable headers.
        case list
        /// Names only, with a chevron on folders.
        case column
    }

    let style: Style
    let model: BrowserModel
    let tableView = FileTable()
    let scrollView = NSScrollView()

    /// The folder these items are in; drops onto the empty area go here.
    var folder: URL
    /// False for Recents, which isn't a real folder.
    var acceptsNewItems = true

    var onSelectionChange: ((FileListController) -> Void)?
    var onOpen: ((FileListController, [FileItem]) -> Void)?
    var onFocus: ((FileListController) -> Void)?
    var onMoveLeft: ((FileListController) -> Bool)?
    var onMoveRight: ((FileListController) -> Bool)?

    private(set) var items: [FileItem] = []
    private var cutPaths: Set<String> = []
    /// True while we change the table ourselves, so delegate callbacks don't write back into the model.
    private var isUpdating = false
    private var renamingItem: FileItem?
    private var scheduledRename: URL?
    private var rowSize: RowSize = .regular
    private var accentColor: NSColor = .controlAccentColor
    private var palette: ThemePalette?
    private var alternatingRows = false
    private var hasAppliedSettings = false

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    init(style: Style, model: BrowserModel, folder: URL) {
        self.style = style
        self.model = model
        self.folder = folder
        super.init()
        configureTable()
    }

    var selectedItems: [FileItem] {
        tableView.selectedRowIndexes.compactMap { items.indices.contains($0) ? items[$0] : nil }
    }

    var selectedURLs: Set<URL> { Set(selectedItems.map(\.url)) }

    private func configureTable() {
        tableView.style = .plain
        tableView.allowsMultipleSelection = true
        tableView.allowsEmptySelection = true
        tableView.intercellSpacing = NSSize(width: 0, height: 2)
        tableView.backgroundColor = .clear
        tableView.focusRingType = .none

        switch style {
        case .list:
            tableView.allowsColumnReordering = true
            tableView.allowsColumnResizing = true
            tableView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
            for column in FileColumn.allCases {
                let tableColumn = NSTableColumn(identifier: column.identifier)
                tableColumn.headerCell = ThemedHeaderCell(textCell: column.title)
                tableColumn.title = column.title
                tableColumn.width = column.width
                tableColumn.minWidth = 60
                tableColumn.sortDescriptorPrototype = NSSortDescriptor(key: column.sortKey.rawValue, ascending: true)
                if column == .size {
                    tableColumn.headerCell.alignment = .right
                }
                tableView.addTableColumn(tableColumn)
            }
        case .column:
            tableView.headerView = nil
            tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
            let tableColumn = NSTableColumn(identifier: FileColumn.name.identifier)
            tableColumn.resizingMask = .autoresizingMask
            tableView.addTableColumn(tableColumn)
        }

        tableView.dataSource = self
        tableView.delegate = self
        tableView.actions = self
        tableView.target = self
        tableView.doubleAction = #selector(doubleClicked(_:))

        tableView.registerForDraggedTypes([.fileURL])
        tableView.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
        tableView.setDraggingSourceOperationMask([.copy, .move], forLocal: false)

        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        tableView.menu = menu

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
    }

    // MARK: - Updating

    /// Shows `newItems`. `selectedPaths` replaces the selection; `nil` keeps the current one.
    func display(_ newItems: [FileItem], selectedPaths: Set<String>?, cutPaths newCutPaths: Set<String>) {
        isUpdating = true
        defer { isUpdating = false }

        let keepPaths = selectedPaths ?? Set(selectedItems.map(\.url.path))
        if (newItems != items || newCutPaths != cutPaths) && renamingItem == nil {
            items = newItems
            cutPaths = newCutPaths
            tableView.reloadData()
        }

        let rows = IndexSet(items.indices.filter { keepPaths.contains(items[$0].url.path) })
        if rows != tableView.selectedRowIndexes {
            tableView.selectRowIndexes(rows, byExtendingSelection: false)
            if let first = rows.first {
                tableView.scrollRowToVisible(first)
            }
        }
        tableView.refreshQuickLook()
    }

    /// Shows the sort in the list header without feeding it back to the model.
    func showSort(_ sort: FileSort) {
        guard style == .list else { return }
        let descriptor = NSSortDescriptor(key: sort.key.rawValue, ascending: sort.ascending)
        updateHeaderSortIndicators(sort)
        guard tableView.sortDescriptors.first != descriptor else { return }
        isUpdating = true
        tableView.sortDescriptors = [descriptor]
        isUpdating = false
    }

    private func updateHeaderSortIndicators(_ sort: FileSort) {
        for tableColumn in tableView.tableColumns {
            guard let cell = tableColumn.headerCell as? ThemedHeaderCell else { continue }
            let ascending: Bool? = tableColumn.identifier.rawValue == sort.key.rawValue ? sort.ascending : nil
            if cell.sortAscending != ascending {
                cell.sortAscending = ascending
                tableView.headerView?.needsDisplay = true
            }
        }
    }

    /// Applies the look from Settings; `rowSize` overrides the row size (e.g. thumbnails for Screenshots).
    func apply(_ settings: ThemeSettings, rowSize override: RowSize? = nil) {
        let accent = settings.accentNSColor
        let newRowSize = override ?? settings.rowSize
        let newPalette = settings.palette
        let changed = !hasAppliedSettings || newRowSize != rowSize || accent != accentColor
            || newPalette != palette || alternatingRows != settings.alternatingRows
        guard changed else { return }
        hasAppliedSettings = true
        rowSize = newRowSize
        accentColor = accent
        palette = newPalette
        alternatingRows = settings.alternatingRows
        tableView.rowHeight = rowSize.rowHeight

        // Color themes paint their own background and alternate rows; Native uses the system's.
        tableView.usesAlternatingRowBackgroundColors = palette == nil && alternatingRows
        tableView.backgroundColor = palette?.background ?? .clear
        scrollView.drawsBackground = palette != nil
        scrollView.backgroundColor = palette?.background ?? .clear
        for tableColumn in tableView.tableColumns {
            (tableColumn.headerCell as? ThemedHeaderCell)?.palette = palette
        }
        tableView.headerView?.needsDisplay = true
        tableView.enumerateAvailableRowViews { rowView, row in
            self.configure(rowView, row: row)
        }

        isUpdating = true
        tableView.reloadData()
        tableView.selectRowIndexes(tableView.selectedRowIndexes, byExtendingSelection: false)
        isUpdating = false
    }

    func focus(selectingFirstRowIfEmpty: Bool = false) {
        tableView.window?.makeFirstResponder(tableView)
        if selectingFirstRowIfEmpty, tableView.selectedRowIndexes.isEmpty, !items.isEmpty {
            tableView.selectRowIndexes([0], byExtendingSelection: false)
        }
    }

    func scrollToTop() {
        if !items.isEmpty {
            tableView.scrollRowToVisible(0)
        }
    }

    // MARK: - Data source & delegate

    func numberOfRows(in tableView: NSTableView) -> Int {
        items.count
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let rowView = ThemedRowView()
        configure(rowView, row: row)
        return rowView
    }

    private func configure(_ rowView: NSTableRowView, row: Int) {
        guard let rowView = rowView as? ThemedRowView else { return }
        rowView.accentColor = accentColor
        rowView.alternateColor = alternatingRows && row % 2 == 1 ? palette?.alternateRow : nil
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let identifier = tableColumn?.identifier,
              let column = FileColumn(rawValue: identifier.rawValue),
              items.indices.contains(row)
        else { return nil }

        let item = items[row]
        let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? FileCellView
            ?? FileCellView(column: column, showsChevron: style == .column)
        cell.apply(rowSize, palette: palette)

        switch column {
        case .name:
            cell.textField?.stringValue = item.name
            cell.textField?.isEditable = false
            cell.textField?.delegate = self
            cell.showsChevron = style == .column && item.isBrowsable
            showIcon(for: item, in: cell)
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

    /// Shows the file's icon right away, then swaps in a real thumbnail for images, videos and PDFs.
    private func showIcon(for item: FileItem, in cell: FileCellView) {
        cell.representedPath = item.url.path
        let size = rowSize.iconSize
        let thumbnails = ThumbnailCache.shared
        if let cached = thumbnails.cachedThumbnail(for: item.url, size: size, modified: item.dateModified) {
            cell.imageView?.image = cached
            return
        }
        cell.imageView?.image = NSWorkspace.shared.icon(forFile: item.url.path)
        guard !item.isDirectory, ThumbnailCache.supportsThumbnail(item.url) else { return }
        thumbnails.loadThumbnail(for: item.url, size: size, modified: item.dateModified) { [weak cell] image in
            guard let cell, cell.representedPath == item.url.path else { return }
            cell.imageView?.image = image
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        tableView.refreshQuickLook()
        guard !isUpdating else { return }
        onSelectionChange?(self)
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard !isUpdating,
              let descriptor = tableView.sortDescriptors.first,
              let key = FileSort.Key(rawValue: descriptor.key ?? "")
        else { return }
        model.sort.key = key
        model.sort.ascending = descriptor.ascending
    }

    @objc private func doubleClicked(_ sender: NSTableView) {
        let row = sender.clickedRow
        guard items.indices.contains(row) else { return }
        onOpen?(self, [items[row]])
    }

    // MARK: - FileTableActions

    var hasSelection: Bool { !model.selection.isEmpty }

    var canPaste: Bool {
        model.clipboard.refreshFromPasteboard()
        return model.canPaste
    }

    var quickLookURLs: [URL] { selectedItems.map(\.url) }

    func openSelection() { onOpen?(self, selectedItems) }
    func renameSelection() { model.renameSelection() }
    func copySelection() { model.copySelection() }
    func cutSelection() { model.cutSelection() }
    func pasteHere() { model.paste(undoManager: tableView.undoManager) }
    func trashSelection() { model.trashSelection(undoManager: tableView.undoManager) }
    func moveLeft() -> Bool { onMoveLeft?(self) ?? false }
    func moveRight() -> Bool { onMoveRight?(self) ?? false }
    func didBecomeFirstResponder() { onFocus?(self) }
    func cancelCut() { model.clipboard.cancelCut() }

    // MARK: - Rename

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
        guard let row = items.firstIndex(where: { $0.url.path == url.path }) else { return }
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
        model.rename(item.url, to: newName, undoManager: tableView.undoManager)
        tableView.window?.makeFirstResponder(tableView)
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
        tableView.window?.makeFirstResponder(tableView)
        return true
    }

    // MARK: - Drag & drop

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
        if let target = dropFolder(row: row, operation: dropOperation) {
            destination = target
        } else {
            // Not onto a folder: drop into the folder being shown.
            guard acceptsNewItems else { return [] }
            tableView.setDropRow(-1, dropOperation: .on)
            destination = folder
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
        let destination = dropFolder(row: row, operation: dropOperation) ?? folder
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

    // MARK: - Context menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let clickedRow = tableView.clickedRow
        if clickedRow < 0 {
            tableView.deselectAll(nil)
        } else if !tableView.selectedRowIndexes.contains(clickedRow) {
            tableView.selectRowIndexes([clickedRow], byExtendingSelection: false)
        }
        // Make sure the model acts on this list (matters in column view).
        tableView.window?.makeFirstResponder(tableView)
        let selected = selectedItems

        if selected.isEmpty {
            if acceptsNewItems {
                menu.addItem(item("New Folder", #selector(menuNewFolder)))
                menu.addItem(.separator())
                let paste = item("Paste", #selector(menuPaste))
                paste.isEnabled = canPaste
                menu.addItem(paste)
                menu.addItem(.separator())
                menu.addItem(item("Open in Terminal", #selector(menuTerminal)))
            }
            return
        }

        menu.addItem(item("Open", #selector(menuOpen)))
        if let openWith = openWithMenu(for: selected) {
            let openWithItem = NSMenuItem(title: "Open With", action: nil, keyEquivalent: "")
            openWithItem.submenu = openWith
            menu.addItem(openWithItem)
        }
        menu.addItem(item("Quick Look", #selector(menuQuickLook)))
        menu.addItem(.separator())
        menu.addItem(item("Copy", #selector(menuCopy), key: "c"))
        menu.addItem(item("Cut", #selector(menuCut), key: "x"))
        let paste = item("Paste", #selector(menuPaste), key: "v")
        paste.isEnabled = canPaste
        menu.addItem(paste)
        menu.addItem(item("Duplicate", #selector(menuDuplicate), key: "d"))
        if selected.count == 1, ThumbnailCache.isImage(selected[0].url) {
            menu.addItem(item("Copy Image", #selector(menuCopyImage)))
        }
        menu.addItem(.separator())
        let rename = item("Rename", #selector(menuRename), key: "r")
        rename.isEnabled = selected.count == 1
        menu.addItem(rename)
        menu.addItem(item("Move to Trash", #selector(menuTrash), key: "\u{8}"))
        menu.addItem(item("Delete Immediately…", #selector(menuDelete), key: "\u{8}", modifiers: [.command, .option]))
        menu.addItem(.separator())
        if model.location.kind != .folder, selected.count == 1 {
            menu.addItem(item("Show in Enclosing Folder", #selector(menuEnclosingFolder)))
        }
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
        for other in selected.dropFirst() {
            let paths = Set(workspace.urlsForApplications(toOpen: other.url).map(\.path))
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

    /// A context menu item. `key` only shows the shortcut (the File/Edit menus handle the keys).
    private func item(
        _ title: String, _ action: Selector, key: String = "", modifiers: NSEvent.ModifierFlags = .command
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = self
        return item
    }

    @objc private func menuOpen() { openSelection() }
    @objc private func menuOpenWith(_ sender: NSMenuItem) {
        guard let app = sender.representedObject as? URL else { return }
        model.open(model.selectedItems, withApplicationAt: app)
    }
    @objc private func menuQuickLook() { tableView.toggleQuickLook() }
    @objc private func menuNewFolder() { model.newFolder(undoManager: tableView.undoManager) }
    @objc private func menuCopy() { copySelection() }
    @objc private func menuCut() { cutSelection() }
    @objc private func menuPaste() { pasteHere() }
    @objc private func menuDuplicate() { model.duplicateSelection(undoManager: tableView.undoManager) }
    @objc private func menuRename() { renameSelection() }
    @objc private func menuTrash() { trashSelection() }
    @objc private func menuDelete() { model.deleteSelectionImmediately() }
    @objc private func menuCopyPath() { model.copyPathsOfSelection() }
    @objc private func menuCopyImage() { model.copyImageOfSelection() }
    @objc private func menuReveal() { model.revealSelectionInFinder() }
    @objc private func menuEnclosingFolder() {
        guard let item = selectedItems.first else { return }
        model.showInEnclosingFolder(item)
    }
    @objc private func menuTerminal() {
        let target = selectedItems.first.flatMap { $0.isBrowsable ? $0.browseURL : nil }
        model.openTerminal(at: target ?? folder)
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
    var quickLookURLs: [URL] { get }
    func openSelection()
    func renameSelection()
    func copySelection()
    func cutSelection()
    func pasteHere()
    func trashSelection()
    /// Column view: ← / →. Returns false to let the table handle the key.
    func moveLeft() -> Bool
    func moveRight() -> Bool
    func didBecomeFirstResponder()
    /// Esc: forget a pending cut.
    func cancelCut()
}

/// Hooks the standard Edit menu (⌘C / ⌘X / ⌘V), Quick Look and Finder-style keys into a file list.
final class FileTable: NSTableView {
    weak var actions: FileTableActions?
    private let quickLookSource = QuickLookSource()

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

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted {
            actions?.didBecomeFirstResponder()
        }
        return accepted
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
        } else if event.keyCode == 53 && modifiers.isEmpty { // Esc
            actions?.cancelCut()
        } else if event.keyCode == 49 && modifiers.isEmpty { // Space
            toggleQuickLook()
        } else if event.keyCode == 123 && modifiers.isEmpty, actions?.moveLeft() == true { // ←
            return
        } else if event.keyCode == 124 && modifiers.isEmpty, actions?.moveRight() == true { // →
            return
        } else {
            super.keyDown(with: event)
        }
    }

    // MARK: Quick Look

    func toggleQuickLook() {
        guard let panel = QLPreviewPanel.shared() else { return }
        if QLPreviewPanel.sharedPreviewPanelExists() && panel.isVisible {
            panel.orderOut(nil)
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    /// Keeps an open Quick Look panel in sync with the selection.
    func refreshQuickLook() {
        guard QLPreviewPanel.sharedPreviewPanelExists(),
              let panel = QLPreviewPanel.shared(), panel.isVisible,
              (panel.dataSource as AnyObject?) === quickLookSource
        else { return }
        quickLookSource.urls = actions?.quickLookURLs ?? []
        panel.reloadData()
    }

    nonisolated override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        true
    }

    nonisolated override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            quickLookSource.urls = actions?.quickLookURLs ?? []
            panel.dataSource = quickLookSource
            panel.delegate = quickLookSource
            panel.reloadData()
        }
    }

    nonisolated override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = nil
            panel.delegate = nil
        }
    }
}

/// Feeds the selected files to the Quick Look panel.
final class QuickLookSource: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    var urls: [URL] = []

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        urls.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        urls[index] as NSURL
    }
}

// MARK: - Cells

final class FileCellView: NSTableCellView {
    private var iconWidth: NSLayoutConstraint?
    private var iconHeight: NSLayoutConstraint?
    private let chevron = NSImageView()
    private var appliedSize: RowSize?
    private var palette: ThemePalette?
    private let isNameColumn: Bool
    /// The file this cell currently shows, so late thumbnails don't land on a reused cell.
    var representedPath: String?

    var showsChevron = false {
        didSet { chevron.isHidden = !showsChevron }
    }

    init(column: FileColumn, showsChevron allowsChevron: Bool) {
        isNameColumn = column == .name
        super.init(frame: .zero)
        identifier = column.identifier

        let label = NSTextField(labelWithString: "")
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = column == .name ? .byTruncatingMiddle : .byTruncatingTail
        label.alignment = column == .size ? .right : .left
        addSubview(label)
        textField = label
        updateColors()

        var trailingAnchorForLabel = trailingAnchor
        if allowsChevron {
            chevron.translatesAutoresizingMaskIntoConstraints = false
            chevron.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)
            chevron.contentTintColor = .tertiaryLabelColor
            chevron.symbolConfiguration = .init(pointSize: 10, weight: .semibold)
            chevron.isHidden = true
            addSubview(chevron)
            NSLayoutConstraint.activate([
                chevron.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
                chevron.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
            trailingAnchorForLabel = chevron.leadingAnchor
        }

        if column == .name {
            let icon = NSImageView()
            icon.translatesAutoresizingMaskIntoConstraints = false
            icon.imageScaling = .scaleProportionallyUpOrDown
            addSubview(icon)
            imageView = icon
            iconWidth = icon.widthAnchor.constraint(equalToConstant: 20)
            iconHeight = icon.heightAnchor.constraint(equalToConstant: 20)
            NSLayoutConstraint.activate([
                icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
                icon.centerYAnchor.constraint(equalTo: centerYAnchor),
                iconWidth!, iconHeight!,
                label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 7),
            ])
        } else {
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4).isActive = true
        }
        NSLayoutConstraint.activate([
            label.trailingAnchor.constraint(equalTo: trailingAnchorForLabel, constant: -6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    func apply(_ size: RowSize, palette newPalette: ThemePalette?) {
        if newPalette != palette {
            palette = newPalette
            updateColors()
        }
        guard size != appliedSize else { return }
        appliedSize = size
        iconWidth?.constant = size.iconSize
        iconHeight?.constant = size.iconSize
        // Dates and sizes use tabular digits so the columns line up.
        textField?.font = isNameColumn
            ? .systemFont(ofSize: size.fontSize)
            : .monospacedDigitSystemFont(ofSize: size.fontSize - 1, weight: .regular)
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { updateColors() }
    }

    /// Theme text colors, switching to the theme's selection text color on a selected row.
    private func updateColors() {
        let selected = backgroundStyle == .emphasized
        if let palette {
            textField?.textColor = selected ? palette.selectionText : (isNameColumn ? palette.text : palette.secondaryText)
            chevron.contentTintColor = selected ? palette.selectionText : palette.secondaryText
        } else {
            textField?.textColor = isNameColumn ? .labelColor : .secondaryLabelColor
            chevron.contentTintColor = .tertiaryLabelColor
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}
