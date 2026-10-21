import AppKit
import SwiftUI

/// Colors for every surface of the app. `nil` palette (the Native theme) means "use system colors".
struct ThemePalette: Equatable {
    let isDark: Bool
    let background: NSColor
    let sidebar: NSColor
    let alternateRow: NSColor
    /// Path bar, status bar, list header and toolbar.
    let bar: NSColor
    /// Cards inside the preview pane.
    let card: NSColor
    let separator: NSColor
    let text: NSColor
    let secondaryText: NSColor
    let accent: NSColor
    /// Text on top of the accent-colored selection.
    let selectionText: NSColor
}

/// Editor-style color themes, like the ones in VS Code and Neovim.
enum ColorTheme: String, CaseIterable, Identifiable {
    case native
    case dracula
    case nord
    case tokyoNight
    case catppuccinMocha
    case oneDark
    case gruvbox
    case rosePine
    case catppuccinLatte
    case solarizedLight
    case githubLight

    var id: String { rawValue }

    var title: String {
        switch self {
        case .native: return "Native"
        case .dracula: return "Dracula"
        case .nord: return "Nord"
        case .tokyoNight: return "Tokyo Night"
        case .catppuccinMocha: return "Catppuccin Mocha"
        case .oneDark: return "One Dark"
        case .gruvbox: return "Gruvbox"
        case .rosePine: return "Rosé Pine"
        case .catppuccinLatte: return "Catppuccin Latte"
        case .solarizedLight: return "Solarized Light"
        case .githubLight: return "GitHub Light"
        }
    }

    var palette: ThemePalette? {
        switch self {
        case .native:
            return nil
        case .dracula:
            return ThemePalette(
                isDark: true, background: hex(0x282A36), sidebar: hex(0x21222C), alternateRow: hex(0x2C2E3B),
                bar: hex(0x21222C), card: hex(0x343746), separator: hex(0x44475A),
                text: hex(0xF8F8F2), secondaryText: hex(0x9EA8C7), accent: hex(0xBD93F9), selectionText: hex(0x1E1F29)
            )
        case .nord:
            return ThemePalette(
                isDark: true, background: hex(0x2E3440), sidebar: hex(0x272C36), alternateRow: hex(0x323845),
                bar: hex(0x272C36), card: hex(0x3B4252), separator: hex(0x434C5E),
                text: hex(0xECEFF4), secondaryText: hex(0xA3ADBF), accent: hex(0x88C0D0), selectionText: hex(0x2E3440)
            )
        case .tokyoNight:
            return ThemePalette(
                isDark: true, background: hex(0x1A1B26), sidebar: hex(0x16161E), alternateRow: hex(0x1E1F2C),
                bar: hex(0x16161E), card: hex(0x24283B), separator: hex(0x292E42),
                text: hex(0xC0CAF5), secondaryText: hex(0x7A82AE), accent: hex(0x7AA2F7), selectionText: hex(0x16161E)
            )
        case .catppuccinMocha:
            return ThemePalette(
                isDark: true, background: hex(0x1E1E2E), sidebar: hex(0x181825), alternateRow: hex(0x232334),
                bar: hex(0x181825), card: hex(0x313244), separator: hex(0x313244),
                text: hex(0xCDD6F4), secondaryText: hex(0xA6ADC8), accent: hex(0xCBA6F7), selectionText: hex(0x1E1E2E)
            )
        case .oneDark:
            return ThemePalette(
                isDark: true, background: hex(0x282C34), sidebar: hex(0x21252B), alternateRow: hex(0x2C313A),
                bar: hex(0x21252B), card: hex(0x323842), separator: hex(0x3E4451),
                text: hex(0xD7DAE0), secondaryText: hex(0x8B92A0), accent: hex(0x61AFEF), selectionText: hex(0x1E2127)
            )
        case .gruvbox:
            return ThemePalette(
                isDark: true, background: hex(0x282828), sidebar: hex(0x1D2021), alternateRow: hex(0x2E2C2B),
                bar: hex(0x1D2021), card: hex(0x3C3836), separator: hex(0x3C3836),
                text: hex(0xEBDBB2), secondaryText: hex(0xA89984), accent: hex(0xFABD2F), selectionText: hex(0x282828)
            )
        case .rosePine:
            return ThemePalette(
                isDark: true, background: hex(0x191724), sidebar: hex(0x1F1D2E), alternateRow: hex(0x1D1B2A),
                bar: hex(0x1F1D2E), card: hex(0x26233A), separator: hex(0x26233A),
                text: hex(0xE0DEF4), secondaryText: hex(0x908CAA), accent: hex(0xC4A7E7), selectionText: hex(0x191724)
            )
        case .catppuccinLatte:
            return ThemePalette(
                isDark: false, background: hex(0xEFF1F5), sidebar: hex(0xE6E9EF), alternateRow: hex(0xE9ECF2),
                bar: hex(0xE6E9EF), card: hex(0xDCE0E8), separator: hex(0xCCD0DA),
                text: hex(0x4C4F69), secondaryText: hex(0x6C6F85), accent: hex(0x8839EF), selectionText: hex(0xFFFFFF)
            )
        case .solarizedLight:
            return ThemePalette(
                isDark: false, background: hex(0xFDF6E3), sidebar: hex(0xEEE8D5), alternateRow: hex(0xF6EFDB),
                bar: hex(0xEEE8D5), card: hex(0xEEE8D5), separator: hex(0xE0D8C0),
                text: hex(0x586E75), secondaryText: hex(0x93A1A1), accent: hex(0x268BD2), selectionText: hex(0xFFFFFF)
            )
        case .githubLight:
            return ThemePalette(
                isDark: false, background: hex(0xFFFFFF), sidebar: hex(0xF6F8FA), alternateRow: hex(0xF6F8FA),
                bar: hex(0xF6F8FA), card: hex(0xF6F8FA), separator: hex(0xD0D7DE),
                text: hex(0x1F2328), secondaryText: hex(0x656D76), accent: hex(0x0969DA), selectionText: hex(0xFFFFFF)
            )
        }
    }
}

