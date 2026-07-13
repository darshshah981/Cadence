import AppKit
import Carbon
import Darwin
import Foundation
import Testing
@testable import Cadence

struct CadenceTests {
    @Test
    @MainActor
    func analyticsServiceRequiresOptInAndSanitizesProperties() {
        let sink = CapturingAnalyticsSink()
        let analytics = AnalyticsService(isEnabled: false, sink: sink)

        analytics.track("ignored")
        analytics.setEnabled(true)
        analytics.track("sample", properties: ["detail": "hello\nworld"])

        #expect(sink.events.map(\.name) == ["analytics_consent_updated", "sample"])
        #expect(sink.events.last?.properties["detail"] == .string("hello world"))
    }

    @Test
    func permissionsSnapshotRequiresMicrophoneAccessibilityAndInputMonitoring() {
        let missingInputMonitoring = PermissionsSnapshot(
            microphoneGranted: true,
            accessibilityGranted: true,
            inputMonitoringGranted: false,
            screenRecordingGranted: true
        )
        let allGranted = PermissionsSnapshot(
            microphoneGranted: true,
            accessibilityGranted: true,
            inputMonitoringGranted: true,
            screenRecordingGranted: false
        )

        #expect(!missingInputMonitoring.allRequiredGranted)
        #expect(allGranted.allRequiredGranted)
        #expect(!allGranted.screenRecordingGranted)
    }

    @Test
    func defaultHotkeyMatchesPlannedShortcut() {
        #expect(HotkeyConfiguration.defaultHoldToTalk.displayName == "Fn")
        #expect(HotkeyConfiguration.defaultHoldToTalk.symbolDisplayName == "fn")
        #expect(HotkeyConfiguration.defaultHoldToTalk.matches(modifiers: [.function], activeModifierKeyCodes: []))
    }

