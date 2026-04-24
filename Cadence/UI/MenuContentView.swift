import SwiftUI

enum FlowTheme {
    static let background = Color(dynamicLight: 0xFAF8F5, dark: 0x171615)
    static let elevated = Color(dynamicLight: 0xFFFDFB, dark: 0x22201E)
    static let subtle = Color(dynamicLight: 0xF3EEE9, dark: 0x2B2825)
    static let border = Color(dynamicLight: 0xE4DBD4, dark: 0x3C3732)
    static let borderStrong = Color(dynamicLight: 0xCABBB0, dark: 0x575049)
    static let textPrimary = Color(dynamicLight: 0x1E1B18, dark: 0xF4EFEA)
    static let textSecondary = Color(dynamicLight: 0x69615A, dark: 0xBDB4AA)
    static let textTertiary = Color(dynamicLight: 0x91887F, dark: 0x8D8378)
    static let placeholder = Color(dynamicLight: 0xC7BDB4, dark: 0x70675E)
    static let accent = Color(dynamicLight: 0xFF5C48, dark: 0xFF7A66)
    static let accentPressed = Color(dynamicLight: 0xE64B3B, dark: 0xFF8A78)
    static let accentSubtle = Color(dynamicLight: 0xFFF1EC, dark: 0x3A211D)
    static let accentBorder = Color(dynamicLight: 0xFFC8BB, dark: 0x7D3A31)
    static let success = Color(dynamicLight: 0x29A36A, dark: 0x58D594)
    static let successSubtle = Color(dynamicLight: 0xEAF8F0, dark: 0x173226)
    static let teal = Color(dynamicLight: 0x169B8F, dark: 0x4DD4C6)
    static let tealSubtle = Color(dynamicLight: 0xE8F8F6, dark: 0x12312E)
    static let error = Color(dynamicLight: 0xDC3C32, dark: 0xFF7F72)
    static let errorSubtle = Color(dynamicLight: 0xFFF0ED, dark: 0x391B18)
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
        .background(FlowTheme.elevated, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(FlowTheme.border, lineWidth: 1)
        )
    }
}

struct FlowSectionHeader: View {
    let title: String

    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .kerning(0.7)
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
            MenuHeaderView(title: headerTitle, status: headerStatus) {
                NSApp.terminate(nil)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 12)

            if let statusModel {
                StatusPillView(model: statusModel)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
            }

            contentArea
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            MenuTabBar(selection: $appModel.menuScreen)
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
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
            return "Cadence"
        case .settings:
            return "Settings"
        }
    }

    private var contentArea: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
                switch appModel.menuScreen {
                case .home:
                    HomeDashboardView(
                        appModel: appModel,
                        transcriptHistory: appModel.transcriptHistory,
                        copiedTranscriptID: appModel.copiedTranscriptID,
                        shortcutHint: primaryShortcutHint,
                        expandedTranscriptIDs: $expandedTranscriptIDs,
                        onCopy: appModel.copyTranscript,
                        onOpenPermissionsWizard: appModel.openPermissionsWizard,
                        onOpenSettings: appModel.showSettingsScreen
                    )
                case .settings:
                    SettingsView(appModel: appModel)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 6)
            .padding(.top, 0)
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

    private var headerStatus: MenuHeaderStatus {
        if appModel.userFacingErrorMessage != nil {
            return MenuHeaderStatus(text: "Needs attention", color: FlowTheme.error)
        }

        if !appModel.permissions.allRequiredGranted {
            return MenuHeaderStatus(text: "Setup needed", color: FlowTheme.accent)
        }

        switch appModel.state {
        case .idle:
            return MenuHeaderStatus(text: "Ready", color: FlowTheme.success)
        case .listening:
            return MenuHeaderStatus(text: "Recording", color: FlowTheme.accent)
        case .finalizing, .inserting:
            return MenuHeaderStatus(text: "Working", color: FlowTheme.teal)
        case .error:
            return MenuHeaderStatus(text: "Needs attention", color: FlowTheme.error)
        }
    }

    private var statusModel: StatusPillModel? {
        if let message = appModel.userFacingErrorMessage {
            return StatusPillModel(
                kind: .error,
                text: message
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
            return StatusPillModel(kind: .error, text: AppModel.humanizedErrorMessage(message))
        }
    }
}

private struct MenuHeaderStatus {
    let text: String
    let color: Color
}

private struct MenuHeaderView: View {
    let title: String
    let status: MenuHeaderStatus
    let onQuit: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            CadenceMarkView(size: 42)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(FlowTheme.textPrimary)

                HStack(spacing: 6) {
                    Circle()
                        .fill(status.color)
                        .frame(width: 8, height: 8)

                    Text(status.text)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(status.color)
                }
            }

            Spacer()

            Button(action: onQuit) {
                Image(systemName: "power")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(FlowTheme.textTertiary)
                    .frame(width: 34, height: 34)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}

