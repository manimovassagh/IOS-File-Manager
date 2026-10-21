import AppKit
import SwiftUI

@main
struct FilesApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var clipboard = ClipboardController()

    var body: some Scene {
        WindowGroup {
            BrowserView(clipboard: clipboard)
                .frame(minWidth: 720, minHeight: 420)
        }
        .windowToolbarStyle(.unified)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched as a bare executable (`swift run`) rather than from an .app bundle.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }
}