    @Test
    @MainActor
    func freshDefaultsPreserveScribeLeftControlConstraint() throws {
        let suiteName = "HotkeyDefaults.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let binding = AppModel.loadBinding(defaults: defaults, action: .scribe)

        #expect(binding.shortcut == .defaultScribe)
        #expect(binding.shortcut.sidedModifierKeyCodes == [59])
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
    func sidedModifierShortcutKeepsLeftAndRightIdentity() {
        let configuration = HotkeyConfiguration.from(
            keyCode: 49,
            modifiers: [.option, .shift],
            characters: " ",
            sidedModifierKeyCodes: [58, 60]
        )

        #expect(configuration.requiresSpecificModifierSides)
        #expect(configuration.displayName == "Left Option + Right Shift + Space")
        #expect(configuration.symbolDisplayName == "L⌥ R⇧ SPACE")
    }

    @Test
    func sidedModifierShortcutOnlyMatchesCapturedSides() {
        let configuration = HotkeyConfiguration.from(
            keyCode: 49,
            modifiers: [.option, .shift],
            characters: " ",
            sidedModifierKeyCodes: [58, 60]
        )

        #expect(configuration.matches(keyCode: 49, modifiers: [.option, .shift], activeModifierKeyCodes: [58, 60]))
        #expect(!configuration.matches(keyCode: 49, modifiers: [.option, .shift], activeModifierKeyCodes: [58, 56]))
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
    func scribeHasAnIndependentNonDictationShortcut() {
        #expect(HotkeyAction.scribe.dictationTriggerMode == nil)
        #expect(HotkeyBinding.defaultScribe.action == .scribe)
        #expect(HotkeyBinding.defaultScribe.isEnabled)
        #expect(HotkeyAction.scribe.supports(.defaultScribe))
        #expect(HotkeyConfiguration.defaultScribe.displayName == "Fn + Left Control")
        #expect(HotkeyConfiguration.defaultScribe.symbolDisplayName == "fn L⌃")
        #expect(HotkeyConfiguration.defaultScribe.matches(
            modifiers: [.function, .control],
            activeModifierKeyCodes: [59]
        ))
        #expect(!HotkeyAction.scribe.supports(HotkeyConfiguration(
            keyCode: HotkeyConfiguration.modifierOnlyKeyCode,
            carbonModifiers: UInt32(optionKey),
            keyDisplay: ""
        )))
    }

    @Test
    func dictationHUDMakesPersistentListeningExplicit() {
        let hold = HUDVisualState.recording(triggerMode: .holdToTalk, showsHint: false)
        let persistent = HUDVisualState.recording(triggerMode: .tapToStartStop, showsHint: false)

        #expect(!DictationTriggerMode.holdToTalk.showsLockIndicator)
        #expect(DictationTriggerMode.tapToStartStop.showsLockIndicator)
        #expect(hold.accessibilityLabel == "Dictation is listening")
        #expect(hold.accessibilityHint == "Release the shortcut to finish dictating.")
        #expect(persistent.accessibilityLabel == "Continuous dictation is listening")
        #expect(persistent.accessibilityHint == "Press the Dictation shortcut again to finish.")
        #expect(!HUDState(
            visualState: persistent,
            subtitle: "",
            level: 0,
            waveformLevels: [],
            isVisible: true,
            showsSubtitle: false
        ).showsControls)
    }

    @Test
    func doublePressLatchRecognizesOnlyTwoNearbyTaps() {
        var latch = DoublePressLatch(maxInterval: 0.38)

        let firstTap = latch.registerTap(at: 10)
        let nearbySecondTap = latch.registerTap(at: 10.25)
        let nextFirstTap = latch.registerTap(at: 11)
        let expiredSecondTap = latch.registerTap(at: 11.5)
        let finalNearbyTap = latch.registerTap(at: 11.7)

        #expect(!firstTap)
        #expect(nearbySecondTap)
        #expect(!nextFirstTap)
        #expect(!expiredSecondTap)
        #expect(finalNearbyTap)
    }

    @Test
    func dictationQuickTapGestureStartsOnDoublePressAndStopsOnThirdPress() {
        var gesture = DictationQuickTapGesture()

        #expect(gesture.register(state: .idle, activeTriggerMode: nil, at: 10) == .none)
        #expect(gesture.register(state: .idle, activeTriggerMode: nil, at: 10.2) == .startToggleRecording)
        #expect(gesture.register(
            state: .listening,
            activeTriggerMode: .tapToStartStop,
            at: 10.4
        ) == .stopToggleRecording)
        #expect(gesture.register(state: .finalizing, activeTriggerMode: .tapToStartStop, at: 10.5) == .none)
    }

    @Test
    func productionModifierEngineCoversHoldQuickTapAndReleaseSequences() {
        var engine = ModifierOnlyGestureEngine()
        let bindings = [HotkeyBinding.defaultHoldToTalk, HotkeyBinding.defaultScribe]

        #expect(engine.flagsChanged(
            bindings: bindings,
            flags: [.function],
            activeModifierKeyCodes: [63],
            releasedKeyCode: 63
        ) == [.schedule(.holdToTalk)])
        #expect(engine.activationDelayElapsed(for: .holdToTalk) == .press(.holdToTalk))
        #expect(engine.flagsChanged(
            bindings: bindings,
            flags: [],
            activeModifierKeyCodes: [],
            releasedKeyCode: 63
        ) == [.release(.holdToTalk)])

        #expect(engine.flagsChanged(
            bindings: bindings,
            flags: [.function],
            activeModifierKeyCodes: [63],
            releasedKeyCode: 63
        ) == [.schedule(.holdToTalk)])
        #expect(engine.flagsChanged(
            bindings: bindings,
            flags: [],
            activeModifierKeyCodes: [],
            releasedKeyCode: 63
        ) == [.cancelScheduled(.holdToTalk), .quickTap(.holdToTalk)])
    }

    @Test
    func fnScribeChordDoesNotLeakIntoDictationGesture() {
        var engine = ModifierOnlyGestureEngine()
        let bindings = [HotkeyBinding.defaultHoldToTalk, HotkeyBinding.defaultScribe]

        #expect(engine.flagsChanged(
            bindings: bindings,
            flags: [.function],
            activeModifierKeyCodes: [63],
            releasedKeyCode: 63
        ) == [.schedule(.holdToTalk)])
        #expect(engine.flagsChanged(
            bindings: bindings,
            flags: [.function, .control],
            activeModifierKeyCodes: [63, 59],
            releasedKeyCode: 59
        ) == [.cancelScheduled(.holdToTalk), .schedule(.scribe)])
        #expect(engine.activationDelayElapsed(for: .scribe) == .press(.scribe))
        #expect(engine.flagsChanged(
            bindings: bindings,
            flags: [.function],
            activeModifierKeyCodes: [63],
            releasedKeyCode: 59
        ) == [.release(.scribe)])
        #expect(engine.flagsChanged(
            bindings: bindings,
            flags: [],
            activeModifierKeyCodes: [],
            releasedKeyCode: 63
        ).isEmpty)
    }

    @Test
    func interruptedFnChordDoesNotStartOrQuickTapDictation() {
        var engine = ModifierOnlyGestureEngine()
        let bindings = [HotkeyBinding.defaultHoldToTalk]

        #expect(engine.flagsChanged(
            bindings: bindings,
            flags: [.function],
            activeModifierKeyCodes: [63],
            releasedKeyCode: 63
        ) == [.schedule(.holdToTalk)])
        #expect(engine.flagsChanged(
            bindings: bindings,
            flags: [.function, .shift],
            activeModifierKeyCodes: [63, 56],
            releasedKeyCode: 56
        ) == [.cancelScheduled(.holdToTalk)])
        #expect(engine.activationDelayElapsed(for: .holdToTalk) == nil)
        #expect(engine.flagsChanged(
            bindings: bindings,
            flags: [],
            activeModifierKeyCodes: [],
            releasedKeyCode: 63
        ).isEmpty)
    }

    @Test
    @MainActor
    func scribePanelDirectLifecycleHasNoIntentPickerState() throws {
        let model = ScribePanelViewModel()
        model.apply(
            state: .listening(requestID: UUID()),
            failureMessage: nil,
            literalTranscript: nil,
            environmentCue: nil,
            exactLiterals: [],
            canRetryGeneration: false
        )
        #expect(model.state.requestID != nil)
    }

    @Test
    func dictationHUDExposesTerminalAndProcessingStates() {
        #expect(HUDVisualState.preparingModel.accessibilityLabel == "Preparing the speech model")
        #expect(HUDVisualState.transcribing.accessibilityLabel == "Transcribing dictation")
        #expect(HUDVisualState.inserting.accessibilityLabel == "Inserting dictation")
        #expect(HUDVisualState.success.accessibilityLabel == "Dictation inserted")
        #expect(HUDVisualState.cancelled.accessibilityLabel == "Dictation cancelled")
        #expect(HUDVisualState.error(message: "Mic access needed").accessibilityLabel == "Mic access needed")
    }

    @Test
    func defaultTranscriptionConfigurationUsesFastPreset() {
        let configuration = TranscriptionConfiguration()

        #expect(configuration.model == .baseEnglish)
        #expect(configuration.decodingMode == .greedy)
        #expect(configuration.fillerWordPolicy == .preserve)
        #expect(configuration.keepContext)
        #expect(configuration.trimSilence)
        #expect(configuration.normalizeAudio)
        #expect(!configuration.livePreviewEnabled)
        #expect(!configuration.tapStopsOnNextKeyPress)
        #expect(configuration.appAwarePolishingEnabled)
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
            configuration: TranscriptionConfiguration(
                vocabularyText: """
                Anthropic: anthropik
                Kubernetes: kuber netties
                """
            )
        )

        #expect(result == "Anthropic, Kubernetes and Anthropic.")
    }

    @Test
    func fillerWordPolicyCanRemoveCommonFillers() {
        let result = VocabularyPostProcessor.apply(
            to: "Um, I mean, this is, like, a test.",
            configuration: TranscriptionConfiguration(fillerWordPolicy: .remove)
        )

        #expect(result == "this is a test.")
    }

    @Test
    func appAwarePolisherKeepsMessagingInsertsCompact() {
        let target = DictationTargetApplication(
            bundleIdentifier: "com.tinyspeck.slackmacgap",
            displayName: "Slack"
        )
        let result = AppAwareTextPolisher.apply(
            to: "  sounds good   I will check  ",
            configuration: TranscriptionConfiguration(),
            targetApplication: target
        )

        #expect(result.profile == .messaging)
        #expect(result.text == "sounds good I will check")
        #expect(result.insertionText == "sounds good I will check")
    }

    @Test
    func appAwarePolisherAddsSentencePunctuationForWritingApps() {
        let target = DictationTargetApplication(
            bundleIdentifier: "com.apple.mail",
            displayName: "Mail"
        )
        let result = AppAwareTextPolisher.apply(
            to: "I will send the update tomorrow",
            configuration: TranscriptionConfiguration(),
            targetApplication: target
        )

        #expect(result.profile == .writing)
        #expect(result.text == "I will send the update tomorrow.")
        #expect(result.insertionText == "I will send the update tomorrow. ")
    }

    @Test
    func appAwarePolisherKeepsCodeAndTerminalAppsLiteral() {
        let target = DictationTargetApplication(
            bundleIdentifier: "com.microsoft.VSCode",
            displayName: "Visual Studio Code"
        )
        let result = AppAwareTextPolisher.apply(
            to: "git status",
            configuration: TranscriptionConfiguration(),
            targetApplication: target
        )

        #expect(result.profile == .code)
        #expect(result.text == "git status")
        #expect(result.insertionText == "git status")
    }

    @Test
    func disabledAppAwarePolisherKeepsDefaultInsertionSpacing() {
        let target = DictationTargetApplication(
            bundleIdentifier: "com.tinyspeck.slackmacgap",
            displayName: "Slack"
        )
        let result = AppAwareTextPolisher.apply(
            to: "sounds good",
            configuration: TranscriptionConfiguration(appAwarePolishingEnabled: false),
            targetApplication: target
        )

        #expect(result.profile == .general)
        #expect(result.insertionText == "sounds good ")
    }

    @Test
    func meetingStoreSavesLoadsUpdatesAndDeletesNotes() throws {
        let store = try MeetingStore(directoryURL: temporaryMeetingStoreURL())
        var note = MeetingNote(
            title: "Product Sync",
            userNotes: "Launch risks and owner follow-ups",
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 100)
        )

        try store.save(note)
        var loadedNotes = try store.loadNotes()
        #expect(loadedNotes.count == 1)
        #expect(loadedNotes[0].title == "Product Sync")

        note.userNotes = "Launch risk moved to Friday"
        note.updatedAt = Date(timeIntervalSince1970: 200)
        try store.save(note)
        loadedNotes = try store.loadNotes()
        #expect(loadedNotes.count == 1)
        #expect(loadedNotes[0].userNotes == "Launch risk moved to Friday")

        try store.delete(id: note.id)
        #expect(try store.loadNotes().isEmpty)
    }

    @Test
    func meetingStoreSearchesAcrossMeetingContent() throws {
        let store = try MeetingStore(directoryURL: temporaryMeetingStoreURL())
        let customerCall = MeetingNote(
            title: "Customer Call",
            userNotes: "Procurement is worried about security",
            transcriptSegments: [
                TranscriptSegment(text: "They asked about SSO and audit logs.", startTime: 0, endTime: 12)
            ],
            summary: MeetingSummary(
                overview: "Security review",
                decisions: ["Send SOC 2 packet"],
                actionItems: [MeetingActionItem(text: "Darsh to share audit log docs")]
            )
        )
        let productSync = MeetingNote(title: "Product Sync", userNotes: "Roadmap triage")

        try store.save(customerCall)
        try store.save(productSync)
        let notes = try store.loadNotes()

        #expect(store.search(notes, query: "audit").map(\.id) == [customerCall.id])
        #expect(store.search(notes, query: "roadmap").map(\.id) == [productSync.id])
        #expect(store.search(notes, query: "").count == 2)
    }

    @Test
    func meetingStorePersistsCalendarEventAndTranscriptSourceMetadata() throws {
        let store = try MeetingStore(directoryURL: temporaryMeetingStoreURL())
        let recordingID = UUID()
        let note = MeetingNote(
            title: "Design Review",
            transcriptSegments: [
                TranscriptSegment(
                    text: "This came from the call audio.",
                    startTime: 4,
                    endTime: 9,
                    speaker: .systemAudio,
                    captureSource: .systemAudio,
                    origin: .final,
                    recordingID: recordingID
                )
            ],
            calendarEventID: "calendar-event-123",
            transcriptState: .final,
            audioRecordings: [
                MeetingAudioRecordingMetadata(
                    id: recordingID,
                    fileName: "recording.caf",
                    source: .systemAudio,
                    duration: 5,
                    frameCount: 80_000,
                    speechDetected: true,
                    speechFrameCount: 80_000
                )
            ]
        )

        try store.save(note)
        let loadedNote = try #require(store.loadNotes().first)

        #expect(loadedNote.calendarEventID == "calendar-event-123")
        #expect(loadedNote.effectiveTranscriptState == .final)
        #expect(loadedNote.effectiveAudioRecordings.first?.fileName == "recording.caf")
        #expect(loadedNote.transcriptSegments.first?.speaker == .systemAudio)
        #expect(loadedNote.transcriptSegments.first?.captureSource == .systemAudio)
        #expect(loadedNote.transcriptSegments.first?.effectiveOrigin == .final)
        #expect(loadedNote.transcriptSegments.first?.recordingID == recordingID)
    }

    @Test
    func meetingStoreMigratesLegacyNotesToCurrentSchemaVersion() throws {
        let directoryURL = temporaryMeetingStoreURL()
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let legacyID = UUID()
        let legacyJSON = """
        {
          "id": "\(legacyID.uuidString)",
          "title": "Legacy Sync",
          "userNotes": "Old note format",
          "transcriptSegments": [],
          "createdAt": "1970-01-01T00:00:01Z",
          "updatedAt": "1970-01-01T00:00:02Z"
        }
        """
        let legacyURL = directoryURL.appendingPathComponent(legacyID.uuidString).appendingPathExtension("json")
        try legacyJSON.data(using: .utf8)?.write(to: legacyURL)

        let store = try MeetingStore(directoryURL: directoryURL)
        let result = try store.loadNotesWithDiagnostics()
        let migratedNote = try #require(result.notes.first)
        let migratedData = try Data(contentsOf: legacyURL)
        let migratedJSON = String(decoding: migratedData, as: UTF8.self)

        #expect(result.quarantinedFiles.isEmpty)
        #expect(migratedNote.id == legacyID)
        #expect(migratedNote.title == "Legacy Sync")
        #expect(migratedNote.schemaVersion == MeetingNote.currentSchemaVersion)
        #expect(migratedJSON.contains("\"schemaVersion\" : \(MeetingNote.currentSchemaVersion)"))
    }

    @Test
    func meetingStoreQuarantinesUnreadableFilesWithoutDroppingReadableNotes() throws {
        let directoryURL = temporaryMeetingStoreURL()
        let store = try MeetingStore(directoryURL: directoryURL)
        let readableNote = MeetingNote(title: "Readable")
        try store.save(readableNote)

        let corruptURL = directoryURL.appendingPathComponent("corrupt").appendingPathExtension("json")
        try Data("{ not valid json".utf8).write(to: corruptURL)

        let result = try store.loadNotesWithDiagnostics()
        let quarantine = try #require(result.quarantinedFiles.first)
        let quarantinedURL = directoryURL
            .appendingPathComponent("Quarantine", isDirectory: true)
            .appendingPathComponent(quarantine.quarantineFileName)

        #expect(result.notes.map(\.id) == [readableNote.id])
        #expect(result.quarantinedFiles.count == 1)
        #expect(quarantine.originalFileName == "corrupt.json")
        #expect(!FileManager.default.fileExists(atPath: corruptURL.path))
        #expect(FileManager.default.fileExists(atPath: quarantinedURL.path))
        #expect(!quarantine.reason.isEmpty)
    }

    @Test
    func meetingNoteReplacesOnlyMatchingLiveDraftSegmentsWithFinalTranscript() {
        let recordingID = UUID()
        let olderRecordingID = UUID()
        var note = MeetingNote(
            transcriptSegments: [
                TranscriptSegment(
                    text: "Earlier final transcript",
                    startTime: 0,
                    endTime: 2,
                    origin: .final,
                    recordingID: olderRecordingID
                ),
                TranscriptSegment(
                    text: "Live draft one",
                    startTime: 0,
                    endTime: 5,
                    origin: .liveDraft,
                    recordingID: recordingID
                ),
                TranscriptSegment(
                    text: "Live draft two",
                    startTime: 5,
                    endTime: 10,
                    origin: .liveDraft,
                    recordingID: recordingID
                )
            ],
            transcriptState: .finalizing
        )

        note.replaceLiveDraftSegments(
            recordingID: recordingID,
            with: [
                TranscriptSegment(
                    text: "Final whole recording transcript",
                    startTime: 0,
                    endTime: 10,
                    origin: .final,
                    recordingID: recordingID
                )
            ]
        )

        #expect(note.effectiveTranscriptState == .final)
        #expect(note.transcriptSegments.map(\.text) == [
            "Earlier final transcript",
            "Final whole recording transcript"
        ])
        #expect(note.transcriptSegments.last?.effectiveOrigin == .final)
    }

    @Test
    func meetingRecordingStateDefaultsToFinalForLegacyMetadata() {
        let legacy = MeetingAudioRecordingMetadata(
            id: UUID(),
            fileName: "recording.caf",
            source: .systemAudio
        )
        #expect(legacy.state == nil)
        #expect(legacy.effectiveState == .final)
    }

    @Test
    func legacyRecordingStateDefaultsToFinalAfterDecoding() throws {
        let recordingID = UUID()
        let note = MeetingNote(audioRecordings: [
            MeetingAudioRecordingMetadata(
                id: recordingID,
                fileName: "legacy.caf",
                source: .systemAudio,
                state: .final
            )
        ])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var object = try #require(JSONSerialization.jsonObject(with: encoder.encode(note)) as? [String: Any])
        var recordings = try #require(object["audioRecordings"] as? [[String: Any]])
        recordings[0].removeValue(forKey: "state")
        object["audioRecordings"] = recordings
        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let decoded = try decoder.decode(MeetingNote.self, from: legacyData)

        #expect(decoded.effectiveAudioRecordings.first?.state == nil)
        #expect(decoded.effectiveAudioRecordings.first?.effectiveState == .final)
    }

    @Test
    func meetingNoteRecoversRecordingInterruptedByForceQuit() {
        let recordingID = UUID()
        let note = MeetingNote(
            transcriptSegments: [
                TranscriptSegment(text: "Live draft before the crash", startTime: 0, endTime: 5, origin: .liveDraft, recordingID: recordingID)
            ],
            transcriptState: .liveDraft,
            audioRecordings: [
                MeetingAudioRecordingMetadata(id: recordingID, fileName: "r.caf", source: .systemAudio, state: .recording)
            ]
        )

        let recovered = note.recoveredAfterInterruptedCapture()

        #expect(recovered.effectiveTranscriptState == .finalizationFailed)
        #expect(recovered.transcriptStatusMessage?.contains("Recording was interrupted") == true)
        #expect(recovered.effectiveAudioRecordings.first?.effectiveState == .finalizationFailed)
        #expect(recovered.transcriptSegments.map(\.text) == ["Live draft before the crash"])
    }

    @Test
    func meetingNoteRecoversFinalizationInterruptedAfterStop() {
        let recordingID = UUID()
        let note = MeetingNote(
            transcriptState: .finalizing,
            audioRecordings: [
                MeetingAudioRecordingMetadata(
                    id: recordingID,
                    fileName: "r.caf",
                    source: .systemAudio,
                    duration: 10,
                    frameCount: 160_000,
                    state: .recorded
                )
            ]
        )

        let recovered = note.recoveredAfterInterruptedCapture()

        #expect(recovered.effectiveTranscriptState == .finalizationFailed)
        #expect(recovered.transcriptStatusMessage?.contains("Retry from the saved audio") == true)
        #expect(recovered.effectiveAudioRecordings.first?.effectiveState == .finalizationFailed)
    }

    @Test
    func meetingNoteLeavesCompletedNotesUntouchedByRecovery() {
        let recordingID = UUID()
        let note = MeetingNote(
            transcriptSegments: [
                TranscriptSegment(text: "Final", startTime: 0, endTime: 1, origin: .final, recordingID: recordingID)
            ],
            transcriptState: .final,
            audioRecordings: [
                MeetingAudioRecordingMetadata(id: recordingID, fileName: "r.caf", source: .systemAudio, state: .final)
            ]
        )

        let recovered = note.recoveredAfterInterruptedCapture()

        #expect(recovered.effectiveTranscriptState == .final)
        #expect(recovered.transcriptStatusMessage == nil)
    }

    @Test
    func meetingNoteResetsLiveDraftWithNoAudioOnRecovery() {
        let withDraft = MeetingNote(
            transcriptSegments: [
                TranscriptSegment(text: "Draft only", startTime: 0, endTime: 1, origin: .liveDraft)
            ],
            transcriptState: .liveDraft
        )
        #expect(withDraft.recoveredAfterInterruptedCapture().effectiveTranscriptState == .liveDraft)

        let empty = MeetingNote(transcriptState: .liveDraft)
        #expect(empty.recoveredAfterInterruptedCapture().effectiveTranscriptState == .empty)
    }

    @Test
    func meetingNoteDoesNotClaimMissingAudioSurvivedRecovery() {
        let recordingID = UUID()
        let note = MeetingNote(
            transcriptSegments: [
                TranscriptSegment(text: "Draft survived", startTime: 0, endTime: 1, origin: .liveDraft, recordingID: recordingID)
            ],
            transcriptState: .liveDraft,
            audioRecordings: [
                MeetingAudioRecordingMetadata(id: recordingID, fileName: "missing.caf", source: .systemAudio, state: .recording)
            ]
        )

        let recovered = note.recoveredAfterInterruptedCapture(usableRecordingIDs: [])

        #expect(recovered.effectiveTranscriptState == .liveDraft)
        #expect(recovered.transcriptStatusMessage?.contains("saved recording is unavailable") == true)
        #expect(recovered.transcriptStatusMessage?.contains("audio and draft transcript are saved") != true)
        #expect(recovered.effectiveAudioRecordings.isEmpty)
        #expect(recovered.transcriptSegments.map(\.text) == ["Draft survived"])
    }

    @Test
    func meetingRecordingRecoveryRelinksOrphansToMatchingNote() throws {
        let noteID = UUID()
        let recordingID = UUID()
        let note = MeetingNote(id: noteID, title: "Recovered", transcriptState: .liveDraft)
        let orphan = OrphanedMeetingRecording(recordingID: recordingID, noteID: noteID, fileName: "\(noteID.uuidString)-\(recordingID.uuidString).caf")

        let result = MeetingRecordingRecovery.relink([note], orphans: [orphan])

        #expect(result.unrecoverable.isEmpty)
        let recovered = try #require(result.notes.first)
        #expect(recovered.effectiveAudioRecordings.count == 1)
        #expect(recovered.effectiveAudioRecordings.first?.id == recordingID)
        #expect(recovered.effectiveAudioRecordings.first?.effectiveState == .recording)
    }

    @Test
    func meetingRecordingRecoveryCollectsUnrecoverableOrphans() {
        let noteID = UUID()
        let recordingID = UUID()
        let orphan = OrphanedMeetingRecording(recordingID: recordingID, noteID: noteID, fileName: "stranded.caf")

        let result = MeetingRecordingRecovery.relink([], orphans: [orphan])

        #expect(result.notes.isEmpty)
        #expect(result.unrecoverable.map(\.id) == [recordingID])
    }

    @Test
    func orphanKeepAcknowledgementSurvivesOnlyWhileFileIsDetected() {
        let keptID = UUID()
        let vanishedID = UUID()
        let detected = OrphanedMeetingRecording(
            recordingID: keptID,
            noteID: UUID(),
            fileName: "kept.caf"
        )
        let stored = OrphanRecordingAcknowledgements.load([keptID.uuidString, vanishedID.uuidString])

        let reconciled = OrphanRecordingAcknowledgements.reconcile(stored, detectedOrphans: [detected])

        #expect(reconciled == Set([keptID]))
    }

    @Test
    func meetingRecordingRecoverySkipsAlreadyReferencedRecordings() {
        let noteID = UUID()
        let recordingID = UUID()
        let note = MeetingNote(
            id: noteID,
            transcriptState: .final,
            audioRecordings: [MeetingAudioRecordingMetadata(id: recordingID, fileName: "existing.caf", source: .systemAudio, state: .final)]
        )
        let orphan = OrphanedMeetingRecording(recordingID: recordingID, noteID: noteID, fileName: "\(noteID.uuidString)-\(recordingID.uuidString).caf")

        let result = MeetingRecordingRecovery.relink([note], orphans: [orphan])

        #expect(result.unrecoverable.isEmpty)
        #expect(result.notes.first?.effectiveAudioRecordings.count == 1)
    }

    @Test
    func relinkedOrphanFlowsIntoInterruptedRecoveryMessage() throws {
        let noteID = UUID()
        let recordingID = UUID()
        let note = MeetingNote(id: noteID, transcriptState: .liveDraft)
        let orphan = OrphanedMeetingRecording(recordingID: recordingID, noteID: noteID, fileName: "\(noteID.uuidString)-\(recordingID.uuidString).caf")

        let relinked = MeetingRecordingRecovery.relink([note], orphans: [orphan]).notes
        let recovered = try #require(relinked.first).recoveredAfterInterruptedCapture()

        #expect(recovered.effectiveTranscriptState == .finalizationFailed)
        #expect(recovered.transcriptStatusMessage?.contains("Recording was interrupted") == true)
    }

    @Test
    func meetingAudioStoreParsesRecordingFileNames() throws {
        let noteID = UUID()
        let recordingID = UUID()
        let fileName = "\(noteID.uuidString)-\(recordingID.uuidString).caf"

        let parsed = try #require(MeetingAudioStore.parseRecordingFileName(fileName))
        #expect(parsed.noteID == noteID)
        #expect(parsed.recordingID == recordingID)
        #expect(parsed.fileName == fileName)

        #expect(MeetingAudioStore.parseRecordingFileName("not-a-valid-file.caf") == nil)
        #expect(MeetingAudioStore.parseRecordingFileName("\(UUID().uuidString).caf") == nil)
    }

    @Test
    func meetingAudioStoreDiscoversOrphansNotReferencedByNotes() throws {
        let store = try MeetingAudioStore(directoryURL: temporaryMeetingAudioStoreURL())
        let noteID = UUID()
        let referencedRecordingID = UUID()
        let orphanedRecordingID = UUID()

        let referencedName = "\(noteID.uuidString)-\(referencedRecordingID.uuidString).caf"
        let orphanedName = "\(noteID.uuidString)-\(orphanedRecordingID.uuidString).caf"
        try Data([0x00]).write(to: store.fileURL(for: MeetingAudioRecordingMetadata(id: referencedRecordingID, fileName: referencedName, source: .systemAudio)))
        try Data([0x00]).write(to: store.fileURL(for: MeetingAudioRecordingMetadata(id: orphanedRecordingID, fileName: orphanedName, source: .systemAudio)))

        let note = MeetingNote(
            id: noteID,
            transcriptState: .final,
            audioRecordings: [MeetingAudioRecordingMetadata(id: referencedRecordingID, fileName: referencedName, source: .systemAudio, state: .final)]
        )

        let orphans = store.orphanedRecordingDescriptors(referencedBy: [note])
        #expect(orphans.map(\.recordingID) == [orphanedRecordingID])
    }

    @Test
    func meetingAudioStoreRequiresSavedFramesBeforeReportingAudioUsable() async throws {
        let store = try MeetingAudioStore(directoryURL: temporaryMeetingAudioStoreURL())
        let noteID = UUID()

        let emptyRecording = MeetingAudioRecordingMetadata(
            id: UUID(),
            fileName: MeetingAudioStore.recordingFileName(noteID: noteID, recordingID: UUID()),
            source: .systemAudio,
            state: .recording
        )
        try Data().write(to: store.fileURL(for: emptyRecording))
        #expect(!store.hasUsableAudio(for: emptyRecording))

        let recordingID = UUID()
        let recorder = try store.makeRecorder(
            noteID: noteID,
            recordingID: recordingID,
            source: .systemAudio
        )
        let chunk = AudioChunk(samples: Array(repeating: 0.1, count: 1_600), frameCount: 1_600, sampleRate: 16_000)
        try await recorder.append(chunk, level: 0.1)
        let savedRecording = await recorder.finish(fallbackMetrics: nil)

        #expect(store.hasUsableAudio(for: savedRecording))
    }

    @Test
    func meetingAudioRecorderPreservesFramesWhenCaptureStartupFails() async throws {
        let store = try MeetingAudioStore(directoryURL: temporaryMeetingAudioStoreURL())
        let noteID = UUID()
        let recordingID = UUID()
        let recorder = try store.makeRecorder(noteID: noteID, recordingID: recordingID, source: .microphone)
        let chunk = AudioChunk(samples: Array(repeating: 0.1, count: 1_600), frameCount: 1_600, sampleRate: 16_000)
        try await recorder.append(chunk, level: 0.1)

        let preserved = try #require(await recorder.finishAfterCaptureStartFailure())

        #expect(preserved.effectiveState == .finalizationFailed)
        #expect(preserved.frameCount == 1_600)
        #expect(store.hasUsableAudio(for: preserved))
    }

    @Test
    func meetingAudioRecorderCleansUpZeroFrameStartupFailure() async throws {
        let store = try MeetingAudioStore(directoryURL: temporaryMeetingAudioStoreURL())
        let noteID = UUID()
        let recordingID = UUID()
        let fileName = MeetingAudioStore.recordingFileName(noteID: noteID, recordingID: recordingID)
        let metadata = MeetingAudioRecordingMetadata(id: recordingID, fileName: fileName, source: .systemAudio, state: .recording)
        let recorder = try store.makeRecorder(noteID: noteID, recordingID: recordingID, source: .systemAudio)

        #expect(try await recorder.finishAfterCaptureStartFailure() == nil)
        #expect(!FileManager.default.fileExists(atPath: store.fileURL(for: metadata).path))
    }

    @Test
    func meetingAudioRecorderReportsZeroFrameCleanupFailure() async throws {
        let directoryURL = temporaryMeetingAudioStoreURL()
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let fileURL = directoryURL.appendingPathComponent("cleanup-failure.caf")
        let recorder = try MeetingAudioRecorder(
            fileURL: fileURL,
            fileName: fileURL.lastPathComponent,
            recordingID: UUID(),
            source: .systemAudio,
            removeFile: { _ in throw CocoaError(.fileWriteNoPermission) }
        )

        var didThrow = false
        do {
            _ = try await recorder.finishAfterCaptureStartFailure()
        } catch {
            didThrow = true
        }

        #expect(didThrow)
        #expect(FileManager.default.fileExists(atPath: fileURL.path))
    }

    @Test
    func meetingCaptureChunkQueueDrainsQueuedOperationsInOrder() async {
        let queue = MeetingCaptureChunkQueue()
        let values = IntCollector()
        queue.enqueue {
            try? await Task.sleep(for: .milliseconds(30))
            await values.append(1)
        }
        queue.enqueue {
            await values.append(2)
        }

        await queue.drain()

        #expect(await values.snapshot() == [1, 2])
    }

    @Test
    func meetingCaptureChunkQueueDrainsRecorderWritesBeforeFinish() async throws {
        let store = try MeetingAudioStore(directoryURL: temporaryMeetingAudioStoreURL())
        let noteID = UUID()
        let recordingID = UUID()
        let recorder = try store.makeRecorder(noteID: noteID, recordingID: recordingID, source: .systemAudio)
        let queue = MeetingCaptureChunkQueue()
        queue.enqueue {
            try? await Task.sleep(for: .milliseconds(30))
            try? await recorder.append(
                AudioChunk(samples: Array(repeating: 0.1, count: 1_600), frameCount: 1_600, sampleRate: 16_000),
                level: 0.1
            )
        }

        await queue.drain()
        let recording = await recorder.finish(fallbackMetrics: nil)

        #expect(recording.frameCount == 1_600)
        #expect(store.hasUsableAudio(for: recording))
    }

    @Test
    func meetingAudioOrphanSweepNeverDeletesDiscoveredAudio() async throws {
        let store = try MeetingAudioStore(directoryURL: temporaryMeetingAudioStoreURL())
        let noteID = UUID()
        let recordingID = UUID()
        let recorder = try store.makeRecorder(noteID: noteID, recordingID: recordingID, source: .systemAudio)
        let chunk = AudioChunk(samples: Array(repeating: 0.1, count: 1_600), frameCount: 1_600, sampleRate: 16_000)
        try await recorder.append(chunk, level: 0.1)
        let recording = await recorder.finish(fallbackMetrics: nil)

        let firstSweep = store.orphanedRecordingDescriptors(referencedBy: [])
        let secondSweep = store.orphanedRecordingDescriptors(referencedBy: [])

        #expect(firstSweep.map(\.recordingID) == [recordingID])
        #expect(secondSweep.map(\.recordingID) == [recordingID])
        #expect(store.hasUsableAudio(for: recording))
    }

    @Test
    func meetingAudioOrphanIsDeletedOnlyAfterExplicitDiscard() async throws {
        let store = try MeetingAudioStore(directoryURL: temporaryMeetingAudioStoreURL())
        let noteID = UUID()
        let recordingID = UUID()
        let recorder = try store.makeRecorder(noteID: noteID, recordingID: recordingID, source: .systemAudio)
        let chunk = AudioChunk(samples: Array(repeating: 0.1, count: 1_600), frameCount: 1_600, sampleRate: 16_000)
        try await recorder.append(chunk, level: 0.1)
        let recording = await recorder.finish(fallbackMetrics: nil)
        let orphan = try #require(store.orphanedRecordingDescriptors(referencedBy: []).first)

        #expect(store.hasUsableAudio(for: recording))
        store.discardOrphanedRecording(orphan)

        #expect(!FileManager.default.fileExists(atPath: store.fileURL(for: recording).path))
        #expect(store.orphanedRecordingDescriptors(referencedBy: []).isEmpty)
    }

    @Test
    func matchingNoteOrphanRelinkPersistsAcrossReload() async throws {
        let meetingStore = try MeetingStore(directoryURL: temporaryMeetingStoreURL())
        let audioStore = try MeetingAudioStore(directoryURL: temporaryMeetingAudioStoreURL())
        let noteID = UUID()
        let recordingID = UUID()
        try meetingStore.save(MeetingNote(id: noteID, title: "Interrupted", transcriptState: .liveDraft))
        let recorder = try audioStore.makeRecorder(noteID: noteID, recordingID: recordingID, source: .systemAudio)
        let chunk = AudioChunk(samples: Array(repeating: 0.1, count: 1_600), frameCount: 1_600, sampleRate: 16_000)
        try await recorder.append(chunk, level: 0.1)
        _ = await recorder.finish(fallbackMetrics: nil)

        let loadedNotes = try meetingStore.loadNotes()
        let orphans = audioStore.orphanedRecordingDescriptors(referencedBy: loadedNotes)
        let relinked = MeetingRecordingRecovery.relink(loadedNotes, orphans: orphans)
        let usableIDs = Set(relinked.notes.flatMap(\.effectiveAudioRecordings).filter { audioStore.hasUsableAudio(for: $0) }.map(\.id))
        let recovered = try #require(relinked.notes.first).recoveredAfterInterruptedCapture(usableRecordingIDs: usableIDs)
        try meetingStore.save(recovered)

        let reloaded = try #require(meetingStore.loadNotes().first)
        #expect(reloaded.effectiveAudioRecordings.first?.id == recordingID)
        #expect(reloaded.effectiveAudioRecordings.first?.effectiveState == .finalizationFailed)
        #expect(reloaded.transcriptStatusMessage?.contains("Your audio and draft transcript are saved") == true)
        #expect(audioStore.hasUsableAudio(for: try #require(reloaded.effectiveAudioRecordings.first)))
    }

    @Test
    func launchRecoveryReconstructsInterruptedCaptureFromPersistedStores() async throws {
        let meetingStore = try MeetingStore(directoryURL: temporaryMeetingStoreURL())
        let audioStore = try MeetingAudioStore(directoryURL: temporaryMeetingAudioStoreURL())
        let noteID = UUID()
        let recordingID = UUID()
        let fileName = MeetingAudioStore.recordingFileName(noteID: noteID, recordingID: recordingID)
        let note = MeetingNote(
            id: noteID,
            transcriptSegments: [
                TranscriptSegment(text: "Persisted live draft", startTime: 0, endTime: 1, origin: .liveDraft, recordingID: recordingID)
            ],
            transcriptState: .liveDraft,
            audioRecordings: [
                MeetingAudioRecordingMetadata(id: recordingID, fileName: fileName, source: .systemAudio, state: .recording)
            ]
        )
        try meetingStore.save(note)
        let recorder = try audioStore.makeRecorder(noteID: noteID, recordingID: recordingID, source: .systemAudio)
        try await recorder.append(
            AudioChunk(samples: Array(repeating: 0.1, count: 1_600), frameCount: 1_600, sampleRate: 16_000),
            level: 0.1
        )
        _ = await recorder.finish(fallbackMetrics: nil)

        let recovered = audioStore.recover(notes: try meetingStore.loadNotes())
        let recoveredNote = try #require(recovered.notes.first)

        #expect(recoveredNote.effectiveAudioRecordings.first?.effectiveState == .finalizationFailed)
        #expect(recoveredNote.transcriptSegments.map(\.text) == ["Persisted live draft"])
        #expect(recoveredNote.transcriptStatusMessage?.contains("audio and draft transcript are saved") == true)
        #expect(recovered.recoverableOrphans.isEmpty)
    }

    @Test
    func launchRecoveryPreservesMissingAudioWarningAndDisablesRetry() throws {
        let recordingID = UUID()
        let note = MeetingNote(
            transcriptSegments: [
                TranscriptSegment(text: "Draft remains", startTime: 0, endTime: 1, origin: .liveDraft, recordingID: recordingID)
            ],
            transcriptState: .finalizationFailed,
            audioRecordings: [
                MeetingAudioRecordingMetadata(id: recordingID, fileName: "missing.caf", source: .systemAudio, state: .finalizationFailed)
            ]
        )
        let audioStore = try MeetingAudioStore(directoryURL: temporaryMeetingAudioStoreURL())
        let recovered = audioStore.recover(notes: [note]).notes.first

        #expect(recovered?.effectiveAudioRecordings.isEmpty == true)
        #expect(recovered?.effectiveTranscriptState == .liveDraft)
        #expect(recovered?.transcriptStatusMessage?.contains("saved recording is unavailable") == true)
        #expect(recovered?.finalPassChallenges.isEmpty == true)
    }

    @Test
    func unusableReferencedAudioIsSurfacedByTheSameRecoverySweep() throws {
        let audioStore = try MeetingAudioStore(directoryURL: temporaryMeetingAudioStoreURL())
        let noteID = UUID()
        let recordingID = UUID()
        let fileName = MeetingAudioStore.recordingFileName(noteID: noteID, recordingID: recordingID)
        let recording = MeetingAudioRecordingMetadata(
            id: recordingID,
            fileName: fileName,
            source: .systemAudio,
            state: .recording
        )
        try Data([0x00]).write(to: audioStore.fileURL(for: recording))
        let note = MeetingNote(
            id: noteID,
            transcriptState: .liveDraft,
            audioRecordings: [recording]
        )

        let recovered = note.recoveredAfterInterruptedCapture(usableRecordingIDs: [])
        let surfaced = audioStore.orphanedRecordingDescriptors(referencedBy: [recovered])

        #expect(recovered.effectiveAudioRecordings.isEmpty)
        #expect(surfaced.map(\.recordingID) == [recordingID])
    }

    @Test
    func meetingNoteReplacesAllSegmentsForRecordingIdempotently() {
        let recordingID = UUID()
        let otherRecordingID = UUID()
        var note = MeetingNote(
            transcriptSegments: [
                TranscriptSegment(text: "Other recording final", startTime: 0, endTime: 1, origin: .final, recordingID: otherRecordingID),
                TranscriptSegment(text: "Live draft", startTime: 0, endTime: 5, origin: .liveDraft, recordingID: recordingID),
                TranscriptSegment(text: "Prior final", startTime: 0, endTime: 10, origin: .final, recordingID: recordingID)
            ],
            transcriptState: .finalizationFailed
        )

        note.replaceSegmentsForRecording(recordingID: recordingID, with: [
            TranscriptSegment(text: "Fresh final", startTime: 0, endTime: 10, origin: .final, recordingID: recordingID)
        ])

        #expect(note.transcriptSegments.map(\.text) == ["Other recording final", "Fresh final"])
        #expect(note.effectiveTranscriptState == .final)

        note.replaceSegmentsForRecording(recordingID: recordingID, with: [
            TranscriptSegment(text: "Fresh final", startTime: 0, endTime: 10, origin: .final, recordingID: recordingID)
        ])
        #expect(note.transcriptSegments.map(\.text) == ["Other recording final", "Fresh final"])
    }

    @Test
    func meetingNoteRetainsAndRevertsLiveDraftWhenFinalDiffers() {
        let recordingID = UUID()
        var note = MeetingNote(
            transcriptSegments: [
                TranscriptSegment(text: "Draft take", startTime: 0, endTime: 5, origin: .liveDraft, recordingID: recordingID)
            ],
            transcriptState: .finalizing
        )

        note.applyFinalSegments(
            [TranscriptSegment(text: "Cleaned final take", startTime: 0, endTime: 5, origin: .final, recordingID: recordingID)],
            forRecording: recordingID
        )

        #expect(note.retainedLiveDraftText(for: recordingID) == "Draft take")
        #expect(note.transcriptSegments.map(\.text) == ["Cleaned final take"])

        note.revertFinalPass(for: recordingID)

        #expect(note.transcriptSegments.map(\.text) == ["Draft take"])
        #expect(note.effectiveTranscriptState == .liveDraft)
        #expect(note.retainedLiveDraftText(for: recordingID) == nil)
    }

    @Test
    func repeatedFinalPassPreservesOriginalDraftAndTranscriptOrder() {
        let earlierRecordingID = UUID()
        let retriedRecordingID = UUID()
        let laterRecordingID = UUID()
        var note = MeetingNote(
            transcriptSegments: [
                TranscriptSegment(text: "Earlier final", startTime: 0, endTime: 2, origin: .final, recordingID: earlierRecordingID),
                TranscriptSegment(text: "Original live draft", startTime: 0, endTime: 5, origin: .liveDraft, recordingID: retriedRecordingID),
                TranscriptSegment(text: "Later final", startTime: 0, endTime: 2, origin: .final, recordingID: laterRecordingID)
            ],
            transcriptState: .finalizing
        )

        note.applyFinalSegments(
            [TranscriptSegment(text: "First cleaned final", startTime: 0, endTime: 5, origin: .final, recordingID: retriedRecordingID)],
            forRecording: retriedRecordingID
        )
        note.applyFinalSegments(
            [TranscriptSegment(text: "Second cleaned final", startTime: 0, endTime: 5, origin: .final, recordingID: retriedRecordingID)],
            forRecording: retriedRecordingID
        )

        #expect(note.transcriptSegments.map(\.text) == ["Earlier final", "Second cleaned final", "Later final"])
        #expect(note.retainedLiveDraftText(for: retriedRecordingID) == "Original live draft")

        note.revertFinalPass(for: retriedRecordingID)

        #expect(note.transcriptSegments.map(\.text) == ["Earlier final", "Original live draft", "Later final"])
    }

    @Test
    func meetingNoteDoesNotRetainLiveDraftWhenFinalMatches() {
        let recordingID = UUID()
        var note = MeetingNote(
            transcriptSegments: [
                TranscriptSegment(text: "Same words", startTime: 0, endTime: 5, origin: .liveDraft, recordingID: recordingID)
            ],
            transcriptState: .finalizing
        )

        note.applyFinalSegments(
            [TranscriptSegment(text: "Same words", startTime: 0, endTime: 5, origin: .final, recordingID: recordingID)],
            forRecording: recordingID
        )

        #expect(note.retainedLiveDraftText(for: recordingID) == nil)
        #expect(note.transcriptSegments.map(\.text) == ["Same words"])
        #expect(note.effectiveTranscriptState == .final)
    }

    @Test
    func finalPassMaterialChangeIgnoresWhitespaceCasingAndPunctuation() {
        #expect(!MeetingNote.isMaterialFinalPassChange(
            liveDraftText: "  Hello, WORLD!  This is Cadence.",
            finalText: "hello world this is cadence"
        ))
        #expect(MeetingNote.isMaterialFinalPassChange(
            liveDraftText: "We agreed to ship on Friday.",
            finalText: "We agreed to revisit the plan next month."
        ))
        #expect(MeetingNote.isMaterialFinalPassChange(
            liveDraftText: "We should meet now here.",
            finalText: "We should meet nowhere."
        ))
    }

    @Test
    func trivialFinalPassChangesDoNotRetainLineage() {
        let recordingID = UUID()
        var note = MeetingNote(
            transcriptSegments: [
                TranscriptSegment(text: "Hello, WORLD!", startTime: 0, endTime: 2, origin: .liveDraft, recordingID: recordingID)
            ],
            transcriptState: .finalizing
        )

        note.applyFinalSegments(
            [TranscriptSegment(text: "hello world", startTime: 0, endTime: 2, origin: .final, recordingID: recordingID)],
            forRecording: recordingID
        )

        #expect(note.retainedLiveDraftText(for: recordingID) == nil)
    }

    @Test
    func transcriptStateRollupKeepsUnfinishedRecordingsVisible() {
        func recording(_ state: MeetingRecordingState) -> MeetingAudioRecordingMetadata {
            MeetingAudioRecordingMetadata(
                id: UUID(),
                fileName: "\(UUID().uuidString).caf",
                source: .systemAudio,
                state: state
            )
        }

        #expect(MeetingNote.rollupTranscriptState(
            recordings: [recording(.final), recording(.finalizationFailed)],
            hasTranscript: true
        ) == .finalizationFailed)
        #expect(MeetingNote.rollupTranscriptState(
            recordings: [recording(.final), recording(.finalizing)],
            hasTranscript: true
        ) == .finalizing)
        #expect(MeetingNote.rollupTranscriptState(
            recordings: [recording(.final), recording(.recording)],
            hasTranscript: true
        ) == .liveDraft)
        #expect(MeetingNote.rollupTranscriptState(
            recordings: [recording(.final), recording(.recorded)],
            hasTranscript: true
        ) == .finalizing)
        #expect(MeetingNote.rollupTranscriptState(
            recordings: [recording(.final)],
            hasTranscript: true
        ) == .final)
    }

    @Test
    func successfulRecordingDoesNotHideAnotherFailedRecording() {
        let successfulRecordingID = UUID()
        let failedRecordingID = UUID()
        var note = MeetingNote(
            transcriptSegments: [
                TranscriptSegment(text: "Draft", startTime: 0, endTime: 2, origin: .liveDraft, recordingID: successfulRecordingID)
            ],
            transcriptState: .finalizationFailed,
            audioRecordings: [
                MeetingAudioRecordingMetadata(id: successfulRecordingID, fileName: "success.caf", source: .systemAudio, state: .finalizing),
                MeetingAudioRecordingMetadata(id: failedRecordingID, fileName: "failed.caf", source: .microphone, state: .finalizationFailed)
            ]
        )

        note.applyFinalSegments(
            [TranscriptSegment(text: "Final", startTime: 0, endTime: 2, origin: .final, recordingID: successfulRecordingID)],
            forRecording: successfulRecordingID
        )
        note.audioRecordings?[0].state = .final

        #expect(note.effectiveTranscriptState == .finalizationFailed)
    }

    @Test
    func finalPassChallengesArePerRecordingAndSkipNormalSuccess() {
        let failedRecordingID = UUID()
        let changedRecordingID = UUID()
        let successfulRecordingID = UUID()
        let retainedSegment = TranscriptSegment(
            text: "Original changed-recording draft",
            startTime: 0,
            endTime: 2,
            origin: .liveDraft,
            recordingID: changedRecordingID
        )
        let note = MeetingNote(
            transcriptSegments: [
                TranscriptSegment(text: "Failed recording draft", startTime: 0, endTime: 2, origin: .liveDraft, recordingID: failedRecordingID),
                TranscriptSegment(text: "Changed final", startTime: 0, endTime: 2, origin: .final, recordingID: changedRecordingID),
                TranscriptSegment(text: "Normal final", startTime: 0, endTime: 2, origin: .final, recordingID: successfulRecordingID)
            ],
            transcriptState: .finalizationFailed,
            audioRecordings: [
                MeetingAudioRecordingMetadata(id: failedRecordingID, fileName: "failed.caf", source: .systemAudio, state: .finalizationFailed),
                MeetingAudioRecordingMetadata(id: changedRecordingID, fileName: "changed.caf", source: .microphone, state: .final),
                MeetingAudioRecordingMetadata(id: successfulRecordingID, fileName: "normal.caf", source: .systemAudio, state: .final)
            ],
            retainedLiveDraftByRecording: [changedRecordingID.uuidString: [retainedSegment]]
        )

        #expect(note.finalPassChallenges == [
            MeetingFinalPassChallenge(
                recordingID: failedRecordingID,
                kind: .failure,
                draftPeek: "Failed recording draft",
                allowsRevertToDraft: false
            ),
            MeetingFinalPassChallenge(
                recordingID: changedRecordingID,
                kind: .materialChange,
                draftPeek: "Original changed-recording draft",
                allowsRevertToDraft: true
            )
        ])

        var finalizing = note
        finalizing.audioRecordings?[1].state = .finalizing
        #expect(finalizing.finalPassChallenges.map(\.recordingID) == [failedRecordingID])
    }

    @Test
    func meetingNoteAcceptClearsRetainedLiveDraft() {
        let recordingID = UUID()
        var note = MeetingNote(
            transcriptSegments: [
                TranscriptSegment(text: "Draft", startTime: 0, endTime: 5, origin: .liveDraft, recordingID: recordingID)
            ],
            transcriptState: .finalizing
        )
        note.applyFinalSegments(
            [TranscriptSegment(text: "Different final", startTime: 0, endTime: 5, origin: .final, recordingID: recordingID)],
            forRecording: recordingID
        )
        #expect(note.retainedLiveDraftText(for: recordingID) != nil)

        note.acceptFinalPass(for: recordingID)

        #expect(note.retainedLiveDraftText(for: recordingID) == nil)
        #expect(note.transcriptSegments.map(\.text) == ["Different final"])
    }

    @Test
    func retainedLiveDraftSnapshotsSurviveCodableRoundTrip() throws {
        let recordingID = UUID()
        let retainedSegment = TranscriptSegment(
            text: "Durable original draft",
            startTime: 0,
            endTime: 4,
            origin: .liveDraft,
            recordingID: recordingID
        )
        let note = MeetingNote(
            transcriptSegments: [
                TranscriptSegment(text: "Final transcript", startTime: 0, endTime: 4, origin: .final, recordingID: recordingID)
            ],
            transcriptState: .final,
            audioRecordings: [
                MeetingAudioRecordingMetadata(id: recordingID, fileName: "recording.caf", source: .systemAudio, state: .final)
            ],
            retainedLiveDraftByRecording: [recordingID.uuidString: [retainedSegment]]
        )

        let decoded = try JSONDecoder().decode(MeetingNote.self, from: JSONEncoder().encode(note))

        #expect(decoded.retainedLiveDraftText(for: recordingID) == "Durable original draft")
        #expect(decoded.finalPassChallenges.first?.recordingID == recordingID)
    }

    @Test
    func meetingNoteResolvesRenamesAndMergesSpeakerIdentity() {
        let speakerA = MeetingSpeakerIdentity(displayName: "Alice")
        let speakerB = MeetingSpeakerIdentity(displayName: "Bob")
        var note = MeetingNote(
            transcriptSegments: [
                TranscriptSegment(text: "Hello", startTime: 0, endTime: 1, speaker: .systemAudio, speakerID: speakerA.id),
                TranscriptSegment(text: "Hi", startTime: 1, endTime: 2, speaker: .systemAudio, speakerID: speakerB.id)
            ],
            speakers: [speakerA, speakerB]
        )

        #expect(note.resolvedSpeakerLabel(for: note.transcriptSegments[0]) == "Alice")
        #expect(note.resolvedSpeakerLabel(for: note.transcriptSegments[1]) == "Bob")

        note.renameSpeaker(id: speakerA.id, to: "Alicia")
        #expect(note.resolvedSpeakerLabel(for: note.transcriptSegments[0]) == "Alicia")

        note.mergeSpeakers(from: speakerB.id, into: speakerA.id)
        #expect(note.resolvedSpeakerLabel(for: note.transcriptSegments[1]) == "Alicia")
        #expect(note.effectiveSpeakers.count == 1)
    }

    @Test
    func meetingNoteSplitsSpeakerIntoSeparateTurns() {
        let speaker = MeetingSpeakerIdentity(displayName: "Host")
        var note = MeetingNote(
            transcriptSegments: [
                TranscriptSegment(text: "One", startTime: 0, endTime: 1, speakerID: speaker.id),
                TranscriptSegment(text: "Two", startTime: 1, endTime: 2, speakerID: speaker.id)
            ],
            speakers: [speaker]
        )
        let firstTurnID = note.transcriptSegments[0].id

        let newID = note.splitSpeaker(from: speaker.id, named: "Guest", turnSegmentIDs: [firstTurnID])

        #expect(note.effectiveSpeakers.count == 2)
        #expect(note.resolvedSpeakerLabel(for: note.transcriptSegments[0]) == "Guest")
        #expect(note.resolvedSpeakerLabel(for: note.transcriptSegments[1]) == "Host")
        #expect(newID != nil)
    }

    @Test
    func meetingNoteAssignsProxyOnlyTurnToNewSpeakerIdentity() {
        var note = MeetingNote(
            transcriptSegments: [
                TranscriptSegment(text: "One", startTime: 0, endTime: 1, speaker: .systemAudio),
                TranscriptSegment(text: "Two", startTime: 1, endTime: 2, speaker: .systemAudio)
            ]
        )
        let firstTurnID = note.transcriptSegments[0].id

        let newID = note.assignSpeaker(named: "Guest", turnSegmentIDs: [firstTurnID])

        #expect(newID != nil)
        #expect(note.effectiveSpeakers.count == 1)
        #expect(note.resolvedSpeakerLabel(for: note.transcriptSegments[0]) == "Guest")
        #expect(note.resolvedSpeakerLabel(for: note.transcriptSegments[1]) == "System Audio")
    }

    @Test
    func meetingNoteIgnoresSpeakerEditsWithInvalidSpeakerIDs() {
        let speaker = MeetingSpeakerIdentity(displayName: "Host")
        var note = MeetingNote(
            transcriptSegments: [
                TranscriptSegment(text: "One", startTime: 0, endTime: 1, speakerID: speaker.id)
            ],
            speakers: [speaker]
        )
        let originalNote = note

        note.mergeSpeakers(from: speaker.id, into: UUID())
        #expect(note == originalNote)

        let splitID = note.splitSpeaker(from: UUID(), named: "Guest", turnSegmentIDs: [note.transcriptSegments[0].id])
        #expect(splitID == nil)
        #expect(note == originalNote)
    }

    @Test
    func meetingMarkdownPrefersResolvedSpeakerIdentityOverProxy() {
        let speaker = MeetingSpeakerIdentity(displayName: "Darsh")
        let note = MeetingNote(
            title: "Speaker Test",
            transcriptSegments: [
                TranscriptSegment(text: "Assigned line.", startTime: 0, endTime: 1, speaker: .user, speakerID: speaker.id),
                TranscriptSegment(text: "Proxy only line.", startTime: 1, endTime: 2, speaker: .systemAudio),
                TranscriptSegment(text: "Unlabeled line.", startTime: 2, endTime: 3)
            ],
            speakers: [speaker]
        )

        let markdown = MeetingMarkdownFormatter.markdown(for: note)

        #expect(markdown.contains("Darsh: Assigned line."))
        #expect(markdown.contains("System Audio: Proxy only line."))
        #expect(markdown.contains("- [00:02] Unlabeled line."))
    }

    @Test
    func finalTranscriptionServiceReplaysSavedRecordingAsSingleFinalSegment() async throws {
        let audioStore = try MeetingAudioStore(directoryURL: temporaryMeetingAudioStoreURL())
        let noteID = UUID()
        let recordingID = UUID()
        let recorder = try audioStore.makeRecorder(
            noteID: noteID,
            recordingID: recordingID,
            source: .systemAudio
        )
        let chunk = AudioChunk(
            samples: Array(repeating: 0.2, count: 8_000),
            frameCount: 8_000,
            sampleRate: 16_000
        )

        try await recorder.append(chunk, level: 0.2)
        let recording = await recorder.finish(fallbackMetrics: nil)

        let service = MeetingFinalTranscriptionService(
            audioStore: audioStore,
            makeEngine: { MockTranscriptionEngine() },
            readChunkFrames: 4_000
        )
        let segments = try await service.transcribe(
            recording: recording,
            configuration: TranscriptionConfiguration()
        )

        #expect(segments.count == 1)
        #expect(segments.first?.effectiveOrigin == .final)
        #expect(segments.first?.recordingID == recordingID)
        #expect(segments.first?.speaker == .systemAudio)
        #expect(segments.first?.captureSource == .systemAudio)
        #expect(segments.first?.text.contains("0.5 seconds") == true)
    }

    @Test
    func finalTranscriptionServiceSupportsFailureEmptyAndRepeatedSavedAudioRetries() async throws {
        let audioStore = try MeetingAudioStore(directoryURL: temporaryMeetingAudioStoreURL())
        let noteID = UUID()
        let recordingID = UUID()
        let otherRecordingID = UUID()
        let recorder = try audioStore.makeRecorder(
            noteID: noteID,
            recordingID: recordingID,
            source: .systemAudio
        )
        try await recorder.append(
            AudioChunk(samples: Array(repeating: 0.2, count: 4_000), frameCount: 4_000, sampleRate: 16_000),
            level: 0.2
        )
        let recording = await recorder.finish(fallbackMetrics: nil)
        let engine = SequencedTranscriptionEngine(outcomes: [
            .failure,
            .transcript(""),
            .transcript("First recovered final"),
            .transcript("Second recovered final")
        ])
        let service = MeetingFinalTranscriptionService(
            audioStore: audioStore,
            makeEngine: { engine }
        )

        var threw = false
        do {
            _ = try await service.transcribe(recording: recording, configuration: TranscriptionConfiguration())
        } catch {
            threw = true
        }
        #expect(threw)

        let emptySegments = try await service.transcribe(recording: recording, configuration: TranscriptionConfiguration())
        #expect(emptySegments.isEmpty)

        let firstSegments = try await service.transcribe(recording: recording, configuration: TranscriptionConfiguration())
        let secondSegments = try await service.transcribe(recording: recording, configuration: TranscriptionConfiguration())
        var note = MeetingNote(transcriptSegments: [
            TranscriptSegment(text: "Other recording", startTime: 0, endTime: 1, origin: .final, recordingID: otherRecordingID),
            TranscriptSegment(text: "Draft", startTime: 0, endTime: 1, origin: .liveDraft, recordingID: recordingID)
        ])
        note.applyFinalSegments(firstSegments, forRecording: recordingID)
        note.applyFinalSegments(secondSegments, forRecording: recordingID)

        #expect(note.transcriptSegments.map(\.text) == ["Other recording", "Second recovered final"])
        #expect(note.transcriptSegments.last?.recordingID == recordingID)
        #expect(note.retainedLiveDraftText(for: recordingID) == "Draft")
    }

    @Test
    func meetingNoteBlankDraftOnlyMatchesUntouchedNotes() {
        #expect(MeetingNote().isBlankDraft)
        #expect(!MeetingNote(title: "Customer Call").isBlankDraft)
        #expect(!MeetingNote(userNotes: "Real notes").isBlankDraft)
        #expect(!MeetingNote(transcriptSegments: [
            TranscriptSegment(text: "Real transcript", startTime: 0, endTime: 1)
        ]).isBlankDraft)
        #expect(!MeetingNote(summary: MeetingSummary(overview: "Real summary")).isBlankDraft)
        #expect(!MeetingNote(calendarEventID: "calendar-event").isBlankDraft)
    }

    @Test
    func systemAudioNoDisplayErrorIncludesEnvironmentDiagnostics() {
        let error = SystemAudioCaptureError.noDisplayAvailable(
            screenCount: 1,
            activeDisplayCount: 0,
            shareableDisplayCount: 0,
            applicationCount: 27
        )

        #expect(error.localizedDescription.contains("NSScreen=1"))
        #expect(error.localizedDescription.contains("CoreGraphics active displays=0"))
        #expect(error.localizedDescription.contains("ScreenCaptureKit displays=0"))
        #expect(error.localizedDescription.contains("apps=27"))
    }

    @Test
    func meetingNoteDerivesDisplayTitleFromContentWithoutOverwritingCustomTitles() {
        let transcriptBackedNote = MeetingNote(
            transcriptSegments: [
                TranscriptSegment(
                    text: "A specific domain of knowledge and just knowing it deeply.",
                    startTime: 0,
                    endTime: 4
                )
            ]
        )
        let customTitleNote = MeetingNote(
            title: "Customer Discovery",
            userNotes: "Procurement asked about audit logs."
        )

        #expect(transcriptBackedNote.displayTitle == "A specific domain of knowledge and just knowing it deeply.")
        #expect(transcriptBackedNote.suggestedTitle == "A specific domain of knowledge and just knowing it deeply.")
        #expect(customTitleNote.displayTitle == "Customer Discovery")
    }

    @Test
    func meetingNoteDoesNotUseTranscriptionFailureAsGeneratedTitle() {
        let note = MeetingNote(
            title: "Whisper did not return any transcript text.",
            transcriptSegments: [
                TranscriptSegment(
                    text: "Whisper did not return any transcript text.",
                    startTime: 0,
                    endTime: 0
                ),
                TranscriptSegment(
                    text: "I always like talking about how video cards compare in the GPU landscape.",
                    startTime: 10,
                    endTime: 14,
                    speaker: .systemAudio,
                    captureSource: .systemAudio
                )
            ]
        )

        #expect(note.usesDefaultTitle)
        #expect(note.displayTitle == "I always like talking about how video cards compare in the GP...")
        #expect(note.previewText == "I always like talking about how video cards compare in the GPU landscape.")
    }

    @Test
    func meetingNoteDoesNotUseEmptySummaryFallbackAsGeneratedTitle() {
        let note = MeetingNote(
            summary: MeetingSummary(overview: "Untitled Meeting has no meeting content yet.")
        )

        #expect(note.displayTitle == "Untitled Meeting")
        #expect(note.suggestedTitle == nil)
    }

    @Test
    func meetingCaptureSourcesDeclareSourceSpecificPermissions() {
        #expect(!MeetingCaptureSource.systemAudio.requiresMicrophone)
        #expect(MeetingCaptureSource.systemAudio.requiresScreenRecording)

        #expect(MeetingCaptureSource.microphone.requiresMicrophone)
        #expect(!MeetingCaptureSource.microphone.requiresScreenRecording)

        #expect(MeetingCaptureSource.microphoneAndSystemAudio.requiresMicrophone)
        #expect(MeetingCaptureSource.microphoneAndSystemAudio.requiresScreenRecording)
    }

    @Test
    @MainActor
    func meetingCaptureUsesFastRollingTranscriptionConfiguration() {
        let userConfiguration = TranscriptionConfiguration(
            model: .largeV3,
            decodingMode: .beamSearch,
            keepContext: true,
            trimSilence: false,
            normalizeAudio: false
        )

        let meetingConfiguration = AppModel.meetingCaptureTranscriptionConfiguration(from: userConfiguration)

        #expect(meetingConfiguration.model == .baseEnglish)
        #expect(meetingConfiguration.decodingMode == .greedy)
        #expect(!meetingConfiguration.keepContext)
        #expect(meetingConfiguration.trimSilence)
        #expect(meetingConfiguration.normalizeAudio)
    }

    @Test
    func meetingCapturePhasesUseUserFacingRecordingLanguage() {
        #expect(MeetingCapturePhase.starting.displayName == "Starting")
        #expect(MeetingCapturePhase.recording.displayName == "Recording")
        #expect(MeetingCapturePhase.finalizing.displayName == "Transcribing")
    }

    @Test
    func rollingMeetingTranscriptionEmitsBoundedSegments() async throws {
        let service = MeetingRollingTranscriptionService(
            engine: MockTranscriptionEngine(),
            windowDuration: 0.5
        )
        try await service.start(configuration: TranscriptionConfiguration())

        let firstChunk = AudioChunk(samples: Array(repeating: 0.1, count: 8_000), frameCount: 8_000, sampleRate: 16_000)
        let firstSegments = try await service.append(firstChunk, level: 0.2)
        let firstSegment = firstSegments.first

        #expect(firstSegment?.startTime == 0)
        #expect(firstSegment?.endTime == 0.5)
        #expect(firstSegment?.text.contains("0.5 seconds") == true)

        let secondChunk = AudioChunk(samples: Array(repeating: 0.1, count: 4_000), frameCount: 4_000, sampleRate: 16_000)
        let pendingSegments = try await service.append(secondChunk, level: 0.2)
        #expect(pendingSegments.isEmpty)

        let finalSegment = try await service.finish().first
        #expect(finalSegment?.startTime == 0.5)
        #expect(finalSegment?.endTime == 0.75)
        #expect(finalSegment?.text.contains("Cadence mock transcript") == true)
    }

    @Test
    func rollingMeetingTranscriptionFlushesShortLowLevelCaptureOnFinish() async throws {
        let service = MeetingRollingTranscriptionService(
            engine: MockTranscriptionEngine(),
            windowDuration: 30
        )
        try await service.start(configuration: TranscriptionConfiguration())

        let shortChunk = AudioChunk(samples: Array(repeating: 0.001, count: 4_000), frameCount: 4_000, sampleRate: 16_000)
        let pendingSegment = try await service.append(shortChunk, level: 0)

        #expect(pendingSegment.isEmpty)

        let finalSegment = try await service.finish().first
        #expect(finalSegment?.startTime == 0)
        #expect(finalSegment?.endTime == 0.25)
        #expect(finalSegment?.text.contains("0.2 seconds") == true)
    }

    @Test
    func rollingMeetingTranscriptionTreatsQuietCapturedFramesAsSpeechCandidate() async throws {
        let engine = SpeechMetricsRequiredTranscriptionEngine()
        let service = MeetingRollingTranscriptionService(
            engine: engine,
            windowDuration: 30
        )
        try await service.start(configuration: TranscriptionConfiguration())

        let quietChunk = AudioChunk(samples: Array(repeating: 0.0001, count: 4_000), frameCount: 4_000, sampleRate: 16_000)
        let pendingSegment = try await service.append(quietChunk, level: 0)

        #expect(pendingSegment.isEmpty)

        let finalSegment = try await service.finish().first
        let metrics = await engine.capturedMetrics()

        #expect(finalSegment?.text == "Quiet captured audio was transcribed")
        #expect(metrics?.speechDetected == true)
        #expect(metrics?.speechFrameCount == 4_000)
    }

    @Test
    func rollingMeetingTranscriptionKeepsLongChunksBoundedToWindowDuration() async throws {
        let service = MeetingRollingTranscriptionService(
            engine: MockTranscriptionEngine(),
            windowDuration: 0.5
        )
        try await service.start(configuration: TranscriptionConfiguration())

        let longChunk = AudioChunk(samples: Array(repeating: 0.1, count: 20_000), frameCount: 20_000, sampleRate: 16_000)
        let emittedSegments = try await service.append(longChunk, level: 0.2)
        let firstSegment = emittedSegments.first
        let secondSegment = emittedSegments.dropFirst().first

        #expect(emittedSegments.count == 2)
        #expect(firstSegment?.startTime == 0)
        #expect(firstSegment?.endTime == 0.5)
        #expect(secondSegment?.startTime == 0.5)
        #expect(secondSegment?.endTime == 1.0)

        let finalSegment = try await service.finish().first
        #expect(finalSegment?.startTime == 1.0)
        #expect(finalSegment?.endTime == 1.25)
    }

    @Test
    func rollingMeetingTranscriptionStreamsLongSessionsAcrossMultipleWindows() async throws {
        let service = MeetingRollingTranscriptionService(
            engine: MockTranscriptionEngine(),
            windowDuration: 2
        )
        try await service.start(configuration: TranscriptionConfiguration())

        var emittedSegments = [TranscriptSegment]()
        for _ in 0..<5 {
            let chunk = AudioChunk(samples: Array(repeating: 0.1, count: 16_000), frameCount: 16_000, sampleRate: 16_000)
            emittedSegments += try await service.append(chunk, level: 0.2)
        }
        emittedSegments += try await service.finish()

        #expect(emittedSegments.map(\.startTime) == [0, 2, 4])
        #expect(emittedSegments.map(\.endTime) == [2, 4, 5])
        #expect(emittedSegments.allSatisfy { $0.text.contains("Cadence mock transcript") })
    }

    @Test
    func rollingMeetingTranscriptionSerializesConcurrentChunkAppends() async throws {
        let engine = DelayedCountingTranscriptionEngine(delay: .milliseconds(50))
        let service = MeetingRollingTranscriptionService(
            engine: engine,
            windowDuration: 0.5
        )
        try await service.start(configuration: TranscriptionConfiguration())

        let chunk = AudioChunk(samples: Array(repeating: 0.1, count: 4_000), frameCount: 4_000, sampleRate: 16_000)
        var emittedSegments = [TranscriptSegment]()
        try await withThrowingTaskGroup(of: [TranscriptSegment].self) { group in
            for _ in 0..<4 {
                group.addTask {
                    try await service.append(chunk, level: 0.2)
                }
            }

            for try await segments in group {
                emittedSegments += segments
            }
        }
        emittedSegments += try await service.finish()

        let sortedSegments = emittedSegments.sorted { $0.startTime < $1.startTime }

        #expect(await engine.finishCount() == 2)
        #expect(sortedSegments.map(\.startTime) == [0, 0.5])
        #expect(sortedSegments.map(\.endTime) == [0.5, 1.0])
    }

    @Test
    func rollingMeetingTranscriptionSkipsEmptyWindowsAndContinues() async throws {
        let service = MeetingRollingTranscriptionService(
            engine: SequencedTranscriptionEngine(outcomes: [
                .failure,
                .transcript("Recovered meeting transcript")
            ]),
            windowDuration: 0.5
        )
        try await service.start(configuration: TranscriptionConfiguration())

        let firstChunk = AudioChunk(samples: Array(repeating: 0.1, count: 8_000), frameCount: 8_000, sampleRate: 16_000)
        let emptySegments = try await service.append(firstChunk, level: 0.2)
        #expect(emptySegments.isEmpty)

        let secondChunk = AudioChunk(samples: Array(repeating: 0.1, count: 8_000), frameCount: 8_000, sampleRate: 16_000)
        let recoveredSegments = try await service.append(secondChunk, level: 0.2)

        #expect(recoveredSegments.map(\.startTime) == [0.5])
        #expect(recoveredSegments.map(\.endTime) == [1.0])
        #expect(recoveredSegments.first?.text == "Recovered meeting transcript")
    }

    @Test
    func meetingTranscriptionFinalizerTimesOutSlowFinish() async throws {
        let service = MeetingRollingTranscriptionService(
            engine: SlowFinalizationTranscriptionEngine(delay: .seconds(2)),
            windowDuration: 1
        )
        try await service.start(configuration: TranscriptionConfiguration())
        let chunk = AudioChunk(samples: Array(repeating: 0.1, count: 4_000), frameCount: 4_000, sampleRate: 16_000)
        _ = try await service.append(chunk, level: 0.2)

        let startedAt = Date()
        let result = await MeetingTranscriptionFinalizer.finish(service: service, timeout: .milliseconds(50))

        #expect(result == .timedOut)
        #expect(Date().timeIntervalSince(startedAt) < 1)
    }

    @Test
    func meetingSummaryUsesNotesTranscriptAndActionMarkers() {
        let note = MeetingNote(
            title: "Launch Review",
            userNotes: """
            Launch is on track with one security follow-up.
            Decision: ship the private beta on Friday
            Action: Darsh - send the SOC 2 packet
            Open question: who owns customer enablement?
            """,
            transcriptSegments: [
                TranscriptSegment(
                    text: "The team discussed onboarding risk. Action: Priya - draft onboarding notes.",
                    startTime: 0,
                    endTime: 12
                )
            ]
        )

        let summary = MeetingSummaryService().generateSummary(for: note)

        #expect(summary.overview == "Launch is on track with one security follow-up.")
        #expect(summary.decisions == ["ship the private beta on Friday"])
        #expect(summary.actionItems.map(\.owner) == ["Darsh", "Priya"])
        #expect(summary.actionItems.map(\.text) == ["send the SOC 2 packet", "draft onboarding notes."])
        #expect(summary.openQuestions == ["who owns customer enablement?"])
        #expect(summary.followUpDraft.contains("Launch Review follow-up"))
    }

    @Test
    func meetingSummaryDoesNotInventDecisionsFromPlainTranscript() {
        let note = MeetingNote(
            transcriptSegments: [
                TranscriptSegment(
                    text: "The team explored model breadth and domain depth. No final calls were made.",
                    startTime: 0,
                    endTime: 6
                )
            ]
        )

        let summary = MeetingSummaryService().generateSummary(for: note)

        #expect(summary.overview == "The team explored model breadth and domain depth")
        #expect(summary.decisions.isEmpty)
        #expect(summary.actionItems.isEmpty)
    }

    @Test
    func meetingSummaryKeepsExplicitDecisionMarkers() {
        let note = MeetingNote(userNotes: "Decision: move launch to Friday")

        let summary = MeetingSummaryService().generateSummary(for: note)

        #expect(summary.decisions == ["move launch to Friday"])
    }

    @Test
    func meetingMarkdownIncludesSummaryNotesAndTranscript() {
        let note = MeetingNote(
            title: "Customer Call",
            userNotes: "Customer cares about audit logs.",
            transcriptSegments: [
                TranscriptSegment(text: "They asked for admin exports.", startTime: 65, endTime: 80),
                TranscriptSegment(
                    text: "I will send the packet.",
                    startTime: 82,
                    endTime: 88,
                    speaker: .user,
                    captureSource: .microphone
                )
            ],
            summary: MeetingSummary(
                overview: "Security-heavy customer call.",
                decisions: ["Send security materials"],
                actionItems: [MeetingActionItem(text: "Share audit log docs", owner: "Darsh")],
                openQuestions: ["Do they need SCIM?"],
                followUpDraft: "Hi all,\n\nSecurity-heavy customer call."
            ),
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 200)
        )

        let markdown = MeetingMarkdownFormatter.markdown(for: note)

        #expect(markdown.contains("# Customer Call"))
        #expect(markdown.contains("## Summary"))
        #expect(markdown.contains("- Darsh: Share audit log docs"))
        #expect(markdown.contains("## Notes"))
        #expect(markdown.contains("Customer cares about audit logs."))
        #expect(markdown.contains("- [01:05] They asked for admin exports."))
        #expect(markdown.contains("- [01:22] You: I will send the packet."))
    }

    @Test
    func meetingMarkdownCollapsesAdjacentDuplicateTranscriptSegments() {
        let note = MeetingNote(
            title: "Music Lesson",
            transcriptSegments: [
                TranscriptSegment(
                    text: "Play B flats in the bass as well.",
                    startTime: 25,
                    endTime: 30,
                    speaker: .systemAudio,
                    captureSource: .systemAudio
                ),
                TranscriptSegment(
                    text: "Play B flats in the bass as well.",
                    startTime: 30,
                    endTime: 35,
                    speaker: .systemAudio,
                    captureSource: .systemAudio
                )
            ]
        )

        let markdown = MeetingMarkdownFormatter.markdown(for: note)

        #expect(markdown.components(separatedBy: "Play B flats in the bass as well.").count == 2)
    }

    @Test
    func googleOAuthSessionUsesCalendarReadonlyScopeAndPKCE() throws {
        let service = GoogleCalendarService(tokenStore: InMemoryGoogleCalendarTokenStore())
        let configuration = GoogleCalendarOAuthConfiguration(
            clientID: "123-abc.apps.googleusercontent.com",
            redirectScheme: "com.googleusercontent.apps.123-abc"
        )

        let session = try service.makeAuthorizationSession(configuration: configuration)
        let components = URLComponents(url: session.authURL, resolvingAgainstBaseURL: false)
        let queryItems = Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).compactMap { item in
            item.value.map { (item.name, $0) }
        })

        #expect(queryItems["client_id"] == configuration.clientID)
        #expect(queryItems["redirect_uri"] == configuration.redirectURI)
        #expect(queryItems["access_type"] == "offline")
        #expect(queryItems["include_granted_scopes"] == "true")
        #expect(queryItems["code_challenge_method"] == "S256")
        #expect(queryItems["scope"]?.contains(GoogleCalendarOAuthConfiguration.calendarReadonlyScope) == true)
        #expect(queryItems["code_challenge"] == GoogleCalendarService.codeChallenge(for: session.codeVerifier))
    }

    @Test
    func googleOAuthConfigurationDerivesNativeRedirectScheme() {
        let configuration = GoogleCalendarOAuthConfiguration(clientID: "123-abc.apps.googleusercontent.com")

        #expect(configuration.redirectScheme == "com.googleusercontent.apps.123-abc")
        #expect(configuration.redirectURI == "com.googleusercontent.apps.123-abc:/oauth2redirect")
    }

    @Test
    func googleOAuthLoopbackReceiverAcceptsCallback() async throws {
        let receiver = try GoogleOAuthLoopbackRedirectReceiver.start()
        let callbackTask = Task {
            try await receiver.waitForCallback()
        }

        let response = try sendLoopbackCallback(
            port: try #require(receiver.redirectURI.port),
            path: "/oauth2redirect?code=abc&state=expected"
        )
        #expect(response.contains("200 OK"))
        #expect(try GoogleCalendarService.authorizationCode(from: try await callbackTask.value, expectedState: "expected") == "abc")
    }

    @Test
    func googleIDTokenEmailAppearsInConnectionState() throws {
        let store = InMemoryGoogleCalendarTokenStore()
        let service = GoogleCalendarService(tokenStore: store)
        let configuration = GoogleCalendarOAuthConfiguration(
            clientID: "123-abc.apps.googleusercontent.com",
            redirectScheme: "com.googleusercontent.apps.123-abc"
        )
        let idToken = makeUnsignedGoogleIDToken(email: "darsh@example.com")

        try store.saveTokenSet(
            GoogleCalendarTokenSet(
                accessToken: "access",
                refreshToken: "refresh",
                expiresAt: Date().addingTimeInterval(3600),
                idToken: idToken
            )
        )

        let state = service.connectionState(configuration: configuration)

        #expect(state.isConnected)
        #expect(state.accountEmail == "darsh@example.com")
        #expect(GoogleCalendarService.accountEmail(fromIDToken: idToken) == "darsh@example.com")
    }

    @Test
    func googleOAuthCallbackRequiresMatchingState() throws {
        let callbackURL = URL(string: "com.googleusercontent.apps.123:/oauth2redirect?code=abc&state=expected")!

        #expect(try GoogleCalendarService.authorizationCode(from: callbackURL, expectedState: "expected") == "abc")
        #expect(throws: GoogleCalendarError.authorizationStateMismatch) {
            try GoogleCalendarService.authorizationCode(from: callbackURL, expectedState: "other")
        }
    }

    @Test
    func googleCalendarConnectionStateReflectsStoredToken() throws {
        let store = InMemoryGoogleCalendarTokenStore()
        let service = GoogleCalendarService(tokenStore: store)
        let configuration = GoogleCalendarOAuthConfiguration(clientID: "123-abc.apps.googleusercontent.com")

        #expect(!service.connectionState(configuration: configuration).isConnected)

        try store.saveTokenSet(
            GoogleCalendarTokenSet(
                accessToken: "access",
                refreshToken: "refresh",
                expiresAt: Date().addingTimeInterval(3600),
                idToken: nil
            )
        )

        let state = service.connectionState(configuration: configuration)
        #expect(state.isConfigured)
        #expect(state.isConnected)
    }

    @Test
    func googleCalendarRefreshesExpiredTokenAndRequestsExplicitWindow() async throws {
        let tokenStore = InMemoryGoogleCalendarTokenStore()
        try tokenStore.saveTokenSet(
            GoogleCalendarTokenSet(
                accessToken: "expired-access",
                refreshToken: "refresh-token",
                expiresAt: Date(timeIntervalSince1970: 100),
                idToken: nil
            )
        )
        let recorder = CalendarRequestRecorder()
        let now = Date(timeIntervalSince1970: 1_800)
        let timeMax = now.addingTimeInterval(36 * 60 * 60)
        let formatter = ISO8601DateFormatter()
        CalendarMockURLProtocol.handler = { request in
            recorder.record(request)
            if request.url?.host == "oauth2.googleapis.com" {
                let body = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
                #expect(body.contains("grant_type=refresh_token"))
                return CalendarMockURLProtocol.response(
                    for: request,
                    json: #"{"access_token":"new-access","expires_in":3600}"#
                )
            }

            if request.url?.path == "/calendar/v3/users/me/calendarList" {
                return CalendarMockURLProtocol.response(
                    for: request,
                    json: """
                    {
                      "items": [
                        { "id": "primary@example.com" },
                        { "id": "team@example.com" }
                      ]
                    }
                    """
                )
            }

            let isTeamCalendar = request.url?.absoluteString.contains("team%40example.com") == true
            let eventJSON = """
            {
              "items": [
                {
                  "id": "\(isTeamCalendar ? "team-event" : "primary-event")",
                  "summary": "\(isTeamCalendar ? "Team Sync" : "Design Review")",
                  "htmlLink": "https://calendar.google.com/event",
                  "hangoutLink": "https://meet.google.com/abc-defg-hij",
                  "start": { "dateTime": "\(formatter.string(from: now.addingTimeInterval(isTeamCalendar ? 1200 : 600)))" },
                  "end": { "dateTime": "\(formatter.string(from: now.addingTimeInterval(isTeamCalendar ? 3000 : 2400)))" },
                  "attendees": [{ "email": "a@example.com" }, { "email": "b@example.com" }]
                }
              ]
            }
            """
            return CalendarMockURLProtocol.response(for: request, json: eventJSON)
        }
        defer { CalendarMockURLProtocol.handler = nil }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CalendarMockURLProtocol.self]
        let service = GoogleCalendarService(
            tokenStore: tokenStore,
            urlSession: URLSession(configuration: configuration)
        )

        let events = try await service.upcomingEvents(
            limit: 12,
            now: now,
            timeMax: timeMax,
            configuration: GoogleCalendarOAuthConfiguration(clientID: "123-abc.apps.googleusercontent.com")
        )
        let savedToken = try #require(tokenStore.currentTokenSet())
        let calendarListURL = try #require(recorder.requests.first { $0.url?.path == "/calendar/v3/users/me/calendarList" }?.url)
        let eventURLs = recorder.requests.compactMap(\.url).filter { $0.path.hasSuffix("/events") }
        let firstEventURL = try #require(eventURLs.first)
        let queryItems = Dictionary(uniqueKeysWithValues: (URLComponents(url: firstEventURL, resolvingAgainstBaseURL: false)?.queryItems ?? []).compactMap { item in
            item.value.map { (item.name, $0) }
        })

        #expect(savedToken.accessToken == "new-access")
        #expect(calendarListURL.path == "/calendar/v3/users/me/calendarList")
        #expect(eventURLs.count == 2)
        #expect(events.map(\.id) == ["primary-event", "team-event"])
        #expect(events.map(\.title) == ["Design Review", "Team Sync"])
        #expect(events.first?.meetingURL?.host() == "meet.google.com")
        #expect(queryItems["maxResults"] == "12")
        #expect(queryItems["timeMin"] == formatter.string(from: now))
        #expect(queryItems["timeMax"] == formatter.string(from: timeMax))
    }

    @Test
    func googleCalendarRefreshSurfacesCalendarAPIErrorMessage() async throws {
        let tokenStore = InMemoryGoogleCalendarTokenStore()
        try tokenStore.saveTokenSet(
            GoogleCalendarTokenSet(
                accessToken: "valid-access",
                refreshToken: nil,
                expiresAt: Date().addingTimeInterval(3600),
                idToken: nil
            )
        )
        CalendarMockURLProtocol.handler = { request in
            CalendarMockURLProtocol.response(
                for: request,
                json: """
                {
                  "error": {
                    "code": 403,
                    "message": "Google Calendar API has not been used in this project or it is disabled.",
                    "status": "PERMISSION_DENIED"
                  }
                }
                """,
                statusCode: 403
            )
        }
        defer { CalendarMockURLProtocol.handler = nil }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CalendarMockURLProtocol.self]
        let service = GoogleCalendarService(
            tokenStore: tokenStore,
            urlSession: URLSession(configuration: configuration)
        )

        do {
            _ = try await service.upcomingEvents(
                now: Date(timeIntervalSince1970: 1_800),
                configuration: GoogleCalendarOAuthConfiguration(clientID: "123-abc.apps.googleusercontent.com")
            )
            Issue.record("Expected Calendar API failures to preserve Google's error message.")
        } catch GoogleCalendarError.calendarRequestFailed(let message) {
            #expect(message == "Google Calendar API has not been used in this project or it is disabled.")
        } catch {
            Issue.record("Expected calendarRequestFailed, got \(error).")
        }
    }

    @Test
    func calendarEventCacheSavesLoadsSortsAndClearsEvents() throws {
        let store = CalendarEventCacheStore(directoryURL: temporaryCalendarCacheURL())
        let later = GoogleCalendarEvent(
            id: "later",
            title: "Later",
            startDate: Date(timeIntervalSince1970: 400),
            endDate: Date(timeIntervalSince1970: 500),
            meetingURL: nil,
            calendarURL: nil,
            attendeeEmails: []
        )
        let earlier = GoogleCalendarEvent(
            id: "earlier",
            title: "Earlier",
            startDate: Date(timeIntervalSince1970: 200),
            endDate: Date(timeIntervalSince1970: 300),
            meetingURL: nil,
            calendarURL: nil,
            attendeeEmails: []
        )

        try store.save(CalendarEventCache(
            generatedAt: Date(timeIntervalSince1970: 100),
            windowStart: Date(timeIntervalSince1970: 150),
            windowEnd: Date(timeIntervalSince1970: 600),
            events: [later, earlier]
        ))

        #expect(try store.load()?.events.map(\.id) == ["earlier", "later"])
        try store.delete()
        #expect(try store.load() == nil)
    }

    @Test
    func calendarDashboardGroupsTodayAndTomorrowOnly() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = ISO8601DateFormatter().date(from: "2026-07-03T10:00:00Z")!
        let pastToday = GoogleCalendarEvent(
            id: "past",
            title: "Past",
            startDate: ISO8601DateFormatter().date(from: "2026-07-03T08:00:00Z")!,
            endDate: ISO8601DateFormatter().date(from: "2026-07-03T08:30:00Z")!,
            meetingURL: nil,
            calendarURL: nil,
            attendeeEmails: []
        )
        let today = GoogleCalendarEvent(
            id: "today",
            title: "Today",
            startDate: ISO8601DateFormatter().date(from: "2026-07-03T12:00:00Z")!,
            endDate: ISO8601DateFormatter().date(from: "2026-07-03T12:30:00Z")!,
            meetingURL: nil,
            calendarURL: nil,
            attendeeEmails: []
        )
        let ongoingToday = GoogleCalendarEvent(
            id: "ongoing",
            title: "Ongoing",
            startDate: ISO8601DateFormatter().date(from: "2026-07-03T09:30:00Z")!,
            endDate: ISO8601DateFormatter().date(from: "2026-07-03T10:30:00Z")!,
            meetingURL: nil,
            calendarURL: nil,
            attendeeEmails: []
        )
        let tomorrow = GoogleCalendarEvent(
            id: "tomorrow",
            title: "Tomorrow",
            startDate: ISO8601DateFormatter().date(from: "2026-07-04T09:00:00Z")!,
            endDate: ISO8601DateFormatter().date(from: "2026-07-04T09:30:00Z")!,
            meetingURL: nil,
            calendarURL: nil,
            attendeeEmails: []
        )
        let later = GoogleCalendarEvent(
            id: "later",
            title: "Later",
            startDate: ISO8601DateFormatter().date(from: "2026-07-05T09:00:00Z")!,
            endDate: ISO8601DateFormatter().date(from: "2026-07-05T09:30:00Z")!,
            meetingURL: nil,
            calendarURL: nil,
            attendeeEmails: []
        )

        let groups = CalendarEventDashboard.groups(events: [later, tomorrow, pastToday, today, ongoingToday], now: now, calendar: calendar)

        #expect(groups.map(\.title) == ["Today", "Tomorrow"])
        #expect(groups.flatMap(\.events).map(\.id) == ["ongoing", "today", "tomorrow"])
    }

    @Test
    func calendarMeetingNoteTitlePrefixesEventDate() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let event = GoogleCalendarEvent(
            id: "standup",
            title: "Weekly Standup",
            startDate: ISO8601DateFormatter().date(from: "2026-07-03T15:00:00Z")!,
            endDate: ISO8601DateFormatter().date(from: "2026-07-03T15:30:00Z")!,
            meetingURL: nil,
            calendarURL: nil,
            attendeeEmails: []
        )

        #expect(CalendarEventDashboard.calendarMeetingNoteTitle(for: event, calendar: calendar) == "Jul 3 - Weekly Standup")
    }

    @Test
    func googleCalendarEventsDetectMeetingCandidatesNearStartTime() {
        let now = Date(timeIntervalSince1970: 1_000)
        let nearVideoMeeting = GoogleCalendarEvent(
            id: "meeting",
            title: "Design Review",
            startDate: now.addingTimeInterval(120),
            endDate: now.addingTimeInterval(1_920),
            meetingURL: URL(string: "https://meet.google.com/abc-defg-hij"),
            calendarURL: nil,
            attendeeEmails: ["a@example.com"]
        )
        let laterNonMeeting = GoogleCalendarEvent(
            id: "focus",
            title: "Focus Time",
            startDate: now.addingTimeInterval(3_600),
            endDate: now.addingTimeInterval(7_200),
            meetingURL: nil,
            calendarURL: nil,
            attendeeEmails: []
        )

        #expect(nearVideoMeeting.isMeetingCandidate)
        #expect(nearVideoMeeting.startsWithin(5 * 60, from: now))
        #expect(!laterNonMeeting.isMeetingCandidate)
        #expect(!laterNonMeeting.startsWithin(5 * 60, from: now))
    }

    @Test
    func meetingDetectionPromptsNearestEligibleUnpromptedEvent() {
        let now = Date(timeIntervalSince1970: 1_000)
        let alreadyPrompted = GoogleCalendarEvent(
            id: "prompted",
            title: "Already Prompted",
            startDate: now.addingTimeInterval(60),
            endDate: now.addingTimeInterval(1_800),
            meetingURL: URL(string: "https://meet.google.com/prompted"),
            calendarURL: nil,
            attendeeEmails: []
        )
        let eligible = GoogleCalendarEvent(
            id: "eligible",
            title: "Eligible",
            startDate: now.addingTimeInterval(120),
            endDate: now.addingTimeInterval(1_920),
            meetingURL: URL(string: "https://zoom.us/j/123"),
            calendarURL: nil,
            attendeeEmails: []
        )
        let tooLate = GoogleCalendarEvent(
            id: "late",
            title: "Late",
            startDate: now.addingTimeInterval(900),
            endDate: now.addingTimeInterval(1_500),
            meetingURL: URL(string: "https://meet.google.com/late"),
            calendarURL: nil,
            attendeeEmails: []
        )

        let detection = MeetingDetectionService(promptWindow: 5 * 60)
        let prompt = detection.nextPrompt(
            from: [tooLate, eligible, alreadyPrompted],
            now: now,
            promptedEventIDs: ["prompted"]
        )

        #expect(prompt?.id == "eligible")
    }

    @Test
    func meetingDetectionIgnoresNonMeetingEvents() {
        let now = Date(timeIntervalSince1970: 1_000)
        let focus = GoogleCalendarEvent(
            id: "focus",
            title: "Focus",
            startDate: now.addingTimeInterval(60),
            endDate: now.addingTimeInterval(1_800),
            meetingURL: nil,
            calendarURL: nil,
            attendeeEmails: []
        )

        let detection = MeetingDetectionService(promptWindow: 5 * 60)

        #expect(detection.nextPrompt(from: [focus], now: now, promptedEventIDs: []) == nil)
    }

    @Test
    func hudLogoIdleStateIsVisibleWithIdleVisualState() {
        let logoIdle = HUDState.logoIdle

        #expect(logoIdle.isVisible)
        #expect(logoIdle.visualState == .idle)
        #expect(logoIdle.subtitle == "")
        #expect(logoIdle.waveformLevels == Array(repeating: 0.0, count: 16))
    }

    @Test
    func hudIdleStateIsHiddenAndDistinctFromLogoIdle() {
        let hidden = HUDState.idle
        let logo = HUDState.logoIdle

        #expect(!hidden.isVisible)
        #expect(logo.isVisible)
        #expect(hidden.visualState != logo.visualState)
    }

    @Test
    func hudVisualStateIdleIsDistinctFromOtherCases() {
        #expect(HUDVisualState.idle != .preparingModel)
        #expect(HUDVisualState.idle != .transcribing)
        #expect(HUDVisualState.idle != .error(message: "test"))
        #expect(HUDVisualState.idle != .recording(triggerMode: .holdToTalk, showsHint: false))
    }

    @Test
    func hudPositionsRemainFullyRounded() {
        for position in HUDPosition.allCases {
            let radii = position.cornerRadii
            #expect(radii.topLeading > 0)
            #expect(radii.topTrailing > 0)
            #expect(radii.bottomLeading > 0)
            #expect(radii.bottomTrailing > 0)
        }
    }


    @Test
    func hudPositionBottomRightOriginUsesPhysicalScreenInset() {
        let screenFrame = NSRect(x: 0, y: 0, width: 1920, height: 1080)
        let visibleFrame = NSRect(x: 0, y: 70, width: 1920, height: 1010)
        let hudSize = NSSize(width: 44, height: 44)
        let origin = HUDPosition.bottomRight.origin(screenFrame: screenFrame, visibleFrame: visibleFrame, hudSize: hudSize)
        #expect(origin.x == screenFrame.maxX - hudSize.width - HUDMetrics.screenInset)
        #expect(origin.y == screenFrame.minY + HUDMetrics.screenInset)
    }

    @Test
    func hudPositionTopLeftOriginUsesPhysicalScreenInset() {
        let screenFrame = NSRect(x: 0, y: 0, width: 1920, height: 1080)
        let visibleFrame = NSRect(x: 0, y: 70, width: 1920, height: 986)
        let hudSize = NSSize(width: 44, height: 44)
        let origin = HUDPosition.topLeft.origin(screenFrame: screenFrame, visibleFrame: visibleFrame, hudSize: hudSize)
        #expect(origin.x == screenFrame.minX + HUDMetrics.screenInset)
        #expect(origin.y == screenFrame.maxY - hudSize.height - HUDMetrics.screenInset)
    }

    @Test
    func hudPositionNearestReturnsCorrectCorner() {
        let sf = NSRect(x: 0, y: 0, width: 1920, height: 1080)
        let vf = NSRect(x: 0, y: 70, width: 1920, height: 1010)
        let sz = NSSize(width: 44, height: 44)
        #expect(HUDPosition.nearest(to: NSPoint(x: 30, y: 1060), screenFrame: sf, visibleFrame: vf, hudSize: sz) == .topLeft)
        #expect(HUDPosition.nearest(to: NSPoint(x: 1900, y: 20), screenFrame: sf, visibleFrame: vf, hudSize: sz) == .bottomRight)
        #expect(HUDPosition.nearest(to: NSPoint(x: 960, y: 100), screenFrame: sf, visibleFrame: vf, hudSize: sz) == .bottomCenter)
    }

    @Test
    func hudPositionRoundTripsThroughRawValue() {
        for position in HUDPosition.allCases {
            #expect(HUDPosition(rawValue: position.rawValue) == position)
        }
    }

    @Test
    func hudPositionUnknownRawValueReturnsNil() {
        #expect(HUDPosition(rawValue: "nonexistent") == nil)
    }

    @Test
    func hudPositionBottomCenterOriginChangesWithDockHeight() {
        let sf = NSRect(x: 0, y: 0, width: 1920, height: 1080)
        let sz = NSSize(width: 44, height: 44)
        let o1 = HUDPosition.bottomCenter.origin(screenFrame: sf, visibleFrame: NSRect(x: 0, y: 70, width: 1920, height: 1010), hudSize: sz)
        let o2 = HUDPosition.bottomCenter.origin(screenFrame: sf, visibleFrame: NSRect(x: 0, y: 120, width: 1920, height: 960), hudSize: sz)
        #expect(o1.x == sf.midX - sz.width / 2)
        #expect(o2.x == sf.midX - sz.width / 2)
        #expect(o2.y > o1.y)
    }

    @Test
    func hudPositionBottomCenterStaysCenteredWithLeftDock() {
        let screenFrame = NSRect(x: 0, y: 0, width: 1920, height: 1080)
        let visibleFrame = NSRect(x: 80, y: 0, width: 1840, height: 1080)
        let hudSize = NSSize(width: 44, height: 44)

        let origin = HUDPosition.bottomCenter.origin(
            screenFrame: screenFrame,
            visibleFrame: visibleFrame,
            hudSize: hudSize
        )

        #expect(origin.x == screenFrame.midX - hudSize.width / 2)
        #expect(origin.y == visibleFrame.minY + HUDMetrics.screenInset)
    }

    @Test
    func hudPositionBottomCenterStaysCenteredWithRightDock() {
        let screenFrame = NSRect(x: 0, y: 0, width: 1920, height: 1080)
        let visibleFrame = NSRect(x: 0, y: 0, width: 1840, height: 1080)
        let hudSize = NSSize(width: 44, height: 44)

        let origin = HUDPosition.bottomCenter.origin(
            screenFrame: screenFrame,
            visibleFrame: visibleFrame,
            hudSize: hudSize
        )

        #expect(origin.x == screenFrame.midX - hudSize.width / 2)
        #expect(origin.y == visibleFrame.minY + HUDMetrics.screenInset)
    }

    @Test
    func hudPositionCornerOriginsUnaffectedByVisibleFrameChanges() {
        let sf = NSRect(x: 0, y: 0, width: 1920, height: 1080)
        let sz = NSSize(width: 44, height: 44)
        let o1 = HUDPosition.topLeft.origin(screenFrame: sf, visibleFrame: NSRect(x: 0, y: 70, width: 1920, height: 1010), hudSize: sz)
        let o2 = HUDPosition.topLeft.origin(screenFrame: sf, visibleFrame: NSRect(x: 0, y: 120, width: 1920, height: 960), hudSize: sz)
        #expect(o1 == o2)
    }


    @Test
    @MainActor
    func hudDropZoneViewModelStartsWithNilNearestZone() {
        let vm = HUDDropZoneViewModel()
        #expect(vm.nearestZone == nil)
    }

    @Test
    @MainActor
    func hudDropZoneViewModelUpdatesNearestZone() {
        let vm = HUDDropZoneViewModel()
        vm.nearestZone = .topLeft
        #expect(vm.nearestZone == .topLeft)
    }

    @Test
    func dragTooltipShownPersistsAndPreventsReTrigger() {
        let suite = "CadenceTests.dragTooltip.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = HUDDragTooltipStateStore(defaults: defaults)
        #expect(!store.hasBeenShown)
        store.markShown()
        #expect(store.hasBeenShown)
    }

    private func temporaryMeetingStoreURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("CadenceTests-\(UUID().uuidString)", isDirectory: true)
    }

    private func temporaryMeetingAudioStoreURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("CadenceAudioTests-\(UUID().uuidString)", isDirectory: true)
    }

    private func temporaryCalendarCacheURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("CadenceCalendarTests-\(UUID().uuidString)", isDirectory: true)
    }

    private func makeUnsignedGoogleIDToken(email: String) -> String {
        let header = base64URLData(#"{"alg":"none","typ":"JWT"}"#.data(using: .utf8) ?? Data())
        let payload = base64URLData(#"{"email":"\#(email)"}"#.data(using: .utf8) ?? Data())
        return "\(header).\(payload)."
    }

    private func base64URLData(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func sendLoopbackCallback(port: Int, path: String) throws -> String {
        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ENOTSOCK)
        }
        defer { close(socketFD) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let connectResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                connect(socketFD, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connectResult == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ECONNREFUSED)
        }

        let request = """
        GET \(path) HTTP/1.1\r
        Host: 127.0.0.1:\(port)\r
        Connection: close\r
        \r
        """
        try Data(request.utf8).withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var sentByteCount = 0
            while sentByteCount < rawBuffer.count {
                let result = send(
                    socketFD,
                    baseAddress.advanced(by: sentByteCount),
                    rawBuffer.count - sentByteCount,
                    0
                )
                guard result > 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                sentByteCount += result
            }
        }

        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let byteCount = buffer.withUnsafeMutableBytes { rawBuffer in
                recv(socketFD, rawBuffer.baseAddress, rawBuffer.count, 0)
            }
            if byteCount > 0 {
                response.append(buffer, count: byteCount)
            } else {
                break
            }
        }
        return String(data: response, encoding: .utf8) ?? ""
    }

    @Test
    @MainActor
    func soundFeedbackServiceDefaultsToEnabled() {
        let service = SoundFeedbackService()
        #expect(service.isEnabled)
    }

    @Test
    @MainActor
    func soundFeedbackServiceRespectsDisabledFlag() {
        let service = SoundFeedbackService(isEnabled: false)
        #expect(!service.isEnabled)
        service.playActivationSound()
    }

    @Test
    @MainActor
    func capturingFeedbackServiceRecordsActivationWhenEnabled() {
        let service = CapturingFeedbackService()
        service.isEnabled = true
        service.playActivationSound()
        #expect(service.activationSoundCallCount == 1)
    }

    @Test
    @MainActor
    func capturingFeedbackServiceSkipsActivationWhenDisabled() {
        let service = CapturingFeedbackService()
        service.isEnabled = false
        service.playActivationSound()
        #expect(service.activationSoundCallCount == 0)
    }

    @Test
    @MainActor
    func hudViewModelInjectsPulseOnVisibleIdleToRecordingTransition() {
        let viewModel = HUDViewModel()
        viewModel.reduceMotionProvider = { false }

        viewModel.apply(HUDState.logoIdle)

        let recordingState = HUDState(
            visualState: .recording(triggerMode: .holdToTalk, showsHint: false),
            subtitle: "",
            level: 0.1,
            waveformLevels: Array(repeating: 0.0, count: 16),
            isVisible: true,
            showsSubtitle: false
        )
        viewModel.apply(recordingState)

        #expect(viewModel.displayBars.contains { $0 > 0.1 })
    }

    @Test
    @MainActor
    func hudViewModelDoesNotReInjectPulseOnSubsequentUpdates() {
        let viewModel = HUDViewModel()
        viewModel.reduceMotionProvider = { false }

        let recordingState = HUDState(
            visualState: .recording(triggerMode: .holdToTalk, showsHint: false),
            subtitle: "",
            level: 0.1,
            waveformLevels: Array(repeating: 0.0, count: 16),
            isVisible: true,
            showsSubtitle: false
        )
        viewModel.apply(HUDState.logoIdle)
        viewModel.apply(recordingState)

        let firstBars = viewModel.displayBars

        viewModel.apply(recordingState)
        viewModel.apply(recordingState)

        for index in 0..<16 {
            #expect(viewModel.displayBars[index] <= firstBars[index] + 0.001)
        }
    }

    @Test
    @MainActor
    func hudViewModelResetsPulseFlagWhenReturningToIdleBetweenSessions() {
        let viewModel = HUDViewModel()
        viewModel.reduceMotionProvider = { false }

        let recordingState = HUDState(
            visualState: .recording(triggerMode: .holdToTalk, showsHint: false),
            subtitle: "",
            level: 0.1,
            waveformLevels: Array(repeating: 0.0, count: 16),
            isVisible: true,
            showsSubtitle: false
        )
        viewModel.apply(HUDState.logoIdle)
        viewModel.apply(recordingState)
        #expect(viewModel.displayBars.contains { $0 > 0.1 })

        viewModel.apply(HUDState(
            visualState: .success,
            subtitle: "",
            level: 0,
            waveformLevels: Array(repeating: 0.0, count: 16),
            isVisible: true,
            showsSubtitle: false
        ))
        viewModel.apply(HUDState.logoIdle)
        viewModel.setReducedMotion(true)
        #expect(viewModel.displayBars.allSatisfy { $0 == 0 })
        viewModel.setReducedMotion(false)

        viewModel.apply(recordingState)
        #expect(viewModel.displayBars.contains { $0 > 0.1 })
    }

    @Test
    @MainActor
    func hudViewModelSkipsPulseWhenReduceMotionActive() {
        let viewModel = HUDViewModel()
        viewModel.reduceMotionProvider = { true }

        let recordingState = HUDState(
            visualState: .recording(triggerMode: .holdToTalk, showsHint: false),
            subtitle: "",
            level: 0.1,
            waveformLevels: Array(repeating: 0.0, count: 16),
            isVisible: true,
            showsSubtitle: false
        )
        viewModel.apply(HUDState.logoIdle)
        viewModel.apply(recordingState)

        #expect(viewModel.displayBars.allSatisfy { $0 == 0 })
    }
}

