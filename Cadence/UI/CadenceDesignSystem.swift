import SwiftUI

enum FlowTheme {
    static let background = Color(dynamicLight: 0xFAF9F5, dark: 0x1A1A18)
    static let elevated = Color(dynamicLight: 0xFFFFFF, dark: 0x24241F)
    static let subtle = Color(dynamicLight: 0xF5F3EC, dark: 0x14140F)
    static let border = Color(dynamicLight: 0xECE8DD, dark: 0x2E2E28)
    static let borderStrong = Color(dynamicLight: 0xC4C0B6, dark: 0x545048)
    static let textPrimary = Color(dynamicLight: 0x1B1B19, dark: 0xEDEAE0)
    static let textSecondary = Color(dynamicLight: 0x6B6B66, dark: 0x9A968A)
    static let textTertiary = Color(dynamicLight: 0xA8A8A0, dark: 0x5D5A52)
    static let placeholder = Color(dynamicLight: 0xA8A8A0, dark: 0x5D5A52)
    static let accent = Color(dynamicLight: 0x1B1B19, dark: 0xEDEAE0)
    static let accentPressed = Color(dynamicLight: 0x3D3D39, dark: 0xFFFFFF)
    static let accentSubtle = Color(dynamicLight: 0xEFEBE1, dark: 0x2E2E28)
    static let accentBorder = Color(dynamicLight: 0xD6D4CB, dark: 0x5D5A52)
    static let success = Color(dynamicLight: 0x4F7A5B, dark: 0x7DA088)
    static let successSubtle = Color(dynamicLight: 0xE0EAE0, dark: 0x243328)
    static let teal = Color(dynamicLight: 0x4F7A5B, dark: 0x7DA088)
    static let tealSubtle = Color(dynamicLight: 0xE0EAE0, dark: 0x243328)
    static let error = Color(dynamicLight: 0xB84A3A, dark: 0xD17563)
    static let errorSubtle = Color(dynamicLight: 0xF5E3DE, dark: 0x33201C)
}

enum FlowMotion {
    static let control = Animation.spring(response: 0.26, dampingFraction: 0.86, blendDuration: 0.04)
    static let page = Animation.spring(response: 0.34, dampingFraction: 0.9, blendDuration: 0.04)
    static let section = Animation.spring(response: 0.3, dampingFraction: 0.88, blendDuration: 0.04)
    static let quick = Animation.easeOut(duration: 0.16)

    static func enabled(_ animation: Animation, reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : animation
    }
}

extension Color {
    init(dynamicLight lightHex: UInt32, dark darkHex: UInt32) {
        self.init(
            nsColor: NSColor(name: nil) { appearance in
                let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                return NSColor(hex: isDark ? darkHex : lightHex)
            }
        )
    }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        let red = CGFloat((hex >> 16) & 0xFF) / 255
        let green = CGFloat((hex >> 8) & 0xFF) / 255
        let blue = CGFloat(hex & 0xFF) / 255
        self.init(red: red, green: green, blue: blue, alpha: alpha)
    }
}

struct FlowSectionCard<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(FlowTheme.elevated, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(FlowTheme.border, lineWidth: 1)
        )
    }
}

enum CadenceDesignMetrics {
    static let spacingXS: CGFloat = 4
    static let spacingS: CGFloat = 8
    static let spacingM: CGFloat = 12
    static let spacingL: CGFloat = 16
    static let spacingXL: CGFloat = 24
    static let radiusS: CGFloat = 8
    static let radiusM: CGFloat = 12
    static let rowMinimumHeight: CGFloat = 32
    static let disclosureHitTarget: CGFloat = 24
    static let disclosureChevronFrame: CGFloat = 24
    static let compactActionBreakpoint: CGFloat = 560
}

struct CadenceAccessibilityPreferences: Equatable, Sendable {
    let reduceMotion: Bool
    let reduceTransparency: Bool
    let differentiateWithoutColor: Bool
    let increasedContrast: Bool

    func resolving(debugOverride: Self?) -> Self {
        debugOverride ?? self
    }

    static let standard = Self(
        reduceMotion: false,
        reduceTransparency: false,
        differentiateWithoutColor: false,
        increasedContrast: false
    )
}

private struct CadenceAccessibilityPreferencesKey: EnvironmentKey {
    static let defaultValue = CadenceAccessibilityPreferences.standard
}

