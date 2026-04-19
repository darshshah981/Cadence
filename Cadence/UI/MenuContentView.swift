import SwiftUI

enum FlowTheme {
    static let background = Color(dynamicLight: 0xF8F7F4, dark: 0x1A1917)
    static let elevated = Color(dynamicLight: 0xFFFFFF, dark: 0x242220)
    static let subtle = Color(dynamicLight: 0xF0EEE9, dark: 0x2C2925)
    static let border = Color(dynamicLight: 0xE4E1DA, dark: 0x38352F)
    static let borderStrong = Color(dynamicLight: 0xC9C5BC, dark: 0x4A453E)
    static let textPrimary = Color(dynamicLight: 0x1C1A17, dark: 0xF0EDE8)
    static let textSecondary = Color(dynamicLight: 0x6B6860, dark: 0xB8B1A7)
    static let textTertiary = Color(dynamicLight: 0xA39F96, dark: 0x8B857B)
    static let placeholder = Color(dynamicLight: 0xC2BDB5, dark: 0x70695F)
    static let accent = Color(dynamicLight: 0xD97316, dark: 0xF59E0B)
    static let accentSubtle = Color(dynamicLight: 0xFEF3C7, dark: 0x3A2B12)
    static let accentBorder = Color(dynamicLight: 0xFDE68A, dark: 0x8A6115)
    static let success = Color(dynamicLight: 0x16A34A, dark: 0x4ADE80)
    static let successSubtle = Color(dynamicLight: 0xDCFCE7, dark: 0x16311F)
    static let error = Color(dynamicLight: 0xDC2626, dark: 0xF87171)
    static let errorSubtle = Color(dynamicLight: 0xFEE2E2, dark: 0x351B1B)
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
        VStack(spacing: 0) {
            content
        }
        .background(FlowTheme.elevated, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(FlowTheme.border, lineWidth: 1)
        )
    }
}

struct FlowSectionHeader: View {
    let title: String

    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 11, weight: .medium))
            .kerning(0.8)
            .foregroundStyle(FlowTheme.textSecondary)
            .padding(.bottom, 8)
    }
}

struct FlowToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(configuration.isOn ? FlowTheme.accent : FlowTheme.border)
                .frame(width: 30, height: 18)
                .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                    Circle()
                        .fill(Color.white)
                        .frame(width: 12, height: 12)
                        .padding(3)
                }
                .animation(.easeOut(duration: 0.15), value: configuration.isOn)
        }
        .buttonStyle(.plain)
    }
}

struct MenuContentView: View {
    @ObservedObject var appModel: AppModel
    @State private var expandedTranscriptIDs = Set<UUID>()

    var body: some View {
        VStack(spacing: 0) {
            MenuHeaderView(title: headerTitle) {
                NSApp.terminate(nil)
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 10)

            if let statusModel {
                StatusPillView(model: statusModel)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
            }

            contentArea
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            MenuTabBar(selection: $appModel.menuScreen)
                .padding(.horizontal, 10)
                .padding(.vertical, 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(FlowTheme.background)
        .task {
            await appModel.refreshPermissions()
        }
    }

    private var headerTitle: String {
        switch appModel.menuScreen {
        case .home:
            return "Transcripts"
        case .settings:
            return "Settings"
        }
    }

    private var contentArea: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
                switch appModel.menuScreen {
                case .home:
                    TranscriptListView(
                        transcriptHistory: appModel.transcriptHistory,
                        copiedTranscriptID: appModel.copiedTranscriptID,
                        shortcutHint: primaryShortcutHint,
                        needsPermissions: !appModel.permissions.allRequiredGranted,
                        expandedTranscriptIDs: $expandedTranscriptIDs,
                        onCopy: appModel.copyTranscript,
                        onOpenSettings: appModel.showSettingsScreen
                    )
                case .settings:
                    SettingsView(appModel: appModel)
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 6)
            .padding(.top, 2)
        }
    }

