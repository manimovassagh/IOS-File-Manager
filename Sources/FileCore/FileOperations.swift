import Darwin
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

/// Progress of a multi-item operation, reported before each item starts.
public struct OperationProgress: Equatable, Sendable {
    public let completed: Int
    public let total: Int
    /// Name of the item being processed now (empty when finished).
    public let currentName: String

    public var fraction: Double { total == 0 ? 1 : Double(completed) / Double(total) }

    public init(completed: Int, total: Int, currentName: String) {
        self.completed = completed
        self.total = total
        self.currentName = currentName
    }
}

public enum FileOperationError: LocalizedError, Equatable {
    case destinationInsideSource(URL)
    case invalidName(String)
    case nameTaken(String)

    public var errorDescription: String? {
        switch self {
        case .destinationInsideSource(let url):
            return "“\(url.lastPathComponent)” can’t be pasted into itself."
        case .invalidName(let name):
            return "“\(name)” isn’t a valid name. Names can’t be empty or contain “/” or “:”."
        case .nameTaken(let name):
            return "The name “\(name)” is already taken. Please choose a different name."
        }
    }
}

/// What an operation changed on disk, so it can be undone.
public struct OperationRecord: Equatable, Sendable {
    public enum Step: Equatable, Sendable {
        /// A new item exists at this URL (a copy or a new folder).
        case created(at: URL)
        case moved(from: URL, to: URL)
        case trashed(original: URL, trashLocation: URL)
    }

    public internal(set) var steps: [Step] = []

    public var isEmpty: Bool { steps.isEmpty }

    public init() {}
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
    /// True when the user chose `.stop` on a conflict or the task was cancelled.
    public internal(set) var stopped = false
}

/// Copy / move / rename / trash operations. Methods are `async` and run off the main thread.
public struct FileOperations: Sendable {
    public typealias ConflictHandler = @Sendable (FileConflict) async -> ConflictResolution
    public typealias ProgressHandler = @Sendable (OperationProgress) async -> Void

    public enum NamingStyle: Sendable {
        /// "file copy.txt", "file copy 2.txt" — used when duplicating into the same folder.
        case copy
        /// "file 2.txt", "file 3.txt" — used for "Keep Both" and new folders.
        case numbered
    }

    private var fileManager: FileManager { .default }

    public init() {}

