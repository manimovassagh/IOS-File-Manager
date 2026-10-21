import XCTest
@testable import FileCore

final class DirectoryListerTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DirectoryListerTests-\(UUID().uuidString)", isDirectory: true)
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: root.appendingPathComponent("Zeta"), withIntermediateDirectories: true)
        for name in ["file10.txt", "file2.txt", ".hidden", "alpha.txt"] {
            try Data("x".utf8).write(to: root.appendingPathComponent(name))
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testHiddenFilesAreSkippedByDefault() throws {
        let names = try DirectoryLister.contents(of: root, includeHidden: false).map(\.name)
        XCTAssertFalse(names.contains(".hidden"))

        let all = try DirectoryLister.contents(of: root, includeHidden: true).map(\.name)
        XCTAssertTrue(all.contains(".hidden"))
    }

    func testSortPutsFoldersFirstAndUsesNaturalOrder() throws {
        let items = try DirectoryLister.contents(of: root, includeHidden: false)
        let sorted = FileSort().sorted(items).map(\.name)
        XCTAssertEqual(sorted, ["Zeta", "alpha.txt", "file2.txt", "file10.txt"])
    }

    func testDescendingSort() throws {
        let items = try DirectoryLister.contents(of: root, includeHidden: false)
        let sorted = FileSort(ascending: false, foldersFirst: false).sorted(items).map(\.name)
        XCTAssertEqual(sorted, ["Zeta", "file10.txt", "file2.txt", "alpha.txt"])
    }

    func testFolderItemProperties() throws {
        let folder = try XCTUnwrap(DirectoryLister.contents(of: root, includeHidden: false).first { $0.name == "Zeta" })
        XCTAssertTrue(folder.isDirectory)
        XCTAssertTrue(folder.isBrowsable)
        XCTAssertNil(folder.size)
    }
}
