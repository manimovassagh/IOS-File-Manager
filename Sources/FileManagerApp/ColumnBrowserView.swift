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

    func makeNSView(context: Context) -> ColumnsHostView {
        context.coordinator.hostView
    }

    func updateNSView(_ hostView: ColumnsHostView, context: Context) {
        context.coordinator.update(settings: settings, cutPaths: cutPaths)
    }
}

/// Lays the columns out side by side in a horizontally scrolling area.
///
/// Uses plain frames rather than Auto Layout: a stack view inside a scroll view's document view
/// is easy to get wrong and can end up with zero size, leaving the area blank.
final class ColumnsHostView: NSView {
    let scrollView = NSScrollView()
    private let documentView = FlippedView()
    /// Side-by-side panes. A `nil` width means "fill the remaining space" (the preview).
    private(set) var panes: [(view: NSView, width: CGFloat?)] = []
    /// Panes that have had their first real layout (and were scrolled to the top then).
    private var laidOutPanes: Set<ObjectIdentifier> = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.documentView = documentView
        scrollView.frame = bounds
        scrollView.autoresizingMask = [.width, .height]
        addSubview(scrollView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func setPanes(_ newPanes: [(view: NSView, width: CGFloat?)]) {
        let newViews = Set(newPanes.map { ObjectIdentifier($0.view) })
        for pane in panes where !newViews.contains(ObjectIdentifier(pane.view)) {
            pane.view.removeFromSuperview()
        }
        for pane in newPanes where pane.view.superview !== documentView {
            documentView.addSubview(pane.view)
        }
        panes = newPanes
        laidOutPanes.formIntersection(newViews)
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    override func layout() {
        super.layout()
        scrollView.frame = bounds
        let height = max(scrollView.contentSize.height, 1)
        let fixedWidth = panes.compactMap(\.width).reduce(0, +)
        let flexibleWidth = max(ColumnBrowserController.minPreviewWidth, scrollView.contentSize.width - fixedWidth)
        var x: CGFloat = 0
        for pane in panes {
            let width = pane.width ?? flexibleWidth
            pane.view.frame = NSRect(x: x, y: 0, width: width, height: height)
            x += width
        }
        documentView.frame = NSRect(x: 0, y: 0, width: max(x, scrollView.contentSize.width), height: height)
        for pane in panes {
            pane.view.layoutSubtreeIfNeeded()
            let scrollViews = pane.view.subviews.compactMap { $0 as? NSScrollView }
            if height > 1, laidOutPanes.insert(ObjectIdentifier(pane.view)).inserted {
                // A new column starts at its first row (unless a selected row needs to be shown).
                scrollViews.forEach(Self.scrollToTop)
            }
            scrollViews.forEach(Self.keepScrollPositionInRange)
        }
    }

    static func scrollToTop(_ scrollView: NSScrollView) {
        if let table = scrollView.documentView as? NSTableView, let selected = table.selectedRowIndexes.first {
            table.scrollRowToVisible(selected)
            return
        }
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: 0))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    /// After a column grows, AppKit can leave it scrolled past its content, hiding the first rows
    /// above the top edge (with a short folder the column then looks empty). Pull it back in range.
    static func keepScrollPositionInRange(_ scrollView: NSScrollView) {
        guard let document = scrollView.documentView else { return }
        let clip = scrollView.contentView
        let maxY = max(0, document.frame.height - clip.bounds.height)
        let y = clip.bounds.origin.y
        guard y < 0 || y > maxY else { return }
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: min(max(y, 0), maxY)))
        scrollView.reflectScrolledClipView(clip)
    }

    /// Background behind the columns and preview for color themes (`nil`: none).
    func applyBackground(_ color: NSColor?) {
        scrollView.drawsBackground = color != nil
        scrollView.backgroundColor = color ?? .clear
    }

    func scrollToEnd() {
        guard let last = panes.last?.view else { return }
        documentView.scrollToVisible(last.frame)
    }
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// One column's view: the file list filling it, with a 1 pt separator on the right.
///
/// Lays out its subviews explicitly. AppKit's autoresizing, starting from a small initial frame,
/// stretched the list to double width and pushed its first rows above the visible area.
final class ColumnContainerView: NSView {
    let content: NSView
    private let separator = NSBox()

    /// Separator color for color themes; `nil` uses the system separator.
    var separatorColor: NSColor? {
        didSet {
            guard separatorColor != oldValue else { return }
            separator.boxType = separatorColor == nil ? .separator : .custom
            separator.borderWidth = 0
            separator.fillColor = separatorColor ?? .clear
        }
    }

    init(content: NSView) {
        self.content = content
        super.init(frame: NSRect(x: 0, y: 0, width: ColumnBrowserController.columnWidth, height: 400))
        autoresizesSubviews = false
        content.autoresizingMask = []
        separator.boxType = .separator
        addSubview(content)
        addSubview(separator)
        layoutContent()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutContent()
    }