    private var primaryShortcutHint: String {
        let activeShortcuts = [
            appModel.holdToTalkBinding.isEnabled ? appModel.holdToTalkBinding.shortcut.symbolDisplayName : nil,
            appModel.tapToStartStopBinding.isEnabled ? appModel.tapToStartStopBinding.shortcut.symbolDisplayName : nil
        ]
        .compactMap { $0 }

        if !activeShortcuts.isEmpty {
            return activeShortcuts.joined(separator: " or ")
        }
        return "⌃ ⌥"
    }

    private var statusModel: StatusPillModel? {
        if let lastError = appModel.lastError?.trimmingCharacters(in: .whitespacesAndNewlines), !lastError.isEmpty {
            return StatusPillModel(
                kind: .error,
                text: humanizedError(lastError)
            )
        }

        switch appModel.state {
        case .idle:
            return nil
        case .listening:
            return StatusPillModel(kind: .recording, text: "Recording…")
        case .finalizing, .inserting:
            return StatusPillModel(kind: .transcribing, text: "Transcribing")
        case .error(let message):
            return StatusPillModel(kind: .error, text: humanizedError(message))
        }
    }

    private func humanizedError(_ raw: String) -> String {
        if raw.contains("Whisper did not return any transcript text") {
            return "Nothing picked up. Try speaking louder or check your mic."
        }
        if raw.contains("Press To Start/Stop shortcut rejected") {
            return "Shortcut needs 3+ keys. Try something like ⌃ ⌥ SPACE."
        }
        if raw.contains("Hold To Talk shortcut rejected") {
            return "Hold to Talk works best with 1-2 modifier keys."
        }
        return raw
    }
}

private struct MenuHeaderView: View {
    let title: String
    let onQuit: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .kerning(-0.16)
                .foregroundStyle(FlowTheme.textPrimary)

            Spacer()

            Button(action: onQuit) {
                Image(systemName: "power")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(FlowTheme.textTertiary)
                    .frame(width: 30, height: 30)
                    .background(FlowTheme.elevated, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(FlowTheme.border, lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
        }
    }
}

private struct StatusPillModel {
    enum Kind {
        case recording
        case transcribing
        case error
    }

    let kind: Kind
    let text: String
}

private struct StatusPillView: View {
    let model: StatusPillModel

    var body: some View {
        HStack(spacing: 6) {
            switch model.kind {
            case .recording:
                Circle()
                    .fill(FlowTheme.error)
                    .frame(width: 6, height: 6)
                    .scaleEffect(0.9)
                    .opacity(0.8)
            case .transcribing:
                ProgressView()
                    .controlSize(.small)
                    .tint(FlowTheme.textSecondary)
                    .scaleEffect(0.7)
            case .error:
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(FlowTheme.error)
            }

            Text(model.text)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(model.kind == .error ? FlowTheme.error : FlowTheme.textPrimary)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(backgroundColor, in: Capsule(style: .continuous))
        .overlay(Capsule(style: .continuous).stroke(borderColor, lineWidth: 1))
    }

    private var backgroundColor: Color {
        switch model.kind {
        case .recording:
            return FlowTheme.accentSubtle
        case .transcribing:
            return FlowTheme.subtle
        case .error:
            return FlowTheme.errorSubtle
        }
    }

    private var borderColor: Color {
        switch model.kind {
        case .recording:
            return FlowTheme.accentBorder
        case .transcribing:
            return FlowTheme.border
        case .error:
            return FlowTheme.error
        }
    }
}

private struct TranscriptListView: View {
    let transcriptHistory: [TranscriptHistoryItem]
    let copiedTranscriptID: UUID?
    let shortcutHint: String
    let needsPermissions: Bool
    @Binding var expandedTranscriptIDs: Set<UUID>
    let onCopy: (TranscriptHistoryItem) -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        if transcriptHistory.isEmpty {
            EmptyTranscriptStateView(
                shortcutHint: shortcutHint,
                needsPermissions: needsPermissions,
                onOpenSettings: onOpenSettings
            )
            .frame(maxWidth: .infinity, minHeight: 280, alignment: .top)
        } else {
            LazyVStack(spacing: 0) {
                ForEach(transcriptHistory) { item in
                    TranscriptCardView(
                        item: item,
                        isExpanded: expandedTranscriptIDs.contains(item.id),
                        isCopied: copiedTranscriptID == item.id,
                        onToggleExpanded: {
                            if expandedTranscriptIDs.contains(item.id) {
                                expandedTranscriptIDs.remove(item.id)
                            } else {
                                expandedTranscriptIDs.insert(item.id)
                            }
                        },
                        onCopy: {
                            onCopy(item)
                        }
                    )
                    if item.id != transcriptHistory.last?.id {
                        Divider()
                            .overlay(FlowTheme.border)
                    }
                }
            }
            .background(FlowTheme.elevated, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(FlowTheme.border, lineWidth: 1)
            )
        }
    }
}

private struct EmptyTranscriptStateView: View {
    let shortcutHint: String
    let needsPermissions: Bool
    let onOpenSettings: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "waveform.and.mic")
                .font(.system(size: 28, weight: .regular))
                .foregroundStyle(FlowTheme.textTertiary)

