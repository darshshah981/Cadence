import Foundation
import Testing
@testable import Cadence

@MainActor
struct ComposeTextEditWritingDefaultsTests {
    @Test
    func savedTextEditChoicesReachOnlyPinnedTextEditAndVoiceStillWins() throws {
        let suite = "cadence-textedit-defaults-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let archive = ComposeScopedWritingPreferenceArchive(defaults: defaults, key: "scoped-writing")
        let store = ComposeTextEditWritingDefaultsStore(archive: archive, localUserID: 501)
        let now = Date(timeIntervalSince1970: 2_000)
        let initial = try store.load(now: now)
        #expect(initial == .init())
        let choices = ComposeTextEditWritingDefaults(tone: .warm, preferConcise: true)
        try store.save(choices, replacing: initial, now: now)
        let restarted = ComposeTextEditWritingDefaultsStore(archive: archive, localUserID: 501)
        #expect(try restarted.load(now: now) == choices)

        let target = application(bundle: "com.apple.TextEdit", path: "/System/Applications/TextEdit.app")
        #expect(try restarted.values(for: target, now: now) == [.tone(.warm), .concise])
        #expect(try restarted.values(
            for: application(bundle: "com.example.Other", path: "/Applications/Other.app"), now: now
        ).isEmpty)
        #expect(try restarted.values(
            for: application(bundle: "com.apple.TextEdit", path: "/Applications/Impostor.app"), now: now
        ).isEmpty)
        #expect(try ComposeTextEditWritingDefaultsStore(
            archive: archive, localUserID: 502
        ).values(for: target, now: now).isEmpty)

        let resolved = ComposePreferenceResolver.combining(
            global: [.tone(.formal)], application: try restarted.values(for: target, now: now)
        )
        #expect(resolved == [.tone(.warm), .concise])
        let input = try ScribeRequestPolicy.providerSafeInput(
            for: .init(intent: .compose,
                       spokenTranscript: "Hey, how are you? Write this formally.",
                       writingDefaults: resolved),
            destination: .legacyLocal
        )
        #expect(input.systemMessage.contains(ScribeWritingDirection.tone(.formal).instruction))
        #expect(!input.userMessage.contains(ScribeWritingDirection.tone(.warm).instruction))
        #expect(input.userMessage.contains(ScribeWritingDirection.concise.instruction))
    }

    @Test
    func staleSavePreservesAcceptedChoiceAndResetRemovesOnlyTextEdit() throws {
        let suite = "cadence-textedit-defaults-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let archive = ComposeScopedWritingPreferenceArchive(defaults: defaults, key: "scoped-writing")
        let store = ComposeTextEditWritingDefaultsStore(archive: archive, localUserID: 501)
        let now = Date(timeIntervalSince1970: 2_000)
        let initial = try store.load(now: now)
        let formal = ComposeTextEditWritingDefaults(tone: .formal)
        try store.save(formal, replacing: initial, now: now)
        #expect(throws: ComposeScopedWritingPreferenceArchiveError.staleEdit) {
            try store.save(.init(tone: .warm), replacing: initial, now: now)
        }
        #expect(try store.load(now: now) == formal)
        try store.reset(replacing: formal, now: now.addingTimeInterval(1))
        #expect(try store.load(now: now.addingTimeInterval(1)) == .init())
        #expect(try archive.load().preferences.isEmpty)
    }

    @Test
    func configuredTextEditProfileTakesPriorityOverSavedTextEditChoices() throws {
        let descriptor = InstalledApplicationDescriptor(
            bundleURL: URL(fileURLWithPath: "/System/Applications/TextEdit.app"),
            bundleIdentifier: ScribeTextEditDocumentIdentityAdapter.bundleIdentifier,
            displayName: "TextEdit", version: nil, build: nil,
            isInstalled: true, isRunning: false
        )
        let configuration = try ApplicationConfiguration(
            application: .init(
                bundleIdentifier: descriptor.bundleIdentifier,
                lastKnownBundleURL: descriptor.bundleURL,
                lastKnownDisplayName: descriptor.displayName
            ),
            isEnabled: true, familyID: .general,
            presetSelection: .familyDefault,
            customGuidance: try ScribeCustomGuidance("Use formal wording."),
            revision: 1
        )
        let guidance = ScribeGuidanceResolver.resolve(
            application: .exact(descriptor), adaptationEnabled: true,
            configurationLoadResult: .valid(.init(revision: 1, configurations: [configuration])),
            presetState: .valid(.generalNeutral)
        )
        #expect(guidance.resolutionSource == .configuredApplication)
        let savedTextEditChoices = ComposeTextEditWritingDefaults(
            tone: .warm, preferConcise: true
        ).values
        let request = ScribeRequest(
            intent: .compose, spokenTranscript: "The draft is ready.",
            resolvedGuidance: guidance, writingDefaults: savedTextEditChoices
        )
        #expect(request.effectiveWritingDefaults.isEmpty)
        let input = try ScribeRequestPolicy.providerSafeInput(for: request, destination: .legacyLocal)
        #expect(input.userMessage.contains("Use formal wording."))
        #expect(!input.userMessage.contains(ScribeWritingDirection.tone(.warm).instruction))
        #expect(!input.userMessage.contains(ScribeWritingDirection.concise.instruction))
    }

    private func application(bundle: String, path: String) -> ApplicationTargetCapture {
        .init(
            process: .init(
                processIdentifier: 100, bundleIdentifier: bundle,
                bundleURL: URL(fileURLWithPath: path), incarnation: UUID()
            ),
            identityRevision: 1, captureRevision: 1,
            source: .scribeAccessibility
        )
    }
}
