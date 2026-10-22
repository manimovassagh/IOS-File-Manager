import AppKit
import FileCore
import SwiftUI

struct BrowserView: View {
    @ObservedObject var clipboard: ClipboardController
    @ObservedObject var settings: ThemeSettings
    @ObservedObject var favorites: FavoritesStore
    @StateObject private var model: BrowserModel
    @Environment(\.undoManager) private var undoManager

    init(clipboard: ClipboardController, settings: ThemeSettings, favorites: FavoritesStore = .shared) {
        self.clipboard = clipboard
        self.settings = settings
        self.favorites = favorites
        _model = StateObject(wrappedValue: BrowserModel(clipboard: clipboard))
    }

    var body: some View {
        NavigationSplitView {
            SidebarView(
                location: model.location,
                palette: settings.palette,
                accent: settings.accentColor,
                favorites: favorites,
                onSelect: { model.navigate(to: $0) },
                onDrop: { urls, folder, mode in model.drop(urls, into: folder, mode: mode, undoManager: undoManager) }
            )
        } detail: {
            VStack(spacing: 0) {
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if let notice = clipboard.notice {
                    NoticeBar(message: notice) { clipboard.notice = nil }
                        .task(id: notice) {
                            try? await Task.sleep(for: .seconds(6))
                            if clipboard.notice == notice { clipboard.notice = nil }
                        }
                }
                if let contents = clipboard.contents {
                    ClipboardBar(
                        contents: contents,
                        canPaste: model.canPaste,
                        onPaste: { model.paste(undoManager: undoManager) },
                        onClear: { clipboard.clear() }
                    )
                }
                Divider()
                PathBar(components: model.pathComponents) { model.navigate(to: $0) }
                    .themeBackground(settings.palette?.bar)
                Divider()
                StatusBar(
                    itemCount: model.items.count,
                    selectedCount: model.selection.count,
                    selectedSize: model.selectedSize,
                    availableCapacity: model.availableCapacity,
                    activity: model.activity,
                    queuedCount: model.queuedCount,
                    progress: model.progress,
                    onCancel: { model.cancelOperation() }
                )
                .themeBackground(settings.palette?.bar)
            }
            .themeBackground(settings.palette?.background)
            .inspector(isPresented: inspectorBinding) {
                inspector
                    .themeBackground(settings.palette?.background)
                    .inspectorColumnWidth(min: 260, ideal: 340, max: 520)
            }
        }
        .themeForeground(settings.palette?.text)
        .themeToolbar(settings.palette?.bar)
        .background(WindowThemer(color: settings.palette?.bar))
        .navigationTitle(model.title)
        .searchable(text: $model.filterText, placement: .toolbar, prompt: "Filter")
        .focusedSceneObject(model)
        .toolbar { toolbar }
        .tint(settings.accentColor)
        .alert("Something went wrong", isPresented: errorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            clipboard.refreshFromPasteboard()
            if model.location.kind == .recents {
                model.reload()
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.viewMode {
        case .list:
            FileTableView(model: model, settings: settings, cutPaths: clipboard.cutPaths)
                .overlay { emptyState }
        case .columns:
            ColumnBrowserView(model: model, settings: settings, cutPaths: clipboard.cutPaths)
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if model.items.isEmpty && !model.isLoading {
            if !model.filterText.isEmpty {
                ContentUnavailableView.search(text: model.filterText)
            } else if model.location.kind == .screenshots {
                ContentUnavailableView(
                    "No Screenshots",
                    systemImage: "camera.viewfinder",
                    description: Text("Screenshots you take (⇧⌘3, ⇧⌘4, ⇧⌘5) appear here.")
                )
            } else if model.location.kind == .recents {
                ContentUnavailableView("No Recent Files", systemImage: "clock")
            } else {
                ContentUnavailableView("Empty Folder", systemImage: "folder")
            }
        }
    }

    @ViewBuilder
    private var inspector: some View {
        let selected = model.selectedItems
        if selected.count == 1, let item = selected.first {
            FilePreview(item: item)
        } else {
            PreviewPlaceholder(selectedCount: selected.count)
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        // Keyboard shortcuts for these live in the Go and View menus.
        ToolbarItemGroup(placement: .navigation) {
            Button { model.goBack() } label: {
                Label("Back", systemImage: "chevron.left")
            }
            .disabled(!model.canGoBack)
            .help("Back (⌘[)")

            Button { model.goForward() } label: {
                Label("Forward", systemImage: "chevron.right")
            }
            .disabled(!model.canGoForward)
            .help("Forward (⌘])")
        }

        ToolbarItem(placement: .principal) {
            Picker("View", selection: $model.viewMode) {
                Label("List", systemImage: "list.bullet").tag(ViewMode.list)
                Label("Columns", systemImage: "rectangle.split.3x1").tag(ViewMode.columns)
            }
            .pickerStyle(.segmented)
            .labelStyle(.iconOnly)
            .help("View as List (⌘1) or Columns (⌘3)")
        }

        ToolbarItemGroup(placement: .primaryAction) {
            Button { model.newFolder(undoManager: undoManager) } label: {
                Label("New Folder", systemImage: "folder.badge.plus")
            }
            .disabled(!model.acceptsNewItems)
            .help("New Folder (⇧⌘N)")

            // ⌘C / ⌘X / ⌘V come from the Edit menu; these buttons are for mouse users.
            Button { model.copySelection() } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            .disabled(model.selection.isEmpty)
            .help("Copy (⌘C)")

            Button { model.cutSelection() } label: {
                Label("Cut", systemImage: "scissors")
            }
            .disabled(model.selection.isEmpty)
            .help("Cut (⌘X)")

            Button { model.paste(undoManager: undoManager) } label: {
                Label("Paste", systemImage: "doc.on.clipboard")
            }
            .disabled(!model.canPaste)
            .help("Paste (⌘V)")

            Button { model.trashSelection(undoManager: undoManager) } label: {
                Label("Move to Trash", systemImage: "trash")
            }
            .disabled(model.selection.isEmpty)
            .help("Move to Trash (⌘⌫)")

            Button { model.showHidden.toggle() } label: {
                Label(
                    model.showHidden ? "Hide Hidden Files" : "Show Hidden Files",
                    systemImage: model.showHidden ? "eye" : "eye.slash"
                )
            }
            .help("Show/Hide Hidden Files (⇧⌘.)")

            Button { model.showInspector.toggle() } label: {
                Label("Preview", systemImage: "sidebar.right")
            }
            .disabled(model.viewMode != .list)
            .help("Show/Hide Preview (⌥⌘I)")
        }
    }

    /// The column view has its own preview pane, so the inspector is only for the list view.
    private var inspectorBinding: Binding<Bool> {
        Binding(
            get: { model.showInspector && model.viewMode == .list },
            set: { model.showInspector = $0 }
        )
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )
    }
}

/// Newer macOS draws the toolbar itself and ignores `toolbarBackground`, so color themes also
/// paint the window behind a transparent title bar, which colors the toolbar area.
private struct WindowThemer: NSViewRepresentable {
    let color: NSColor?

    func makeNSView(context: Context) -> NSView {
        NSView()
    }

    func updateNSView(_ view: NSView, context: Context) {
        let color = color
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.titlebarAppearsTransparent = color != nil
            window.backgroundColor = color ?? .windowBackgroundColor
        }
    }
}

private extension View {
    /// Colors the window toolbar for color themes.
    @ViewBuilder
    func themeToolbar(_ color: NSColor?) -> some View {
        if let color {
            toolbarBackground(Color(nsColor: color), for: .windowToolbar)
                .toolbarBackground(.visible, for: .windowToolbar)
        } else {
            self
        }
    }
}