            Text(needsPermissions ? "Set up Cadence" : "No transcripts yet")
                .font(.system(size: 20, weight: .semibold))
                .kerning(-0.2)
                .foregroundStyle(FlowTheme.textPrimary)

            Text(
                needsPermissions
                    ? "Grant microphone and keyboard access, then choose a shortcut to start dictating."
                    : "Use \(shortcutHint) and start speaking."
            )
            .font(.system(size: 13))
            .foregroundStyle(FlowTheme.textSecondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)

            Button(needsPermissions ? "Complete Setup" : "How to use") {
                onOpenSettings()
            }
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(FlowTheme.accent)
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .background(FlowTheme.elevated, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(FlowTheme.border, lineWidth: 1)
        )
    }
}

private struct TranscriptCardView: View {
    let item: TranscriptHistoryItem
    let isExpanded: Bool
    let isCopied: Bool
    let onToggleExpanded: () -> Void
    let onCopy: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(item.createdAt.formatted(.dateTime.weekday(.wide).hour().minute()))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(FlowTheme.textTertiary)

                Spacer()

                Button(action: onCopy) {
                    Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(isCopied ? FlowTheme.accent : FlowTheme.textSecondary)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
            }

            Button(action: onToggleExpanded) {
                Text(item.text)
                    .font(.system(size: 13))
                    .foregroundStyle(FlowTheme.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(isExpanded ? nil : 3)
                    .multilineTextAlignment(.leading)
            }
            .buttonStyle(.plain)

            if isExpanded {
                Text("\(item.text.count) characters • \(wordCount) words")
                    .font(.system(size: 11))
                    .foregroundStyle(FlowTheme.textTertiary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var wordCount: Int {
        item.text.split(whereSeparator: \.isWhitespace).count
    }
}

private struct MenuTabBar: View {
    @Binding var selection: MenuScreen

    var body: some View {
        HStack(spacing: 6) {
            MenuTabButton(
                title: "Transcripts",
                symbolName: "text.bubble",
                isSelected: selection == .home
            ) {
                selection = .home
            }

            MenuTabButton(
                title: "Settings",
                symbolName: "slider.horizontal.3",
                isSelected: selection == .settings
            ) {
                selection = .settings
            }
        }
        .padding(4)
        .background(FlowTheme.subtle, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(FlowTheme.border, lineWidth: 1)
        )
    }
}

private struct MenuTabButton: View {
    let title: String
    let symbolName: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbolName)
                    .font(.system(size: 11, weight: .medium))
                Text(title)
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(isSelected ? FlowTheme.textPrimary : FlowTheme.textSecondary)
            .frame(maxWidth: .infinity)
            .frame(height: 30)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? FlowTheme.elevated : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(isSelected ? FlowTheme.border : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}
