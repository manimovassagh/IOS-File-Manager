import AppKit
import FileCore
import SwiftUI

/// File, View and Go menu commands for the frontmost browser window.
struct FileCommands: Commands {
    @FocusedObject private var model: BrowserModel?
    @ObservedObject var settings: ThemeSettings

    private var hasSelection: Bool { !(model?.selection.isEmpty ?? true) }
    private var undoManager: UndoManager? { NSApp.keyWindow?.undoManager }

    /// False while a text field (an inline rename or the filter field) is being edited, so that
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
            .disabled(!(model?.acceptsNewItems ?? false))

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
            .keyboardShortcut("r", modifiers: .command)
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

        CommandGroup(before: .toolbar) {
            // Switch color themes from the menu bar at any time, like in VS Code.
            Picker("Theme", selection: $settings.colorTheme) {
                ForEach(ColorTheme.allCases) { theme in
                    Text(theme.title).tag(theme)
                }
            }

            Divider()

            Button("as List") { model?.viewMode = .list }
                .keyboardShortcut("1", modifiers: .command)
            Button("as Columns") { model?.viewMode = .columns }
                .keyboardShortcut("3", modifiers: .command)

            Divider()

            Menu("Sort By") {
                ForEach(FileSort.Key.allCases, id: \.self) { key in
                    Button {
                        model?.sort.key = key
                    } label: {
                        if model?.sort.key == key {
                            Label(key.title, systemImage: "checkmark")
                        } else {
                            Text(key.title)
                        }
                    }
                }
                Divider()
                Button(model?.sort.ascending == false ? "Ascending" : "Descending") {
                    model?.sort.ascending.toggle()
                }
            }
            .disabled(model == nil)

            Button(model?.showInspector == true ? "Hide Preview" : "Show Preview") {
                model?.showInspector.toggle()
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
            .disabled(model?.viewMode != .list)

            Button(model?.showHidden == true ? "Hide Hidden Files" : "Show Hidden Files") {
                model?.showHidden.toggle()
            }
            .keyboardShortcut(".", modifiers: [.command, .shift])
            .disabled(model == nil)

            Divider()
        }

        CommandMenu("Go") {
            Button("Back") { model?.goBack() }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(!(model?.canGoBack ?? false))
            Button("Forward") { model?.goForward() }
                .keyboardShortcut("]", modifiers: .command)
                .disabled(!(model?.canGoForward ?? false))
            Button("Enclosing Folder") {
                guard isFileListActive else { return }
                model?.goUp()
            }
            .keyboardShortcut(.upArrow, modifiers: .command)
            .disabled(!(model?.canGoUp ?? false))

            Divider()

            ForEach(GoShortcut.all) { shortcut in
                Button(shortcut.title) { model?.navigate(to: shortcut.location()) }
                    .keyboardShortcut(shortcut.key, modifiers: shortcut.modifiers)
                    .disabled(model == nil)
            }
        }
    }
}

/// Finder-style Go menu shortcuts.
private struct GoShortcut: Identifiable {
    let title: String
    let key: KeyEquivalent
    let modifiers: EventModifiers
    let location: () -> Location

    var id: String { title }

    static var all: [GoShortcut] { [
        GoShortcut(title: "Recents", key: "f", modifiers: [.command, .shift]) { .recents },
        GoShortcut(title: "Documents", key: "o", modifiers: [.command, .shift]) { folder(.documentDirectory) },
        GoShortcut(title: "Desktop", key: "d", modifiers: [.command, .shift]) { folder(.desktopDirectory) },
        GoShortcut(title: "Screenshots", key: "s", modifiers: [.command, .shift]) { .screenshots },
        GoShortcut(title: "Downloads", key: "l", modifiers: [.command, .option]) { folder(.downloadsDirectory) },
        GoShortcut(title: "Home", key: "h", modifiers: [.command, .shift]) {
            .folder(FileManager.default.homeDirectoryForCurrentUser)
        },
        GoShortcut(title: "Applications", key: "a", modifiers: [.command, .shift]) {
            .folder(URL(fileURLWithPath: "/Applications", isDirectory: true))
        },
    ] }

    private static func folder(_ directory: FileManager.SearchPathDirectory) -> Location {
        let url = FileManager.default.urls(for: directory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return .folder(url)
    }
}

extension FileSort.Key {
    var title: String {
        switch self {
        case .name: return "Name"
        case .dateModified: return "Date Modified"
        case .size: return "Size"
        case .kind: return "Kind"
        }
    }
}