    /// Pastes `sources` into `destination`, copying or moving depending on `mode`.
    ///
    /// Per-item errors are collected in `OperationResult.failures` instead of aborting the whole paste.
    /// Throws only if the paste is invalid as a whole (e.g. a folder pasted into itself); nothing is changed then.
    /// Cancelling the calling task stops before the next item; finished items stay done and undoable.
    public func paste(
        _ sources: [URL],
        into destination: URL,
        mode: FileClipboard.Mode,
        onConflict: ConflictHandler,
        onProgress: ProgressHandler? = nil
    ) async throws -> OperationResult {
        let destination = destination.standardizedFileURL
        let canonicalDestination = Self.canonical(destination)

        for source in sources where Self.isSameOrDescendant(canonicalDestination, of: Self.canonical(source)) {
            throw FileOperationError.destinationInsideSource(source)
        }

        var result = OperationResult()
        let sources = sources.map(\.standardizedFileURL)
        for (index, source) in sources.enumerated() {
            await onProgress?(OperationProgress(completed: index, total: sources.count, currentName: source.lastPathComponent))
            if Task.isCancelled {
                result.stopped = true
                break
            }

            do {
                if Self.canonical(source.deletingLastPathComponent()) == canonicalDestination {
                    switch mode {
                    case .cut:
                        // Already here; nothing to move.
                        result.resultURLs.append(source)
                    case .copy:
                        let target = Self.uniqueURL(for: source.lastPathComponent, in: destination, style: .copy)
                        try fileManager.copyItem(at: source, to: target)
                        result.record.steps.append(.created(at: target))
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
                    result.record.steps.append(.created(at: target))
                case .cut:
                    try fileManager.moveItem(at: source, to: target)
                    result.record.steps.append(.moved(from: source, to: target))
                }
                result.resultURLs.append(target)
            } catch {
                result.failures.append(.init(url: source, message: error.localizedDescription))
            }
        }
        if !result.stopped {
            await onProgress?(OperationProgress(completed: sources.count, total: sources.count, currentName: ""))
        }
        return result
    }

    /// Renames the item at `url` in place. Returns its new URL.
    public func rename(_ url: URL, to newName: String) async throws -> (url: URL, record: OperationRecord) {
        guard Self.isValidName(newName) else { throw FileOperationError.invalidName(newName) }
        let source = url.standardizedFileURL
        let target = source.deletingLastPathComponent().appendingPathComponent(newName)
        var record = OperationRecord()
        guard target.lastPathComponent != source.lastPathComponent else { return (source, record) }

        if Self.itemExists(at: target), !Self.isSameItem(source, target) {
            throw FileOperationError.nameTaken(newName)
        }
        try moveItem(at: source, to: target)
        record.steps.append(.moved(from: source, to: target))
        return (target, record)
    }

    /// Creates a folder named `name` (or "name 2", … if taken) inside `directory`.
    public func createFolder(in directory: URL, name: String = "untitled folder") async throws -> (url: URL, record: OperationRecord) {
        guard Self.isValidName(name) else { throw FileOperationError.invalidName(name) }
        var target = directory.standardizedFileURL.appendingPathComponent(name)
        if Self.itemExists(at: target) {
            target = Self.uniqueURL(for: name, in: directory.standardizedFileURL, style: .numbered)
        }
        try fileManager.createDirectory(at: target, withIntermediateDirectories: false)
        var record = OperationRecord()
        record.steps.append(.created(at: target))
        return (target, record)
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

    /// Permanently deletes `urls`. This can't be undone.
    public func deleteImmediately(_ urls: [URL]) async -> OperationResult {
        var result = OperationResult()
        for url in urls {
            do {
                try fileManager.removeItem(at: url)
            } catch {
                result.failures.append(.init(url: url, message: error.localizedDescription))
            }
        }
        return result
    }

    /// Reverts the steps of `record`, newest first.
    ///
    /// Returns the inverse record: undoing it re-applies `record` (that's how Redo works).
    @discardableResult
    public func undo(_ record: OperationRecord) async throws -> OperationRecord {
        var inverse = OperationRecord()
        for step in record.steps.reversed() {
            switch step {
            case .created(let url):
                var trashed: NSURL?
                try fileManager.trashItem(at: url, resultingItemURL: &trashed)
                if let trashed = trashed as URL? {
                    inverse.steps.append(.trashed(original: url, trashLocation: trashed))
                }
            case .moved(let from, let to):
                try moveItem(at: to, to: from)
                inverse.steps.append(.moved(from: to, to: from))
            case .trashed(let original, let trashLocation):
                try moveItem(at: trashLocation, to: original)
                inverse.steps.append(.created(at: original))
            }
        }
        return inverse
    }

    // MARK: - Helpers

    /// Moves without ever overwriting. Same-folder moves use `rename(2)` so case-only renames
    /// ("a.txt" → "A.txt") work on case-insensitive volumes.
    private func moveItem(at source: URL, to destination: URL) throws {
        if Self.itemExists(at: destination), !Self.isSameItem(source, destination) {
            throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: destination.path])
        }
        let sameFolder = source.deletingLastPathComponent().standardizedFileURL.path
            == destination.deletingLastPathComponent().standardizedFileURL.path
        if sameFolder {
            guard Darwin.rename(source.path, destination.path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } else {
            try fileManager.moveItem(at: source, to: destination)
        }
    }

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

    public static func isValidName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains(":") && !name.contains("\0")
    }

    /// True if both URLs live on the same volume (so a move is a fast rename rather than a copy).
    public static func isOnSameVolume(_ a: URL, _ b: URL) -> Bool {
        guard let first = volumeIdentifier(of: a), let second = volumeIdentifier(of: b) else { return false }
        return first.isEqual(second)
    }

    private static func volumeIdentifier(of url: URL) -> (any NSObjectProtocol)? {
        var url = url
        url.removeAllCachedResourceValues()
        return (try? url.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier as? any NSObjectProtocol
    }

    /// True if something (including a broken symbolic link) occupies `url`.
    static func itemExists(at url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
    }

    /// True if both URLs refer to the same file (e.g. "a.txt" and "A.txt" on a case-insensitive volume).
    static func isSameItem(_ a: URL, _ b: URL) -> Bool {
        func identifier(_ url: URL) -> (any NSObjectProtocol)? {
            var url = url
            url.removeAllCachedResourceValues()
            return (try? url.resourceValues(forKeys: [.fileResourceIdentifierKey]))?.fileResourceIdentifier as? any NSObjectProtocol
        }
        guard let first = identifier(a), let second = identifier(b) else { return false }
        return first.isEqual(second)
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
