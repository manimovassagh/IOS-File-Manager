import AppKit
import ImageIO
import QuickLookThumbnailing
import UniformTypeIdentifiers

/// Thumbnails for images, videos and PDFs, generated in the background and cached.
///
/// Images are decoded directly with ImageIO: it's fast and works the same for every image,
/// light or dark. Quick Look is used for everything else (PDFs, videos) and as a fallback; it
/// can fail now and then (for example while a new screenshot is still being written), so
/// failed attempts are retried instead of leaving the generic file icon.
@MainActor
final class ThumbnailCache {
    static let shared = ThumbnailCache()

    private let cache = NSCache<NSString, NSImage>()
    private var pending: [String: [(NSImage?) -> Void]] = [:]

    private init() {
        cache.countLimit = 2_000
    }

    nonisolated static func isImage(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) ?? false
    }

    /// Whether `url` is a kind of file that has a meaningful thumbnail.
    nonisolated static func supportsThumbnail(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .image) || type.conforms(to: .movie) || type.conforms(to: .pdf)
    }

    private static func key(_ url: URL, size: CGFloat, modified: Date?) -> String {
        "\(url.path)|\(Int(size))|\(modified?.timeIntervalSince1970 ?? 0)"
    }

    func cachedThumbnail(for url: URL, size: CGFloat, modified: Date?) -> NSImage? {
        cache.object(forKey: Self.key(url, size: size, modified: modified) as NSString)
    }

    /// Calls `completion` with the thumbnail once it's ready, or with `nil` if none can be made.
    /// `size` is in points; `framed` adds rounded corners and a hairline border (for list rows,
    /// so white images stay visible on light backgrounds).
    func loadThumbnail(
        for url: URL, size: CGFloat, modified: Date?, framed: Bool = false,
        completion: @escaping (NSImage?) -> Void
    ) {
        let key = Self.key(url, size: size, modified: modified) + (framed ? "|framed" : "")
        if let image = cache.object(forKey: key as NSString) {
            completion(image)
            return
        }
        if pending[key] != nil {
            pending[key]?.append(completion)
            return
        }
        pending[key] = [completion]

        let pixelSize = Int(size * (NSScreen.main?.backingScaleFactor ?? 2))
        Task {
            var cgImage = await Self.makeThumbnail(for: url, maxPixelSize: pixelSize)
            if framed, let thumbnail = cgImage {
                cgImage = Self.framed(thumbnail) ?? thumbnail
            }
            let image = cgImage.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
            let callbacks = pending.removeValue(forKey: key) ?? []
            if let image {
                cache.setObject(image, forKey: key as NSString)
            }
            callbacks.forEach { $0(image) }
        }
    }

    func thumbnail(for url: URL, size: CGFloat, modified: Date?) async -> NSImage? {
        await withCheckedContinuation { continuation in
            loadThumbnail(for: url, size: size, modified: modified) { continuation.resume(returning: $0) }
        }
    }

    /// Like `cachedThumbnail` for list rows (framed).
    func cachedRowThumbnail(for url: URL, size: CGFloat, modified: Date?) -> NSImage? {
        cache.object(forKey: (Self.key(url, size: size, modified: modified) + "|framed") as NSString)
    }

    // MARK: - Generating

    nonisolated static func makeThumbnail(for url: URL, maxPixelSize: Int) async -> CGImage? {
        if isImage(url) {
            // A screenshot that was just taken may still be being written: try a few times.
            for attempt in 0..<3 {
                let image = await Task.detached(priority: .userInitiated) {
                    imageIOThumbnail(for: url, maxPixelSize: maxPixelSize)
                }.value
                if let image { return image }
                if attempt < 2 { try? await Task.sleep(for: .milliseconds(400)) }
            }
        }
        return await quickLookThumbnail(for: url, maxPixelSize: maxPixelSize)
    }

    nonisolated static func imageIOThumbnail(for url: URL, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(maxPixelSize, 16),
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    nonisolated static func quickLookThumbnail(for url: URL, maxPixelSize: Int) async -> CGImage? {
        let side = CGFloat(maxPixelSize) / 2
        let request = QLThumbnailGenerator.Request(
            fileAt: url, size: CGSize(width: side, height: side), scale: 2, representationTypes: .thumbnail
        )
        for attempt in 0..<2 {
            if let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) {
                return representation.cgImage
            }
            if attempt == 0 { try? await Task.sleep(for: .milliseconds(500)) }
        }
        return nil
    }

    /// Rounded corners and a hairline border, so white or transparent images don't disappear.
    nonisolated static func framed(_ image: CGImage) -> CGImage? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0, let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        let shortSide = CGFloat(min(width, height))
        let line = max(1, shortSide / 60)
        let radius = max(2, shortSide * 0.06)
        let path = CGPath(
            roundedRect: rect.insetBy(dx: line / 2, dy: line / 2),
            cornerWidth: radius, cornerHeight: radius, transform: nil
        )
        context.addPath(path)
        context.clip()
        context.draw(image, in: rect)
        context.resetClip()
        context.addPath(path)
        context.setStrokeColor(CGColor(gray: 0, alpha: 0.22))
        context.setLineWidth(line)
        context.strokePath()
        return context.makeImage()
    }
}