private final class CapturingFeedbackService: FeedbackServing {
    var isEnabled: Bool = true
    private(set) var activationSoundCallCount = 0

    func playActivationSound() {
        guard isEnabled else { return }
        activationSoundCallCount += 1
    }
}

private final class CapturingAnalyticsSink: AnalyticsSink, @unchecked Sendable {
    private(set) var events = [AnalyticsEvent]()

    func send(_ event: AnalyticsEvent) {
        events.append(event)
    }
}

private final class InMemoryGoogleCalendarTokenStore: GoogleCalendarTokenStoring, @unchecked Sendable {
    private var tokenSet: GoogleCalendarTokenSet?

    func loadTokenSet() throws -> GoogleCalendarTokenSet? {
        tokenSet
    }

    func saveTokenSet(_ tokenSet: GoogleCalendarTokenSet) throws {
        self.tokenSet = tokenSet
    }

    func deleteTokenSet() throws {
        tokenSet = nil
    }

    func currentTokenSet() -> GoogleCalendarTokenSet? {
        tokenSet
    }
}

private final class CalendarRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var requests = [URLRequest]()

    func record(_ request: URLRequest) {
        lock.lock()
        requests.append(request)
        lock.unlock()
    }
}

private final class CalendarMockURLProtocol: URLProtocol, @unchecked Sendable {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            let (response, data) = try handler(Self.requestWithMaterializedBody(request))
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    private static func requestWithMaterializedBody(_ request: URLRequest) -> URLRequest {
        guard request.httpBody == nil, let stream = request.httpBodyStream else { return request }

        var request = request
        stream.open()
        defer { stream.close() }

        var body = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            body.append(buffer, count: count)
        }
        request.httpBody = body
        return request
    }

    static func response(for request: URLRequest, json: String, statusCode: Int = 200) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        return (response, Data(json.utf8))
    }
}

