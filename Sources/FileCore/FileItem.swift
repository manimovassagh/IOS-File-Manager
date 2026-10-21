import Foundation

/// A snapshot of one entry in a directory listing.
public struct FileItem: Identifiable, Hashable, Sendable {
    public let url: URL
    public let name: String
    public let isDirectory: Bool
    public let isPackage: Bool
    public let isHidden: Bool
    public let isSymbolicLink: Bool
    /// File size in bytes; `nil` for directories.
    public let size: Int64?
    public let dateModified: Date?
    /// Localized type description, e.g. "PDF document".
    public let kind: String
    /// True for folders that open in place (packages such as `.app` bundles open with an app instead).
    public let isBrowsable: Bool
    /// The URL to navigate to when browsing; resolves symbolic links to folders.
    public let browseURL: URL

    public var id: URL { url }

    static let resourceKeys: [URLResourceKey] = [
        .nameKey, .isDirectoryKey, .isPackageKey, .isHiddenKey, .isSymbolicLinkKey,
        .fileSizeKey, .contentModificationDateKey, .localizedTypeDescriptionKey,
    ]

    public init(url: URL) throws {
        let values = try url.resourceValues(forKeys: Set(Self.resourceKeys))
        self.url = url
        name = values.name ?? url.lastPathComponent
        isDirectory = values.isDirectory ?? false
        isPackage = values.isPackage ?? false
        isHidden = values.isHidden ?? false
        isSymbolicLink = values.isSymbolicLink ?? false
        size = isDirectory ? nil : values.fileSize.map(Int64.init)
        dateModified = values.contentModificationDate
        kind = values.localizedTypeDescription ?? (isDirectory ? "Folder" : "Document")

        if isSymbolicLink {
            let target = url.resolvingSymlinksInPath()
            let targetValues = try? target.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
            isBrowsable = (targetValues?.isDirectory ?? false) && !(targetValues?.isPackage ?? false)
            browseURL = target
        } else {
            isBrowsable = isDirectory && !isPackage
            browseURL = url
        }
    }
}
