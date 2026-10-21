import Foundation

public struct FileSort: Equatable, Sendable {
    public enum Key: String, CaseIterable, Sendable {
        case name, dateModified, size, kind
    }

    public var key: Key
    public var ascending: Bool
    public var foldersFirst: Bool

    public init(key: Key = .name, ascending: Bool = true, foldersFirst: Bool = true) {
        self.key = key
        self.ascending = ascending
        self.foldersFirst = foldersFirst
    }

    public func sorted(_ items: [FileItem]) -> [FileItem] {
        items.sorted(by: areInIncreasingOrder)
    }

    public func areInIncreasingOrder(_ a: FileItem, _ b: FileItem) -> Bool {
        if foldersFirst, a.isBrowsable != b.isBrowsable {
            return a.isBrowsable
        }
        let result = compare(a, b)
        if result == .orderedSame {
            // Stable, predictable tie-break: always by name, ascending.
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        return ascending ? result == .orderedAscending : result == .orderedDescending
    }

    private func compare(_ a: FileItem, _ b: FileItem) -> ComparisonResult {
        switch key {
        case .name: return a.name.localizedStandardCompare(b.name)
        case .dateModified: return Self.compare(a.dateModified ?? .distantPast, b.dateModified ?? .distantPast)
        case .size: return Self.compare(a.size ?? -1, b.size ?? -1)
        case .kind: return a.kind.localizedStandardCompare(b.kind)
        }
    }

    private static func compare<T: Comparable>(_ a: T, _ b: T) -> ComparisonResult {
        if a < b { return .orderedAscending }
        if a > b { return .orderedDescending }
        return .orderedSame
    }
}
