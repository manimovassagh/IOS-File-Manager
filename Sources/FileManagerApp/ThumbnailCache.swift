import AppKit
import QuickLookThumbnailing
import UniformTypeIdentifiers

/// Real thumbnails (via Quick Look) for images, videos and PDFs, generated in the background and cached.
@MainActor
final class ThumbnailCache {
    static let shared = ThumbnailCache()

    private let cache = NSCache<NSString, NSImage>()
    private var pending: [String: [(NSImage) -> Void]] = [:]

    private init() {
        cache.countLimit = 2_000
    }

    /// Whether `url` is a kind of file that has a meaningful thumbnail.
    static func supportsThumbnail(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .image) || type.conforms(to: .movie) || type.conforms(to: .pdf)
    }

    private static func key(_ url: URL, size: CGFloat, modified: Date?) -> String {
        "\(url.path)|\(Int(size))|\(modified?.timeIntervalSince1970 ?? 0)"
    }

    func cachedThumbnail(for url: URL, size: CGFloat, modified: Date?) -> NSImage? {
        cache.object(forKey: Self.key(url, size: size, modified: modified) as NSString)
    }

    /// Calls `completion` with the thumbnail once it's ready (not called if none can be made).
    func loadThumbnail(for url: URL, size: CGFloat, modified: Date?, completion: @escaping (NSImage) -> Void) {
        let key = Self.key(url, size: size, modified: modified)
        if let image = cache.object(forKey: key as NSString) {
            completion(image)
            return
        }
        if pending[key] != nil {
            pending[key]?.append(completion)
            return
        }
        pending[key] = [completion]

        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: size, height: size),
            scale: NSScreen.main?.backingScaleFactor ?? 2,
            representationTypes: .thumbnail
        )
        Task {
            let image = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).nsImage
            let callbacks = pending.removeValue(forKey: key) ?? []
            guard let image else { return }
            cache.setObject(image, forKey: key as NSString)
            callbacks.forEach { $0(image) }
        }
    }
}
