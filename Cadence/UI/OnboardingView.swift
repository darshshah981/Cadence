import SwiftUI

struct OnboardingView: View {
    @ObservedObject var appModel: AppModel
    @ObservedObject private var microphoneMonitor: OnboardingMicrophoneMonitor
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(appModel: AppModel) {
        self.appModel = appModel
        self.microphoneMonitor = appModel.onboardingMicrophoneMonitor
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                ForEach(Array(appModel.availableOnboardingSteps.enumerated()), id: \.element.id) { index, step in
                    Capsule()
                        .fill(index <= appModel.currentOnboardingVisibleIndex ? FlowTheme.accent : FlowTheme.border)
                        .frame(height: 4)
                        .accessibilityLabel(stepTitle(step))
                        .accessibilityValue(index < appModel.currentOnboardingVisibleIndex ? "Complete" : index == appModel.currentOnboardingVisibleIndex ? "Current" : "Upcoming")
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 22)

            HStack(spacing: 0) {
                onboardingRail
                    .frame(width: 220)
                Divider()
                stepContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .id(appModel.currentOnboardingStep)
                    .transition(reduceMotion ? .identity : .opacity.combined(with: .move(edge: .trailing)))
            }

            Divider()
            footer
        }
        .frame(width: 820, height: 560)
        .background(FlowTheme.background)
        .preferredColorScheme(appModel.appearancePreference.colorScheme)
        .interactiveDismissDisabled()
        .animation(FlowMotion.enabled(FlowMotion.section, reduceMotion: reduceMotion), value: appModel.currentOnboardingVisibleIndex)
        .onChange(of: appModel.currentOnboardingStep) { _, step in
            if step != .microphone { microphoneMonitor.stop() }
        }
        .onDisappear { microphoneMonitor.stop() }
    }

    private var onboardingRail: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Cadence", systemImage: "waveform.and.mic")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(FlowTheme.textPrimary)

            VStack(alignment: .leading, spacing: 10) {
                Text("VOICE, WITH CONTROL")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(1.1)
                    .foregroundStyle(FlowTheme.textTertiary)
                Text("Dictate quickly. Draft deliberately. Keep the final say.")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(FlowTheme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()
            Label("Audio and transcripts stay on this Mac.", systemImage: "lock.fill")
                .font(.system(size: 11))
                .foregroundStyle(FlowTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(26)
        .background(FlowTheme.subtle.opacity(0.55))
    }

    @ViewBuilder
    private var stepContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            Image(systemName: stepIcon(appModel.currentOnboardingStep))
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(FlowTheme.accent)
                .frame(width: 52, height: 52)
                .background(FlowTheme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 13, style: .continuous))

            Text(stepTitle(appModel.currentOnboardingStep))
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(FlowTheme.textPrimary)
            Text(stepDetail(appModel.currentOnboardingStep))
                .font(.system(size: 14))
                .foregroundStyle(FlowTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            stepSpecificContent
            Spacer(minLength: 0)
        }
        .padding(38)
    }

    @ViewBuilder
    private var stepSpecificContent: some View {
        switch appModel.currentOnboardingStep {
        case .welcome:
            featureRows(welcomeFeatures)
        case .privacy:
            featureRows(privacyFeatures)
        case .permissions:
            VStack(alignment: .leading, spacing: 12) {
                permissionRow("Microphone", granted: appModel.permissions.microphoneGranted)
                permissionRow("Accessibility", granted: appModel.permissions.accessibilityGranted)
                permissionRow("Input Monitoring", granted: appModel.permissions.inputMonitoringGranted)
                CadenceActionButton(title: "Review permissions", role: .primary) {
                    appModel.openPermissionsWizard()
                }
                Text("Screen Recording is requested later only if you capture system audio in a meeting.")
                    .font(.system(size: 11))
                    .foregroundStyle(FlowTheme.textTertiary)
            }
        case .microphone:
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 4) {
                    ForEach(0..<12, id: \.self) { index in
                        Capsule()
                            .fill(Double(index) / 12 < microphoneMonitor.level ? FlowTheme.accent : FlowTheme.border)
                            .frame(width: 10, height: CGFloat(10 + index * 2))
                    }
                }
                .frame(height: 36, alignment: .bottom)
                Text(microphoneMonitor.isListening ? "Listening only—nothing is saved or transcribed." : "Run a private level check before your first dictation.")
                    .font(.system(size: 12))
                    .foregroundStyle(FlowTheme.textSecondary)
                CadenceActionButton(
                    title: microphoneMonitor.isListening ? "Stop microphone check" : "Check microphone",
                    role: microphoneMonitor.isListening ? .secondary : .primary
                ) {
                    microphoneMonitor.isListening ? microphoneMonitor.stop() : microphoneMonitor.start()
                }
                if let error = microphoneMonitor.errorMessage {
                    Text(error).font(.system(size: 11)).foregroundStyle(.red)
                }
            }
        case .dictation:
            shortcutCard(
                title: "Press to dictate",
                shortcut: appModel.holdToTalkBinding.shortcut.symbolDisplayName,
                detail: "Hold Fn, speak, then release to insert. Double-press Fn to lock recording on; press it again to finish."
            )
        case .scribe:
            VStack(alignment: .leading, spacing: 12) {
                shortcutCard(
                    title: "Open Scribe",
                    shortcut: appModel.scribeBinding.shortcut.symbolDisplayName,
                    detail: "Dictate what you want to write, then review the polished result before you insert it."
                )
                Text(appModel.scribeProviderStatus)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(FlowTheme.textTertiary)
                if !appModel.scribeReadiness.canGenerate {
                    CadenceActionButton(title: "Set up Scribe provider", role: .primary) {
                        appModel.presentScribeProviderSetup()
                    }
                }
            }
        case .personalization:
            featureRows(personalizationFeatures)
        case .ready:
            featureRows(readyFeatures)
        }
    }

    private var welcomeFeatures: [(String, String, String)] {
        var features = [
            (CadenceIconography.dictation, "Dictation", "Speak into any text field and insert the transcript.")
        ]
        if appModel.featureFlags.scribeEnabled {
            features.append((
                CadenceIconography.scribe,
                "Scribe",
                "Dictate a request, then review the polished result before insertion."
            ))
        }
        features.append((
            "person.2.wave.2",
            "Meeting capture",
            "Keep durable audio and recoverable transcripts for calls."
        ))
        return features
    }

    private var privacyFeatures: [(String, String, String)] {
        var features = [
            (
                "lock.shield",
                "Local transcription",
                "Cadence transcribes microphone audio on this Mac."
            )
        ]
        if appModel.featureFlags.scribeEnabled {
            features.append(contentsOf: [
                (
                    "network",
                    "Optional cloud drafting",
                    "Scribe sends current-session text only after you choose and validate a provider."
                ),
                (
                    "checkmark.circle",
                    "Review before insert",
                    "Generated drafts never replace text until you approve them."
                )
            ])
        } else {
            features.append((
                "eye.slash",
                "Private by default",
                "Dictation and meeting files stay on this Mac unless you choose to export or copy them."
            ))
        }
        return features
    }

    private var readyFeatures: [(String, String, String)] {
        var features = [
            (
                appModel.permissions.allRequiredGranted
                    ? "checkmark.circle.fill"
                    : "exclamationmark.circle",
                appModel.permissions.allRequiredGranted
                    ? "Core permissions ready"
                    : "Permissions still need attention",
                appModel.setupProgressLabel
            ),
            (
                CadenceIconography.dictation,
                "Dictation shortcut",
                appModel.holdToTalkBinding.shortcut.symbolDisplayName
            )
        ]
        if appModel.featureFlags.scribeEnabled {
            features.append((
                CadenceIconography.scribe,
                "Scribe shortcut",
                appModel.scribeBinding.shortcut.symbolDisplayName
            ))
        }
        return features
    }

    private var personalizationFeatures: [(String, String, String)] {
        var features = [
            (
                "text.badge.plus",
                "Spoken shortcuts",
                "Turn a short phrase into a longer reusable response."
            )
        ]
        if appModel.featureFlags.scribeEnabled {
            features.append((
                "textformat",
                "Writing profiles",
                "Set tone, length, punctuation, and formatting globally or per app."
            ))
        }
        features.append((
            "character.book.closed",
            "Custom words",
            "Teach Cadence names and phrases without sending them away."
        ))
        return features
    }

    private var footer: some View {
        HStack {
            CadenceActionButton(title: "Skip for now", role: .quiet) { appModel.skipOnboarding() }
            Spacer()
            if appModel.currentOnboardingVisibleIndex > 0 {
                CadenceActionButton(title: "Back", role: .secondary) { appModel.moveBackInOnboarding() }
            }
            CadenceActionButton(
                title: appModel.currentOnboardingStep == .ready ? "Start using Cadence" : "Continue",
                role: .primary,
                keyboardShortcut: .defaultAction
            ) {
                appModel.advanceOnboarding()
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    private func featureRows(_ rows: [(String, String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: row.0).frame(width: 20).foregroundStyle(FlowTheme.accent)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(row.1).font(.system(size: 13, weight: .medium)).foregroundStyle(FlowTheme.textPrimary)
                        Text(row.2).font(.system(size: 11)).foregroundStyle(FlowTheme.textSecondary)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(FlowTheme.subtle, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            }
        }
    }

    private func permissionRow(_ title: String, granted: Bool) -> some View {
        HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(granted ? FlowTheme.success : FlowTheme.textTertiary)
            Text(title).foregroundStyle(FlowTheme.textPrimary)
            Spacer()
            Text(granted ? "Ready" : "Needed")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(granted ? FlowTheme.success : FlowTheme.textSecondary)
        }
        .padding(11)
        .background(FlowTheme.subtle, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func shortcutCard(title: String, shortcut: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title).font(.system(size: 14, weight: .semibold))
                Spacer()
                Text(shortcut)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(FlowTheme.elevated, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
            Text(detail).font(.system(size: 11)).foregroundStyle(FlowTheme.textSecondary)
        }
        .padding(14)
        .background(FlowTheme.subtle, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func stepTitle(_ step: OnboardingStep) -> String {
        switch step {
        case .welcome: return "Meet Cadence"
        case .privacy: return "Your voice stays yours"
        case .permissions: return "Connect only what is needed"
        case .microphone: return "Check your microphone"
        case .dictation: return "Speak anywhere"
        case .scribe: return "Draft with Scribe"
        case .personalization: return "Make it sound like you"
        case .ready: return "You are ready"
        }
    }

    private func stepDetail(_ step: OnboardingStep) -> String {
        switch step {
        case .welcome:
            return appModel.featureFlags.scribeEnabled
                ? "Three focused workflows share one calm, native Mac experience."
                : "Dictation and meeting capture share one calm, native Mac experience."
        case .privacy: return "Cadence minimizes what it reads, saves, and sends. You stay in control at every handoff."
        case .permissions: return "Dictation needs microphone, Accessibility, and Input Monitoring. Each permission has one clear purpose."
        case .microphone: return "See that Cadence can hear you without recording a transcript or saving audio."
        case .dictation: return "Use push-to-talk for fast text insertion without opening a window."
        case .scribe: return "Turn spoken intent into a reviewable draft, separate from fast Dictation."
        case .personalization: return "Keep reusable language and writing preferences locally on this Mac."
        case .ready:
            return appModel.featureFlags.scribeEnabled
                ? "Review your setup, then start with Dictation or Scribe from any app."
                : "Review your setup, then start dictating from any app."
        }
    }

    private func stepIcon(_ step: OnboardingStep) -> String {
        switch step {
        case .welcome: return "waveform.and.mic"
        case .privacy: return "lock.shield.fill"
        case .permissions: return "checkmark.seal"
        case .microphone: return "mic.fill"
        case .dictation: return CadenceIconography.dictation
        case .scribe: return CadenceIconography.scribe
        case .personalization: return "person.crop.circle.badge.checkmark"
        case .ready: return "checkmark.circle.fill"
        }
    }
}
