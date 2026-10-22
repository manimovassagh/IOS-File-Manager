import XCTest
@testable import FileCore

final class DestinationRankingTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func daysAgo(_ days: Double) -> Date { now.addingTimeInterval(-days * 86_400) }
    private func folder(_ name: String) -> URL { URL(fileURLWithPath: "/Users/me/\(name)", isDirectory: true) }

    func testFrequentAndRecentFoldersComeFirst() {
        var history = DestinationHistory()
        for _ in 0..<5 { history.record(folder("Archive"), at: daysAgo(60)) }  // often, but long ago
        for _ in 0..<3 { history.record(folder("Projects"), at: daysAgo(1)) }  // often and recent
        history.record(folder("Inbox"), at: now)                               // once, just now
        XCTAssertEqual(history.ranked(now: now), ["/Users/me/Projects", "/Users/me/Inbox", "/Users/me/Archive"])
    }

    func testRecordingAgainUpdatesTheSameEntry() {
        var history = DestinationHistory()
        history.record(folder("Projects"), at: daysAgo(3))
        history.record(URL(fileURLWithPath: "/Users/me/Projects/./", isDirectory: true), at: now)
        XCTAssertEqual(history.entries.count, 1)
        XCTAssertEqual(history.entries[0].count, 2)
        XCTAssertEqual(history.entries[0].lastUsed, now)
    }

    func testHistoryKeepsTheBestFolders() {
        var history = DestinationHistory()
        for _ in 0..<3 { history.record(folder("Keep"), at: now) }
        for index in 0..<DestinationHistory.limit + 5 { history.record(folder("F\(index)"), at: daysAgo(30)) }
        XCTAssertEqual(history.entries.count, DestinationHistory.limit)
        XCTAssertEqual(history.ranked(now: now).first, "/Users/me/Keep")
    }

    func testHistoryRoundTripsThroughJSON() throws {
        var history = DestinationHistory()
        history.record(folder("Projects"), at: now)
        let decoded = try JSONDecoder().decode(DestinationHistory.self, from: JSONEncoder().encode(history))
        XCTAssertEqual(decoded, history)
    }

    func testFuzzyMatchNeedsLettersInOrder() {
        XCTAssertNotNil(FuzzyMatch.score("doc", in: "Documents"))
        XCTAssertNotNil(FuzzyMatch.score("dcmt", in: "Documents"))
        XCTAssertNil(FuzzyMatch.score("doc", in: "Downloads"))
        XCTAssertNil(FuzzyMatch.score("sdoc", in: "Documents"))
        XCTAssertEqual(FuzzyMatch.score("", in: "Anything"), 0)
    }

    func testFuzzyMatchPrefersPrefixesAndWordStarts() throws {
        let prefix = try XCTUnwrap(FuzzyMatch.score("pro", in: "Projects"))
        let wordStart = try XCTUnwrap(FuzzyMatch.score("pro", in: "Old Projects"))
        let scattered = try XCTUnwrap(FuzzyMatch.score("pro", in: "Shape Rotation"))
        XCTAssertGreaterThan(prefix, wordStart)
        XCTAssertGreaterThan(wordStart, scattered)
        let exact = try XCTUnwrap(FuzzyMatch.score("projects", in: "Projects"))
        let longer = try XCTUnwrap(FuzzyMatch.score("projects", in: "Projects Backup"))
        XCTAssertGreaterThan(exact, longer)
    }
}
