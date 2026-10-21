import Foundation

/// Files waiting to be pasted, and whether pasting copies or moves them.
public struct FileClipboard: Equatable, Sendable {
    public enum Mode: Sendable {
        case copy
        case cut
    }

    public var urls: [URL]
    public var mode: Mode

    public init(urls: [URL], mode: Mode) {
        self.urls = urls
        self.mode = mode
    }
}
