import AppKit
import Combine
import FileCore

enum ViewMode: String, CaseIterable {
    case list, columns
}

/// One piece of the path bar.
struct PathComponent: Identifiable {
    let id: String
    let title: String
    /// Folder to open when clicked; `nil` for a smart location.
    let url: URL?
    let systemImage: String?
}

/// State of one browser window: current location, its items, selection and history.
@MainActor
final class BrowserModel: ObservableObject {
    @Published private(set) var location: Location
    /// The folder being worked in: paste, new folder and drops go here. In column view this is the
    /// folder of the focused column, which may be deeper than `location`.
    @Published private(set) var currentURL: URL
    /// Items shown: `allItems` sorted and filtered.
    @Published private(set) var items: [FileItem] = []
    @Published private(set) var allItems: [FileItem] = []
    @Published var selection: Set<URL> = []
    @Published var sort: FileSort {
        didSet {
            guard sort != oldValue else { return }
            sorts[location.kind] = sort
            applyFilterAndSort()
        }
    }
    @Published var showHidden = false {
        didSet { if showHidden != oldValue { reload() } }
    }
    @Published var filterText = "" {
        didSet { if filterText != oldValue { applyFilterAndSort() } }
    }
    @Published var viewMode: ViewMode {
        didSet {
            guard viewMode != oldValue else { return }
            UserDefaults.standard.set(viewMode.rawValue, forKey: "viewMode")
            navigationID += 1
        }
    }
    /// Preview panel next to the list view.
    @Published var showInspector = false
    @Published var errorMessage: String?
    /// Description of a running operation, e.g. "Copying 3 items".
    @Published private(set) var activity: String?
    /// Item-level progress of a running copy/move.
    @Published private(set) var progress: OperationProgress?
    @Published private(set) var availableCapacity: Int64?
    @Published private(set) var isLoading = false
    /// An item whose name should become editable in the list (set by Rename and New Folder).
    @Published var renameRequest: URL?
    /// Changes whenever the user goes to a new place or switches views; the column view rebuilds then.
    @Published private(set) var navigationID = 0

    let clipboard: ClipboardController

    private let operations = FileOperations()
    private let settings = ThemeSettings.shared
    private(set) var baseURL: URL
    private var sorts: [Location.Kind: FileSort] = [:]
    private var backStack: [Location] = []
    private var forwardStack: [Location] = []
    private var watcher: DirectoryWatcher?
    private var pendingReload: DispatchWorkItem?
    private var loadGeneration = 0
    private var operationTask: Task<Void, Never>?
    private var subscriptions: Set<AnyCancellable> = []

    init(clipboard: ClipboardController, start: Location = .folder(FileManager.default.homeDirectoryForCurrentUser)) {
        self.clipboard = clipboard
        location = start
        baseURL = start.baseURL
        currentURL = start.baseURL
        sort = start.kind.defaultSort
        viewMode = UserDefaults.standard.string(forKey: "viewMode").flatMap(ViewMode.init(rawValue:)) ?? .list

        settings.$foldersFirst
            .dropFirst()
            .sink { [weak self] _ in
                // Published fires before the value is stored; re-sort on the next turn.
                DispatchQueue.main.async { self?.applyFilterAndSort() }
            }
            .store(in: &subscriptions)

        load(start)
    }

    // MARK: - Derived state

    var title: String {
        if let smartTitle = location.smartTitle, isAtBase {
            return smartTitle
        }
        return FileManager.default.displayName(atPath: currentURL.path)
    }

