import SwiftUI
import UIKit
import VIGBTCore

extension UIColor {
    convenience init(_ rgb: RGB) {
        self.init(red: CGFloat(rgb.r) / 255, green: CGFloat(rgb.g) / 255, blue: CGFloat(rgb.b) / 255, alpha: 1)
    }

    /// Resolves to the high-contrast dark or light palette depending on the effective appearance.
    /// The user's Theme setting forces the appearance at the root (`preferredColorScheme`).
    static func themed(_ pick: @escaping (ThemePalette) -> RGB) -> UIColor {
        UIColor { traits in
            UIColor(pick(traits.userInterfaceStyle == .light ? .highContrastLight : .highContrastDark))
        }
    }
}

/// Every colour the UI uses. Values come from `ThemePalette` (contrast-tested in `AccessibilityTests`).
enum Palette {
    static let background = Color(UIColor.themed(\.background))
    static let surface = Color(UIColor.themed(\.surface))
    static let text = Color(UIColor.themed(\.text))
    static let secondaryText = Color(UIColor.themed(\.secondaryText))
    static let accent = Color(UIColor.themed(\.accent))
    static let onAccent = Color(UIColor.themed(\.onAccent))
    static let warning = Color(UIColor.themed(\.warning))
    static let success = Color(UIColor.themed(\.success))
    static let secondaryButton = Color(UIColor.themed(\.secondaryButton))
    static let water = Color(UIColor.themed(\.water))
    static let bunker = Color(UIColor.themed(\.bunker))
    static let green = Color(UIColor.themed(\.green))
    static let fairway = Color(UIColor.themed(\.fairway))
    static let outOfBounds = Color(UIColor.themed(\.outOfBounds))
    static let pin = Color(UIColor.themed(\.pin))
}

extension Theme {
    var colorScheme: ColorScheme? {
        switch self {
        case .highContrastDark: return .dark
        case .highContrastLight: return .light
        case .system: return nil
        }
    }
}

/// Border width: thicker when the user turns on Increase Contrast.
struct OutlineWidth {
    static func value(_ contrast: ColorSchemeContrast) -> CGFloat { contrast == .increased ? 3 : 2 }
}

// MARK: - Buttons

/// Primary: accent fill, on-accent text (≥ 7:1). Secondary: neutral fill with a text-colour outline,
/// because the fill alone does not reach 3:1 against the page.
struct VIGBTButtonStyle: ButtonStyle {
    var prominent: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorSchemeContrast) private var contrast

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.title2.bold())
            .multilineTextAlignment(.center)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: 64)
            .foregroundStyle(prominent ? Palette.onAccent : Palette.text)
            .background(RoundedRectangle(cornerRadius: 14).fill(prominent ? Palette.accent : Palette.secondaryButton))
            .overlay(RoundedRectangle(cornerRadius: 14)
                .stroke(Palette.text, lineWidth: prominent ? 0 : OutlineWidth.value(contrast)))
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.45)
            .contentShape(RoundedRectangle(cornerRadius: 14))
    }
}

/// Smaller outlined button (≥ 44 pt) for secondary rows.
struct CompactButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorSchemeContrast) private var contrast

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 48)
            .foregroundStyle(Palette.text)
            .background(RoundedRectangle(cornerRadius: 10).fill(Palette.secondaryButton))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.text, lineWidth: OutlineWidth.value(contrast)))
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.45)
            .contentShape(RoundedRectangle(cornerRadius: 10))
    }
}

/// Full-width, tall button with a large label (≥ 64 pt touch target).
struct BigButton: View {
    let title: String
    var hint: String? = nil
    var prominent = true
    let action: () -> Void

    var body: some View {
        Button(title, action: action)
            .buttonStyle(VIGBTButtonStyle(prominent: prominent))
            .accessibilityHint(hint ?? "")
    }
}

struct ScreenTitle: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.largeTitle.bold())
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Layout

/// Horizontal row that becomes a vertical stack at accessibility text sizes, so labels never truncate.
struct AdaptiveStack<Content: View>: View {
    @Environment(\.dynamicTypeSize) private var size
    var spacing: CGFloat = 12
    @ViewBuilder var content: Content

    var body: some View {
        if size.isAccessibilitySize {
            VStack(spacing: spacing) { content }
        } else {
            HStack(spacing: spacing) { content }
        }
    }
}

/// Standard screen container: scrolls (so nothing is clipped at large text), themed background.
struct Screen<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(spacing: 16) { content }
                .padding()
                .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
    }
}

// MARK: - Settings (Display)

struct SettingsButton: View {
    @State private var showing = false

    var body: some View {
        Button("Settings") { showing = true }
            .buttonStyle(CompactButtonStyle())
            .sheet(isPresented: $showing) { DisplaySettingsView() }
    }
}

struct DisplaySettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            Form {
                Section {
                    Picker("Theme", selection: $model.theme) {
                        ForEach(Theme.allCases) { Text($0.displayName).tag($0) }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } header: {
                    Text("Display")
                } footer: {
                    Text("Both themes keep all text at 7 to 1 contrast or better. Text size follows your iPhone's Text Size setting, including the largest accessibility sizes.")
                }
                Section {
                    Toggle("Ball highlight while finding the ball", isOn: $model.ballHighlightEnabled)
                } footer: {
                    Text("Shows a magnifiable view where only ball-coloured pixels are bright.")
                }
                Section {
                    Text("Version \(VIGBTVersion.string) (\(VIGBTVersion.build))")
                    Text("Open source under the Apache License 2.0. Course data © OpenStreetMap contributors (ODbL).")
                        .font(.footnote)
                }
            }
            .navigationTitle("Settings")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