private struct CadenceMarkView: View {
    let size: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                .fill(FlowTheme.accent)

            Text("C")
                .font(.system(size: size * 0.56, weight: .bold, design: .rounded))
                .foregroundStyle(Color.white)
        }
        .frame(width: size, height: size)
        .shadow(color: FlowTheme.accent.opacity(0.18), radius: 10, y: 5)
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

private struct HomeDashboardView: View {
    @ObservedObject var appModel: AppModel
    let transcriptHistory: [TranscriptHistoryItem]
    let copiedTranscriptID: UUID?
    let shortcutHint: String
    @Binding var expandedTranscriptIDs: Set<UUID>
    let onCopy: (TranscriptHistoryItem) -> Void
    let onOpenPermissionsWizard: () -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !appModel.permissions.allRequiredGranted {
                attentionCard
            }
            commandStrip
            transcriptSection
        }
    }

    private var commandStrip: some View {
        HStack(spacing: 10) {
            Image(systemName: appModel.primaryTriggerMode == .holdToTalk ? "mic.fill" : "record.circle")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(FlowTheme.accent)
                .frame(width: 26, height: 26)
                .background(FlowTheme.accentSubtle, in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(commandStatusTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(FlowTheme.textPrimary)

                Text(commandHint)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(FlowTheme.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
            }

            Spacer(minLength: 8)

            Button(action: onOpenSettings) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(FlowTheme.textTertiary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(FlowTheme.elevated, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(FlowTheme.border, lineWidth: 1)
        )
    }

    private var attentionCard: some View {
        HomeCard {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(FlowTheme.accent)
                    .frame(width: 22, height: 22)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Finish setup")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(FlowTheme.textPrimary)

                    Text(appModel.setupSummaryDetail)
                        .font(.system(size: 12))
                        .foregroundStyle(FlowTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                Button("Open") {
                    onOpenPermissionsWizard()
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(FlowTheme.accent)
            }
        }
    }

    private var commandStatusTitle: String {
        if appModel.hotkeyConflictMessage != nil {
            return "Shortcut conflict"
        }

        guard appModel.holdToTalkBinding.isEnabled || appModel.tapToStartStopBinding.isEnabled else {
            return "Shortcuts off"
        }

        return appModel.permissions.allRequiredGranted ? "Ready to dictate" : "Setup needed"
    }

    private var commandHint: String {
        if appModel.hotkeyConflictMessage != nil {
            return "Choose different shortcuts in Settings"
        }

        let hold = appModel.holdToTalkBinding.isEnabled ? "Hold \(appModel.holdToTalkBinding.shortcut.symbolDisplayName)" : nil
        let tap = appModel.tapToStartStopBinding.isEnabled ? "Press \(appModel.tapToStartStopBinding.shortcut.symbolDisplayName)" : nil
        let hints = [hold, tap].compactMap { $0 }

        if hints.isEmpty {
            return "Enable a shortcut in Settings"
        }

        return hints.joined(separator: " · ")
    }

    private var transcriptSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Recent transcripts")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(FlowTheme.textPrimary)

                Spacer()

                if !transcriptHistory.isEmpty {
                    Text("\(transcriptHistory.count)")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(FlowTheme.textTertiary)
                }
            }

            TranscriptListView(
                transcriptHistory: transcriptHistory,
                copiedTranscriptID: copiedTranscriptID,
                shortcutHint: shortcutHint,
                needsPermissions: !appModel.permissions.allRequiredGranted,
                expandedTranscriptIDs: $expandedTranscriptIDs,
                onCopy: onCopy,
                onOpenSettings: appModel.permissions.allRequiredGranted ? onOpenSettings : onOpenPermissionsWizard
            )
        }
    }

}

private struct HomeCard<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(FlowTheme.elevated, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(FlowTheme.border, lineWidth: 1)
        )
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
                    ? "Finish setup, choose a shortcut, and your first dictation will show up here."
                    : "Your recent dictations show up here. Use \(shortcutHint) and start speaking."
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
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "doc.text")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(FlowTheme.textSecondary)
                .frame(width: 30, height: 30)
                .background(FlowTheme.subtle, in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 6) {
                Button(action: onToggleExpanded) {
                    Text(item.text)
                        .font(.system(size: 13.5))
                        .foregroundStyle(FlowTheme.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .lineLimit(isExpanded ? nil : 2)
                        .multilineTextAlignment(.leading)
                }
                .buttonStyle(.plain)

                Text(isExpanded ? "\(item.text.count) characters • \(wordCount) words" : item.createdAt.formatted(.dateTime.hour().minute()))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(FlowTheme.textTertiary)
            }

            Button(action: onCopy) {
                Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isCopied ? FlowTheme.accent : FlowTheme.textSecondary)
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
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
