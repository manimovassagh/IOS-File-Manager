import AppKit

/// Some menu shortcuts are also text-editing keys: ⌘⌫ (delete to start of line) is Move to Trash,
/// ⌘↑ (go to start) is Enclosing Folder. While a text field is being edited (the filter, an inline
/// rename), send those keys to the text field instead of letting the menu act on files.
enum TextEditingKeys {
    /// Delete, forward delete, ↑, ↓, ←, →.
    private static let keyCodes: Set<UInt16> = [51, 117, 126, 125, 123, 124]

    static func install() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let handled = MainActor.assumeIsolated { sendToTextField(event) }
            return handled ? nil : event
        }
    }

    @MainActor
    private static func sendToTextField(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command), keyCodes.contains(event.keyCode),
              let editor = (event.window ?? NSApp.keyWindow)?.firstResponder as? NSTextView,
              editor.isEditable
        else { return false }
        editor.keyDown(with: event)
        return true
    }
}