private final actor SequencedTranscriptionEngine: TranscriptionEngine {
    enum Outcome: Sendable {
        case failure
        case transcript(String)
    }

    private var outcomes: [Outcome]

    init(outcomes: [Outcome]) {
        self.outcomes = outcomes
    }

    func updateConfiguration(_ configuration: TranscriptionConfiguration) async throws {}

    func isPrepared() async -> Bool { true }

    func prepare() async throws {}

    func startSession() async throws {}

    func appendAudio(_ chunk: AudioChunk) async {}

    func previewTranscript() async -> PreviewTranscript? { nil }

    func finishSession(metrics: AudioCaptureSessionMetrics) async throws -> FinalTranscript {
        guard !outcomes.isEmpty else { throw WhisperEngineError.noTranscript }
        switch outcomes.removeFirst() {
        case .failure:
            throw WhisperEngineError.noTranscript
        case .transcript(let text):
            return FinalTranscript(rawText: text, cleanedText: text, duration: metrics.duration)
        }
    }

    func cancelSession() async {}

    func statusSummary() async -> String { "Sequenced transcription test engine" }
}

private actor IntCollector {
    private var values = [Int]()

    func append(_ value: Int) {
        values.append(value)
    }

    func snapshot() -> [Int] {
        values
    }
}