#if DEBUG
private struct CadenceAccessibilityOverrideKey: EnvironmentKey {
    static let defaultValue: CadenceAccessibilityPreferences? = nil
}
#endif

extension EnvironmentValues {
    var cadenceAccessibility: CadenceAccessibilityPreferences {
        get { self[CadenceAccessibilityPreferencesKey.self] }
        set { self[CadenceAccessibilityPreferencesKey.self] = newValue }
    }

    #if DEBUG
    fileprivate var cadenceAccessibilityOverride: CadenceAccessibilityPreferences? {
        get { self[CadenceAccessibilityOverrideKey.self] }
        set { self[CadenceAccessibilityOverrideKey.self] = newValue }
    }
    #endif
}

private struct CadenceAccessibilityPreferenceModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    @Environment(\.colorSchemeContrast) private var contrast
    #if DEBUG
    @Environment(\.cadenceAccessibilityOverride) private var debugOverride
    #endif

    func body(content: Content) -> some View {
        let system = CadenceAccessibilityPreferences(
            reduceMotion: reduceMotion,
            reduceTransparency: reduceTransparency,
            differentiateWithoutColor: differentiateWithoutColor,
            increasedContrast: contrast == .increased
        )
        #if DEBUG
        content.environment(\.cadenceAccessibility, system.resolving(debugOverride: debugOverride))
        #else
        content.environment(\.cadenceAccessibility, system)
        #endif
    }
}

extension View {
    func cadenceAccessibilityPreferences() -> some View {
        modifier(CadenceAccessibilityPreferenceModifier())
    }

    #if DEBUG
    func cadenceAccessibilityFixture(_ preferences: CadenceAccessibilityPreferences?) -> some View {
        environment(\.cadenceAccessibilityOverride, preferences)
    }
    #endif
}

enum CadenceControlInteraction: Equatable, Sendable {
    case discreteMenu
    case continuousSlider
}

struct CadenceControlSemantic: Equatable, Sendable {
    let interaction: CadenceControlInteraction
    let isAccessibilityAdjustable: Bool
}

enum CadenceControlSemantics {
    static let quality = CadenceControlSemantic(interaction: .discreteMenu, isAccessibilityAdjustable: false)
    static let searchDepth = CadenceControlSemantic(interaction: .discreteMenu, isAccessibilityAdjustable: false)
    static let fillerWords = CadenceControlSemantic(interaction: .discreteMenu, isAccessibilityAdjustable: false)
    static let recognitionModel = CadenceControlSemantic(interaction: .discreteMenu, isAccessibilityAdjustable: false)
    static let slackBehavior = CadenceControlSemantic(interaction: .discreteMenu, isAccessibilityAdjustable: false)
    static let waveformSensitivity = CadenceControlSemantic(interaction: .continuousSlider, isAccessibilityAdjustable: true)
}

struct CadenceDiscretePicker<SelectionValue: Hashable, Content: View>: View {
    let title: String
    @Binding var selection: SelectionValue
    @ViewBuilder let content: Content

    var body: some View {
        Picker(title, selection: $selection) { content }
            .pickerStyle(.menu)
    }
}

struct CadenceToggle: View {
    let title: String
    @Binding var isOn: Bool
    var accessibilityIdentifier: String?

    var body: some View {
        Toggle(title, isOn: $isOn)
            .toggleStyle(.switch)
            .modifier(OptionalAccessibilityIdentifier(identifier: accessibilityIdentifier))
    }
}

struct CadenceDropdownRow<SelectionValue: Hashable, Content: View>: View {
    let title: String
    let detail: String?
    @Binding var selection: SelectionValue
    let accessibilityIdentifier: String
    @ViewBuilder let content: Content

    init(
        title: String,
        detail: String? = nil,
        selection: Binding<SelectionValue>,
        accessibilityIdentifier: String,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.detail = detail
        _selection = selection
        self.accessibilityIdentifier = accessibilityIdentifier
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .top, spacing: CadenceDesignMetrics.spacingM) {
            VStack(alignment: .leading, spacing: CadenceDesignMetrics.spacingXS) {
                Text(title)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(FlowTheme.textSecondary)
                }
            }
            Spacer(minLength: CadenceDesignMetrics.spacingM)
            Picker(title, selection: $selection) { content }
                .labelsHidden()
                .pickerStyle(.menu)
                .accessibilityLabel(title)
                .accessibilityIdentifier(accessibilityIdentifier)
        }
        .frame(minHeight: CadenceDesignMetrics.rowMinimumHeight)
    }
}

