import AppKit
import CoreServices
import FileCore
import ImageIO
import QuickLookThumbnailing
import SwiftUI

/// Large thumbnail and details for one file (column view's last pane and the list view's inspector).
struct FilePreview: View {
    let item: FileItem
    @StateObject private var loader = PreviewLoader()

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                content(imageHeight: Self.imageHeight(for: geometry.size))
            }
        }
        .task(id: item.url) {
            await loader.load(item.url)
        }
    }

    /// The image takes most of the pane: two thirds of its height (at least 220 pt).
    static func imageHeight(for size: CGSize) -> CGFloat {
        max(220, size.height * 0.66)
    }

    private func content(imageHeight: CGFloat) -> some View {
        VStack(spacing: 14) {
            thumbnail
                .frame(maxWidth: .infinity)
                .frame(height: imageHeight)

            VStack(spacing: 4) {
                Text(item.name)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                Text(summary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if let details = loader.details {
                VStack(spacing: 6) {
                    if let created = details.created { row("Created", created.formatted(date: .abbreviated, time: .shortened)) }
                    if let modified = details.modified { row("Modified", modified.formatted(date: .abbreviated, time: .shortened)) }
                    if let lastOpened = details.lastOpened { row("Last opened", lastOpened.formatted(date: .abbreviated, time: .shortened)) }
                    if let dimensions = details.dimensions { row("Dimensions", dimensions) }
                    if let itemCount = details.itemCount { row("Contains", "\(itemCount) \(itemCount == 1 ? "item" : "items")") }
                    row("Where", item.url.deletingLastPathComponent().path)
                }
                .padding(12)
                .frame(maxWidth: 460)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
            }

            Button("Open") {
                NSWorkspace.shared.open(item.url)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity)
        .padding(18)
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let image = loader.thumbnail {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
        } else {
            Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path))
                .resizable()
                .aspectRatio(contentMode: .fit)
                .padding(30)
        }
    }

    private var summary: String {
        var parts = [item.kind]
        if let size = item.size {
            parts.append(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
        }
        return parts.joined(separator: " — ")
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 84, alignment: .trailing)
            Text(value)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(3)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
        .font(.caption)
    }
}

/// Shown in the inspector when there isn't exactly one item selected.
struct PreviewPlaceholder: View {
    let selectedCount: Int

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: selectedCount == 0 ? "eye" : "square.stack.3d.up")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.tertiary)
            Text(selectedCount == 0 ? "Select a file to preview it" : "\(selectedCount) items selected")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct FileDetails: Sendable {
    var created: Date?
    var modified: Date?
    var lastOpened: Date?
    var dimensions: String?
    var itemCount: Int?

    init(url: URL) {
        let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey, .isDirectoryKey, .isPackageKey])
        created = values?.creationDate
        modified = values?.contentModificationDate

        if let metadata = MDItemCreateWithURL(nil, url as CFURL) {
            lastOpened = MDItemCopyAttribute(metadata, kMDItemLastUsedDate) as? Date
        }

        if values?.isDirectory == true, values?.isPackage != true {
            itemCount = (try? FileManager.default.contentsOfDirectory(atPath: url.path))?.filter { !$0.hasPrefix(".") }.count
        } else if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int {
            dimensions = "\(width) × \(height)"
        }
    }
}

@MainActor
final class PreviewLoader: ObservableObject {
    @Published private(set) var thumbnail: NSImage?
    @Published private(set) var details: FileDetails?

    func load(_ url: URL) async {
        thumbnail = nil
        details = nil
        details = await Task.detached(priority: .userInitiated) { FileDetails(url: url) }.value

        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            // Large enough to stay sharp when the preview fills a big window.
            size: CGSize(width: 1600, height: 1200),
            scale: NSScreen.main?.backingScaleFactor ?? 2,
            representationTypes: .thumbnail
        )
        if let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) {
            guard !Task.isCancelled else { return }
            thumbnail = representation.nsImage
        }
    }
}