private final actor SpeechMetricsRequiredTranscriptionEngine: TranscriptionEngine {
    private var metrics: AudioCaptureSessionMetrics?

    func updateConfiguration(_ configuration: TranscriptionConfiguration) async throws {}

    func isPrepared() async -> Bool {
        true
    }

    func prepare() async throws {}

    func startSession() async throws {}

    func appendAudio(_ chunk: AudioChunk) async {}

    func previewTranscript() async -> PreviewTranscript? {
        nil
    }

    func finishSession(metrics: AudioCaptureSessionMetrics) async throws -> FinalTranscript {
        self.metrics = metrics
        guard metrics.speechDetected, metrics.speechFrameCount > 0 else {
            throw WhisperEngineError.emptyAudio
        }
        return FinalTranscript(
            rawText: "Quiet captured audio was transcribed",
            cleanedText: "Quiet captured audio was transcribed",
            duration: metrics.duration
        )
    }

    func cancelSession() async {}

    func statusSummary() async -> String {
        "Speech metrics required test engine"
    }

    func capturedMetrics() async -> AudioCaptureSessionMetrics? {
        metrics
    }
}

private final actor DelayedCountingTranscriptionEngine: TranscriptionEngine {
    private let delay: Duration
    private var finishSessionCount = 0

    init(delay: Duration) {
        self.delay = delay
    }

    func updateConfiguration(_ configuration: TranscriptionConfiguration) async throws {}

    func isPrepared() async -> Bool {
        true
    }

    func prepare() async throws {}

    func startSession() async throws {}

    func appendAudio(_ chunk: AudioChunk) async {}

    func previewTranscript() async -> PreviewTranscript? {
        nil
    }

    func finishSession(metrics: AudioCaptureSessionMetrics) async throws -> FinalTranscript {
        finishSessionCount += 1
        try? await Task.sleep(for: delay)
        return FinalTranscript(
            rawText: "Serialized window \(finishSessionCount)",
            cleanedText: "Serialized window \(finishSessionCount)",
            duration: metrics.duration
        )
    }

    func cancelSession() async {}

    func statusSummary() async -> String {
        "Delayed counting test engine"
    }

    func finishCount() async -> Int {
        finishSessionCount
    }
}

