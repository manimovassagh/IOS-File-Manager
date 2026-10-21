import AppKit
import FileCore

/// App-wide file clipboard, shared by all windows.
///
/// File URLs are also written to the system pasteboard, so items copied here can be pasted
/// in Finder or other apps, and files copied in Finder can be pasted here. The pasteboard
/// has no notion of "cut", so cut mode is tracked only inside this app.
@MainActor
final class ClipboardController: ObservableObject {
    @Published private(set) var contents: FileClipboard?

    private let pasteboard = NSPasteboard.general
    private var knownChangeCount = -1

    init() {
        refreshFromPasteboard()
    }

    /// Paths of items that will be moved on the next paste.
    var cutPaths: Set<String> {
        guard let contents, contents.mode == .cut else { return [] }
        return Set(contents.urls.map(\.path))
    }

    func set(_ urls: [URL], mode: FileClipboard.Mode) {
        guard !urls.isEmpty else { return }
        pasteboard.clearContents()
        pasteboard.writeObjects(urls as [NSURL])
        knownChangeCount = pasteboard.changeCount
        contents = FileClipboard(urls: urls, mode: mode)
    }

    func clear() {
        if pasteboard.changeCount == knownChangeCount {
            pasteboard.clearContents()
            knownChangeCount = pasteboard.changeCount
        }
        contents = nil
    }

    /// Picks up files copied in other apps since we last looked.
    func refreshFromPasteboard() {
        guard pasteboard.changeCount != knownChangeCount else { return }
        knownChangeCount = pasteboard.changeCount
        let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []
        contents = urls.isEmpty ? nil : FileClipboard(urls: urls, mode: .copy)
    }

    /// Cut items are gone from their old location after a paste, so the clipboard is emptied.
    func didPaste() {
        if contents?.mode == .cut {
            clear()
        }
    }
}
