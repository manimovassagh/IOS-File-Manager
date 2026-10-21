import XCTest
@testable import FileCore

final class FileOperationsTests: XCTestCase {
    private var root: URL!
    private let operations = FileOperations()

    private static let noConflictExpected: FileOperations.ConflictHandler = { conflict in
        XCTFail("Unexpected conflict for \(conflict.source.lastPathComponent)")
        return .stop
    }

    private static func always(_ resolution: ConflictResolution) -> FileOperations.ConflictHandler {
        { _ in resolution }
    }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileCoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Helpers

    private func url(_ path: String) -> URL { root.appendingPathComponent(path) }

    @discardableResult
    private func makeFile(_ path: String, contents: String = "content") throws -> URL {
        let url = url(path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data(contents.utf8).write(to: url)
        return url
    }

    @discardableResult
    private func makeDirectory(_ path: String) throws -> URL {
        let url = url(path)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: url(path).path)
    }

    private func read(_ path: String) -> String? {
        (try? Data(contentsOf: url(path))).map { String(decoding: $0, as: UTF8.self) }
    }

    // MARK: - Copy

    func testCopyIntoAnotherFolderKeepsOriginal() async throws {
        let source = try makeFile("a/file.txt")
        let destination = try makeDirectory("b")

        let result = try await operations.paste([source], into: destination, mode: .copy, onConflict: Self.noConflictExpected)

        XCTAssertTrue(exists("a/file.txt"))
        XCTAssertEqual(read("b/file.txt"), "content")
        XCTAssertEqual(result.resultURLs.map(\.lastPathComponent), ["file.txt"])
        XCTAssertEqual(result.record.steps.count, 1)
        XCTAssertTrue(result.failures.isEmpty)
    }

    func testCopyFolderCopiesContents() async throws {
        try makeFile("a/folder/inner.txt")
        let destination = try makeDirectory("b")

        _ = try await operations.paste([url("a/folder")], into: destination, mode: .copy, onConflict: Self.noConflictExpected)

        XCTAssertEqual(read("b/folder/inner.txt"), "content")
        XCTAssertTrue(exists("a/folder/inner.txt"))
    }

    func testCopyIntoSameFolderCreatesCopyNames() async throws {
        let source = try makeFile("a/file.txt")
        let folder = url("a")

        _ = try await operations.paste([source], into: folder, mode: .copy, onConflict: Self.noConflictExpected)
        _ = try await operations.paste([source], into: folder, mode: .copy, onConflict: Self.noConflictExpected)

        XCTAssertTrue(exists("a/file.txt"))
        XCTAssertTrue(exists("a/file copy.txt"))
        XCTAssertTrue(exists("a/file copy 2.txt"))
    }

    // MARK: - Cut

    func testCutMovesFile() async throws {
        let source = try makeFile("a/file.txt")
        let destination = try makeDirectory("b")

        let result = try await operations.paste([source], into: destination, mode: .cut, onConflict: Self.noConflictExpected)

        XCTAssertFalse(exists("a/file.txt"))
        XCTAssertEqual(read("b/file.txt"), "content")
        XCTAssertEqual(result.record.steps.count, 1)
    }

    func testCutIntoSameFolderDoesNothing() async throws {
        let source = try makeFile("a/file.txt")

        let result = try await operations.paste([source], into: url("a"), mode: .cut, onConflict: Self.noConflictExpected)

        XCTAssertTrue(exists("a/file.txt"))
        XCTAssertTrue(result.record.isEmpty)
        XCTAssertEqual(result.resultURLs.count, 1)
    }

    func testPasteFolderIntoItselfThrowsAndChangesNothing() async throws {
        let other = try makeFile("other.txt")
        let folder = try makeDirectory("folder")
        let child = try makeDirectory("folder/child")

        do {
            _ = try await operations.paste([other, folder], into: child, mode: .cut, onConflict: Self.noConflictExpected)
            XCTFail("Expected an error")
        } catch {
            guard case .destinationInsideSource(let offending)? = error as? FileOperationError else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(offending.lastPathComponent, folder.lastPathComponent)
        }
        XCTAssertTrue(exists("other.txt"))
        XCTAssertTrue(exists("folder/child"))
    }

