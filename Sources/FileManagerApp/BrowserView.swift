import AppKit
import FileCore
import SwiftUI

struct BrowserView: View {
    @ObservedObject var clipboard: ClipboardController
    @StateObject private var model: BrowserModel
    @Environment(\.undoManager) private var undoManager

    init(clipboard: ClipboardController) {
        self.clipboard = clipboard
        _model = StateObject(wrappedValue: BrowserModel(clipboard: clipboard))
    }

    var body: some View {
        NavigationSplitView {
            SidebarView(currentURL: model.currentURL) { model.navigate(to: $0) }
        } detail: {
            VStack(spacing: 0) {
                FileTableView(model: model, cutPaths: clipboard.cutPaths)
                Divider()
                PathBar(url: model.currentURL) { model.navigate(to: $0) }
                if let contents = clipboard.contents {
                    Divider()
                    ClipboardBar(
                        contents: contents,
                        canPaste: model.canPaste,
                        onPaste: { model.paste(undoManager: undoManager) },
                        onClear: { clipboard.clear() }
                    )
                }
                Divider()
                StatusBar(
                    itemCount: model.items.count,
                    selectedCount: model.selection.count,
                    availableCapacity: model.availableCapacity,
                    activity: model.activity
                )
            }
        }
        .navigationTitle(model.title)
        .toolbar { toolbar }
        .alert("Something went wrong", isPresented: errorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            clipboard.refreshFromPasteboard()
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button { model.goBack() } label: {
                Label("Back", systemImage: "chevron.left")
            }
            .disabled(!model.canGoBack)
            .keyboardShortcut("[", modifiers: .command)
            .help("Back (⌘[)")

            Button { model.goForward() } label: {
                Label("Forward", systemImage: "chevron.right")
            }
            .disabled(!model.canGoForward)
            .keyboardShortcut("]", modifiers: .command)
            .help("Forward (⌘])")

            Button { model.goUp() } label: {
                Label("Enclosing Folder", systemImage: "arrow.up")
            }
            .disabled(!model.canGoUp)
            .keyboardShortcut(.upArrow, modifiers: .command)
            .help("Enclosing Folder (⌘↑)")
        }

        ToolbarItemGroup(placement: .primaryAction) {
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
            .keyboardShortcut(".", modifiers: [.command, .shift])
            .help("Show/Hide Hidden Files (⇧⌘.)")
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )
    }
}
