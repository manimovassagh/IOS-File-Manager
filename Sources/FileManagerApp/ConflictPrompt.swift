import AppKit
import FileCore

/// Asks the user what to do when a pasted item's name is already taken.
/// One instance is used per paste, so "Apply to all" lasts for that paste only.
@MainActor
final class ConflictPrompt {
    private var rememberedResolution: ConflictResolution?

    func resolve(_ conflict: FileConflict) -> ConflictResolution {
        if let rememberedResolution {
            return rememberedResolution
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "An item named “\(conflict.existing.lastPathComponent)” already exists in this location."
        alert.informativeText = "Do you want to replace it with the one you’re pasting?"
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Keep Both")
        alert.addButton(withTitle: "Skip")
        alert.addButton(withTitle: "Stop")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Apply to all"

        let resolution: ConflictResolution
        switch alert.runModal() {
        case .alertFirstButtonReturn: resolution = .replace
        case .alertSecondButtonReturn: resolution = .keepBoth
        case .alertThirdButtonReturn: resolution = .skip
        default: resolution = .stop
        }

        if alert.suppressionButton?.state == .on, resolution != .stop {
            rememberedResolution = resolution
        }
        return resolution
    }
}
