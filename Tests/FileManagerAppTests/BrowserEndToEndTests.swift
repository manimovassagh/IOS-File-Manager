import AppKit
import FileCore
import SwiftUI
import XCTest
@testable import FileManagerApp

/// End-to-end tests: put the app's real views in a window, point them at a folder of test files,
/// let them load, and check what is on screen. Each test also saves a screenshot of the window
/// to `$SNAPSHOT_DIR` (CI uploads these so the UI can be looked at).
final class BrowserEndToEndTests: XCTestCase {
    private var root: URL!
    private var window: NSWindow?

    override func setUpWithError() throws {
        _ = NSApplication.shared
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BrowserEndToEndTests-\(UUID().uuidString)", isDirectory: true)
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: root.appendingPathComponent("Documents"), withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: root.appendingPathComponent("Documents/inner.txt"))
        try Data("notes".utf8).write(to: root.appendingPathComponent("notes.txt"))
        try Self.writePNG(to: root.appendingPathComponent("photo.png"), color: .systemOrange, label: "Photo")
        try Self.writePNG(
            to: root.appendingPathComponent("Screenshot 2026-10-21 at 10.00.00.png"), color: .systemTeal, label: "Shot"
        )
        Screenshots.folderOverride = root
    }

    override func tearDownWithError() throws {
        window?.close()
        window = nil
        Screenshots.folderOverride = nil
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Column view

    @MainActor
    func testColumnViewShowsFolderAndOpensColumnsAndPreview() throws {
        let model = BrowserModel(clipboard: ClipboardController(), start: .folder(root))
        model.viewMode = .columns
        let controller = ColumnBrowserController(model: model)
        show(controller.hostView)
        let pump = { controller.update(settings: .shared, cutPaths: []) }

        XCTAssertTrue(wait(pump) { controller.columns.first?.list.items.count == 4 }, "Root column didn't load")
        let rootColumn = try XCTUnwrap(controller.columns.first)
        XCTAssertEqual(rootColumn.container.frame.width, ColumnBrowserController.columnWidth)
        XCTAssertEqual(rootColumn.list.scrollView.frame.width, ColumnBrowserController.columnWidth - 1)
        XCTAssertGreaterThan(rootColumn.container.frame.height, 100, "Column has no height, so nothing would be visible")
        XCTAssertEqual(rootColumn.list.tableView.numberOfRows, 4)
        XCTAssertGreaterThan(rootColumn.list.tableView.visibleRect.height, 100)
        XCTAssertGreaterThan(rootColumn.list.tableView.rect(ofRow: 0).width, 100, "Rows are too narrow to show names")
        assertFirstRowVisible(rootColumn.list.tableView)
        snapshot("columns-1-root")

        // Selecting a folder opens it in the next column.
        let folderRow = try XCTUnwrap(rootColumn.list.items.firstIndex { $0.name == "Documents" })
        rootColumn.list.tableView.selectRowIndexes([folderRow], byExtendingSelection: false)
        XCTAssertTrue(wait(pump) { controller.columns.count == 2 && controller.columns[1].list.items.count == 1 })
        let second = try XCTUnwrap(controller.columns.dropFirst().first, "Selecting a folder didn't open a column")
        assertFirstRowVisible(second.list.tableView)
        XCTAssertEqual(second.list.items.first?.name, "inner.txt")
        XCTAssertEqual(second.container.frame.minX, ColumnBrowserController.columnWidth)
        XCTAssertEqual(model.selection.map(\.lastPathComponent), ["Documents"])

        // Selecting a file shows the preview pane after the columns.
        second.list.tableView.selectRowIndexes([0], byExtendingSelection: false)
        XCTAssertTrue(wait(pump) { controller.preview != nil })
        let preview = try XCTUnwrap(controller.preview)
        XCTAssertEqual(preview.frame.minX, ColumnBrowserController.columnWidth * 2)
        assertPreviewFillsRemainingSpace(preview, in: controller.hostView)
        XCTAssertEqual(model.currentURL.lastPathComponent, "Documents", "Paste should go into the focused column")
        snapshot("columns-2-preview")

        // Going back to the first column and picking a file removes the second column.
        let fileRow = try XCTUnwrap(rootColumn.list.items.firstIndex { $0.name == "notes.txt" })
        rootColumn.list.tableView.selectRowIndexes([fileRow], byExtendingSelection: false)
        XCTAssertTrue(wait(pump) { controller.columns.count == 1 && controller.preview?.rootView.item.name == "notes.txt" })
    }

    // MARK: - List view

    @MainActor
    func testListViewShowsFolderContents() throws {
        let model = BrowserModel(clipboard: ClipboardController(), start: .folder(root))
        model.viewMode = .list
        let coordinator = FileTableView.Coordinator(model: model)
        show(coordinator.list.scrollView)
        let pump = { coordinator.update(settings: .shared, cutPaths: []) }

        XCTAssertTrue(wait(pump) { coordinator.list.items.count == 4 })
        XCTAssertEqual(coordinator.list.tableView.numberOfRows, 4)
        XCTAssertEqual(coordinator.list.items.first?.name, "Documents", "Folders should be listed first")
        XCTAssertEqual(coordinator.list.tableView.numberOfColumns, 4)
        assertFirstRowVisible(coordinator.list.tableView)
        snapshot("list-1-folder")

        // Selecting in the table updates the model (what copy/cut act on).
        coordinator.list.tableView.selectRowIndexes([1, 2], byExtendingSelection: false)
        XCTAssertEqual(model.selection.count, 2)
    }

    // MARK: - Screenshots

    @MainActor
    func testScreenshotsShowOnlyScreenshotsWithThumbnailsAndPreview() throws {
        let model = BrowserModel(clipboard: ClipboardController(), start: .screenshots)
        model.viewMode = .list
        XCTAssertTrue(model.showInspector, "The preview panel should open automatically in Screenshots")
        let coordinator = FileTableView.Coordinator(model: model)
        show(coordinator.list.scrollView)
        let pump = { coordinator.update(settings: .shared, cutPaths: []) }

        XCTAssertTrue(wait(pump) { coordinator.list.items.count == 1 })
        let item = try XCTUnwrap(coordinator.list.items.first)
        XCTAssertTrue(item.name.hasPrefix("Screenshot"))
        XCTAssertEqual(coordinator.list.tableView.rowHeight, RowSize.thumbnails.rowHeight)

        // A real thumbnail replaces the generic PNG icon.
        let size = RowSize.thumbnails.iconSize
        XCTAssertTrue(
            wait(pump, timeout: 20) {
                ThumbnailCache.shared.cachedRowThumbnail(for: item.url, size: size, modified: item.dateModified) != nil
            },
            "No thumbnail was generated"
        )
        snapshot("screenshots-1-thumbnails")
    }

    @MainActor
    func testScreenshotsInColumnViewShowFullNamesAndLargePreview() throws {
        let model = BrowserModel(clipboard: ClipboardController(), start: .screenshots)
        model.viewMode = .columns
        let controller = ColumnBrowserController(model: model)
        show(controller.hostView)
        let pump = { controller.update(settings: .shared, cutPaths: []) }

        XCTAssertTrue(wait(pump) { controller.columns.first?.list.items.count == 1 })
        let column = try XCTUnwrap(controller.columns.first)
        XCTAssertEqual(column.container.frame.width, ColumnBrowserController.thumbnailColumnWidth)
        XCTAssertEqual(column.list.tableView.rowHeight, RowSize.thumbnails.rowHeight)
        assertFirstRowVisible(column.list.tableView)

        // The whole name (with date and time) fits; it isn't cut to "Screensho….png".
        let cell = try XCTUnwrap(column.list.tableView.view(atColumn: 0, row: 0, makeIfNecessary: true) as? NSTableCellView)
        let label = try XCTUnwrap(cell.textField)
        cell.layoutSubtreeIfNeeded()
        XCTAssertLessThanOrEqual(
            label.attributedStringValue.size().width, label.frame.width + 1,
            "“\(label.stringValue)” doesn't fit in \(label.frame.width) pt"
        )

        // Selecting the screenshot shows a large preview filling the rest of the window.
        column.list.tableView.selectRowIndexes([0], byExtendingSelection: false)
        XCTAssertTrue(wait(pump) { controller.preview != nil })
        let preview = try XCTUnwrap(controller.preview)
        assertPreviewFillsRemainingSpace(preview, in: controller.hostView)
        XCTAssertGreaterThanOrEqual(FilePreview.imageHeight(for: preview.frame.size), preview.frame.height - 300)
        wait(timeout: 3) { false }  // let the full-size image load
        snapshot("screenshots-2-columns-preview")
    }

    // MARK: - Whole window

    /// The full SwiftUI window (sidebar, columns, bars) in both views, mainly for the screenshots.
    @MainActor
    func testFullWindowInBothViews() throws {
        for mode in [ViewMode.list, .columns] {
            UserDefaults.standard.set(mode.rawValue, forKey: "viewMode")
            let view = BrowserView(clipboard: ClipboardController(), settings: .shared)
            show(NSHostingView(rootView: view))
            wait(timeout: 2) { false }  // let it load and lay out

            if mode == .columns {
                let host = try XCTUnwrap(findView(ColumnsHostView.self, in: window?.contentView))
                XCTAssertGreaterThan(host.frame.width, 300)
                XCTAssertGreaterThan(host.frame.height, 100)
                XCTAssertFalse(host.panes.isEmpty, "Column view shows no columns")
                XCTAssertGreaterThan(host.panes.first?.view.frame.height ?? 0, 100)
                let rootColumn = try XCTUnwrap(host.panes.first?.view as? ColumnContainerView)
                XCTAssertEqual(rootColumn.frame.width, ColumnBrowserController.columnWidth)
                let table = try XCTUnwrap((rootColumn.content as? NSScrollView)?.documentView as? NSTableView)
                XCTAssertTrue(wait { table.numberOfRows > 0 })
                assertFirstRowVisible(table)
            }
            snapshot("window-\(mode.rawValue)")
            window?.close()
        }
        UserDefaults.standard.removeObject(forKey: "viewMode")
    }

    // MARK: - Thumbnails of light, dark and transparent images

    /// Reported: previews of white PNGs sometimes didn't show (dark ones did). Every kind of image
    /// must produce a thumbnail with its real content, for list rows and for the large preview.
    @MainActor
    func testThumbnailsForWhiteDarkAndTransparentImages() throws {
        let folder = root.appendingPathComponent("Images", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let images: [(name: String, color: NSColor, expectedBrightness: ClosedRange<CGFloat>)] = [
            ("white.png", .white, 0.9...1.0),
            ("almost-white-document.png", NSColor(white: 0.97, alpha: 1), 0.85...1.0),
            ("transparent.png", .clear, 0...1),
            ("dark.png", NSColor(white: 0.08, alpha: 1), 0...0.2),
        ]
        for image in images {
            try Self.writePNG(to: folder.appendingPathComponent(image.name), color: image.color, label: "", size: NSSize(width: 3360, height: 2100))
        }
        let model = BrowserModel(clipboard: ClipboardController(), start: .folder(folder))
        let coordinator = FileTableView.Coordinator(model: model)
        show(coordinator.list.scrollView)
        let pump = { coordinator.update(settings: .shared, cutPaths: []) }
        XCTAssertTrue(wait(pump) { coordinator.list.items.count == images.count })

        let rowSize = RowSize.regular.iconSize
        for item in coordinator.list.items {
            let expected = try XCTUnwrap(images.first { $0.name == item.name })
            // List row thumbnail (framed).
            XCTAssertTrue(wait(pump, timeout: 15) {
                ThumbnailCache.shared.cachedRowThumbnail(for: item.url, size: rowSize, modified: item.dateModified) != nil
            }, "No row thumbnail for \(item.name)")

            // Large preview image, loaded the way the preview pane does.
            let loader = PreviewLoader()
            let done = expectation(description: item.name)
            Task { @MainActor in
                await loader.load(item.url)
                done.fulfill()
            }
            wait(for: [done], timeout: 20)
            let preview = try XCTUnwrap(loader.thumbnail, "No preview image for \(item.name)")
            XCTAssertGreaterThan(preview.size.width, 1000, "\(item.name): preview too small")
            if item.name != "transparent.png" {
                let brightness = try XCTUnwrap(Self.averageBrightness(of: preview))
                XCTAssertTrue(expected.expectedBrightness.contains(brightness), "\(item.name): brightness \(brightness)")
            }
        }

        // Rapidly switching files: the preview must end up showing the last one.
        let loader = PreviewLoader()
        let urls = coordinator.list.items.map(\.url)
        let finished = expectation(description: "switching")
        finished.expectedFulfillmentCount = urls.count
        for url in urls {
            Task { @MainActor in
                await loader.load(url)
                finished.fulfill()
            }
        }
        wait(for: [finished], timeout: 30)
        XCTAssertEqual(loader.currentURL, urls.last)
        XCTAssertNotNil(loader.thumbnail)

        coordinator.list.tableView.selectRowIndexes([0], byExtendingSelection: false)
        snapshot("thumbnails-light-dark-transparent")
    }

    // MARK: - Themes

    /// Each color theme paints the whole window (list, header, sidebar, bars); screenshots for review.
    @MainActor
    func testColorThemesPaintTheWindow() throws {
        defer {
            ThemeSettings.shared.colorTheme = .native
            UserDefaults.standard.removeObject(forKey: "viewMode")
            UserDefaults.standard.removeObject(forKey: "lastLocation")
        }
        UserDefaults.standard.set(root.path, forKey: "lastLocation")
        let themes: [(ColorTheme, ViewMode)] = [
            (.dracula, .list), (.nord, .columns), (.tokyoNight, .list), (.catppuccinMocha, .columns),
            (.catppuccinLatte, .list), (.gruvbox, .list), (.githubLight, .columns),
        ]
        for (theme, mode) in themes {
            let palette = try XCTUnwrap(theme.palette)
            ThemeSettings.shared.colorTheme = theme
            UserDefaults.standard.set(mode.rawValue, forKey: "viewMode")
            show(NSHostingView(rootView: BrowserView(clipboard: ClipboardController(), settings: .shared)))

            XCTAssertTrue(wait { (findView(FileTable.self, in: window?.contentView)?.numberOfRows ?? 0) == 4 }, "\(theme) didn't load")
            let table = try XCTUnwrap(findView(FileTable.self, in: window?.contentView))
            XCTAssertEqual(table.backgroundColor, palette.background, "\(theme): list background")
            if mode == .list {
                let header = try XCTUnwrap(table.tableColumns.first?.headerCell as? ThemedHeaderCell)
                XCTAssertEqual(header.palette, palette)
                // Select a row so the screenshot shows the theme's selection colors.
                table.selectRowIndexes([1], byExtendingSelection: false)
            } else {
                table.selectRowIndexes([0], byExtendingSelection: false)
            }
            wait(timeout: 1.5) { false }
            let nameCell = try XCTUnwrap(table.view(atColumn: 0, row: 2, makeIfNecessary: true) as? NSTableCellView)
            XCTAssertEqual(nameCell.textField?.textColor, palette.text, "\(theme): name color")
            XCTAssertEqual(NSApp.appearance?.name, palette.isDark ? .darkAqua : .aqua)
            XCTAssertEqual(window?.backgroundColor, palette.bar, "\(theme): window/toolbar color")
            snapshot("theme-\(theme.rawValue)-\(mode.rawValue)")
        }
    }

    // MARK: - Fixes from the UX review

    @MainActor
    func testScreenshotsDoNotAcceptNewItems() {
        // New Folder / paste / drop in Screenshots used to land on the Desktop, invisible here.
        let model = BrowserModel(clipboard: ClipboardController(), start: .screenshots)
        XCTAssertFalse(model.acceptsNewItems)
        XCTAssertFalse(model.canPaste)
    }

    @MainActor
    func testSecondOperationIsQueuedInsteadOfIgnored() throws {
        let model = BrowserModel(clipboard: ClipboardController(), start: .folder(root))
        XCTAssertTrue(wait { model.items.count == 4 })
        let notes = try XCTUnwrap(model.items.first { $0.name == "notes.txt" })
        let photo = try XCTUnwrap(model.items.first { $0.name == "photo.png" })

        model.selection = [notes.url]
        model.trashSelection(undoManager: nil)
        model.selection = [photo.url]
        model.trashSelection(undoManager: nil)  // starts while the first one is still running

        XCTAssertTrue(wait {
            !FileManager.default.fileExists(atPath: notes.url.path) && !FileManager.default.fileExists(atPath: photo.url.path)
        }, "The second trash was ignored")
        XCTAssertEqual(model.queuedCount, 0)
    }

    @MainActor
    func testReplacingACutShowsANotice() throws {
        let clipboard = ClipboardController()
        clipboard.set([root.appendingPathComponent("notes.txt")], mode: .cut)
        XCTAssertNil(clipboard.notice)

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("some text", forType: .string)
        clipboard.refreshFromPasteboard()

        XCTAssertNil(clipboard.contents)
        XCTAssertNotNil(clipboard.notice, "The user should be told the cut was cancelled")
    }

    @MainActor
    func testLastLocationIsRemembered() {
        defer { UserDefaults.standard.removeObject(forKey: "lastLocation") }
        _ = BrowserModel(clipboard: ClipboardController(), start: .folder(root))
        XCTAssertEqual(Location.lastUsed, .folder(URL(fileURLWithPath: root.path, isDirectory: true)))
        _ = BrowserModel(clipboard: ClipboardController(), start: .screenshots)
        XCTAssertEqual(Location.lastUsed, .screenshots)
    }

    // MARK: - Bug fixes (#34–#48)

    /// #34: visiting Recents/Screenshots used to switch every folder to "newest first".
    @MainActor
    func testVisitingScreenshotsDoesNotChangeFolderSort() {
        let model = BrowserModel(clipboard: ClipboardController(), start: .folder(root))
        XCTAssertEqual(model.sort, FileSort())
        model.navigate(to: .screenshots)
        XCTAssertEqual(model.sort.key, .dateModified)
        model.navigate(to: root.appendingPathComponent("Documents"))
        XCTAssertEqual(model.sort, FileSort(), "Folders must still sort by name")
    }

    /// #36: Duplicate in Recents must copy each file within its own folder.
    @MainActor
    func testDuplicateGroupsFilesByTheirFolder() {
        let a = URL(fileURLWithPath: "/tmp/one/a.txt")
        let b = URL(fileURLWithPath: "/tmp/two/b.txt")
        let c = URL(fileURLWithPath: "/tmp/one/c.txt")
        let groups = BrowserModel.groupedByFolder([a, b, c])
        XCTAssertEqual(groups.map(\.folder.lastPathComponent), ["one", "two"])
        XCTAssertEqual(groups.map { $0.urls.map(\.lastPathComponent) }, [["a.txt", "c.txt"], ["b.txt"]])
    }

    /// #44: after a partly failed cut-paste, only the items that didn't move stay on the clipboard.
    @MainActor
    func testPartialCutKeepsOnlyUnmovedItems() {
        let clipboard = ClipboardController()
        let moved = root.appendingPathComponent("notes.txt")
        let failed = root.appendingPathComponent("photo.png")
        clipboard.set([moved, failed], mode: .cut)
        clipboard.didMove([moved])
        XCTAssertEqual(clipboard.contents?.urls.map(\.lastPathComponent), ["photo.png"])
        XCTAssertEqual(clipboard.contents?.mode, .cut)
        clipboard.didMove([failed])
        XCTAssertNil(clipboard.contents)
    }

    /// #45: writing to the pasteboard elsewhere in the app (Copy Image in the preview) updates the bar.
    @MainActor
    func testClipboardBarUpdatesAfterAppPasteboardWrite() {
        let clipboard = ClipboardController()
        clipboard.set([root.appendingPathComponent("notes.txt")], mode: .copy)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([NSImage(size: NSSize(width: 4, height: 4))])
        NotificationCenter.default.post(name: .pasteboardChangedByApp, object: nil)
        XCTAssertNil(clipboard.contents, "The bar should no longer offer the old files")
    }

    /// #37: when the focused column disappears (its folder was removed elsewhere), paste must target
    /// the remaining column's folder, not the removed one.
    @MainActor
    func testRemovedColumnMovesFocusBack() throws {
        let model = BrowserModel(clipboard: ClipboardController(), start: .folder(root))
        model.viewMode = .columns
        let controller = ColumnBrowserController(model: model)
        show(controller.hostView)
        let pump = { controller.update(settings: .shared, cutPaths: []) }
        XCTAssertTrue(wait(pump) { controller.columns.first?.list.items.count == 4 })
        let rootColumn = controller.columns[0]
        let folderRow = try XCTUnwrap(rootColumn.list.items.firstIndex { $0.name == "Documents" })
        rootColumn.list.tableView.selectRowIndexes([folderRow], byExtendingSelection: false)
        XCTAssertTrue(wait(pump) { controller.columns.count == 2 && controller.columns[1].list.items.count == 1 })
        controller.columns[1].list.tableView.selectRowIndexes([0], byExtendingSelection: false)
        XCTAssertTrue(wait(pump) { model.currentURL.lastPathComponent == "Documents" })

        try FileManager.default.removeItem(at: root.appendingPathComponent("Documents"))

        XCTAssertTrue(wait(pump) { controller.columns.count == 1 }, "The removed folder's column should close")
        XCTAssertTrue(wait(pump) { model.currentURL.standardizedFileURL.path == self.root.standardizedFileURL.path },
                      "Paste would still go to the removed folder: \(model.currentURL.path)")
    }

    /// #38: filtering must not lose the folder selected in an earlier column.
    @MainActor
    func testFilterKeepsColumnSelection() throws {
        let model = BrowserModel(clipboard: ClipboardController(), start: .folder(root))
        model.viewMode = .columns
        let controller = ColumnBrowserController(model: model)
        show(controller.hostView)
        let pump = { controller.update(settings: .shared, cutPaths: []) }
        XCTAssertTrue(wait(pump) { controller.columns.first?.list.items.count == 4 })
        let rootColumn = controller.columns[0]
        let folderRow = try XCTUnwrap(rootColumn.list.items.firstIndex { $0.name == "Documents" })
        rootColumn.list.tableView.selectRowIndexes([folderRow], byExtendingSelection: false)
        XCTAssertTrue(wait(pump) { controller.columns.count == 2 })

        model.filterText = "zzz"
        wait(pump, timeout: 0.5) { false }
        model.filterText = ""
        wait(pump, timeout: 0.5) { false }

        XCTAssertEqual(rootColumn.list.selectedItems.map(\.name), ["Documents"], "Selection was lost by filtering")
        XCTAssertEqual(controller.columns.count, 2)
        XCTAssertTrue(wait(pump) { model.selection.map(\.lastPathComponent) == ["Documents"] })
    }

    // MARK: - Move To… / Copy To… (#14)

    @MainActor
    func testMoveToPickerFindsFoldersAndMovesWithUndoAndNotice() throws {
        defer { UserDefaults.standard.removeObject(forKey: "destinationHistory") }
        UserDefaults.standard.removeObject(forKey: "destinationHistory")
        let archive = root.appendingPathComponent("Archive", isDirectory: true)
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)

        let model = BrowserModel(clipboard: ClipboardController(), start: .folder(root))
        XCTAssertTrue(wait { model.items.count == 5 })
        let notes = try XCTUnwrap(model.items.first { $0.name == "notes.txt" })
        model.selection = [notes.url]
        model.requestDestination(mode: .cut)
        let request = try XCTUnwrap(model.destinationRequest)
        XCTAssertEqual(request.title, "Move “notes.txt” to…")

        // Typing a fragment finds folders inside the current folder; the folder the file is
        // already in isn't offered for a move.
        let picker = DestinationPickerModel(request: request, history: DestinationHistory(), favorites: [])
        picker.query = "arc"
        XCTAssertEqual(picker.results.first?.name, "Archive")
        picker.query = "doc"
        XCTAssertEqual(picker.results.first?.name, "Documents")
        picker.query = ""
        XCTAssertFalse(picker.results.contains { $0.url.standardizedFileURL.path == self.root.standardizedFileURL.path })
        // Typing a path lists the folders in it.
        picker.query = root.path + "/"
        XCTAssertEqual(Set(picker.results.map(\.name)), ["Archive", "Documents"])
        picker.query = root.path + "/Arch"
        XCTAssertEqual(picker.results.map(\.name), ["Archive"])

        // The picker window, for the screenshot.
        let view = DestinationPicker(request: request, history: DestinationHistory(), favorites: [root, archive],
                                     accent: .accentColor, onChoose: { _ in }, onCancel: {})
        show(NSHostingView(rootView: view))
        wait(timeout: 1) { false }
        snapshot("move-to-1-picker")

        let undoManager = UndoManager()
        model.send(request, to: archive, undoManager: undoManager)
        XCTAssertNil(model.destinationRequest)
        let moved = archive.appendingPathComponent("notes.txt")
        XCTAssertTrue(wait { FileManager.default.fileExists(atPath: moved.path) && model.clipboard.notice != nil })
        XCTAssertFalse(FileManager.default.fileExists(atPath: notes.url.path))
        XCTAssertEqual(model.clipboard.notice, "Moved 1 item to Archive")
        XCTAssertEqual(DestinationHistoryStore.shared.history.ranked().first, archive.standardizedFileURL.path)

        // Recently used destinations come first next time.
        let next = DestinationPickerModel(
            request: DestinationRequest(urls: [root.appendingPathComponent("photo.png")], mode: .copy, currentFolder: root),
            history: DestinationHistoryStore.shared.history, favorites: []
        )
        XCTAssertEqual(next.results.first?.name, "Archive")
        XCTAssertEqual(next.results.first?.isRecent, true)

        XCTAssertTrue(wait { undoManager.canUndo })
        undoManager.undo()
        XCTAssertTrue(wait { FileManager.default.fileExists(atPath: notes.url.path) }, "Undo should move the file back")
    }

    // MARK: - Sidebar favorites (#22)

    /// A FavoritesStore saved in its own defaults domain, removed after the test.
    @MainActor
    private func makeFavorites() -> (FavoritesStore, UserDefaults) {
        let suite = "FavoritesTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        return (FavoritesStore(defaults: defaults), defaults)
    }

    @MainActor
    func testFavoritesCanBeAddedReorderedRemovedAndAreSaved() throws {
        let (favorites, defaults) = makeFavorites()
        XCTAssertEqual(favorites.ids, FavoritesStore.defaultIDs)
        let projects = root.appendingPathComponent("Projects", isDirectory: true)
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)

        favorites.add([projects, root.appendingPathComponent("notes.txt")], at: 1)
        XCTAssertEqual(favorites.ids[1], projects.standardizedFileURL.path, "Folders are added where they're dropped")
        XCTAssertFalse(favorites.ids.contains { $0.hasSuffix("notes.txt") }, "Files can't be favorites")
        favorites.add([projects])
        XCTAssertEqual(favorites.ids.filter { $0 == projects.standardizedFileURL.path }.count, 1, "No duplicates")

        // Drag Projects to the top.
        favorites.move(fromOffsets: [1], toOffset: 0)
        XCTAssertEqual(favorites.items.first?.name, "Projects")
        XCTAssertEqual(favorites.items.first?.systemImage, "folder")
        XCTAssertEqual(FavoritesStore(defaults: defaults).ids, favorites.ids, "The order is saved")

        favorites.remove(id: "recents")
        XCTAssertFalse(FavoritesStore(defaults: defaults).ids.contains("recents"))

        // A favorite whose folder is gone is hidden, and comes back with the folder.
        try FileManager.default.removeItem(at: projects)
        XCTAssertFalse(favorites.items.contains { $0.name == "Projects" })
        XCTAssertTrue(favorites.ids.contains(projects.standardizedFileURL.path))
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        XCTAssertTrue(favorites.items.contains { $0.name == "Projects" })

        favorites.resetToDefaults()
        XCTAssertEqual(FavoritesStore(defaults: defaults).ids, FavoritesStore.defaultIDs)
    }

    @MainActor
    func testAddToSidebarUsesSelectedFoldersOrTheCurrentFolder() throws {
        let model = BrowserModel(clipboard: ClipboardController(), start: .folder(root))
        XCTAssertTrue(wait { model.items.count == 4 })
        XCTAssertEqual(model.foldersForSidebar.map(\.path), [root.path])
        let documents = try XCTUnwrap(model.items.first { $0.name == "Documents" })
        let notes = try XCTUnwrap(model.items.first { $0.name == "notes.txt" })
        model.selection = [documents.url, notes.url]
        XCTAssertEqual(model.foldersForSidebar.map(\.lastPathComponent), ["Documents"])
        model.navigate(to: .recents)
        model.selection = []
        XCTAssertTrue(model.foldersForSidebar.isEmpty)
    }

    /// The window's sidebar lists a newly added favorite, and files dropped on it move there.
    @MainActor
    func testSidebarShowsNewFavoriteAndAcceptsDroppedFiles() throws {
        let (favorites, _) = makeFavorites()
        let projects = root.appendingPathComponent("Projects", isDirectory: true)
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        UserDefaults.standard.set(root.path, forKey: "lastLocation")
        UserDefaults.standard.set(ViewMode.list.rawValue, forKey: "viewMode")
        defer {
            UserDefaults.standard.removeObject(forKey: "lastLocation")
            UserDefaults.standard.removeObject(forKey: "viewMode")
        }

        show(NSHostingView(rootView: BrowserView(clipboard: ClipboardController(), settings: .shared, favorites: favorites)))
        wait(timeout: 2) { false }
        let sidebar = try XCTUnwrap(sidebarTable(), "No sidebar list found")
        let rowsBefore = sidebar.numberOfRows
        XCTAssertGreaterThan(rowsBefore, favorites.items.count, "The sidebar should list every favorite")

        favorites.add([projects], at: 0)
        XCTAssertTrue(wait { sidebar.numberOfRows == rowsBefore + 1 }, "The new favorite didn't appear")
        snapshot("sidebar-1-new-favorite")

        // Dropping files onto the favorite moves them into its folder.
        let model = BrowserModel(clipboard: ClipboardController(), start: .folder(root))
        let sidebarView = SidebarView(
            location: model.location, palette: nil, accent: .accentColor, favorites: favorites,
            onSelect: { _ in },
            onDrop: { urls, folder, mode in model.drop(urls, into: folder, mode: mode, undoManager: nil) }
        )
        let item = try XCTUnwrap(favorites.items.first)
        let notes = root.appendingPathComponent("notes.txt")
        XCTAssertFalse(sidebarView.drop([projects], onto: item, mask: .move), "A folder can't go into itself")
        XCTAssertTrue(sidebarView.drop([notes], onto: item, mask: [.copy, .move, .generic]))
        XCTAssertTrue(wait {
            FileManager.default.fileExists(atPath: projects.appendingPathComponent("notes.txt").path)
                && !FileManager.default.fileExists(atPath: notes.path)
        }, "The dropped file wasn't moved into the favorite folder")
        let recents = try XCTUnwrap(SidebarItem.favorite(id: "recents"))
        XCTAssertFalse(sidebarView.drop([root.appendingPathComponent("photo.png")], onto: recents, mask: .copy),
                       "Recents isn't a folder; nothing can be dropped there")
    }

    /// The SwiftUI sidebar list (the one table that isn't a file list).
    @MainActor
    private func sidebarTable() -> NSTableView? {
        var tables: [NSTableView] = []
        func collect(_ view: NSView) {
            if let table = view as? NSTableView, !(table is FileTable) { tables.append(table) }
            view.subviews.forEach(collect)
        }
        if let content = window?.contentView { collect(content) }
        return tables.first
    }

    // MARK: - Helpers

    /// The preview is the last pane and fills the space after the columns.
    @MainActor
    private func assertPreviewFillsRemainingSpace(
        _ preview: NSView, in host: ColumnsHostView, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertGreaterThanOrEqual(preview.frame.width, ColumnBrowserController.minPreviewWidth, file: file, line: line)
        XCTAssertEqual(preview.frame.maxX, host.scrollView.contentSize.width, accuracy: 1,
                       "Preview should fill the rest of the window", file: file, line: line)
    }

    /// Checks the first row is really on screen: inside the table's visible area *and*, in window
    /// coordinates, inside the visible part of every enclosing view (a misplaced scroll view can
    /// keep the row "visible" in its own coordinates while the window shows something else).
    @MainActor
    private func assertFirstRowVisible(_ table: NSTableView, file: StaticString = #filePath, line: UInt = #line) {
        let firstRow = table.rect(ofRow: 0)
        XCTAssertTrue(
            table.visibleRect.contains(firstRow),
            "First row \(firstRow) is outside the table's visible area \(table.visibleRect)", file: file, line: line
        )
        let rowInWindow = table.convert(firstRow, to: nil)
        var ancestor = table.superview
        while let view = ancestor {
            let visibleInWindow = view.convert(view.visibleRect, to: nil)
            XCTAssertTrue(
                visibleInWindow.insetBy(dx: -1, dy: -1).contains(rowInWindow),
                "First row \(rowInWindow) is cut off by \(type(of: view)) showing \(visibleInWindow)",
                file: file, line: line
            )
            ancestor = view.superview
        }
    }

    @MainActor
    private func show(_ view: NSView) {
        window?.close()
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 1100, height: 600),
            styleMask: [.titled, .resizable, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        window.layoutIfNeeded()
        self.window = window
    }

    /// Runs the main run loop until `condition` is true, calling `pump` (what SwiftUI would do
    /// after each model change) on every turn.
    @MainActor
    @discardableResult
    private func wait(_ pump: () -> Void = {}, timeout: TimeInterval = 10, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            pump()
            window?.layoutIfNeeded()
            if condition() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        pump()
        return condition()
    }

    @MainActor
    private func findView<T: NSView>(_ type: T.Type, in view: NSView?) -> T? {
        guard let view else { return nil }
        if let match = view as? T { return match }
        for subview in view.subviews {
            if let match = findView(type, in: subview) { return match }
        }
        return nil
    }

    /// Saves what the window really looks like on screen (via `screencapture`), falling back to
    /// drawing the view hierarchy, which can misdraw scroll views and SwiftUI materials.
    @MainActor
    private func snapshot(_ name: String) {
        guard let window, let view = window.contentView else { return }
        let directory = ProcessInfo.processInfo.environment["SNAPSHOT_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("FileManagerSnapshots")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("\(name).png")
        try? FileManager.default.removeItem(at: file)

        NSApp.activate()
        window.orderFrontRegardless()
        view.layoutSubtreeIfNeeded()
        view.display()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))

        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = ["-x", "-o", "-l\(window.windowNumber)", file.path]
        try? capture.run()
        capture.waitUntilExit()
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
        if capture.terminationStatus == 0, size > 0 {
            return
        }

        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("\(name)-drawn.png"))
    }

    /// Average brightness (0…1) of an image's opaque content.
    private static func averageBrightness(of image: NSImage) -> CGFloat? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        var total: CGFloat = 0
        var count: CGFloat = 0
        let step = max(1, min(rep.pixelsWide, rep.pixelsHigh) / 20)
        for x in stride(from: 0, to: rep.pixelsWide, by: step) {
            for y in stride(from: 0, to: rep.pixelsHigh, by: step) {
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), color.alphaComponent > 0.5 else { continue }
                total += (color.redComponent + color.greenComponent + color.blueComponent) / 3
                count += 1
            }
        }
        return count > 0 ? total / count : nil
    }

    private static func writePNG(to url: URL, color: NSColor, label: String, size: NSSize = NSSize(width: 320, height: 200)) throws {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height), bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        color.setFill()
        NSRect(origin: .zero, size: size).fill()
        (label as NSString).draw(at: NSPoint(x: 20, y: 80), withAttributes: [
            .font: NSFont.boldSystemFont(ofSize: 48), .foregroundColor: NSColor.white,
        ])
        NSGraphicsContext.restoreGraphicsState()
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: url)
    }
}
