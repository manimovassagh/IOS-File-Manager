import Foundation

public enum DirectoryLister {
    /// Lists the immediate children of `directory`.
    public static func contents(of directory: URL, includeHidden: Bool) throws -> [FileItem] {
        let options: FileManager.DirectoryEnumerationOptions = includeHidden ? [] : [.skipsHiddenFiles]
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: FileItem.resourceKeys,
            options: options
        )
        return urls.compactMap { try? FileItem(url: $0) }
    }
}