struct CadenceFieldRow: View {
    let title: String
    let detail: String?
    let placeholder: String
    @Binding var text: String
    let accessibilityIdentifier: String

    init(
        title: String,
        detail: String? = nil,
        placeholder: String,
        text: Binding<String>,
        accessibilityIdentifier: String
    ) {
        self.title = title
        self.detail = detail
        self.placeholder = placeholder
        _text = text
        self.accessibilityIdentifier = accessibilityIdentifier
    }

    var body: some View {
        CadenceLabeledControl(title: title, detail: detail) {
            TextField(placeholder, text: $text)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel(title)
                .accessibilityIdentifier(accessibilityIdentifier)
        }
    }
}

struct CadenceSecureFieldRow: View {
    let title: String
    let detail: String?
    let placeholder: String
    @Binding var text: String
    let accessibilityIdentifier: String

    init(
        title: String,
        detail: String? = nil,
        placeholder: String,
        text: Binding<String>,
        accessibilityIdentifier: String
    ) {
        self.title = title
        self.detail = detail
        self.placeholder = placeholder
        _text = text
        self.accessibilityIdentifier = accessibilityIdentifier
    }

    var body: some View {
        CadenceLabeledControl(title: title, detail: detail) {
            SecureField(placeholder, text: $text)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel(title)
                .accessibilityIdentifier(accessibilityIdentifier)
        }
    }
}

struct CadenceTextEditorRow: View {
    let title: String
    let detail: String?
    @Binding var text: String
    let accessibilityIdentifier: String
    var minimumHeight: CGFloat = 88

    var body: some View {
        CadenceLabeledControl(title: title, detail: detail) {
            TextEditor(text: $text)
                .scrollContentBackground(.hidden)
                .frame(minHeight: minimumHeight)
                .padding(CadenceDesignMetrics.spacingS)
                .background(FlowTheme.background, in: RoundedRectangle(cornerRadius: CadenceDesignMetrics.radiusS))
                .overlay {
                    RoundedRectangle(cornerRadius: CadenceDesignMetrics.radiusS)
                        .stroke(FlowTheme.border, lineWidth: 1)
                }
                .accessibilityLabel(title)
                .accessibilityIdentifier(accessibilityIdentifier)
        }
    }
}

struct CadenceStatusRow: View {
    let symbol: String
    let title: String
    let detail: String
    var accessibilityIdentifier: String?

    var body: some View {
        HStack(alignment: .top, spacing: CadenceDesignMetrics.spacingM) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(FlowTheme.accent)
                .frame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: CadenceDesignMetrics.spacingXS) {
                Text(title).font(.headline)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(FlowTheme.textSecondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityValue(detail)
        .modifier(OptionalAccessibilityIdentifier(identifier: accessibilityIdentifier))
    }
}

struct CadenceLoadingRow: View {
    let title: String
    let detail: String
    var accessibilityIdentifier: String?

    var body: some View {
        HStack(spacing: CadenceDesignMetrics.spacingM) {
            ProgressView().controlSize(.small).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: CadenceDesignMetrics.spacingXS) {
                Text(title).font(.headline)
                Text(detail).font(.caption).foregroundStyle(FlowTheme.textSecondary)
            }
        }
        .frame(minHeight: CadenceDesignMetrics.rowMinimumHeight)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityValue("Loading. \(detail)")
        .modifier(OptionalAccessibilityIdentifier(identifier: accessibilityIdentifier))
    }
}

private struct CadenceLabeledControl<Control: View>: View {
    let title: String
    let detail: String?
    @ViewBuilder let control: Control

    var body: some View {
        VStack(alignment: .leading, spacing: CadenceDesignMetrics.spacingS) {
            VStack(alignment: .leading, spacing: CadenceDesignMetrics.spacingXS) {
                Text(title).font(.subheadline.weight(.medium))
                if let detail {
                    Text(detail).font(.caption).foregroundStyle(FlowTheme.textSecondary)
                }
            }
            control
        }
    }
}

