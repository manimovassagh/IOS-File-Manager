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
                ThumbnailCache.shared.cachedThumbnail(for: item.url, size: size, modified: item.dateModified) != nil
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

    private static func writePNG(to url: URL, color: NSColor, label: String) throws {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 320, pixelsHigh: 200, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        color.setFill()
        NSRect(x: 0, y: 0, width: 320, height: 200).fill()
        (label as NSString).draw(at: NSPoint(x: 20, y: 80), withAttributes: [
            .font: NSFont.boldSystemFont(ofSize: 48), .foregroundColor: NSColor.white,
        ])
        NSGraphicsContext.restoreGraphicsState()
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: url)
    }
}