private final actor SlowFinalizationTranscriptionEngine: TranscriptionEngine {
    private let delay: Duration
    private var frameCount = 0
    private var sampleRate = 16_000.0

    init(delay: Duration) {
        self.delay = delay
    }

    func updateConfiguration(_ configuration: TranscriptionConfiguration) async throws {}

    func isPrepared() async -> Bool {
        true
    }

    func prepare() async throws {}

    func startSession() async throws {
        frameCount = 0
        sampleRate = 16_000
    }

    func appendAudio(_ chunk: AudioChunk) async {
        frameCount += chunk.frameCount
        sampleRate = chunk.sampleRate
    }

    func previewTranscript() async -> PreviewTranscript? {
        nil
    }

    func finishSession(metrics: AudioCaptureSessionMetrics) async throws -> FinalTranscript {
        try? await Task.sleep(for: delay)
        let duration = Double(frameCount) / max(sampleRate, 1)
        return FinalTranscript(
            rawText: "Slow transcript",
            cleanedText: "Slow transcript",
            duration: duration
        )
    }

    func cancelSession() async {
        frameCount = 0
    }

    func statusSummary() async -> String {
        "Slow finalization test engine"
    }
}

struct IdleExpandedTrayTests {
    @Test
    @MainActor
    func hudViewModelIsExpandedDefaultsToFalse() {
        let model = HUDViewModel()
        #expect(model.isExpanded == false)
    }

