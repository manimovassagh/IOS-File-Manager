import AppKit
import SwiftUI

enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

/// Accent color used for selection, highlights and controls.
enum AppTheme: String, CaseIterable, Identifiable {
    case violet, ocean, teal, forest, sunset, rose, graphite, system

    var id: String { rawValue }

    var title: String {
        switch self {
        case .violet: return "Violet"
        case .ocean: return "Ocean"
        case .teal: return "Teal"
        case .forest: return "Forest"
        case .sunset: return "Sunset"
        case .rose: return "Rose"
        case .graphite: return "Graphite"
        case .system: return "System accent color"
        }
    }

    var nsColor: NSColor {
        switch self {
        case .violet: return NSColor(srgbRed: 0.45, green: 0.36, blue: 0.98, alpha: 1)
        case .ocean: return NSColor(srgbRed: 0.10, green: 0.50, blue: 0.98, alpha: 1)
        case .teal: return NSColor(srgbRed: 0.05, green: 0.62, blue: 0.66, alpha: 1)
        case .forest: return NSColor(srgbRed: 0.18, green: 0.62, blue: 0.33, alpha: 1)
        case .sunset: return NSColor(srgbRed: 0.96, green: 0.48, blue: 0.13, alpha: 1)
        case .rose: return NSColor(srgbRed: 0.91, green: 0.27, blue: 0.50, alpha: 1)
        case .graphite: return NSColor(srgbRed: 0.45, green: 0.47, blue: 0.52, alpha: 1)
        case .system: return .controlAccentColor
        }
    }

    var color: Color { Color(nsColor: nsColor) }
}

enum RowSize: String, CaseIterable, Identifiable {
    case compact, regular, large

    var id: String { rawValue }

    var title: String {
        switch self {
        case .compact: return "Compact"
        case .regular: return "Regular"
        case .large: return "Large"
        }
    }

    var rowHeight: CGFloat {
        switch self {
        case .compact: return 22
        case .regular: return 28
        case .large: return 36
        }
    }

    var iconSize: CGFloat {
        switch self {
        case .compact: return 16
        case .regular: return 20
        case .large: return 26
        }
    }

    var fontSize: CGFloat {
        switch self {
        case .compact: return 12
        case .regular: return 13
        case .large: return 14
        }
    }
}

/// User preferences for the look of the app, stored in UserDefaults.
@MainActor
final class ThemeSettings: ObservableObject {
    static let shared = ThemeSettings()

    @Published var appearance: AppAppearance {
        didSet {
            defaults.set(appearance.rawValue, forKey: Keys.appearance)
            applyAppearance()
        }
    }
    @Published var theme: AppTheme {
        didSet { defaults.set(theme.rawValue, forKey: Keys.theme) }
    }
    @Published var rowSize: RowSize {
        didSet { defaults.set(rowSize.rawValue, forKey: Keys.rowSize) }
    }
    @Published var alternatingRows: Bool {
        didSet { defaults.set(alternatingRows, forKey: Keys.alternatingRows) }
    }
    @Published var foldersFirst: Bool {
        didSet { defaults.set(foldersFirst, forKey: Keys.foldersFirst) }
    }

    private let defaults = UserDefaults.standard

    private enum Keys {
        static let appearance = "appearance"
        static let theme = "theme"
        static let rowSize = "rowSize"
        static let alternatingRows = "alternatingRows"
        static let foldersFirst = "foldersFirst"
    }

    private init() {
        appearance = defaults.string(forKey: Keys.appearance).flatMap(AppAppearance.init(rawValue:)) ?? .system
        theme = defaults.string(forKey: Keys.theme).flatMap(AppTheme.init(rawValue:)) ?? .violet
        rowSize = defaults.string(forKey: Keys.rowSize).flatMap(RowSize.init(rawValue:)) ?? .regular
        alternatingRows = defaults.object(forKey: Keys.alternatingRows) as? Bool ?? false
        foldersFirst = defaults.object(forKey: Keys.foldersFirst) as? Bool ?? true
    }

    func applyAppearance() {
        NSApp.appearance = appearance.nsAppearance
    }
}

/// Row with a rounded, theme-colored selection.
final class ThemedRowView: NSTableRowView {
    var accentColor: NSColor = .controlAccentColor {
        didSet { needsDisplay = true }
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        let rect = bounds.insetBy(dx: 6, dy: 1)
        let color = isEmphasized ? accentColor : accentColor.withAlphaComponent(0.22)
        color.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
    }

    override var interiorBackgroundStyle: NSView.BackgroundStyle {
        isSelected && isEmphasized ? .emphasized : .normal
    }
}