    override func layout() {
        super.layout()
        layoutContent()
    }

    private func layoutContent() {
        let width = max(bounds.width - 1, 0)
        content.frame = NSRect(x: 0, y: 0, width: width, height: bounds.height)
        separator.frame = NSRect(x: width, y: 0, width: 1, height: bounds.height)
    }
}

/// One column: a file list with its own items and folder watcher.
@MainActor
final class BrowserColumn {
    let list: FileListController
    let source: ItemSource
    let container: ColumnContainerView
    var allItems: [FileItem] = []
    var watcher: DirectoryWatcher?
    var generation = 0

    init(list: FileListController, source: ItemSource) {
        self.list = list
        self.source = source
        container = ColumnContainerView(content: list.scrollView)
    }

    var folder: URL { list.folder }
}

@MainActor
final class ColumnBrowserController {
    static let columnWidth: CGFloat = 240
    /// Screenshot columns are wider so the full name (with date and time) fits next to the thumbnail.
    static let thumbnailColumnWidth: CGFloat = 380
    /// The preview fills the space after the columns, but is never narrower than this.
    static let minPreviewWidth: CGFloat = 360

    static func width(for source: ItemSource) -> CGFloat {
        if case .screenshots = source { return thumbnailColumnWidth }
        return columnWidth
    }

    let hostView = ColumnsHostView(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
    private let model: BrowserModel
    private(set) var columns: [BrowserColumn] = []
    private(set) var preview: NSHostingView<FilePreview>?
    private var focusedIndex = 0
    private var navigationID = -1
    private var showHidden = false
    private var sort = FileSort()
    private var filterText = ""
    private var cutPaths: Set<String> = []
    private var settings = ThemeSettings.shared

    init(model: BrowserModel) {
        self.model = model
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
        columns.forEach(applySettings)
        hostView.applyBackground(settings.palette?.background)

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
        columns.removeAll()
        preview = nil
        focusedIndex = 0
        let root = addColumn(folder: model.baseURL, source: model.itemSource(for: model.baseURL))
        root.list.acceptsNewItems = model.location.acceptsNewItems
        DispatchQueue.main.async { root.list.focus() }
    }

    @discardableResult
    private func addColumn(folder: URL, source: ItemSource) -> BrowserColumn {
        let list = FileListController(style: .column, model: model, folder: folder)
        let column = BrowserColumn(list: list, source: source)
        applySettings(column)
        list.onSelectionChange = { [weak self] list in self?.selectionChanged(in: list) }
        list.onFocus = { [weak self] list in self?.focusChanged(to: list) }
        list.onOpen = { [weak self] list, items in self?.open(items, from: list) }
        list.onMoveLeft = { [weak self] list in self?.moveLeft(from: list) ?? false }
        list.onMoveRight = { [weak self] list in self?.moveRight(from: list) ?? false }
        columns.append(column)
        layoutPanes()

        if source != .recents {
            column.watcher = DirectoryWatcher(url: folder) { [weak self, weak column] in
                Task { @MainActor in
                    guard let self, let column else { return }
                    self.load(column)
                }
            }
        }
        load(column)
        return column
    }

    private func applySettings(_ column: BrowserColumn) {
        column.container.separatorColor = settings.palette?.separator
        if case .screenshots = column.source {
            column.list.apply(settings, rowSize: .thumbnails)
        } else {
            column.list.apply(settings)
        }
    }

    private func layoutPanes() {
        var panes: [(view: NSView, width: CGFloat?)] = columns.map { ($0.container, Self.width(for: $0.source)) }
        if let preview {
            panes.append((preview, nil))
        }
        hostView.setPanes(panes)
        DispatchQueue.main.async { [weak self] in self?.hostView.scrollToEnd() }
    }

    private func load(_ column: BrowserColumn) {
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

    private func redisplay(_ column: BrowserColumn, selectedPaths: Set<String>? = nil) {
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
            preview = nil
            addColumn(folder: folder, source: .folder(folder))
        } else {
            truncate(after: index)
            if selected.count == 1 {
                showPreview(selected[0])
            } else if preview != nil {
                preview = nil
                layoutPanes()
            }
        }
    }

    private func truncate(after index: Int) {
        guard columns.count > index + 1 else { return }
        columns.removeSubrange((index + 1)...)
        if focusedIndex > index {
            focusedIndex = index
        }
        layoutPanes()
    }

    private func showPreview(_ item: FileItem) {
        if let preview {
            guard preview.rootView.item != item else { return }
            preview.rootView = FilePreview(item: item)
        } else {
            preview = NSHostingView(rootView: FilePreview(item: item))
        }
        layoutPanes()
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
