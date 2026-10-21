import Darwin
import XCTest
@testable import FileCore

final class ScreenshotsTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScreenshotsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeFile(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data("x".utf8).write(to: url)
        return url
    }

    func testDetectsScreenCaptureAttribute() throws {
        let url = try makeFile("Bildschirmfoto 2026-10-21.png")
        XCTAssertFalse(Screenshots.isScreenshot(url))

        let value: [UInt8] = [1]
        let result = setxattr(url.path, Screenshots.screenCaptureAttribute, value, value.count, 0, 0)
        XCTAssertEqual(result, 0)
        XCTAssertTrue(Screenshots.isScreenshot(url))
    }

    func testFallsBackToEnglishNames() throws {
        XCTAssertTrue(Screenshots.isScreenshot(try makeFile("Screenshot 2026-10-21 at 10.00.00.png")))
        XCTAssertTrue(Screenshots.isScreenshot(try makeFile("Screen Recording 2026-10-21.mov")))
        XCTAssertFalse(Screenshots.isScreenshot(try makeFile("holiday.png")))
    }

    func testContentsListsOnlyScreenshots() throws {
        _ = try makeFile("Screenshot 1.png")
        _ = try makeFile("notes.txt")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Screenshot folder"), withIntermediateDirectories: true
        )

        let names = try Screenshots.contents(of: root).map(\.name)
        XCTAssertEqual(names, ["Screenshot 1.png"])
    }

    func testFolderIsAnAbsolutePath() {
        // The default (Desktop) may not exist on CI, so only check that a sensible path is returned.
        XCTAssertTrue(Screenshots.folder.path.hasPrefix("/"))
    }
}
