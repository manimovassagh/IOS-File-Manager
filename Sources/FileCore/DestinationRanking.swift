import Foundation

/// Folders files were recently moved or copied to, ranked by how often and how recently
/// they were used ("frecency"), for the Move To… / Copy To… picker.
public struct DestinationHistory: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var path: String
        public var count: Int
        public var lastUsed: Date
    }

    public private(set) var entries: [Entry] = []

    /// How many folders are remembered.
    public static let limit = 50

    public init() {}

    public mutating func record(_ folder: URL, at date: Date = Date()) {
        let path = folder.standardizedFileURL.path
        if let index = entries.firstIndex(where: { $0.path == path }) {
            entries[index].count += 1
            entries[index].lastUsed = date
        } else {
            entries.append(Entry(path: path, count: 1, lastUsed: date))
        }
        if entries.count > Self.limit {
            let now = date
            entries.sort { Self.score($0, now: now) > Self.score($1, now: now) }
            entries.removeLast(entries.count - Self.limit)
        }
    }

    public mutating func remove(_ path: String) {
        entries.removeAll { $0.path == path }
    }

    /// Paths, best first.
    public func ranked(now: Date = Date()) -> [String] {
        entries
            .sorted { lhs, rhs in
                let (a, b) = (Self.score(lhs, now: now), Self.score(rhs, now: now))
                return a != b ? a > b : lhs.lastUsed > rhs.lastUsed
            }
            .map(\.path)
    }

    /// Uses count, weighed down as the last use gets older (halved after about a week).
    static func score(_ entry: Entry, now: Date) -> Double {
        let days = max(0, now.timeIntervalSince(entry.lastUsed) / 86_400)
        return Double(entry.count) / (1 + days / 7)
    }
}

/// Fuzzy matching of a typed fragment against folder names, like editor "quick open" pickers.
public enum FuzzyMatch {
    /// `nil` if the characters of `query` don't appear in order in `name` (ignoring case);
    /// otherwise a score, higher for better matches: a prefix or a whole word beats letters
    /// scattered through the name.
    public static func score(_ query: String, in name: String) -> Int? {
        let query = Array(query.lowercased().filter { !$0.isWhitespace })
        guard !query.isEmpty else { return 0 }
        let lowerName = name.lowercased()
        let characters = Array(lowerName)

        var score = 0
        var queryIndex = 0
        var previousMatch: Int?
        for (index, character) in characters.enumerated() where queryIndex < query.count {
            guard character == query[queryIndex] else { continue }
            score += 1
            if let previousMatch, previousMatch == index - 1 { score += 5 }  // consecutive letters
            if index == 0 {
                score += 10
            } else if !characters[index - 1].isLetter && !characters[index - 1].isNumber {
                score += 6  // start of a word
            }
            previousMatch = index
            queryIndex += 1
        }
        guard queryIndex == query.count else { return nil }
        if lowerName == String(query) { score += 50 }
        // Prefer shorter names when the match is otherwise equal.
        return score * 4 - characters.count / 8
    }
}
