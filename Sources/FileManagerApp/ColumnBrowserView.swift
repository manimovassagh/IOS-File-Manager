import AppKit
import FileCore
import SwiftUI

/// Column view, like Finder's: selecting a folder opens its contents in the next column,
/// and selecting a file shows a preview at the end.
struct ColumnBrowserView: NSViewRepresentable {
    @ObservedObject var model: BrowserModel
    @ObservedObject var settings: ThemeSettings
    let cutPaths: Set<String>

    func makeCoordinator() -> ColumnBrowserController {
        ColumnBrowserController(model: model)
    }

    func makeNSView(context: Context) -> NSScrollView {
        context.coordinator.scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.update(settings: settings, cutPaths: cutPaths)
    }
}

/// One column: a file list with its own items and folder watcher.
@MainActor
private final class Column {
    let list: FileListController
    let source: ItemSource
    let container = NSView()
    var allItems: [FileItem] = []
    var watcher: DirectoryWatcher?
    var generation = 0

    init(list: FileListController, source: ItemSource) {
        self.list = list
        self.source = source
    }

    var folder: URL { list.folder }
}

@MainActor
final class ColumnBrowserController {
    static let columnWidth: CGFloat = 240
    static let previewWidth: CGFloat = 300

    let scrollView = NSScrollView()
    private let model: BrowserModel
    private let stack = NSStackView()
    private var columns: [Column] = []
    private var preview: NSHostingView<FilePreview>?
    private var focusedIndex = 0
    private var navigationID = -1
    private var showHidden = false
    private var sort = FileSort()
    private var filterText = ""
    private var cutPaths: Set<String> = []
    private var settings = ThemeSettings.shared