private struct OptionalAccessibilityIdentifier: ViewModifier {
    let identifier: String?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let identifier {
            content.accessibilityIdentifier(identifier)
        } else {
            content
        }
    }
}

struct CadenceSensitivitySlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let minimumLabel: String
    let maximumLabel: String
    let accessibilityIdentifier: String

    init(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        minimumLabel: String,
        maximumLabel: String,
        accessibilityIdentifier: String = "cadence-sensitivity-slider"
    ) {
        self.title = title
        _value = value
        self.range = range
        self.step = step
        self.minimumLabel = minimumLabel
        self.maximumLabel = maximumLabel
        self.accessibilityIdentifier = accessibilityIdentifier
    }

    var body: some View {
        Slider(value: $value, in: range, step: step) {
            Text(title)
        } minimumValueLabel: {
            Text(minimumLabel)
        } maximumValueLabel: {
            Text(maximumLabel)
        }
        .accessibilityLabel(title)
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}

struct CadenceDisclosureGroupStyle: DisclosureGroupStyle {
    @Environment(\.cadenceAccessibility) private var accessibility
    let accessibilityIdentifier: String

    init(accessibilityIdentifier: String = "cadence-disclosure") {
        self.accessibilityIdentifier = accessibilityIdentifier
    }

    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: CadenceDesignMetrics.spacingS) {
            Button {
                withAnimation(FlowMotion.enabled(
                    FlowMotion.control,
                    reduceMotion: accessibility.reduceMotion
                )) {
                    configuration.isExpanded.toggle()
                }
            } label: {
                HStack(alignment: .center, spacing: CadenceDesignMetrics.spacingS) {
                    configuration.label
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: CadenceDesignMetrics.spacingS)
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(configuration.isExpanded ? 90 : 0))
                        .frame(
                            width: CadenceDesignMetrics.disclosureChevronFrame,
                            height: CadenceDesignMetrics.disclosureChevronFrame,
                            alignment: .center
                        )
                        .contentShape(Rectangle())
                        .accessibilityHidden(true)
                }
                .frame(
                    minHeight: CadenceDesignMetrics.disclosureHitTarget,
                    alignment: .center
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(accessibilityIdentifier)
            .accessibilityValue(configuration.isExpanded ? "Expanded" : "Collapsed")
            .accessibilityHint(configuration.isExpanded ? "Collapse this section." : "Expand this section.")
            .overlay(alignment: .topLeading) {
                Text(configuration.isExpanded ? "Expanded" : "Collapsed")
                    .font(.system(size: 1))
                    .foregroundStyle(Color.clear)
                    .frame(width: 1, height: 1)
                    .accessibilityLabel("Disclosure state")
                    .accessibilityValue(configuration.isExpanded ? "Expanded" : "Collapsed")
                    .accessibilityIdentifier("\(accessibilityIdentifier)-state")
            }

            if configuration.isExpanded {
                configuration.content
            }
        }
    }
}

struct CadenceDisclosureLayoutGeometry: Equatable, Sendable {
    let isExpanded: Bool
    let rowHeight: CGFloat
    let chevronFrame: CGRect

    var rowMidY: CGFloat { rowHeight / 2 }
    var chevronMidY: CGFloat { chevronFrame.midY }

    init(labelHeight: CGFloat, isExpanded: Bool) {
        self.isExpanded = isExpanded
        rowHeight = max(CadenceDesignMetrics.disclosureHitTarget, labelHeight)
        chevronFrame = CGRect(
            x: 0,
            y: (rowHeight - CadenceDesignMetrics.disclosureChevronFrame) / 2,
            width: CadenceDesignMetrics.disclosureChevronFrame,
            height: CadenceDesignMetrics.disclosureChevronFrame
        )
    }
}

struct CadencePassiveCard<Content: View>: View {
    @Environment(\.cadenceAccessibility) private var accessibility
    @ViewBuilder let content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(CadenceDesignMetrics.spacingM)
            .background(FlowTheme.elevated, in: RoundedRectangle(cornerRadius: CadenceDesignMetrics.radiusS))
            .overlay {
                RoundedRectangle(cornerRadius: CadenceDesignMetrics.radiusS)
                    .stroke(
                        accessibility.increasedContrast ? FlowTheme.borderStrong : FlowTheme.border,
                        lineWidth: accessibility.increasedContrast ? 2 : 1
                    )
            }
    }
}
