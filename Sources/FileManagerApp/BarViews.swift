import AppKit
import FileCore
import SwiftUI

/// Clickable breadcrumb of the current folder's path.
struct PathBar: View {
    let components: [PathComponent]
    let onSelect: (URL) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(Array(components.enumerated()), id: \.element.id) { index, component in
                    if index > 0 {
                        Image(systemName: "chevron.compact.right")
                            .font(.callout)
                            .foregroundStyle(.tertiary)
                    }
                    let isLast = index == components.count - 1
                    Button {
                        if let url = component.url { onSelect(url) }
                    } label: {
                        HStack(spacing: 5) {
                            if let systemImage = component.systemImage {
                                Image(systemName: systemImage)
                                    .foregroundStyle(.tint)
                            } else if let url = component.url {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                                    .resizable()
                                    .frame(width: 15, height: 15)
                            }
                            Text(component.title)
                                .fontWeight(isLast ? .semibold : .regular)
                        }
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(isLast ? AnyShapeStyle(.tint.opacity(0.14)) : AnyShapeStyle(.clear), in: Capsule())
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help(component.url?.path ?? component.title)
                }
            }
            .padding(.horizontal, 8)
        }
        .font(.callout)
        .frame(height: 30)
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
                .foregroundStyle(.tint)
            Text(summary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button("Paste Here", action: onPaste)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(!canPaste)
            Button(action: onClear) {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.borderless)
            .help("Clear the clipboard")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
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
