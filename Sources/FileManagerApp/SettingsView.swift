import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: ThemeSettings

    var body: some View {
        Form {
            Section("Theme") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 124), spacing: 12)], spacing: 14) {
                    ForEach(ColorTheme.allCases) { theme in
                        ThemeTile(theme: theme, nativeAccent: settings.theme.color, isSelected: settings.colorTheme == theme) {
                            settings.colorTheme = theme
                        }
                    }
                }
                .padding(.vertical, 4)
            }

            if settings.colorTheme == .native {
                Section("Native theme") {
                    Picker("Mode", selection: $settings.appearance) {
                        ForEach(AppAppearance.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)

                    LabeledContent("Accent color") {
                        HStack(spacing: 10) {
                            ForEach(AppTheme.allCases) { theme in
                                ThemeSwatch(theme: theme, isSelected: settings.theme == theme) {
                                    settings.theme = theme
                                }
                            }
                        }
                    }
                }
            }

            Section("File list") {
                Picker("Row size", selection: $settings.rowSize) {
                    ForEach(RowSize.selectable) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Toggle("Alternating row colors", isOn: $settings.alternatingRows)
                Toggle("Keep folders on top", isOn: $settings.foldersFirst)
            }
        }
        .formStyle(.grouped)
        .frame(width: 600)
        .fixedSize(horizontal: false, vertical: true)
        .tint(settings.accentColor)
    }
}

private struct ThemeSwatch: View {
    let theme: AppTheme
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(theme == .system ? AnyShapeStyle(AngularGradient(
                    colors: [.red, .orange, .yellow, .green, .blue, .purple, .red], center: .center
                )) : AnyShapeStyle(theme.color))
                .frame(width: 20, height: 20)
                .overlay {
                    if isSelected {
                        Circle().fill(.white).frame(width: 7, height: 7)
                    }
                }
                .padding(3)
                .overlay(Circle().strokeBorder(isSelected ? theme.color : .clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
        .help(theme.title)
    }
}

/// A small picture of a theme: sidebar, two file rows (one selected) and its name.
private struct ThemeTile: View {
    let theme: ColorTheme
    let nativeAccent: Color
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                miniature
                    .frame(height: 72)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(isSelected ? accent : Color.secondary.opacity(0.25), lineWidth: isSelected ? 2.5 : 1)
                    )
                Text(theme.title)
                    .font(.caption)
                    .fontWeight(isSelected ? .semibold : .regular)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .help(theme.title)
    }

    private var accent: Color {
        theme.palette.map { Color(nsColor: $0.accent) } ?? nativeAccent
    }

    private func color(_ keyPath: KeyPath<ThemePalette, NSColor>, native: NSColor) -> Color {
        Color(nsColor: theme.palette?[keyPath: keyPath] ?? native)
    }

    private var miniature: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(0..<3) { _ in
                    Capsule().fill(accent.opacity(0.8)).frame(width: 18, height: 4)
                }
                Spacer()
            }
            .padding(7)
            .frame(width: 36)
            .frame(maxHeight: .infinity)
            .background(color(\.sidebar, native: .windowBackgroundColor))

            VStack(alignment: .leading, spacing: 4) {
                row(selected: false)
                row(selected: true)
                row(selected: false)
                Spacer()
            }
            .padding(7)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(color(\.background, native: .textBackgroundColor))
        }
    }

    private func row(selected: Bool) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2)
                .fill(selected ? color(\.selectionText, native: .white) : accent.opacity(0.7))
                .frame(width: 8, height: 8)
            Capsule()
                .fill(selected ? color(\.selectionText, native: .white) : color(\.text, native: .labelColor))
                .frame(width: 44, height: 4)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
        .frame(height: 13)
        .background(selected ? AnyShapeStyle(accent) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 3))
    }
}