    var pathComponents: [PathComponent] {
        if let smartTitle = location.smartTitle, isAtBase {
            return [PathComponent(id: smartTitle, title: smartTitle, url: nil, systemImage: location.smartSystemImage)]
        }
        var result: [PathComponent] = []
        var url = currentURL.standardizedFileURL
        for _ in 0..<128 {
            result.insert(PathComponent(
                id: url.path, title: FileManager.default.displayName(atPath: url.path), url: url, systemImage: nil
            ), at: 0)
            if url.path == "/" { break }
            url = url.deletingLastPathComponent().standardizedFileURL
        }
        return result
    }

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }
    var canGoUp: Bool { location.kind == .folder && currentURL.standardizedFileURL.path != "/" }
    var selectedItems: [FileItem] { items.filter { selection.contains($0.url) } }
    var acceptsNewItems: Bool { location.acceptsNewItems || !isAtBase }
    var canPaste: Bool { clipboard.contents != nil && !isBusy && acceptsNewItems }
    var isBusy: Bool { activity != nil }

    /// Sort with the "folders on top" preference applied.
    var effectiveSort: FileSort {
        var sort = sort
        sort.foldersFirst = settings.foldersFirst
        return sort
    }

    /// True when showing the location itself (not a subfolder opened in column view).
    private var isAtBase: Bool {
        currentURL.standardizedFileURL.path == baseURL.standardizedFileURL.path
    }

    /// What to load for `folder`: the location's own source at its base, a plain folder below it.
    func itemSource(for folder: URL) -> ItemSource {
        guard folder.standardizedFileURL.path == baseURL.standardizedFileURL.path else { return .folder(folder) }
        switch location {
        case .folder: return .folder(folder)
        case .screenshots: return .screenshots(folder)
        case .recents: return .recents
        }
    }

    /// Sorts and filters `items` the way the list shows them.
    static func arrange(_ items: [FileItem], sort: FileSort, filter: String) -> [FileItem] {
        let sorted = sort.sorted(items)
        let query = filter.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return sorted }
        return sorted.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    // MARK: - Navigation

    func navigate(to url: URL, selecting paths: Set<String> = []) {
        navigate(to: .folder(url), selecting: paths)
    }

    func navigate(to newLocation: Location, selecting paths: Set<String> = []) {
        if case .folder(let url) = newLocation, case .folder = location,
           url.standardizedFileURL.path == currentURL.standardizedFileURL.path, isAtBase {
            return
        }
        if newLocation == location, newLocation.kind != .folder, isAtBase {
            return
        }
        backStack.append(location)
        forwardStack.removeAll()
        load(newLocation, selecting: paths)
    }

    func goBack() {
        guard let previous = backStack.popLast() else { return }
        forwardStack.append(location)
        load(previous)
    }

    func goForward() {
        guard let next = forwardStack.popLast() else { return }
        backStack.append(location)
        load(next)
    }

    func goUp() {
        guard canGoUp else { return }
        // Select the folder we came from, like Finder does.
        navigate(to: currentURL.deletingLastPathComponent(), selecting: [currentURL.standardizedFileURL.path])
    }

    /// Opens the folder containing `item` with the item selected (useful from Recents).
    func showInEnclosingFolder(_ item: FileItem) {
        navigate(to: item.url.deletingLastPathComponent(), selecting: [item.url.path])
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

    func open(_ itemsToOpen: [FileItem], withApplicationAt application: URL) {
        let urls = itemsToOpen.map(\.url)
        NSWorkspace.shared.open(urls, withApplicationAt: application, configuration: NSWorkspace.OpenConfiguration())
    }

    /// Opens Terminal in `folder`, or in the current folder.
    func openTerminal(at folder: URL? = nil) {
        guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { return }
        NSWorkspace.shared.open([folder ?? currentURL], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
    }

    private func load(_ newLocation: Location, selecting paths: Set<String> = []) {
        if newLocation.kind != location.kind {
            sorts[location.kind] = sort
            sort = sorts[newLocation.kind] ?? newLocation.kind.defaultSort
        }
        location = newLocation
        baseURL = newLocation.baseURL
        currentURL = baseURL
        allItems = []
        items = []
        selection = []
        filterText = ""
        navigationID += 1
        watch(currentURL)
        reload(selecting: paths)
    }

    /// Column view: the user moved focus to the column showing `folder`.
    /// Doesn't touch history; the column view already loaded `newItems`.
    func focusColumn(folder: URL, items newItems: [FileItem], selection newSelection: Set<URL>) {
        if folder.standardizedFileURL.path != currentURL.standardizedFileURL.path {
            currentURL = folder
            watch(folder)
            updateCapacity()
        }
        if newItems != allItems {
            allItems = newItems
            applyFilterAndSort()
        }
        if newSelection != selection {
            selection = newSelection
        }
    }

    private func watch(_ folder: URL) {
        guard itemSource(for: folder) != .recents else {
            watcher = nil
            return
        }
        watcher = DirectoryWatcher(url: folder) { [weak self] in
            Task { @MainActor in self?.scheduleReload() }
        }
    }

    /// Re-reads the current folder in the background. Keeps the selection unless `paths` is given.
    func reload(selecting paths: Set<String>? = nil) {
        loadGeneration += 1
        let generation = loadGeneration
        let source = itemSource(for: currentURL)
        let includeHidden = showHidden
        let keep = paths ?? Set(selection.map(\.path))
        isLoading = true

        Task {
            let result: Result<[FileItem], Error>
            do {
                result = .success(try await ItemLoader.load(source, includeHidden: includeHidden))
            } catch {
                result = .failure(error)
            }
            guard generation == loadGeneration else { return }
            isLoading = false

            switch result {
            case .success(let loaded):
                allItems = loaded
                applyFilterAndSort()
                selection = Set(items.filter { keep.contains($0.url.path) }.map(\.url))
            case .failure(let error):
                allItems = []
                items = []
                selection = []
                errorMessage = error.localizedDescription
            }
            updateCapacity()
        }
    }

    private func applyFilterAndSort() {
        items = Self.arrange(allItems, sort: effectiveSort, filter: filterText)
        let visible = Set(items.map(\.url))
        let kept = selection.filter { visible.contains($0) }
        if kept != selection {
            selection = kept
        }
    }

    private func updateCapacity() {
        availableCapacity = (try? currentURL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage
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
        guard !urls.isEmpty, let folder = urls.first?.deletingLastPathComponent() else { return }
        transfer(urls, into: folder, mode: .copy, actionName: "Duplicate", undoManager: undoManager)
    }

    /// Handles files dropped onto a list or onto a folder in it.
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
                } else {
                    reload()
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
        guard acceptsNewItems else { return }
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
        let manager = WeakUndoManager(undoManager)
        undoManager.registerUndo(withTarget: self) { model in
            // Undo is always invoked from the main thread (menu or ⌘Z).
            MainActor.assumeIsolated {
                guard let undoManager = manager.value else { return }
                model.revert(record, actionName: actionName, undoManager: undoManager)
            }
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
        let manager = WeakUndoManager(undoManager)
        undoManager.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated {
                guard let undoManager = manager.value, let record = inverse.record else { return }
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

/// Lets undo handlers refer back to their undo manager without a retain cycle.
/// Only touched on the main thread, where undo runs.
private final class WeakUndoManager: @unchecked Sendable {
    weak var value: UndoManager?

    init(_ value: UndoManager) {
        self.value = value
    }
}