    @Test
    @MainActor
    func toggleExpandedFlipsStateAndFiresCallback() {
        let model = HUDViewModel()
        var callbacks: [Bool] = []
        model.onExpandToggle = { callbacks.append($0) }

        model.toggleExpanded()
        #expect(model.isExpanded == true)
        model.toggleExpanded()
        #expect(model.isExpanded == false)
        #expect(callbacks == [true, false])
    }

    @Test
    @MainActor
    func setExpandedOnlyFiresWhenChanged() {
        let model = HUDViewModel()
        var callCount = 0
        model.onExpandToggle = { _ in callCount += 1 }

        model.setExpanded(false)
        #expect(callCount == 0)
        model.setExpanded(true)
        #expect(callCount == 1)
        model.setExpanded(true)
        #expect(callCount == 1)
    }

    @Test
    @MainActor
    func applyAutoCollapsesWhenLeavingIdle() {
        let model = HUDViewModel()
        model.apply(.logoIdle)
        model.setExpanded(true)
        #expect(model.isExpanded == true)

        model.apply(HUDState(
            visualState: .recording(triggerMode: .holdToTalk, showsHint: false),
            subtitle: "", level: 0, waveformLevels: [], isVisible: true, showsSubtitle: false
        ))

        #expect(model.isExpanded == false)
    }

