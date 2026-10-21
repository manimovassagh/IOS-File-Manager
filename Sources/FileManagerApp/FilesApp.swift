import AppKit
import SwiftUI

@main
struct FilesApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var clipboard = ClipboardController()
    @StateObject private var settings = ThemeSettings.shared

    var body: some Scene {
        WindowGroup {
            BrowserView(clipboard: clipboard, settings: settings)
                .frame(minWidth: 760, minHeight: 440)
        }
        .windowToolbarStyle(.unified)
        .commands { FileCommands(settings: settings) }

        Settings {
            SettingsView(settings: settings)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched as a bare executable (`swift run`) rather than from an .app bundle.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        MainActor.assumeIsolated {
            ThemeSettings.shared.applyAppearance()
        }
    }
}