    init(model: BrowserModel) {
        self.model = model
        stack.orientation = .horizontal
        stack.spacing = 0
        stack.alignment = .top
        stack.distribution = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false

        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.documentView = stack
        let clip = scrollView.contentView
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: clip.topAnchor),
            stack.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            stack.heightAnchor.constraint(equalTo: clip.heightAnchor),
        ])
    }

    // MARK: - Updates from SwiftUI

    func update(settings newSettings: ThemeSettings, cutPaths newCutPaths: Set<String>) {
        settings = newSettings
        let displayChanged = model.effectiveSort != sort || model.filterText != filterText || newCutPaths != cutPaths
        sort = model.effectiveSort
        filterText = model.filterText
        cutPaths = newCutPaths

        if model.navigationID != navigationID {
            navigationID = model.navigationID
            showHidden = model.showHidden
            rebuild()
        } else if model.showHidden != showHidden {
            showHidden = model.showHidden
            columns.forEach(load)
        } else if displayChanged {
            columns.forEach { redisplay($0) }
        }
        columns.forEach { $0.list.apply(settings) }

        // The model reloads the focused folder after paste, rename, etc.; show its result.
        if columns.indices.contains(focusedIndex), !model.isLoading {
            let focused = columns[focusedIndex]
            if focused.folder.standardizedFileURL.path == model.currentURL.standardizedFileURL.path {
                focused.allItems = model.allItems
                redisplay(focused, selectedPaths: Set(model.selection.map(\.path)))
                syncColumns(after: focusedIndex)
            }
            focused.list.handleRenameRequest(model.renameRequest)
        }
    }

    // MARK: - Building columns

    private func rebuild() {
        columns.forEach { $0.container.removeFromSuperview() }
        columns.removeAll()
        removePreview()
        focusedIndex = 0
        let root = addColumn(folder: model.baseURL, source: model.itemSource(for: model.baseURL))
        root.list.acceptsNewItems = model.location.acceptsNewItems
        DispatchQueue.main.async { root.list.focus() }
    }

    @discardableResult
    private func addColumn(folder: URL, source: ItemSource) -> Column {
        let list = FileListController(style: .column, model: model, folder: folder)
        let column = Column(list: list, source: source)
        list.apply(settings)
        list.onSelectionChange = { [weak self] list in self?.selectionChanged(in: list) }
        list.onFocus = { [weak self] list in self?.focusChanged(to: list) }
        list.onOpen = { [weak self] list, items in self?.open(items, from: list) }
        list.onMoveLeft = { [weak self] list in self?.moveLeft(from: list) ?? false }
        list.onMoveRight = { [weak self] list in self?.moveRight(from: list) ?? false }

        let container = column.container
        container.translatesAutoresizingMaskIntoConstraints = false
        list.scrollView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(list.scrollView)
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(separator)
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: Self.columnWidth),
            list.scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            list.scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            list.scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            list.scrollView.trailingAnchor.constraint(equalTo: separator.leadingAnchor),
            separator.topAnchor.constraint(equalTo: container.topAnchor),
            separator.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            separator.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            separator.widthAnchor.constraint(equalToConstant: 1),
        ])
        if let preview {
            stack.insertArrangedSubview(container, at: stack.arrangedSubviews.firstIndex(of: preview) ?? stack.arrangedSubviews.count)
        } else {
            stack.addArrangedSubview(container)
        }
        container.heightAnchor.constraint(equalTo: stack.heightAnchor).isActive = true
        columns.append(column)

        if source != .recents {
            column.watcher = DirectoryWatcher(url: folder) { [weak self, weak column] in
                Task { @MainActor in
                    guard let self, let column else { return }
                    self.load(column)
                }
            }
        }
        load(column)
        scrollToEnd()
        return column
    }

    private func load(_ column: Column) {
        column.generation += 1
        let generation = column.generation
        let includeHidden = showHidden
        Task {
            let loaded = (try? await ItemLoader.load(column.source, includeHidden: includeHidden)) ?? []
            guard generation == column.generation, let index = columns.firstIndex(where: { $0 === column }) else { return }
            column.allItems = loaded
            redisplay(column)
            if index == focusedIndex {
                model.focusColumn(folder: column.folder, items: column.allItems, selection: column.list.selectedURLs)
            }
            syncColumns(after: index)
        }
    }

    private func redisplay(_ column: Column, selectedPaths: Set<String>? = nil) {
        let items = BrowserModel.arrange(column.allItems, sort: sort, filter: filterText)
        column.list.display(items, selectedPaths: selectedPaths, cutPaths: cutPaths)
    }

    /// Makes the columns after `index` match its selection: a folder opens a column, a file shows a preview.
    private func syncColumns(after index: Int) {
        guard columns.indices.contains(index) else { return }
        let selected = columns[index].list.selectedItems

        if selected.count == 1, selected[0].isBrowsable {
            let folder = selected[0].browseURL
            let nextIndex = index + 1
            if columns.indices.contains(nextIndex),
               columns[nextIndex].folder.standardizedFileURL.path == folder.standardizedFileURL.path {
                return
            }
            truncate(after: index)
            removePreview()
            addColumn(folder: folder, source: .folder(folder))
        } else {
            truncate(after: index)
            if selected.count == 1 {
                showPreview(selected[0])
            } else {
                removePreview()
            }
        }
    }

    private func truncate(after index: Int) {
        while columns.count > index + 1 {
            let column = columns.removeLast()
            column.container.removeFromSuperview()
        }
        if focusedIndex > index {
            focusedIndex = index
        }
    }

    private func showPreview(_ item: FileItem) {
        if let preview {
            preview.rootView = FilePreview(item: item)
        } else {
            let host = NSHostingView(rootView: FilePreview(item: item))
            host.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(host)
            NSLayoutConstraint.activate([
                host.widthAnchor.constraint(equalToConstant: Self.previewWidth),
                host.heightAnchor.constraint(equalTo: stack.heightAnchor),
            ])
            preview = host
        }
        scrollToEnd()
    }

    private func removePreview() {
        preview?.removeFromSuperview()
        preview = nil
    }

    private func scrollToEnd() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let last = self.stack.arrangedSubviews.last else { return }
            self.stack.layoutSubtreeIfNeeded()
            self.stack.scrollToVisible(last.frame)
        }
    }

    // MARK: - User actions

    private func index(of list: FileListController) -> Int? {
        columns.firstIndex { $0.list === list }
    }

    private func selectionChanged(in list: FileListController) {
        guard let index = index(of: list) else { return }
        focusedIndex = index
        let column = columns[index]
        model.focusColumn(folder: column.folder, items: column.allItems, selection: list.selectedURLs)
        syncColumns(after: index)
    }

    private func focusChanged(to list: FileListController) {
        guard let index = index(of: list), index != focusedIndex else { return }
        focusedIndex = index
        let column = columns[index]
        model.focusColumn(folder: column.folder, items: column.allItems, selection: list.selectedURLs)
    }

    private func open(_ items: [FileItem], from list: FileListController) {
        if items.count == 1, items[0].isBrowsable {
            _ = moveRight(from: list)
        } else {
            model.open(items.filter { !$0.isBrowsable })
        }
    }

    private func moveLeft(from list: FileListController) -> Bool {
        guard let index = index(of: list), index > 0 else { return true }
        let previous = columns[index - 1]
        previous.list.focus()
        selectionChanged(in: previous.list)
        return true
    }

    private func moveRight(from list: FileListController) -> Bool {
        guard let index = index(of: list) else { return false }
        let selected = list.selectedItems
        guard selected.count == 1, selected[0].isBrowsable else { return true }
        syncColumns(after: index)
        guard columns.indices.contains(index + 1) else { return true }
        columns[index + 1].list.focus(selectingFirstRowIfEmpty: true)
        return true
    }
}