    @Test
    @MainActor
    func applyDoesNotCollapseWhenStayingIdle() {
        let model = HUDViewModel()
        model.setExpanded(true)

        model.apply(.logoIdle)

        #expect(model.isExpanded == true)
    }

    @Test
    func hudVisualStateIdleIsDistinctFromOtherCases() {
        #expect(HUDVisualState.idle != .recording(triggerMode: .holdToTalk, showsHint: false))
        #expect(HUDVisualState.idle != .preparingModel)
        #expect(HUDVisualState.idle != .transcribing)
    }

    @Test
    func hudStateLogoIdleIsVisible() {
        #expect(HUDState.logoIdle.isVisible == true)
        #expect(HUDState.logoIdle.visualState == .idle)
    }

    @Test
    func hudStateIdleIsTrulyHidden() {
        #expect(HUDState.idle.isVisible == false)
        #expect(HUDState.logoIdle.isVisible == true)
    }
}

struct TapDragDisambiguationTests {
    @Test
    func zeroMovementPointerSequenceIsAClick() {
        var tracker = HUDLogoPointerTracker()
        tracker.begin(at: NSPoint(x: 100, y: 200))

        #expect(tracker.end(at: NSPoint(x: 100, y: 200)) == .click)
    }

    @Test
    func movementBelowThresholdRemainsAClick() {
        var tracker = HUDLogoPointerTracker()
        tracker.begin(at: NSPoint(x: 100, y: 200))

        #expect(tracker.update(to: NSPoint(x: 102, y: 201)) == false)
        #expect(tracker.end(at: NSPoint(x: 102, y: 201)) == .click)
    }

    @Test
    func globalPointerMovementAtThresholdBeginsDrag() {
        var tracker = HUDLogoPointerTracker()
        tracker.begin(at: NSPoint(x: -50, y: 400))

        #expect(tracker.update(to: NSPoint(x: -46, y: 400)) == true)
        #expect(tracker.end(at: NSPoint(x: -46, y: 400)) == .drag)
    }

    @Test
    func verticalScreenCoordinatesKeepAppKitDirection() {
        var tracker = HUDLogoPointerTracker()
        tracker.begin(at: NSPoint(x: 100, y: 300))

        #expect(tracker.update(to: NSPoint(x: 100, y: 320)) == true)
        #expect(tracker.end(at: NSPoint(x: 100, y: 320)) == .drag)
    }

    @Test
    @MainActor
    func collapsedIdleForwardsInteractionButExpandedTrayDoesNot() {
        let model = HUDViewModel()
        var events: [HUDLogoInteractionEvent] = []
        model.onLogoInteraction = { events.append($0) }
        model.apply(.logoIdle)

        model.handleLogoInteraction(.clicked)
        #expect(events == [.clicked])

        model.setExpanded(true)
        model.handleLogoInteraction(.began(NSPoint(x: 1, y: 1)))
        #expect(events == [.clicked])
    }
}

struct HUDPanelLayoutTests {
    @Test
    func expansionComputesOneAnchoredTargetFrame() {
        let screen = NSRect(x: 0, y: 0, width: 1920, height: 1080)
        let visible = NSRect(x: 0, y: 40, width: 1920, height: 1016)
        let frame = HUDPanelLayout.targetFrame(
            position: .bottomCenter,
            screenFrame: screen,
            visibleFrame: visible,
            size: NSSize(width: 240, height: 38)
        )

        #expect(frame == NSRect(
            x: visible.midX - 120,
            y: visible.minY + HUDMetrics.screenInset,
            width: 240,
            height: 38
        ))
    }

    @Test
    func targetFrameSupportsNegativeScreenOrigins() {
        let screen = NSRect(x: -1440, y: 120, width: 1440, height: 900)
        let visible = NSRect(x: -1440, y: 120, width: 1440, height: 876)
        let frame = HUDPanelLayout.targetFrame(
            position: .topRight,
            screenFrame: screen,
            visibleFrame: visible,
            size: NSSize(width: 44, height: 44)
        )

        #expect(frame == NSRect(
            x: screen.maxX - 44 - HUDMetrics.screenInset,
            y: screen.maxY - 44 - HUDMetrics.screenInset,
            width: 44,
            height: 44
        ))
    }

    @Test
    @MainActor
    func reducedMotionStateIsUsedByRuntimeViewModel() {
        let model = HUDViewModel()
        model.reduceMotionProvider = { false }
        model.setReducedMotion(true)

        #expect(model.isReducedMotionEnabled)
        #expect(!HUDPanelTransition.shouldAnimate(reduceMotion: model.isReducedMotionEnabled))
        #expect(HUDPanelTransition.shouldAnimate(reduceMotion: false))
    }

    @Test
    func dragGeometryUsesStableGlobalScreenDeltasWithoutFlippingY() {
        let origin = HUDDragGeometry.origin(
            startOrigin: NSPoint(x: 500, y: 300),
            startPointer: NSPoint(x: 800, y: 400),
            currentPointer: NSPoint(x: 760, y: 475)
        )

        #expect(origin == NSPoint(x: 460, y: 375))
    }

    @Test
    func positionStoreDefaultsToBottomRightAndPersistsSnapSelection() {
        let suite = "HUDPositionStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = HUDPositionStore(defaults: defaults)

        #expect(store.load() == .bottomRight)
        store.save(.topLeft)
        #expect(HUDPositionStore(defaults: defaults).load() == .topLeft)
    }
}

struct AppActivationPolicyTests {
    @Test
    func launchAndDockReopenOpenTheMainWindow() {
        #expect(AppActivationPolicy.shouldOpenMainWindow(for: .launch))
        #expect(AppActivationPolicy.shouldOpenMainWindow(for: .dockReopen))
    }

    @Test
    func incidentalActivationDoesNotOpenTheMainWindow() {
        #expect(!AppActivationPolicy.shouldOpenMainWindow(for: .becameActive))
    }

    @Test @MainActor
    func applicationTerminationInvokesRegisteredServiceShutdown() {
        var shutdownCount = 0
        let previous = AppDelegate.shutdownApplicationServices
        AppDelegate.shutdownApplicationServices = { shutdownCount += 1 }
        defer { AppDelegate.shutdownApplicationServices = previous }

        AppDelegate().applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))

        #expect(shutdownCount == 1)
    }
}

struct HUDHideDurationTests {
    @Test
    func tenMinutesIs600Seconds() {
        #expect(HUDHideDuration.tenMinutes.seconds == 600)
    }

    @Test
    func oneHourIs3600Seconds() {
        #expect(HUDHideDuration.oneHour.seconds == 3600)
    }

    @Test
    func untilNextSessionHasNilSeconds() {
        #expect(HUDHideDuration.untilNextSession.seconds == nil)
    }

    @Test
    func allCasesContainThreeOptions() {
        #expect(HUDHideDuration.allCases.count == 3)
    }

    @Test
    func displayNamesAreHumanReadable() {
        #expect(HUDHideDuration.tenMinutes.displayName == "Hide for 10 minutes")
        #expect(HUDHideDuration.oneHour.displayName == "Hide for 1 hour")
        #expect(HUDHideDuration.untilNextSession.displayName == "Hide until next session")
    }
}
