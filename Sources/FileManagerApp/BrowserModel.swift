import AppKit
import FileCore

/// State of one browser window: current folder, its items, selection and history.
@MainActor
final class BrowserModel: ObservableObject {
    @Published private(set) var currentURL: URL
    @Published private(set) var items: [FileItem] = []
    @Published var selection: Set<URL> = []
    @Published var sort = FileSort() {
        didSet { items = sort.sorted(items) }
    }
    @Published var showHidden = false {
        didSet { reload() }
    }
    @Published var errorMessage: String?
    /// Description of a running operation, e.g. "Copying 3 items…".
    @Published private(set) var activity: String?
    @Published private(set) var availableCapacity: Int64?

    let clipboard: ClipboardController

    private let operations = FileOperations()
    private var backStack: [URL] = []
    private var forwardStack: [URL] = []
    private var watcher: DirectoryWatcher?
    private var pendingReload: DispatchWorkItem?
    private var loadGeneration = 0

    init(clipboard: ClipboardController, startURL: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.clipboard = clipboard
        currentURL = startURL
        load(startURL)
    }

    // MARK: - Derived state

    var title: String { FileManager.default.displayName(atPath: currentURL.path) }
    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }
    var canGoUp: Bool { currentURL.standardizedFileURL.path != "/" }
    var selectedItems: [FileItem] { items.filter { selection.contains($0.url) } }
    var canPaste: Bool { clipboard.contents != nil && activity == nil }

    // MARK: - Navigation

    func navigate(to url: URL, selecting paths: Set<String> = []) {
        guard url.standardizedFileURL.path != currentURL.standardizedFileURL.path else { return }
        backStack.append(currentURL)
        forwardStack.removeAll()
        load(url, selecting: paths)
    }

    func goBack() {
        guard let url = backStack.popLast() else { return }
        forwardStack.append(currentURL)
        load(url)
    }

    func goForward() {
        guard let url = forwardStack.popLast() else { return }
        backStack.append(currentURL)
        load(url)
    }

    func goUp() {
        guard canGoUp else { return }
        // Select the folder we came from, like Finder does.
        navigate(to: currentURL.deletingLastPathComponent(), selecting: [currentURL.standardizedFileURL.path])
    }

    func open(_ itemsToOpen: [FileItem]) {
        if itemsToOpen.count == 1, let item = itemsToOpen.first, item.isBrowsable {
            navigate(to: item.browseURL)
            return
        }
        for item in itemsToOpen where !item.isBrowsable {
            NSWorkspace.shared.open(item.url)
        }
    }

    private func load(_ url: URL, selecting paths: Set<String> = []) {
        currentURL = url
        items = []
        selection = []
        watcher = DirectoryWatcher(url: url) { [weak self] in
            Task { @MainActor in self?.scheduleReload() }
        }
        reload(selecting: paths)
    }

    /// Re-reads the current folder in the background. Keeps the selection unless `paths` is given.
    func reload(selecting paths: Set<String>? = nil) {
        loadGeneration += 1
        let generation = loadGeneration
        let url = currentURL
        let includeHidden = showHidden
        let sort = sort
        let keep = paths ?? Set(selection.map(\.path))

        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result { try sort.sorted(DirectoryLister.contents(of: url, includeHidden: includeHidden)) }
            }.value
            guard generation == loadGeneration else { return }

            switch result {
            case .success(let loaded):
                items = loaded
                selection = Set(loaded.filter { keep.contains($0.url.path) }.map(\.url))
            case .failure(let error):
                items = []
                selection = []
                errorMessage = error.localizedDescription
            }
            availableCapacity = (try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
                .volumeAvailableCapacityForImportantUsage
        }
    }

    private func scheduleReload() {
        pendingReload?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.reload() }
        pendingReload = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    // MARK: - Clipboard

    func copySelection() {
        clipboard.set(selectedItems.map(\.url), mode: .copy)
    }

    func cutSelection() {
        clipboard.set(selectedItems.map(\.url), mode: .cut)
    }

    func copyPathsOfSelection() {
        let paths = selectedItems.map(\.url.path).joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(paths, forType: .string)
        clipboard.refreshFromPasteboard()
    }

    func paste(undoManager: UndoManager?) {
        clipboard.refreshFromPasteboard()
        guard canPaste, let contents = clipboard.contents else { return }
        let destination = currentURL
        let count = contents.urls.count
        activity = "\(contents.mode == .cut ? "Moving" : "Copying") \(count) \(count == 1 ? "item" : "items")…"
        let prompt = ConflictPrompt()

        Task {
            defer { activity = nil }
            do {
                let result = try await operations.paste(
                    contents.urls, into: destination, mode: contents.mode,
                    onConflict: { await prompt.resolve($0) }
                )
                if contents.mode == .cut, result.failures.isEmpty, !result.stopped {
                    clipboard.didPaste()
                }
                registerUndo(result.record, actionName: contents.mode == .cut ? "Move" : "Copy", undoManager: undoManager)
                report(result.failures, verb: "pasted")
                if destination == currentURL {
                    reload(selecting: Set(result.resultURLs.map(\.path)))
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: - Trash

    func trashSelection(undoManager: UndoManager?) {
        let urls = selectedItems.map(\.url)
        guard !urls.isEmpty, activity == nil else { return }
        activity = "Moving \(urls.count) \(urls.count == 1 ? "item" : "items") to the Trash…"

        Task {
            defer { activity = nil }
            let result = await operations.moveToTrash(urls)
            registerUndo(result.record, actionName: "Move to Trash", undoManager: undoManager)
            report(result.failures, verb: "moved to the Trash")
            reload()
        }
    }

    // MARK: - Finder integration

    func revealSelectionInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting(selectedItems.map(\.url))
    }

    // MARK: - Undo

    private func registerUndo(_ record: OperationRecord, actionName: String, undoManager: UndoManager?) {
        guard !record.isEmpty, let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { model in
            // Undo is always invoked from the main thread (menu or ⌘Z).
            MainActor.assumeIsolated { model.performUndo(record) }
        }
        undoManager.setActionName(actionName)
    }

    private func performUndo(_ record: OperationRecord) {
        Task {
            do {
                try await operations.undo(record)
            } catch {
                errorMessage = "Couldn’t undo: \(error.localizedDescription)"
            }
            reload()
        }
    }

    private func report(_ failures: [OperationResult.Failure], verb: String) {
        guard !failures.isEmpty else { return }
        let lines = failures.map { "• \($0.url.lastPathComponent): \($0.message)" }
        let noun = failures.count == 1 ? "1 item" : "\(failures.count) items"
        errorMessage = "\(noun) couldn’t be \(verb):\n" + lines.joined(separator: "\n")
    }
}
