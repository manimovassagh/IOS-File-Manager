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
        XCTAssertEqual(preview.frame.width, ColumnBrowserController.previewWidth)
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
            }
            snapshot("window-\(mode.rawValue)")
            window?.close()
        }
        UserDefaults.standard.removeObject(forKey: "viewMode")
    }

    // MARK: - Helpers

    @MainActor
    private func assertFirstRowVisible(_ table: NSTableView, file: StaticString = #filePath, line: UInt = #line) {
        let firstRow = table.rect(ofRow: 0)
        XCTAssertTrue(
            table.visibleRect.contains(firstRow),
            "First row \(firstRow) is outside the visible area \(table.visibleRect)", file: file, line: line
        )
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

    @MainActor
    private func snapshot(_ name: String) {
        guard let view = window?.contentView else { return }
        view.layoutSubtreeIfNeeded()
        view.display()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { return }

        let directory = ProcessInfo.processInfo.environment["SNAPSHOT_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("FileManagerSnapshots")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: directory.appendingPathComponent("\(name).png"))
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
