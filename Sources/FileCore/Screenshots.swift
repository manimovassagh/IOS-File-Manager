import Darwin
import Foundation

/// Where macOS saves screenshots, and which files are screenshots.
public enum Screenshots {
    /// The extended attribute macOS writes on every screenshot and screen recording.
    static let screenCaptureAttribute = "com.apple.metadata:kMDItemIsScreenCapture"

    /// English name prefixes, used when the attribute is missing (e.g. files copied from elsewhere).
    static let namePrefixes = ["Screenshot ", "Screen Shot ", "Screen Recording "]

    /// Tests point this at a temporary folder instead of the real screenshot location.
    nonisolated(unsafe) public static var folderOverride: URL?

    /// The folder screenshots are saved to (System Settings / Screenshot app "Save to"); Desktop by default.
    public static var folder: URL {
        if let folderOverride {
            return folderOverride
        }
        let defaults = UserDefaults(suiteName: "com.apple.screencapture")
        if let path = defaults?.string(forKey: "location"), !path.isEmpty {
            let expanded = (path as NSString).expandingTildeInPath
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory), isDirectory.boolValue {
                return URL(fileURLWithPath: expanded, isDirectory: true)
            }
        }
        return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop", isDirectory: true)
    }

    public static func isScreenshot(_ url: URL) -> Bool {
        if getxattr(url.path, screenCaptureAttribute, nil, 0, 0, XATTR_NOFOLLOW) >= 0 {
            return true
        }
        let name = url.lastPathComponent
        return namePrefixes.contains { name.hasPrefix($0) }
    }

    /// Screenshots directly inside `folder`.
    public static func contents(of folder: URL) throws -> [FileItem] {
        try DirectoryLister.contents(of: folder, includeHidden: false)
            .filter { !$0.isDirectory && isScreenshot($0.url) }
    }
}
