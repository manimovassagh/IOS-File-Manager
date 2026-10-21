import Foundation

public enum ConflictResolution: Sendable {
    /// Move the existing item to the Trash and put the new one in its place.
    case replace
    /// Keep the existing item and give the new one a numbered name ("file 2.txt").
    case keepBoth
    /// Leave this item out.
    case skip
    /// Cancel this item and every remaining one.
    case stop
}

public struct FileConflict: Sendable {
    public let source: URL
    public let existing: URL
}

public enum FileOperationError: LocalizedError, Equatable {
    case destinationInsideSource(URL)

    public var errorDescription: String? {
        switch self {
        case .destinationInsideSource(let url):
            return "“\(url.lastPathComponent)” can’t be pasted into itself."
        }
    }
}

/// What an operation changed on disk, so it can be undone.
public struct OperationRecord: Equatable, Sendable {
    public enum Step: Equatable, Sendable {
        case copied(to: URL)
        case moved(from: URL, to: URL)
        case trashed(original: URL, trashLocation: URL)
    }

    public internal(set) var steps: [Step] = []

    public var isEmpty: Bool { steps.isEmpty }
}

public struct OperationResult: Sendable {
    public struct Failure: Equatable, Sendable {
        public let url: URL
        public let message: String
    }

    public internal(set) var record = OperationRecord()
    /// Items at their new location (what should be selected after the operation).
    public internal(set) var resultURLs: [URL] = []
    public internal(set) var failures: [Failure] = []
    /// True when the user chose `.stop` on a conflict.
    public internal(set) var stopped = false
}

/// Copy / move / trash operations. Methods are `async` and run off the main thread.
public struct FileOperations: Sendable {
    public typealias ConflictHandler = @Sendable (FileConflict) async -> ConflictResolution

    public enum NamingStyle: Sendable {
        /// "file copy.txt", "file copy 2.txt" — used when duplicating into the same folder.
        case copy
        /// "file 2.txt", "file 3.txt" — used for "Keep Both".
        case numbered
    }

    private var fileManager: FileManager { .default }

    public init() {}

    /// Pastes `sources` into `destination`, copying or moving depending on `mode`.
    ///
    /// Per-item errors are collected in `OperationResult.failures` instead of aborting the whole paste.
    /// Throws only if the paste is invalid as a whole (e.g. a folder pasted into itself); nothing is changed then.
    public func paste(
        _ sources: [URL],
        into destination: URL,
        mode: FileClipboard.Mode,
        onConflict: ConflictHandler
    ) async throws -> OperationResult {
        let destination = destination.standardizedFileURL
        let canonicalDestination = Self.canonical(destination)

        for source in sources where Self.isSameOrDescendant(canonicalDestination, of: Self.canonical(source)) {
            throw FileOperationError.destinationInsideSource(source)
        }

        var result = OperationResult()
        for source in sources.map(\.standardizedFileURL) {
            do {
                if Self.canonical(source.deletingLastPathComponent()) == canonicalDestination {
                    switch mode {
                    case .cut:
                        // Already here; nothing to move.
                        result.resultURLs.append(source)
                    case .copy:
                        let target = Self.uniqueURL(for: source.lastPathComponent, in: destination, style: .copy)
                        try fileManager.copyItem(at: source, to: target)
                        result.record.steps.append(.copied(to: target))
                        result.resultURLs.append(target)
                    }
                    continue
                }

                var target = destination.appendingPathComponent(source.lastPathComponent)
                if Self.itemExists(at: target) {
                    switch await onConflict(FileConflict(source: source, existing: target)) {
                    case .skip:
                        continue
                    case .stop:
                        result.stopped = true
                        return result
                    case .keepBoth:
                        target = Self.uniqueURL(for: source.lastPathComponent, in: destination, style: .numbered)
                    case .replace:
                        if Self.isSameOrDescendant(Self.canonical(source), of: Self.canonical(target)) {
                            result.failures.append(.init(
                                url: source,
                                message: "It can’t replace the folder that contains it."
                            ))
                            continue
                        }
                        var trashed: NSURL?
                        try fileManager.trashItem(at: target, resultingItemURL: &trashed)
                        if let trashed = trashed as URL? {
                            result.record.steps.append(.trashed(original: target, trashLocation: trashed))
                        }
                    }
                }

                switch mode {
                case .copy:
                    try fileManager.copyItem(at: source, to: target)
                    result.record.steps.append(.copied(to: target))
                case .cut:
                    try fileManager.moveItem(at: source, to: target)
                    result.record.steps.append(.moved(from: source, to: target))
                }
                result.resultURLs.append(target)
            } catch {
                result.failures.append(.init(url: source, message: error.localizedDescription))
            }
        }
        return result
    }

    public func moveToTrash(_ urls: [URL]) async -> OperationResult {
        var result = OperationResult()
        for url in urls {
            do {
                var trashed: NSURL?
                try fileManager.trashItem(at: url, resultingItemURL: &trashed)
                if let trashed = trashed as URL? {
                    result.record.steps.append(.trashed(original: url, trashLocation: trashed))
                }
            } catch {
                result.failures.append(.init(url: url, message: error.localizedDescription))
            }
        }
        return result
    }

    /// Reverts the steps of `record`, newest first.
    public func undo(_ record: OperationRecord) async throws {
        for step in record.steps.reversed() {
            switch step {
            case .copied(let url):
                try fileManager.trashItem(at: url, resultingItemURL: nil)
            case .moved(let from, let to):
                try fileManager.moveItem(at: to, to: from)
            case .trashed(let original, let trashLocation):
                try fileManager.moveItem(at: trashLocation, to: original)
            }
        }
    }

    // MARK: - Helpers

    /// Returns a URL in `directory` based on `name` that doesn't exist yet.
    public static func uniqueURL(for name: String, in directory: URL, style: NamingStyle) -> URL {
        let ext = (name as NSString).pathExtension
        var base = (name as NSString).deletingPathExtension
        func fileName(_ base: String) -> String { ext.isEmpty ? base : "\(base).\(ext)" }
        func isFree(_ name: String) -> Bool { !itemExists(at: directory.appendingPathComponent(name)) }

        var candidate: String
        switch style {
        case .copy:
            candidate = fileName("\(base) copy")
            var number = 2
            while !isFree(candidate) {
                candidate = fileName("\(base) copy \(number)")
                number += 1
            }
        case .numbered:
            var number = 2
            // "file 2" continues as "file 3" rather than "file 2 2".
            if let range = base.range(of: #" \d+$"#, options: .regularExpression),
               let existing = Int(base[range].dropFirst()) {
                base = String(base[..<range.lowerBound])
                number = existing + 1
            }
            candidate = fileName("\(base) \(number)")
            while !isFree(candidate) {
                number += 1
                candidate = fileName("\(base) \(number)")
            }
        }
        return directory.appendingPathComponent(candidate)
    }

    /// True if something (including a broken symbolic link) occupies `url`.
    static func itemExists(at url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
    }

    /// Resolves symbolic links in the parent path but keeps the last component as-is,
    /// so a symlink is treated as itself rather than as its target.
    static func canonical(_ url: URL) -> URL {
        let url = url.standardizedFileURL
        guard url.path != "/" else { return url }
        return url.deletingLastPathComponent().resolvingSymlinksInPath()
            .appendingPathComponent(url.lastPathComponent)
    }

    static func isSameOrDescendant(_ url: URL, of ancestor: URL) -> Bool {
        let path = url.pathComponents
        let ancestorPath = ancestor.pathComponents
        return path.count >= ancestorPath.count && Array(path.prefix(ancestorPath.count)) == ancestorPath
    }
}
