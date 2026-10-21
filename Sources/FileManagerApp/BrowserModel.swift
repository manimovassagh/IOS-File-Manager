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
    /// Item-level progress of a running copy/move.
    @Published private(set) var progress: OperationProgress?
    @Published private(set) var availableCapacity: Int64?
    /// An item whose name should become editable in the list (set by Rename and New Folder).
    @Published var renameRequest: URL?

    let clipboard: ClipboardController

    private let operations = FileOperations()
    private var backStack: [URL] = []
    private var forwardStack: [URL] = []
    private var watcher: DirectoryWatcher?
    private var pendingReload: DispatchWorkItem?
    private var loadGeneration = 0
    private var operationTask: Task<Void, Never>?

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
    var isBusy: Bool { activity != nil }

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

    func open(_ itemsToOpen: [FileItem], withApplicationAt application: URL) {
        let urls = itemsToOpen.map(\.url)
        NSWorkspace.shared.open(urls, withApplicationAt: application, configuration: NSWorkspace.OpenConfiguration())
    }

    /// Opens Terminal in `folder`, or in the current folder.
    func openTerminal(at folder: URL? = nil) {
        guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { return }
        NSWorkspace.shared.open([folder ?? currentURL], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
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
        transfer(
            contents.urls, into: currentURL, mode: contents.mode,
            actionName: contents.mode == .cut ? "Move" : "Copy",
            undoManager: undoManager,
            onSuccess: { [clipboard] in
                if contents.mode == .cut { clipboard.didPaste() }
            }
        )
    }

    /// Makes copies of the selection next to the originals ("file copy.txt").
    func duplicateSelection(undoManager: UndoManager?) {
        let urls = selectedItems.map(\.url)
        guard !urls.isEmpty else { return }
        transfer(urls, into: currentURL, mode: .copy, actionName: "Duplicate", undoManager: undoManager)
    }

    /// Handles files dropped onto the list or onto a folder in it.
    func drop(_ urls: [URL], into destination: URL, mode: FileClipboard.Mode, undoManager: UndoManager?) {
        transfer(urls, into: destination, mode: mode, actionName: mode == .cut ? "Move" : "Copy", undoManager: undoManager)
    }

    func cancelOperation() {
        operationTask?.cancel()
    }

    /// Copies or moves `urls` into `destination` in the background, with progress, conflict prompts and undo.
    private func transfer(
        _ urls: [URL],
        into destination: URL,
        mode: FileClipboard.Mode,
        actionName: String,
        undoManager: UndoManager?,
        onSuccess: @escaping () -> Void = {}
    ) {
        guard !urls.isEmpty, !isBusy else { return }
        let count = urls.count
        activity = "\(mode == .cut ? "Moving" : "Copying") \(count) \(count == 1 ? "item" : "items")"
        progress = OperationProgress(completed: 0, total: count, currentName: "")
        let prompt = ConflictPrompt()

        operationTask = Task {
            defer {
                activity = nil
                progress = nil
                operationTask = nil
            }
            do {
                let result = try await operations.paste(
                    urls, into: destination, mode: mode,
                    onConflict: { await prompt.resolve($0) },
                    onProgress: { progress in await self.updateProgress(progress) }
                )
                if result.failures.isEmpty, !result.stopped {
                    onSuccess()
                }
                registerUndo(result.record, actionName: actionName, undoManager: undoManager)
                report(result.failures, verb: mode == .cut ? "moved" : "copied")
                if destination.standardizedFileURL.path == currentURL.standardizedFileURL.path {
                    reload(selecting: Set(result.resultURLs.map(\.path)))
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func updateProgress(_ newProgress: OperationProgress) {
        progress = newProgress
    }

    // MARK: - New folder & rename

    func newFolder(undoManager: UndoManager?) {
        let directory = currentURL
        Task {
            do {
                let (url, record) = try await operations.createFolder(in: directory)
                registerUndo(record, actionName: "New Folder", undoManager: undoManager)
                renameRequest = url
                reload(selecting: [url.path])
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Makes the selected item's name editable in the list.
    func renameSelection() {
        guard selectedItems.count == 1, let item = selectedItems.first else { return }
        renameRequest = item.url
    }

    func rename(_ url: URL, to newName: String, undoManager: UndoManager?) {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name != url.lastPathComponent else { return }
        Task {
            do {
                let (newURL, record) = try await operations.rename(url, to: name)
                registerUndo(record, actionName: "Rename", undoManager: undoManager)
                reload(selecting: [newURL.path])
            } catch {
                errorMessage = error.localizedDescription
                reload()
            }
        }
    }

    // MARK: - Trash & delete

    func trashSelection(undoManager: UndoManager?) {
        let urls = selectedItems.map(\.url)
        guard !urls.isEmpty, !isBusy else { return }
        activity = "Moving \(urls.count) \(urls.count == 1 ? "item" : "items") to the Trash"

        Task {
            defer { activity = nil }
            let result = await operations.moveToTrash(urls)
            registerUndo(result.record, actionName: "Move to Trash", undoManager: undoManager)
            report(result.failures, verb: "moved to the Trash")
            reload()
        }
    }

    /// Permanently deletes the selection after asking for confirmation.
    func deleteSelectionImmediately() {
        let urls = selectedItems.map(\.url)
        guard !urls.isEmpty, !isBusy else { return }

        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = urls.count == 1
            ? "Are you sure you want to delete “\(urls[0].lastPathComponent)” immediately?"
            : "Are you sure you want to delete these \(urls.count) items immediately?"
        alert.informativeText = "You can’t undo this action."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        activity = "Deleting \(urls.count) \(urls.count == 1 ? "item" : "items")"
        Task {
            defer { activity = nil }
            let result = await operations.deleteImmediately(urls)
            report(result.failures, verb: "deleted")
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
        undoManager.registerUndo(withTarget: self) { [weak undoManager] model in
            guard let undoManager else { return }
            // Undo is always invoked from the main thread (menu or ⌘Z).
            MainActor.assumeIsolated { model.revert(record, actionName: actionName, undoManager: undoManager) }
        }
        undoManager.setActionName(actionName)
    }

    /// Undoes `record`. Registering the inverse while the undo manager is undoing puts it on the
    /// redo stack (and vice versa), so this one function handles both Undo and Redo.
    ///
    /// The inverse is only known once the files have moved, but it must be registered right now,
    /// so it goes in a box that the background work fills in.
    private func revert(_ record: OperationRecord, actionName: String, undoManager: UndoManager) {
        let inverse = RecordBox()
        undoManager.registerUndo(withTarget: self) { [weak undoManager] model in
            MainActor.assumeIsolated {
                guard let undoManager, let record = inverse.record else { return }
                model.revert(record, actionName: actionName, undoManager: undoManager)
            }
        }
        undoManager.setActionName(actionName)

        Task {
            do {
                inverse.record = try await operations.undo(record)
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

@MainActor
private final class RecordBox {
    var record: OperationRecord?
}
