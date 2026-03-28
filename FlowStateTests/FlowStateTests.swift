import Carbon
import Testing
@testable import FlowState

struct FlowStateTests {
    @Test
    func permissionsSnapshotRequiresMicrophoneAndAccessibility() {
        let snapshot = PermissionsSnapshot(
            microphoneGranted: true,
            accessibilityGranted: true,
            inputMonitoringGranted: false
        )

        #expect(snapshot.allRequiredGranted)
    }

    @Test
    func defaultHotkeyMatchesPlannedShortcut() {
        #expect(HotkeyConfiguration.defaultHoldToTalk.displayName == "Option + Shift + Space")
    }

    @Test
    func hotkeyConfigurationFormatsUpdatedShortcutDisplayName() {
        let configuration = HotkeyConfiguration(
            keyCode: 9,
            carbonModifiers: UInt32(cmdKey) | UInt32(optionKey) | UInt32(shiftKey),
            keyDisplay: "V"
        )
        #expect(configuration.displayName == "Option + Shift + Command + V")
    }

    @Test
    func modifierOnlyShortcutFormatsWithoutSyntheticKeyName() {
        let configuration = HotkeyConfiguration(
            keyCode: HotkeyConfiguration.modifierOnlyKeyCode,
            carbonModifiers: UInt32(controlKey) | UInt32(optionKey),
            keyDisplay: ""
        )

        #expect(configuration.isModifierOnly)
        #expect(configuration.displayName == "Control + Option")
    }

    @Test
    func holdToTalkSupportsAtMostTwoKeys() {
        let validShortcut = HotkeyConfiguration(
            keyCode: HotkeyConfiguration.modifierOnlyKeyCode,
            carbonModifiers: UInt32(controlKey) | UInt32(optionKey),
            keyDisplay: ""
        )
        let invalidShortcut = HotkeyConfiguration(
            keyCode: 49,
            carbonModifiers: UInt32(controlKey) | UInt32(optionKey),
            keyDisplay: "Space"
        )

        #expect(HotkeyAction.holdToTalk.supports(validShortcut))
        #expect(!HotkeyAction.holdToTalk.supports(invalidShortcut))
    }

    @Test
    func pressToStartStopRequiresAtLeastThreeKeys() {
        let invalidShortcut = HotkeyConfiguration(
            keyCode: HotkeyConfiguration.modifierOnlyKeyCode,
            carbonModifiers: UInt32(controlKey) | UInt32(optionKey),
            keyDisplay: ""
        )
        let validShortcut = HotkeyConfiguration(
            keyCode: 49,
            carbonModifiers: UInt32(controlKey) | UInt32(optionKey),
            keyDisplay: "Space"
        )

        #expect(!HotkeyAction.tapToStartStop.supports(invalidShortcut))
        #expect(HotkeyAction.tapToStartStop.supports(validShortcut))
    }

    @Test
    func defaultTranscriptionConfigurationUsesFastPreset() {
        let configuration = TranscriptionConfiguration()

        #expect(configuration.model == .baseEnglish)
        #expect(configuration.decodingMode == .greedy)
        #expect(configuration.keepContext)
        #expect(configuration.trimSilence)
        #expect(configuration.normalizeAudio)
        #expect(!configuration.tapStopsOnNextKeyPress)
    }

    @Test
    func vocabularyEntriesParseCanonicalTermsAndAliases() {
        let entries = VocabularyEntry.parseList(from: """
        Anthropic: antropic, anthropik
        Kubernetes: kuber netties
        """)

        #expect(entries.count == 2)
        #expect(entries[0].canonical == "Anthropic")
        #expect(entries[0].aliases == ["antropic", "anthropik"])
        #expect(entries[1].canonical == "Kubernetes")
    }

    @Test
    func vocabularyPostProcessorRewritesAliasesPreservingPunctuation() {
        let result = VocabularyPostProcessor.apply(
            to: "anthropik, kuber netties and Anthropic.",
            vocabularyText: """
            Anthropic: anthropik
            Kubernetes: kuber netties
            """
        )

        #expect(result == "Anthropic, Kubernetes and Anthropic.")
    }
}
