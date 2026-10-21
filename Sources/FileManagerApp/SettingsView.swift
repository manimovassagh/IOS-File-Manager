import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: ThemeSettings

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Mode", selection: $settings.appearance) {
                    ForEach(AppAppearance.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)

                LabeledContent("Theme") {
                    HStack(spacing: 10) {
                        ForEach(AppTheme.allCases) { theme in
                            ThemeSwatch(theme: theme, isSelected: settings.theme == theme) {
                                settings.theme = theme
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
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .tint(settings.theme.color)
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
