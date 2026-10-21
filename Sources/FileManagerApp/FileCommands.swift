import AppKit
import SwiftUI

/// File-menu commands for the frontmost browser window.
struct FileCommands: Commands {
    @FocusedObject private var model: BrowserModel?

    private var hasSelection: Bool { !(model?.selection.isEmpty ?? true) }
    private var undoManager: UndoManager? { NSApp.keyWindow?.undoManager }

    /// False while a text field (e.g. an inline rename) is being edited, so that
    /// shortcuts like ⌘⌫ never act on files while typing.
    private var isFileListActive: Bool {
        !(NSApp.keyWindow?.firstResponder is NSText)
    }

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("New Folder") {
                model?.newFolder(undoManager: undoManager)
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            .disabled(model == nil)

            Divider()

            Button("Duplicate") {
                guard isFileListActive else { return }
                model?.duplicateSelection(undoManager: undoManager)
            }
            .keyboardShortcut("d", modifiers: .command)
            .disabled(!hasSelection)

            Button("Rename") {
                guard isFileListActive else { return }
                model?.renameSelection()
            }
            .disabled(model?.selection.count != 1)

            Divider()

            Button("Move to Trash") {
                guard isFileListActive else { return }
                model?.trashSelection(undoManager: undoManager)
            }
            .keyboardShortcut(.delete, modifiers: .command)
            .disabled(!hasSelection)

            Button("Delete Immediately…") {
                guard isFileListActive else { return }
                model?.deleteSelectionImmediately()
            }
            .keyboardShortcut(.delete, modifiers: [.command, .option])
            .disabled(!hasSelection)

            Divider()

            Button("Open in Terminal") {
                model?.openTerminal()
            }
            .keyboardShortcut("t", modifiers: [.command, .option])
            .disabled(model == nil)
        }
    }
}
