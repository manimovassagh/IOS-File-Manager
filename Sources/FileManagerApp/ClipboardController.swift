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
    /// A short message for the user, e.g. when a cut was replaced by something copied elsewhere.
    @Published var notice: String?

    private let pasteboard = NSPasteboard.general
    private var knownChangeCount = -1

    init() {
        refreshFromPasteboard()
        NotificationCenter.default.addObserver(
            self, selector: #selector(pasteboardChangedByApp), name: .pasteboardChangedByApp, object: nil
        )
    }

    /// Parts of the app that write to the pasteboard directly (e.g. Copy Image in the preview) post
    /// `.pasteboardChangedByApp` so the clipboard bar updates right away.
    @objc private func pasteboardChangedByApp() {
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
        let hadCut = contents?.mode == .cut
        let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []
        contents = urls.isEmpty ? nil : FileClipboard(urls: urls, mode: .copy)
        if hadCut {
            notice = "Your cut files were not moved: something else was copied, so the cut was cancelled."
        }
    }

    /// Esc in the file list: forget a pending cut.
    func cancelCut() {
        guard contents?.mode == .cut else { return }
        clear()
    }

    /// After pasting a cut: forget the items that moved, keep any that didn't (failed or skipped).
    func didMove(_ sources: [URL]) {
        guard let contents, contents.mode == .cut else { return }
        let moved = Set(sources.map(\.standardizedFileURL.path))
        let remaining = contents.urls.filter { !moved.contains($0.standardizedFileURL.path) }
        if remaining.isEmpty {
            clear()
        } else {
            set(remaining, mode: .cut)
        }
    }

    /// Cut items are gone from their old location after a paste, so the clipboard is emptied.
    func didPaste() {
        if contents?.mode == .cut {
            clear()
        }
    }
}

extension Notification.Name {
    static let pasteboardChangedByApp = Notification.Name("FileManagerPasteboardChangedByApp")
}