private func hex(_ value: UInt32) -> NSColor {
    NSColor(
        srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
        green: CGFloat((value >> 8) & 0xFF) / 255,
        blue: CGFloat(value & 0xFF) / 255,
        alpha: 1
    )
}

extension View {
    /// Paints `color` behind the view when a color theme is active; does nothing for the Native theme.
    @ViewBuilder
    func themeBackground(_ color: NSColor?) -> some View {
        if let color {
            background(Color(nsColor: color))
        } else {
            self
        }
    }

    /// Sets the primary text color for a color theme (secondary/tertiary styles derive from it).
    @ViewBuilder
    func themeForeground(_ color: NSColor?) -> some View {
        if let color {
            foregroundStyle(Color(nsColor: color))
        } else {
            self
        }
    }
}

/// Theme-colored list header for the AppKit table.
final class ThemedHeaderCell: NSTableHeaderCell {
    var palette: ThemePalette?
    /// `true` ascending, `false` descending, `nil` not the sort column.
    var sortAscending: Bool?

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        guard let palette else {
            super.draw(withFrame: cellFrame, in: controlView)
            return
        }
        palette.bar.setFill()
        cellFrame.fill()
        palette.separator.setFill()
        NSRect(x: cellFrame.minX, y: cellFrame.maxY - 1, width: cellFrame.width, height: 1).fill()
        NSRect(x: cellFrame.maxX - 1, y: cellFrame.minY + 5, width: 1, height: cellFrame.height - 10).fill()
        drawInterior(withFrame: cellFrame, in: controlView)
    }

    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        guard let palette else {
            super.drawInterior(withFrame: cellFrame, in: controlView)
            return
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: palette.secondaryText,
            .paragraphStyle: paragraph,
        ]
        let title = stringValue as NSString
        let height = title.size(withAttributes: attributes).height
        let textRect = NSRect(
            x: cellFrame.minX + 6, y: cellFrame.midY - height / 2,
            width: cellFrame.width - (sortAscending == nil ? 12 : 26), height: height
        )
        title.draw(in: textRect, withAttributes: attributes)
        if let sortAscending {
            drawSortIndicator(withFrame: cellFrame, in: controlView, ascending: sortAscending, priority: 0)
        }
    }
}