    // MARK: - Conflicts

    func testKeepBothUsesNumberedName() async throws {
        let source = try makeFile("a/file.txt", contents: "new")
        try makeFile("b/file.txt", contents: "old")

        _ = try await operations.paste([source], into: url("b"), mode: .copy, onConflict: Self.always(.keepBoth))

        XCTAssertEqual(read("b/file.txt"), "old")
        XCTAssertEqual(read("b/file 2.txt"), "new")
    }

    func testSkipLeavesBothUntouched() async throws {
        let source = try makeFile("a/file.txt", contents: "new")
        try makeFile("b/file.txt", contents: "old")

        let result = try await operations.paste([source], into: url("b"), mode: .cut, onConflict: Self.always(.skip))

        XCTAssertEqual(read("a/file.txt"), "new")
        XCTAssertEqual(read("b/file.txt"), "old")
        XCTAssertTrue(result.record.isEmpty)
    }

    func testStopCancelsRemainingItems() async throws {
        let first = try makeFile("a/1.txt")
        let second = try makeFile("a/2.txt")
        try makeFile("b/1.txt")

        let result = try await operations.paste([first, second], into: url("b"), mode: .copy, onConflict: Self.always(.stop))

        XCTAssertTrue(result.stopped)
        XCTAssertFalse(exists("b/2.txt"))
    }

    func testReplaceAndUndoRestoresOriginal() async throws {
        let source = try makeFile("a/file.txt", contents: "new")
        try makeFile("b/file.txt", contents: "old")

        let result = try await operations.paste([source], into: url("b"), mode: .cut, onConflict: Self.always(.replace))
        XCTAssertEqual(read("b/file.txt"), "new")
        XCTAssertFalse(exists("a/file.txt"))

        try await operations.undo(result.record)
        XCTAssertEqual(read("b/file.txt"), "old")
        XCTAssertEqual(read("a/file.txt"), "new")
    }

    // MARK: - Undo

    func testUndoCopyRemovesCopy() async throws {
        let source = try makeFile("a/file.txt")
        let result = try await operations.paste([source], into: try makeDirectory("b"), mode: .copy, onConflict: Self.noConflictExpected)

        try await operations.undo(result.record)

        XCTAssertFalse(exists("b/file.txt"))
        XCTAssertTrue(exists("a/file.txt"))
    }

    func testUndoCutMovesBack() async throws {
        let source = try makeFile("a/file.txt")
        let result = try await operations.paste([source], into: try makeDirectory("b"), mode: .cut, onConflict: Self.noConflictExpected)

        try await operations.undo(result.record)

        XCTAssertTrue(exists("a/file.txt"))
        XCTAssertFalse(exists("b/file.txt"))
    }

    func testTrashAndUndo() async throws {
        let file = try makeFile("file.txt")

        let result = await operations.moveToTrash([file])
        XCTAssertFalse(exists("file.txt"))
        XCTAssertTrue(result.failures.isEmpty)

        try await operations.undo(result.record)
        XCTAssertEqual(read("file.txt"), "content")
    }

    // MARK: - Naming

    func testNumberedNameContinuesExistingNumber() throws {
        try makeFile("file 2.txt")
        let unique = FileOperations.uniqueURL(for: "file 2.txt", in: root, style: .numbered)
        XCTAssertEqual(unique.lastPathComponent, "file 3.txt")
    }

    func testNamingWithoutExtension() throws {
        try makeDirectory("Folder")
        XCTAssertEqual(FileOperations.uniqueURL(for: "Folder", in: root, style: .numbered).lastPathComponent, "Folder 2")
        XCTAssertEqual(FileOperations.uniqueURL(for: "Folder", in: root, style: .copy).lastPathComponent, "Folder copy")
    }
}
