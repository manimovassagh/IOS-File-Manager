import AppKit
import CoreServices
import FileCore
import ImageIO
import SwiftUI

/// Large thumbnail and details for one file (column view's last pane and the list view's inspector).
struct FilePreview: View {
    let item: FileItem
    @StateObject private var loader = PreviewLoader()
    @ObservedObject private var settings = ThemeSettings.shared

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                content(imageHeight: Self.imageHeight(for: geometry.size))
            }
        }
        .themeBackground(settings.palette?.background)
        .themeForeground(settings.palette?.text)
        .task(id: item.url) {
            await loader.load(item.url)
        }
    }

    /// The image takes all the height the name, details and Open button don't need (about 300 pt),
    /// so everything fits without scrolling; never less than 200 pt.
    static func imageHeight(for size: CGSize) -> CGFloat {
        max(200, size.height - 300)
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
                .background(cardBackground, in: RoundedRectangle(cornerRadius: 10))
            }

            HStack(spacing: 10) {
                Button("Open") {
                    NSWorkspace.shared.open(item.url)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                if ThumbnailCache.isImage(item.url) {
                    Button {
                        copyImage()
                    } label: {
                        Label("Copy Image", systemImage: "photo.on.rectangle")
                    }
                    .controlSize(.large)
                    .help("Copy the picture itself, to paste into a chat, email or document")
                }

                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([item.url])
                } label: {
                    Label("Show in Finder", systemImage: "folder")
                }
                .controlSize(.large)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(18)
    }

    private var cardBackground: AnyShapeStyle {
        if let palette = settings.palette {
            return AnyShapeStyle(Color(nsColor: palette.card))
        }
        return AnyShapeStyle(.quaternary.opacity(0.5))
    }

    private func copyImage() {
        guard let image = NSImage(contentsOf: item.url) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
    }

    /// The preview image; drag it into another app (chat, browser, email) to share the file.
    @ViewBuilder
    private var thumbnail: some View {
        thumbnailImage
            .onDrag { NSItemProvider(contentsOf: item.url) ?? NSItemProvider() }
            .help("Drag into another app to share this file")
    }

    @ViewBuilder
    private var thumbnailImage: some View {
        if let image = loader.thumbnail {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                // A hairline border keeps white or transparent images visible on light backgrounds.
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.15), lineWidth: 1))
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
    /// The file being loaded. Results for any other file (a previous selection that finished
    /// late) are dropped, so they can't overwrite the current preview.
    private(set) var currentURL: URL?

    /// Large enough to stay sharp when the preview fills a big window.
    static let imageSize: CGFloat = 1600

    func load(_ url: URL) async {
        currentURL = url
        thumbnail = nil
        details = nil
        let loadedDetails = await Task.detached(priority: .userInitiated) { FileDetails(url: url) }.value
        guard currentURL == url else { return }
        details = loadedDetails

        let image = await ThumbnailCache.shared.thumbnail(for: url, size: Self.imageSize, modified: loadedDetails.modified)
        guard currentURL == url else { return }
        thumbnail = image
    }
}
