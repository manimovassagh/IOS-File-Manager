import AppKit
import FileCore
import SwiftUI

/// Clickable breadcrumb of the current folder's path.
struct PathBar: View {
    let url: URL
    let onSelect: (URL) -> Void

    private var components: [URL] {
        var result: [URL] = []
        var current = url.standardizedFileURL
        for _ in 0..<128 {
            result.insert(current, at: 0)
            if current.path == "/" { break }
            current = current.deletingLastPathComponent().standardizedFileURL
        }
        return result
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(Array(components.enumerated()), id: \.offset) { index, component in
                    if index > 0 {
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Button {
                        onSelect(component)
                    } label: {
                        HStack(spacing: 4) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: component.path))
                                .resizable()
                                .frame(width: 14, height: 14)
                            Text(FileManager.default.displayName(atPath: component.path))
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
        }
        .font(.callout)
        .frame(height: 26)
    }
}

/// Shows what is on the clipboard, with one-click "Paste Here" and a way to cancel.
struct ClipboardBar: View {
    let contents: FileClipboard
    let canPaste: Bool
    let onPaste: () -> Void
    let onClear: () -> Void

    private var summary: String {
        let what = contents.urls.count == 1
            ? "“\(contents.urls[0].lastPathComponent)”"
            : "\(contents.urls.count) items"
        switch contents.mode {
        case .copy: return "Copied \(what) — paste to make a copy here"
        case .cut: return "Cut \(what) — paste to move here"
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: contents.mode == .cut ? "scissors" : "doc.on.doc")
                .foregroundStyle(Color.accentColor)
            Text(summary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button("Paste Here", action: onPaste)
                .disabled(!canPaste)
            Button(action: onClear) {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.borderless)
            .help("Clear the clipboard")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.accentColor.opacity(0.08))
    }
}

struct StatusBar: View {
    let itemCount: Int
    let selectedCount: Int
    let availableCapacity: Int64?
    let activity: String?
    let progress: OperationProgress?
    let onCancel: () -> Void

    private var text: String {
        var parts = ["\(itemCount) \(itemCount == 1 ? "item" : "items")"]
        if selectedCount > 0 {
            parts.append("\(selectedCount) selected")
        }
        if let availableCapacity {
            parts.append("\(ByteCountFormatter.string(fromByteCount: availableCapacity, countStyle: .file)) available")
        }
        return parts.joined(separator: ", ")
    }

    var body: some View {
        HStack(spacing: 6) {
            if let activity {
                if let progress, progress.total > 1 {
                    ProgressView(value: progress.fraction)
                        .frame(width: 120)
                    Text("\(activity): \(min(progress.completed + 1, progress.total)) of \(progress.total)")
                    if !progress.currentName.isEmpty {
                        Text("— \(progress.currentName)")
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: 200, alignment: .leading)
                    }
                } else {
                    ProgressView().controlSize(.small)
                    Text("\(activity)…")
                }
                if progress != nil {
                    Button("Cancel", action: onCancel)
                        .buttonStyle(.link)
                        .help("Stop after the current item")
                }
            }
            Spacer()
            Text(text)
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .frame(height: 22)
    }
}
